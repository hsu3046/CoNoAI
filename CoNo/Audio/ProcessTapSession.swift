// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Core Audio process tap + 비공개(private) 애그리게이트 디바이스 수명 관리 (캡처 전용).
// 탭 구성은 insidegui/AudioCap (BSD-2-Clause), 탭만 넣은 애그리게이트는 makeusabrew/audiotee 를 참고했다.
//
// 애그리게이트 = [탭] 만 (서브디바이스 없음) → 탭의 원래 레이트(예: 48 kHz)로 입력만 받는다.
// 예전처럼 출력 장치를 같은 애그리게이트에 넣으면, 출력 장치 레이트(예: 96 kHz)가 다를 때 HAL 이
// 드리프트 보정으로 2배 변환을 하며 불규칙한 틱 소리가 났다 (docs/DECISIONS.md). 재생은 PlaybackOutput 이 따로 한다.
// muteBehavior = .mutedWhenTapped 이면 대상 앱 소리는 탭을 읽는 동안에만 스피커로 안 나간다.
// CoNo 가 멈추거나 죽으면 원래 소리가 자동으로 돌아온다.

import AudioToolbox
import Foundation
import OSLog

/// 준비(prepare)와 시작(start)은 백그라운드에서 호출해도 된다 — 시작은 오디오 권한 응답까지 블록될 수 있다.
final class ProcessTapSession: @unchecked Sendable {
    private let logger = Logger(subsystem: "space.knowai.cono", category: "ProcessTapSession")

    private(set) var tapID = AudioObjectID.unknown
    private(set) var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    /// 탭이 내보내는 포맷
    private(set) var tapFormat = AudioStreamBasicDescription()
    /// 애그리게이트(=캡처) 클럭의 샘플레이트. 보통 탭 포맷과 같다.
    private(set) var captureSampleRate: Double = 0

    /// 탭과 애그리게이트 디바이스를 만든다. 실패 시 만든 것까지 정리하고 throw.
    func prepare(source: AudioSource, muteOriginal: Bool) throws {
        do {
            try createTap(source: source, muteOriginal: muteOriginal)
            try createAggregateDevice()
        } catch {
            teardown()
            throw error
        }
    }

    private func createTap(source: AudioSource, muteOriginal: Bool) throws {
        let description: CATapDescription
        switch source.kind {
        case let .app(processObjectIDs):
            guard !processObjectIDs.isEmpty else { throw CoreAudioError("선택한 앱에 오디오 프로세스가 없습니다") }
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        case .systemWide:
            // 자기 자신을 제외하지 못하면 CoNo 출력이 다시 탭으로 들어가 무한 에코가 된다 → fail-closed
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownObjectID: AudioObjectID
            do {
                ownObjectID = try AudioObjectID.translatePIDToProcessObjectID(ownPID)
            } catch {
                throw CoreAudioError("CoNo 자신을 캡처 대상에서 제외할 수 없어 시스템 전체 캡처를 시작하지 않습니다 (피드백 루프 방지). 앱을 직접 선택해 주세요.")
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownObjectID])
        }
        description.uuid = UUID()
        description.name = "CoNo Tap"
        description.isPrivate = true
        description.muteBehavior = muteOriginal ? .mutedWhenTapped : .unmuted

        var newTapID = AudioObjectID.unknown
        let err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID.isValid else {
            throw CoreAudioError("프로세스 탭 생성 실패", status: err)
        }
        tapID = newTapID
        tapFormat = try newTapID.readTapStreamDescription()
        logger.info("tap #\(newTapID) created, format \(self.tapFormat.mSampleRate) Hz / \(self.tapFormat.mChannelsPerFrame) ch")

        // 애그리게이트 구성에 탭 UUID 가 필요하므로 보관
        tapUUID = description.uuid.uuidString
    }

    private var tapUUID = ""

    private func createAggregateDevice() throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoNo Capture",
            kAudioAggregateDeviceUIDKey: "space.knowai.cono.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // 원본 앱이 멈춰도 IO 를 계속 돌려 무음을 받는다 → 재생 지연이 일정하게 유지된다
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: false,
                    kAudioSubTapUIDKey: tapUUID,
                ],
            ],
        ]

        var newDeviceID = AudioObjectID.unknown
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard err == noErr, newDeviceID.isValid else {
            throw CoreAudioError("애그리게이트 디바이스 생성 실패", status: err)
        }
        aggregateDeviceID = newDeviceID
        captureSampleRate = (try? newDeviceID.readNominalSampleRate()).flatMap { $0 > 0 ? $0 : nil } ?? tapFormat.mSampleRate
        logger.info("capture aggregate #\(newDeviceID) @ \(self.captureSampleRate) Hz (tap \(self.tapFormat.mSampleRate) Hz)")
    }

    /// IOProc 을 등록하고 시작. 블록은 오디오 IO 스레드에서 직접 호출된다 (dispatch queue 없음).
    func start(ioBlock: @escaping AudioDeviceIOBlock) throws {
        guard aggregateDeviceID.isValid else { throw CoreAudioError("애그리게이트 디바이스가 준비되지 않았습니다") }

        var procID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock)
        guard err == noErr, let procID else { throw CoreAudioError("IOProc 생성 실패", status: err) }
        ioProcID = procID

        err = AudioDeviceStart(aggregateDeviceID, procID)
        guard err == noErr else { throw CoreAudioError("오디오 디바이스 시작 실패", status: err) }
    }

    /// 역순 정리: IO 정지 → IOProc 제거 → 애그리게이트 제거 → 탭 제거. 여러 번 불러도 안전.
    func teardown() {
        if aggregateDeviceID.isValid {
            if let ioProcID {
                var err = AudioDeviceStop(aggregateDeviceID, ioProcID)
                if err != noErr { logger.warning("AudioDeviceStop failed: \(err)") }
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                if err != noErr { logger.warning("AudioDeviceDestroyIOProcID failed: \(err)") }
                self.ioProcID = nil
            }
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { logger.warning("AudioHardwareDestroyAggregateDevice failed: \(err)") }
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr { logger.warning("AudioHardwareDestroyProcessTap failed: \(err)") }
            tapID = .unknown
        }
    }

    deinit {
        teardown()
    }
}
