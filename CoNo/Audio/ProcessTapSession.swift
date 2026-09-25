// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// Core Audio process tap + 비공개(private) 애그리게이트 디바이스 수명 관리.
// 탭/애그리게이트 구성은 insidegui/AudioCap (BSD-2-Clause) 의 ProcessTap.swift 를 참고했다.
//
// 애그리게이트 = [메인 서브디바이스: 현재 기본 출력 장치] + [탭].
// 한 IOProc 안에서 탭 입력을 받고 같은 클럭으로 출력 장치에 쓴다 → 별도 출력 엔진·클럭 동기화가 필요 없다.
// muteBehavior = .mutedWhenTapped 이면 대상 앱 소리는 탭을 읽는 동안에만 스피커로 안 나간다.
// CoNo 가 멈추거나 죽으면 원래 소리가 자동으로 돌아온다.

import AudioToolbox
import Foundation
import OSLog

final class ProcessTapSession {
    private let logger = Logger(subsystem: "space.knowai.cono", category: "ProcessTapSession")

    private(set) var tapID = AudioObjectID.unknown
    private(set) var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    /// 탭이 내보내는 포맷
    private(set) var tapFormat = AudioStreamBasicDescription()
    /// 출력(=애그리게이트 클럭) 샘플레이트
    private(set) var outputSampleRate: Double = 0
    private(set) var outputDeviceName = ""

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
        let outputDeviceID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputDeviceID.readDeviceUID()
        outputSampleRate = try outputDeviceID.readNominalSampleRate()
        outputDeviceName = (try? outputDeviceID.readString(kAudioObjectPropertyName)) ?? outputUID

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoNo Aggregate",
            kAudioAggregateDeviceUIDKey: "space.knowai.cono.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
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
        logger.info("aggregate #\(newDeviceID) created on output '\(self.outputDeviceName)' @ \(self.outputSampleRate) Hz")
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
