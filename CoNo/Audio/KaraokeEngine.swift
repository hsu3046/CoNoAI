// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// UI 가 쓰는 파사드: 탭 세션 + 지연 파이프라인 + (AI 모드) 분리 모델을 묶어 시작/정지하고 통계를 갱신한다.

import AudioToolbox
import AVFoundation
import Foundation
import Observation

/// AI 분리 설정 (초 단위, 시작할 때 고정)
struct SeparationSettings: Equatable, Sendable {
    var backend: InferenceBackend = .coreMLAll
    /// 몇 초마다 새로 분리할지 — 추론 1회 시간보다 길어야 한다
    var stepSeconds: Double = 1.0
    /// 사용 구간 뒤에 남겨 둘 미래 문맥 — 길수록 품질 ↑ 지연 ↑
    var rightContextSeconds: Double = 1.0

    /// 모델 레이트 기준 샘플 설정
    func streamingSettings(for config: MDXModelConfig) -> StreamingSeparatorSettings {
        let rate = config.sampleRate
        return StreamingSeparatorSettings(
            step: Int(stepSeconds * rate),
            rightContext: Int(rightContextSeconds * rate),
            fade: 2_048
        )
    }
}

/// 모델 로드 + 추론 속도 실측 결과
struct ModelBenchmark: Sendable, Equatable {
    var backend: InferenceBackend
    var loadSeconds: Double
    /// 첫 추론 (CoreML 은 여기서 컴파일·워밍업)
    var firstInferenceMilliseconds: Double
    /// 워밍업 뒤 평균 (전후처리 포함)
    var steadyInferenceMilliseconds: Double
    /// 워밍업 뒤 평균 중 모델 실행만
    var steadyModelMilliseconds: Double
    /// SwiftF0 자가진단: 220 Hz 사인파에서 검출한 음정 (nil = 실패, 사유는 pitchSelfTestError)
    var pitchSelfTestHz: Double?
    var pitchSelfTestError: String?
}

/// 곡이 끝났을 때 보여줄 채점 결과
struct SingingResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String?
    let artist: String?
    let score: SongScore
}

@MainActor
@Observable
final class KaraokeEngine {
    enum Status: Equatable {
        case idle
        /// 탭·장치 준비 중 (첫 실행 땐 오디오 권한 응답을 기다릴 수 있다)
        case starting
        case running(sourceName: String)
        case failed(String)
    }

    enum ModelState: Equatable {
        case notLoaded
        case loading(InferenceBackend)
        case ready(ModelBenchmark)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var modelState: ModelState = .notLoaded
    private(set) var stats = PipelineStats()
    private(set) var inferenceStats = InferenceStats()
    /// 캡처(탭) 레이트와 재생(출력 장치) 레이트 — 달라도 CoNo 가 변환한다
    private(set) var inputSampleRate: Double = 0
    private(set) var outputSampleRate: Double = 0
    private(set) var outputDeviceName = ""
    /// 실행 중인 모드 (시작 시 고정)
    private(set) var runningMode: ProcessingMode?
    /// AI 모드일 때 출력 스트림 오프셋과 최대 대기 (초)
    private(set) var separationTiming: (streamOffset: Double, maxWait: Double)?

    /// 음정 바용 타임라인 (AI 모드 실행 중에만)
    private(set) var pitchTimeline: PitchTimeline?
    /// 음정 검출기를 못 만들었을 때 사유 (분리는 계속 동작)
    private(set) var pitchError: String?
    /// 화면을 소리보다 늦출 시간 (ms). 블루투스 출력은 장치 지연이 커서 150~250 ms 정도 필요하다.
    var displayLatencyMilliseconds: Double = 0

    /// 키 조절 (반음). 실행 전에도 정할 수 있고 실행 중에 바로 반영된다. 음정 바도 같은 만큼 옮겨 그린다.
    /// 바꿀 때는 `changeKey(by:)` / `resetKey()` 로만 (범위 제한은 거기서 한다).
    /// ⚠️ @Observable 클래스에서는 didSet 안에서 자기 자신에 대입하면 didSet 이 다시 불려 무한 재귀 → 스택 오버플로.
    private(set) var keyShift: Int = 0 {
        didSet { output?.setKeyShift(keyShift) }
    }

    func changeKey(by semitones: Int) {
        keyMode = .manual
        setKey(keyShift + semitones)
    }

    func resetKey() {
        keyMode = .manual
        setKey(0)
    }

    private func setKey(_ value: Int) {
        let range = PlaybackOutput.keyShiftRange
        let next = min(max(value, range.lowerBound), range.upperBound)
        if next != keyShift { keyShift = next }
    }

    // MARK: - 내 키 (내 목소리에 맞춘 키)

    enum KeyMode: Equatable {
        /// 사용자가 ♭/♯ 로 직접 고른 키
        case manual
        /// 원곡 음역을 재서 이 목소리에 맞춘다 (곡이 바뀌어도 새 곡에 다시 맞춘다)
        case voice(VoiceType)
    }

    private(set) var keyMode: KeyMode = .manual
    /// 지금 곡의 원곡 보컬 음역 (AI 분리 모드에서 유성 구간이 충분히 쌓이면)
    private(set) var vocalRange: VocalRange?
    /// 음역 추정의 시작점 (출력 스트림 초) — 곡이 바뀌면 새 곡 부분만 잰다
    @ObservationIgnored private var vocalRangeStart: Double = 0
    @ObservationIgnored private var vocalRangeTrackID: String?
    /// 목소리 모드에서 이번 곡에 아직 키를 맞추지 않았는지
    @ObservationIgnored private var voiceKeyPending = false

    /// 이 목소리에 맞는 키 (음역을 아직 모르면 nil)
    func suggestedKey(for voice: VoiceType) -> Int? {
        vocalRange.map { SmartKey.shift(forMedian: $0.medianMidi, toward: voice) }
    }

    /// 내 키 버튼 (설정의 내 목소리). 음역을 이미 알면 바로, 아니면 분석되는 대로 맞춘다.
    func applyVoiceKey(_ voice: VoiceType) {
        keyMode = .voice(voice)
        if let key = suggestedKey(for: voice) {
            setKey(key)
            voiceKeyPending = false
        } else {
            voiceKeyPending = true
        }
    }

    /// 1초마다: 곡 경계를 따라 원곡 음역을 다시 재고, 목소리 모드면 새 곡에 키를 맞춘다.
    private func updateVocalRange() {
        guard let timeline = pitchTimeline else { return }
        let trackID = lyrics.currentTrack?.id
        if trackID != vocalRangeTrackID {
            vocalRangeTrackID = trackID
            // 곡이 바뀐 지점 = 지금 캡처되는 소리 → 출력 스트림 시각으로
            let streamOffset = separationTiming?.streamOffset ?? 0
            vocalRangeStart = (captureTime(atHostTime: mach_absolute_time()) ?? 0) + streamOffset
            vocalRange = nil
            if case .voice = keyMode { voiceKeyPending = true }
        }
        let snapshot = timeline.snapshot(from: vocalRangeStart, to: .greatestFiniteMagnitude)
        let range = SmartKey.estimate(frames: snapshot.frames, framePeriod: timeline.framePeriod)
        if range != vocalRange { vocalRange = range }
        if voiceKeyPending, case let .voice(voice) = keyMode, let key = suggestedKey(for: voice) {
            setKey(key)
            voiceKeyPending = false
        }
    }

    /// 가이드 보컬: 반주에 섞을 원곡 보컬 비율 (0…0.5, AI 모드). 실행 중에도 바로 반영.
    var guideVocalLevel: Double = 0 {
        didSet { separationProcessor?.guideVocalLevel = Float(guideVocalLevel) }
    }

    // MARK: - 마이크 채점 (#9)

    enum SingingState: Equatable {
        case off
        case starting
        case listening(deviceName: String, isBluetooth: Bool)
        case failed(String)
    }

    /// 사용자가 켜 둔 채점 (AI 반주 모드가 시작되면 마이크를 연다)
    private(set) var wantsSinging = false
    private(set) var singingState: SingingState = .off
    /// 채점기 (마이크가 열려 있을 때만)
    private(set) var singing: SingingTracker?
    /// 곡이 끝나면 화면이 보여주고 지운다
    var singingResult: SingingResult?
    var singingDifficulty: SingingJudge.Difficulty = .normal {
        didSet { singing?.difficulty = singingDifficulty }
    }
    @ObservationIgnored private var heardClock: HeardClock?
    @ObservationIgnored private var singingGeneration = 0
    @ObservationIgnored private var scoringTrackID: String?
    @ObservationIgnored private var scoringTrack: TrackInfo?
    /// 결과를 보여줄 만큼 부른 곡 (음표 수)
    private static let minimumScoredNotes = 12

    /// 채점은 분리된 원곡 음정이 있어야 한다
    var canSing: Bool { runningMode == .aiSeparation && pitchTimeline != nil }

    func setSinging(_ on: Bool) {
        wantsSinging = on
        if on {
            Task { await startSinging() }
        } else {
            stopSinging()
            singingState = .off
        }
    }

    private func startSinging() async {
        guard wantsSinging, singing == nil, singingState != .starting else { return }
        guard canSing, let timeline = pitchTimeline, let pipeline else { return }
        singingGeneration &+= 1
        let generation = singingGeneration
        singingState = .starting

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            if generation == singingGeneration {
                singingState = .failed("마이크 권한이 꺼져 있습니다. 시스템 설정 › 개인정보 보호 및 보안 › 마이크에서 CoNo 를 켜 주세요.")
            }
            return
        }
        do {
            // 마이크 장치 열기·검출기 로드는 메인 밖에서
            let (mic, detector) = try await Task.detached { (try MicrophoneInput(), try SwiftF0Detector()) }.value
            // 기다리는 동안 끄거나 노래방을 다시 시작했으면 버린다
            guard generation == singingGeneration, wantsSinging, self.pipeline === pipeline else { return }
            let clock = HeardClock(pipeline: pipeline)
            clock.setExtraLatency(extraLatencySeconds)
            let tracker = try SingingTracker(mic: mic, detector: detector, reference: timeline, clock: clock)
            tracker.keyShift = keyShift
            tracker.difficulty = singingDifficulty
            try mic.start { [weak self] in
                // 입력 장치가 바뀌면 새 장치로 다시 연다
                MainActor.assumeIsolated { self?.restartSinging() }
            }
            tracker.start()
            singing = tracker
            heardClock = clock
            scoringTrack = heardTrack
            scoringTrackID = scoringTrack?.id
            singingState = .listening(deviceName: mic.deviceName, isBluetooth: mic.isBluetooth)
        } catch {
            if generation == singingGeneration { singingState = .failed(error.localizedDescription) }
        }
    }

    private func stopSinging() {
        singingGeneration &+= 1
        if let singing {
            singing.stop()
            singing.mic.stop()
        }
        singing = nil
        heardClock = nil
        if singingState == .starting || singingState.isListening { singingState = .off }
    }

    private func restartSinging() {
        guard singing != nil else { return }
        stopSinging()
        Task { await startSinging() }
    }

    /// 50 ms 마다: 채점기에 지금 키·지연을 알리고, 들리는 곡이 바뀌면 앞 곡 결과를 확정한다
    private func updateSinging() {
        guard let singing else { return }
        heardClock?.setExtraLatency(extraLatencySeconds)
        singing.keyShift = keyShift
        let track = heardTrack
        if track?.id != scoringTrackID {
            let concluded = concludeSong()
            scoringTrack = track
            scoringTrackID = track?.id
            singing.resetScore()
            // 채점한 곡이 끝나 다음 곡이 들리기 시작하면 멈춘다 (노래방처럼 한 곡씩, 결과를 보라고).
            // 다음 곡 앞부분은 버퍼에 남아 있어 재생을 누르면 처음부터 이어진다. 광고로 바뀐 건 멈추지 않는다.
            let onAd = heardCaptureTime().flatMap { lyrics.advertisement(atCaptureTime: $0) } != nil
            if concluded, track != nil, !onAd, !isPaused { pause() }
        }
    }

    /// 지금 곡의 점수를 결과로 (충분히 불렀을 때만). 결과를 냈으면 true.
    @discardableResult
    private func concludeSong(minimumNotes: Int = minimumScoredNotes) -> Bool {
        guard let singing else { return false }
        let score = singing.snapshot().score
        guard score.notesTotal >= minimumNotes else { return false }
        singingResult = SingingResult(title: scoringTrack?.title, artist: scoringTrack?.artist, score: score)
        return true
    }

    // MARK: - 재생·일시정지

    /// CoNo 가 소리를 얼려 둔 상태 (음악 앱도 멈춰 있다)
    private(set) var isPaused = false
    /// 재생 제어 실패 사유 (화면 안내용)
    private(set) var playbackMessage: String?
    /// 실행 중인 소스
    private(set) var runningSource: AudioSource?

    /// 음악 앱은 AppleScript 로 정확히, 다른 앱은 ⏯ 미디어 키로 멈춘다
    private var controlsAppleMusic: Bool {
        LyricsController.isAppleMusic(bundleID: runningSource?.bundleID)
    }

    /// 재생·일시정지를 CoNo 에서 할 수 있는지
    var canControlPlayback: Bool { isRunning }

    /// 화면의 재생 버튼 상태: CoNo 가 얼렸거나, 원곡 앱에서 멈춘 경우
    var showsPaused: Bool {
        isPaused || lyrics.playerState == .paused
    }

    func togglePlayback() {
        if showsPaused { resume() } else { pause() }
    }

    /// CoNo 가 얼린 시각 — 직후에 소리가 계속 들어오면 원곡 앱이 안 멈춘 것 (미디어 키가 다른 앱으로 간 경우)
    @ObservationIgnored private var pausedAt: ContinuousClock.Instant?

    /// 누르는 순간 들리는 소리·가사·음정 바가 멈추고, 원곡 앱도 멈춘다.
    func pause() {
        guard canControlPlayback, let pipeline, !isPaused else { return }
        pipeline.setPaused(true)
        isPaused = true
        pausedAt = .now
        playbackMessage = nil
        if controlsAppleMusic {
            Task {
                if case let .failure(error) = await lyrics.send(.pause) {
                    // 음악 앱이 안 멈추면 캡처가 계속 쌓이므로 얼림을 푼다
                    resumePipeline()
                    playbackMessage = error.localizedDescription
                }
            }
        } else {
            let audible = pipeline.isSourceAudible(within: 0.4)
            Task {
                // 1) "지금 재생 중" 이 이 앱이면 명확한 멈춤 명령
                if await sendToSource(.pause) { return }
                // 2) 안 되면 ⏯ 미디어 키 — 토글이라 원곡이 소리를 내고 있을 때만
                guard audible else { return }
                if !MediaKey.pressPlayPause() {
                    resumePipeline()
                    playbackMessage = Self.accessibilityMessage
                }
            }
        }
    }

    /// 음악 앱이 아닌 앱에 "지금 재생 중" 경로로 명령. 재생 중인 앱이 캡처 중인 앱일 때만 보낸다
    /// (다른 앱이 "지금 재생 중" 이면 엉뚱한 앱을 멈추거나 틀게 된다). 처리했으면 true.
    private func sendToSource(_ command: PlayerCommand) async -> Bool {
        guard let bridge = MediaRemoteBridge.shared,
              let info = await bridge.current(),
              info.belongs(to: runningSource?.bundleID)
        else { return false }
        switch command {
        case .pause where !info.playing, .play where info.playing:
            return true // 이미 원하는 상태
        default:
            return await bridge.send(command)
        }
    }

    /// 멈춘 곳부터 이어서 (CoNo 가 얼려 둔 소리부터 끊김 없이)
    func resume() {
        guard canControlPlayback, let pipeline else { return }
        if endedSong {
            advanceToNextSong(pipeline)
            return
        }
        let sourceSilent = !pipeline.isSourceAudible(within: 0.4)
        resumePipeline()
        playbackMessage = nil
        if controlsAppleMusic {
            Task {
                if case let .failure(error) = await lyrics.send(.play) {
                    playbackMessage = error.localizedDescription
                }
            }
        } else {
            Task {
                if await sendToSource(.play) { return }
                if sourceSilent, !MediaKey.pressPlayPause() {
                    playbackMessage = Self.accessibilityMessage
                }
            }
        }
    }

    /// 끝내기: CoNo 소리를 먼저 끊고, 원곡 앱도 멈춘 뒤(조용해진 걸 확인하고) 정리한다.
    /// 그냥 정리하면 원곡 음소거가 풀리면서 3~4초 앞선 원곡이 갑자기 들린다.
    func finish() async {
        guard isRunning, let pipeline else {
            stop()
            return
        }
        pipeline.setPaused(true)
        isPaused = true
        if controlsAppleMusic {
            _ = await lyrics.send(.pause)
        } else if await !sendToSource(.pause), pipeline.isSourceAudible(within: 0.4) {
            _ = MediaKey.pressPlayPause()
        }
        // 원곡이 0.15초 조용해지거나 1초가 지날 때까지 (멈추지 못해도 끝내기는 한다)
        let deadline = ContinuousClock.now + .seconds(1)
        while pipeline.isSourceAudible(within: 0.15), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        concludeSong()
        stop()
    }

    // MARK: - 곡 끝내기 (연결은 그대로)

    /// 곡을 끝내 둔 상태 — 재생을 누르면 다음 곡으로 넘어간다
    private(set) var endedSong = false
    /// 다음 곡으로 넘어가며 끝낸 곡의 남은 소리를 음소거로 흘려보내는 중
    private(set) var isAdvancingToNextSong = false
    @ObservationIgnored private var advanceStartedAt: ContinuousClock.Instant?
    /// 직접 끝낼 때는 1절만 불러도 결과를 보여준다
    private static let minimumNotesWhenEnded = 5

    /// 노래방 리모컨의 "종료": 여기까지 채점하고 멈춘다. 연결은 끊지 않는다.
    func endSong() {
        guard canControlPlayback, !endedSong else { return }
        concludeSong(minimumNotes: Self.minimumNotesWhenEnded)
        // 끝낸 곡을 다음 곡 경계에서 다시 결과로 내지 않게
        singing?.resetScore()
        pause()
        endedSong = true
    }

    /// 끝낸 곡의 남은 소리(지연 버퍼)는 버리지 않고 음소거로 흘려보내고, 원곡 앱을 다음 곡으로 넘겨 튼다.
    /// 원곡 앱이 멈춰 있던 동안 캡처는 무음을 버리므로, 지금 캡처 위치 = 끝낸 곡 소리의 끝 = 다음 곡의 시작.
    private func advanceToNextSong(_ pipeline: DelayPipeline) {
        endedSong = false
        muteEndedSong(pipeline, excludingSeconds: 0)
        resumePipeline()
        playbackMessage = nil
        isAdvancingToNextSong = true
        advanceStartedAt = .now
        Task {
            var moved = false
            if controlsAppleMusic {
                if case .success = await lyrics.send(.nextTrack) {
                    moved = true
                    _ = await lyrics.send(.play)
                }
            } else if await sendToSource(.nextTrack) {
                moved = true
                _ = await sendToSource(.play)
            } else if MediaKey.pressNextTrack() {
                moved = true
            }
            if !moved {
                playbackMessage = "다음 곡으로 넘기지 못했어요. 음악 앱에서 넘겨 주세요."
            }
        }
    }

    /// 끝낸 곡의 소리가 출력에 남은 구간을 음소거. excludingSeconds = 멈춘 뒤 새로 들어온 소리 (그만큼은 들려준다)
    private func muteEndedSong(_ pipeline: DelayPipeline, excludingSeconds: Double) {
        let streamOffset = runningMode == .aiSeparation ? (separationTiming?.streamOffset ?? 0) : 0
        let captured = (captureTime(atHostTime: mach_absolute_time()) ?? 0) - excludingSeconds
        pipeline.muteOutput(untilStreamSeconds: captured + streamOffset)
    }

    /// 다음 곡 소리가 들리기 시작하면 안내를 끈다
    private func updateAdvance() {
        guard isAdvancingToNextSong, let started = advanceStartedAt else { return }
        let elapsed = ContinuousClock.now - started
        if (!stats.isOutputMuted && elapsed > .milliseconds(300)) || elapsed > .seconds(20) {
            isAdvancingToNextSong = false
            advanceStartedAt = nil
        }
    }

    // MARK: - 이동 (재생 위치)

    /// 이동 중 목표 위치 (진행 막대가 도착 전 옛 위치로 되돌아가 보이지 않게). 새 위치의 소리가 들리면 nil.
    private(set) var seekTarget: Double?
    @ObservationIgnored private var seekStartedAt: ContinuousClock.Instant?
    /// 이동 명령을 보낸 캡처 시각 — 이 뒤로 원곡 앱이 목표 위치를 보고하면 그때가 새 위치 소리의 시작
    @ObservationIgnored private var seekCaptureStart: Double?
    /// 새 위치 소리의 시작을 찾아 소리 켤 지점을 정했는지
    @ObservationIgnored private var seekArrivalFound = false
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    /// 파이프라인에 걸어 둔 광고 구간 (바뀔 때만 다시 건다)
    @ObservationIgnored private var appliedAdWindow: LyricsController.AdWindow?

    /// 곡 안 위치로 이동. CoNo 는 원곡보다 몇 초 늦게 들려주므로, 누르는 순간 소리를 끄고
    /// 원곡 앱이 실제로 새 위치를 재생하기 시작한 지점(재생 위치 보고로 찾는다)이 출력에 닿으면 다시 켠다.
    /// 그 사이 옛 소리는 버리지 않고 흘려보내 스트림 시각·싱크를 유지한다.
    func seek(toSongPosition target: Double) {
        guard canControlPlayback, let pipeline else { return }
        let target = max(0, target)
        seekTarget = target
        seekStartedAt = .now
        seekCaptureStart = captureTime(atHostTime: mach_absolute_time())
        seekArrivalFound = false
        playbackMessage = nil
        pipeline.muteOutputUntilFurtherNotice()
        seekTask?.cancel()
        seekTask = Task {
            let moved = controlsAppleMusic ? await lyrics.seekAppleMusic(to: target) : await seekSource(to: target)
            guard !Task.isCancelled, !moved else { return }
            pipeline.unmuteOutput()
            seekTarget = nil
            playbackMessage = "연결된 앱이 이동 명령을 받지 않았습니다"
        }
    }

    /// 50 ms 마다: 원곡 앱이 목표 위치에 닿은 캡처 시각을 찾으면 그 지점이 출력에 닿을 때 소리를 켠다.
    private func updateSeek() {
        guard let target = seekTarget, let started = seekStartedAt, let pipeline else { return }
        let elapsed = ContinuousClock.now - started
        let streamOffset = runningMode == .aiSeparation ? (separationTiming?.streamOffset ?? 0) : 0
        if !seekArrivalFound {
            if let start = seekCaptureStart, let arrival = lyrics.settleSeek(toward: target, after: start) {
                pipeline.muteOutput(untilStreamSeconds: arrival + streamOffset)
                seekArrivalFound = true
            } else if elapsed > .seconds(10) {
                // 재생 위치 보고가 없거나 안 바뀌면 지금 캡처 위치부터 (최후의 수단)
                pipeline.muteOutput(untilStreamSeconds: (captureTime(atHostTime: mach_absolute_time()) ?? 0) + streamOffset)
                seekArrivalFound = true
            }
        } else if !stats.isOutputMuted, elapsed > .milliseconds(300) {
            seekTarget = nil
        }
        if elapsed > .seconds(20) { seekTarget = nil }
    }

    /// 광고 구간(캡처 시각)을 출력 스트림 구간으로 옮겨 그 동안 소리를 끈다. 출력은 캡처보다 몇 초 늦으므로
    /// 광고를 알아챈 뒤에 걸어도 광고 첫 소리부터 가린다.
    private func updateAdMute() {
        let window = lyrics.adWindow
        guard window != appliedAdWindow, let pipeline else { return }
        appliedAdWindow = window
        let streamOffset = runningMode == .aiSeparation ? (separationTiming?.streamOffset ?? 0) : 0
        pipeline.setAdMute(
            fromStreamSeconds: window.map { $0.start + streamOffset },
            untilStreamSeconds: window?.end.map { $0 + streamOffset }
        )
    }

    private func seekSource(to seconds: Double) async -> Bool {
        guard let bridge = MediaRemoteBridge.shared,
              let info = await bridge.current(),
              info.belongs(to: runningSource?.bundleID)
        else { return false }
        return await bridge.seek(toSeconds: seconds)
    }

    private static let accessibilityMessage =
        "다른 앱을 멈추려면 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 CoNo 를 켜 주세요."

    private func resumePipeline() {
        pipeline?.setPaused(false)
        isPaused = false
        pausedAt = nil
    }

    /// AI 모드에서 들려줄 출력 — 실행 중에도 바꿀 수 있다
    var separationOutput: SeparationOutput = .accompaniment {
        didSet { separationProcessor?.output = separationOutput }
    }

    /// 가사 (음악 앱일 때만 곡 정보·재생 위치 연동)
    let lyrics = LyricsController()

    private let modelConfig = MDXModelConfig.karaoke2
    private var separator: MDXSeparator?
    private var pitchDetector: SwiftF0Detector?
    private var separationProcessor: SeparationProcessor?
    private var session: ProcessTapSession?
    private var output: PlaybackOutput?
    private var pipeline: DelayPipeline?
    private var statsTask: Task<Void, Never>?
    /// 시작 시도마다 올리는 번호. await 뒤에 번호가 바뀌었으면(정지·재시작) 그 시도는 버린다.
    /// status 만 보면 "정지 → 다시 시작" 한 뒤에도 .starting 이라 옛 시도가 살아남는다.
    @ObservationIgnored private var startGeneration = 0

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// 시작 중이거나 실행 중 (설정을 잠가야 하는 상태)
    var isBusy: Bool {
        switch status {
        case .starting, .running: true
        case .idle, .failed: false
        }
    }

    var isModelLoading: Bool {
        if case .loading = modelState { return true }
        return false
    }

    /// AI 모드에서 권장하는 최소 지연: 최대 대기 + 추론 최대 시간×1.5 + 0.5초 여유
    func recommendedDelay(for settings: SeparationSettings) -> Double {
        let inference: Double
        if case let .ready(benchmark) = modelState { inference = benchmark.steadyInferenceMilliseconds / 1000 } else { inference = 1 }
        return settings.rightContextSeconds + settings.stepSeconds + inference * 1.5 + 0.5
    }

    // MARK: - Model

    /// 모델을 로드하고 추론 속도를 잰다. 이미 같은 백엔드로 로드돼 있으면 그대로 둔다.
    @discardableResult
    func prepareModel(backend: InferenceBackend) async -> Bool {
        if case let .ready(benchmark) = modelState, benchmark.backend == backend, separator != nil { return true }
        guard !isRunning, !isModelLoading else { return false }

        modelState = .loading(backend)
        separator = nil
        let config = modelConfig
        let cacheDirectory = Self.coreMLCacheDirectory

        let result = await Task.detached(priority: .userInitiated) { () -> Result<(MDXSeparator, ModelBenchmark, SwiftF0Detector?), Error> in
            do {
                let clock = ContinuousClock()
                let loadStart = clock.now
                let url = try MDXSeparator.bundledModelURL(for: config)
                let separator = try MDXSeparator(config: config, backend: backend, modelURL: url, cacheDirectory: cacheDirectory)
                let loadSeconds = (clock.now - loadStart).milliseconds / 1000

                // 무음이 아닌 결정적 신호로 추론 시간 측정 (첫 회 = 워밍업)
                let n = config.chunkSize
                let left = (0..<n).map { Float(sin(Double($0) * 0.05) * 0.3) }
                let right = (0..<n).map { Float(cos(Double($0) * 0.031) * 0.3) }
                var outLeft = [Float](repeating: 0, count: n)
                var outRight = outLeft
                var timings: [Double] = []
                var modelTimings: [Double] = []
                for _ in 0..<4 {
                    let start = clock.now
                    try left.withUnsafeBufferPointer { l in
                        try right.withUnsafeBufferPointer { r in
                            try outLeft.withUnsafeMutableBufferPointer { ol in
                                try outRight.withUnsafeMutableBufferPointer { orr in
                                    try separator.separate(left: l, right: r, outLeft: ol, outRight: orr)
                                }
                            }
                        }
                    }
                    timings.append((clock.now - start).milliseconds)
                    modelTimings.append(separator.lastModelMilliseconds)
                }
                let steady = timings.dropFirst().reduce(0, +) / Double(timings.count - 1)
                let steadyModel = modelTimings.dropFirst().reduce(0, +) / Double(modelTimings.count - 1)
                // SwiftF0 자가진단: 1초짜리 220 Hz 사인파 → 유성 프레임 음정의 중앙값
                // 실패해도 분리 모델 준비는 성공으로 둔다 (음정 바만 빠짐)
                var detector: SwiftF0Detector?
                var selfTestHz: Double?
                var selfTestError: String?
                do {
                    let created = try SwiftF0Detector()
                    let sine = (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
                    let (pitch, confidence) = try sine.withUnsafeBufferPointer { try created.estimate($0) }
                    let voiced = zip(pitch, confidence).filter { $0.1 >= 0.5 }.map(\.0).sorted()
                    selfTestHz = voiced.isEmpty ? 0 : voiced[voiced.count / 2]
                    detector = created
                } catch {
                    selfTestError = error.localizedDescription
                }
                let benchmark = ModelBenchmark(
                    backend: backend,
                    loadSeconds: loadSeconds,
                    firstInferenceMilliseconds: timings[0],
                    steadyInferenceMilliseconds: steady,
                    steadyModelMilliseconds: steadyModel,
                    pitchSelfTestHz: selfTestHz,
                    pitchSelfTestError: selfTestError
                )
                return .success((separator, benchmark, detector))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success((loaded, benchmark, detector)):
            separator = loaded
            if let detector { pitchDetector = detector }
            modelState = .ready(benchmark)
            return true
        case let .failure(error):
            modelState = .failed(error.localizedDescription)
            return false
        }
    }

    private static var coreMLCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("space.knowai.cono/coreml", isDirectory: true)
    }

    // MARK: - Run

    func start(
        source: AudioSource,
        delaySeconds: Double,
        muteOriginal: Bool,
        mode: ProcessingMode,
        separation: SeparationSettings
    ) async {
        stop()
        startGeneration &+= 1
        let generation = startGeneration
        status = .starting

        if mode == .aiSeparation {
            let modelReady = await prepareModel(backend: separation.backend)
            // 모델을 준비하는 동안 정지·재시작됐으면 이 시도는 버린다
            guard isCurrentStart(generation) else { return }
            guard modelReady, self.separator != nil else {
                if case let .failed(message) = modelState { status = .failed(message) } else { status = .idle }
                return
            }
            // 음정 검출기는 없어도 분리는 돌린다 (음정 바만 빠짐)
            if pitchDetector == nil {
                do {
                    pitchDetector = try SwiftF0Detector()
                    pitchError = nil
                } catch {
                    pitchError = error.localizedDescription
                }
            }
        }

        // 1) 탭 + 캡처 애그리게이트 (백그라운드)
        let session = ProcessTapSession()
        do {
            try await Task.detached { try session.prepare(source: source, muteOriginal: muteOriginal) }.value
        } catch {
            if isCurrentStart(generation) { status = .failed(error.localizedDescription) }
            return
        }
        guard isCurrentStart(generation) else {
            session.teardown()
            return
        }

        let playback = PlaybackOutput()
        let inputRate = session.captureSampleRate
        let outputRate = playback.sampleRate
        var createdPipeline: DelayPipeline?
        do {
            // 2) 처리기 (입력 레이트 → 출력 레이트)
            let processor: StreamProcessor
            var burstSeconds = 0.0
            separationProcessor = nil
            separationTiming = nil
            pitchTimeline = nil
            let needsResample = abs(inputRate - outputRate) > 0.5
            switch mode {
            case .passthrough:
                processor = needsResample
                    ? try ResamplingProcessor(wrapping: PassthroughProcessor(), inputRate: inputRate, outputRate: outputRate)
                    : PassthroughProcessor()
            case .centerCancel:
                processor = needsResample
                    ? try ResamplingProcessor(wrapping: CenterCancelProcessor(), inputRate: inputRate, outputRate: outputRate)
                    : CenterCancelProcessor()
            case .aiSeparation:
                guard let separator else { throw CoreAudioError("분리 모델이 준비되지 않았습니다") }
                let separationProcessor = try SeparationProcessor(
                    separator: separator,
                    settings: separation.streamingSettings(for: modelConfig),
                    inputSampleRate: inputRate,
                    outputSampleRate: outputRate,
                    pitchDetector: pitchDetector
                )
                separationProcessor.output = separationOutput
                separationProcessor.guideVocalLevel = Float(guideVocalLevel)
                self.separationProcessor = separationProcessor
                pitchTimeline = separationProcessor.pitchTimeline
                separationTiming = (separationProcessor.streamOffsetSeconds, separationProcessor.maxWaitSeconds)
                burstSeconds = separationProcessor.maxWaitSeconds
                processor = separationProcessor
            }

            let pipeline = DelayPipeline(
                inputSampleRate: inputRate,
                outputSampleRate: outputRate,
                delaySeconds: delaySeconds,
                processor: processor,
                burstSeconds: burstSeconds
            )
            // 워커는 캡처가 붙고 이 시도가 아직 유효한지 확인한 뒤에 띄운다 (아래).
            // 먼저 띄우면 권한 대기 중 정지·재시작했을 때 옛 워커와 새 워커가 같은 분리 모델을 동시에 쓴다.
            createdPipeline = pipeline

            // 3) 재생 (출력 장치가 바뀌면 엔진이 멈추므로 안전하게 정지하고 안내)
            playback.setKeyShift(keyShift)
            try playback.start(
                render: { [pipeline] frames, buffers, timestamp in
                    pipeline.renderPlayback(frameCount: frames, output: buffers, timestamp: timestamp)
                },
                onConfigurationChange: { [weak self] in
                    MainActor.assumeIsolated {
                        // 시작 중(권한 대기)에 바뀌어도 정지해야 한다 — isRunning 만 보면 알림이 버려지고
                        // 멈춘 엔진으로 .running 이 된다. 정지하면 번호가 바뀌어 대기 중인 시작도 스스로 정리한다.
                        guard let self, generation == self.startGeneration, self.isBusy else { return }
                        self.stop()
                        self.status = .failed("출력 장치가 바뀌어 정지했습니다. 다시 시작해 주세요.")
                    }
                }
            )

            // 4) 캡처 시작 (백그라운드 — 첫 실행 땐 권한 응답까지 블록된다)
            let tapChannels = max(1, Int(session.tapFormat.mChannelsPerFrame))
            try await Task.detached {
                try session.start { [pipeline] _, inputData, inputTime, _, _ in
                    pipeline.renderCapture(input: inputData, inputTime: inputTime, tapChannelCount: tapChannels)
                }
            }.value

            // 시작 대기 중에 정지·재시작됐으면 이 시도가 만든 것만 정리 (워커는 아직 안 떴다)
            guard isCurrentStart(generation) else {
                playback.stop()
                session.teardown()
                return
            }
            pipeline.startWorker()

            self.session = session
            self.output = playback
            self.pipeline = pipeline
            runningSource = source
            isPaused = false
            playbackMessage = nil
            vocalRange = nil
            vocalRangeTrackID = nil
            vocalRangeStart = 0
            inputSampleRate = inputRate
            outputSampleRate = outputRate
            outputDeviceName = playback.deviceName
            stats = PipelineStats()
            inferenceStats = InferenceStats()
            runningMode = mode
            status = .running(sourceName: source.name)
            startStatsPolling()
            lyrics.start(sourceBundleID: source.bundleID) { [weak self] hostTime in
                self?.captureTime(atHostTime: hostTime)
            }
            // 음절 단위 색칠용 보컬 음정 (AI 분리 모드만). start() 가 초기화하므로 그 뒤에 넣는다.
            if let pitchTimeline {
                lyrics.vocalSource = VocalTimingSource(timeline: pitchTimeline, streamOffset: separationTiming?.streamOffset ?? 0)
            }
            if wantsSinging { Task { await startSinging() } }
        } catch {
            playback.stop()
            session.teardown()
            stopPipeline(createdPipeline)
            // 이미 버려진 시도면 새 시도의 상태를 건드리지 않는다
            if isCurrentStart(generation) {
                separationProcessor = nil
                pitchTimeline = nil
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func isCurrentStart(_ generation: Int) -> Bool {
        generation == startGeneration && status == .starting
    }

    /// 파이프라인 워커를 멈춘다. 시간 안에 안 멈추면 워커가 분리 모델·음정 검출기를 아직 쓰고 있을 수 있으므로
    /// 다시 쓰지 않고 버린다 (다음 시작 때 새로 로드). 모델 객체는 한 스레드만 써야 한다.
    private func stopPipeline(_ pipeline: DelayPipeline?) {
        guard let pipeline, !pipeline.stopWorker() else { return }
        separator = nil
        pitchDetector = nil
        modelState = .notLoaded
    }

    func stop() {
        startGeneration &+= 1
        // 채점기가 파이프라인 출력 레벨을 읽으므로 먼저 멈춘다
        stopSinging()
        statsTask?.cancel()
        statsTask = nil
        lyrics.stop()
        // 캡처·재생을 먼저 멈춰야 파이프라인 버퍼 해제 중에 콜백이 돌지 않는다
        output?.stop()
        output = nil
        session?.teardown()
        session = nil
        stopPipeline(pipeline)
        pipeline = nil
        separationProcessor = nil
        pitchTimeline = nil
        runningMode = nil
        runningSource = nil
        isPaused = false
        vocalRange = nil
        seekTask?.cancel()
        seekTarget = nil
        appliedAdWindow = nil
        endedSong = false
        isAdvancingToNextSong = false
        if isBusy { status = .idle }
    }

    /// 지금 들리는 출력 스트림 위치 (초, 화면 싱크 보정 반영). 음정 타임라인과 같은 시간축.
    /// 진단 녹음 저장 결과 (폴더 경로 또는 오류)
    private(set) var diagnosticSaveMessage: String?

    /// 최근 30초의 처리기 입력·출력을 ~/Downloads/CoNo-diagnostic-… 에 WAV 로 저장
    func saveDiagnosticRecording() {
        guard let pipeline else { return }
        do {
            let folder = try pipeline.recorder.save()
            diagnosticSaveMessage = "저장됨: \(folder.path)"
        } catch {
            diagnosticSaveMessage = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 호스트 시각 → 캡처 스트림 시각 (가사 앵커용)
    func captureTime(atHostTime hostTime: UInt64) -> Double? {
        pipeline?.captureStreamPosition(atHostTime: hostTime)
    }

    /// 지금 귀에 들리는 소리가 캡처된 시각 (캡처 스트림 초).
    /// 출력 스트림 ↔ 캡처 스트림: 패스스루/L−R 은 같은 초, AI 분리는 출력 = 캡처 − rightContext.
    func heardCaptureTime() -> Double? {
        let streamOffset = runningMode == .aiSeparation ? (separationTiming?.streamOffset ?? 0) : 0
        return displayPosition().map { $0 - streamOffset }
    }

    /// 키 조절 단계의 지연도 빼서, 지금 "귀에 들리는" 위치를 돌려준다.
    func displayPosition() -> Double? {
        pipeline?.playbackPosition().map { $0 - extraLatencySeconds }
    }

    /// 재생 위치에서 빼는 지연: 키 조절 단계 + 화면 싱크
    private var extraLatencySeconds: Double {
        (output?.processingLatencySeconds ?? 0) + displayLatencyMilliseconds / 1000
    }

    private func startStatsPolling() {
        statsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let pipeline = self.pipeline else { return }
                self.stats = pipeline.takeStats()
                if let separationProcessor = self.separationProcessor {
                    self.inferenceStats = separationProcessor.inferenceStats
                }
                // 얼려 둔 동안 소리가 1초 넘게 계속 들어오면 원곡 앱이 재생 중 → 따라서 푼다.
                // 얼린 직후라면 멈추기에 실패한 것 (미디어 키가 다른 앱으로 갔을 수 있다)
                if self.isPaused, pipeline.pausedAudioSeconds > 1 {
                    // 곡을 끝내 둔 뒤 음악 앱에서 직접 다른 곡을 틀었으면: 끝낸 곡의 남은 소리는 건너뛰고 새로 들어온 소리부터
                    if self.endedSong {
                        self.endedSong = false
                        self.muteEndedSong(pipeline, excludingSeconds: pipeline.pausedAudioSeconds)
                    }
                    let justPaused = self.pausedAt.map { ContinuousClock.now - $0 < .seconds(3) } ?? false
                    self.resumePipeline()
                    if justPaused, !self.controlsAppleMusic {
                        self.playbackMessage = "원곡 앱이 멈추지 않았습니다. 다른 앱이 '지금 재생 중' 으로 잡혀 있을 수 있어요."
                    }
                }
                self.updateSeek()
                self.updateAdMute()
                self.updateAdvance()
                self.updateSinging()
                tick += 1
                if tick % 20 == 0 { self.updateVocalRange() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}

extension KaraokeEngine {
    /// 무대 아래 안내 한 줄: 채점 실패 사유나 블루투스 마이크 주의
    var singingNotice: String? {
        switch singingState {
        case let .failed(message): message
        case .listening(_, isBluetooth: true): "블루투스 마이크를 쓰는 중이에요. 이어폰 소리가 통화 음질로 떨어지면 Mac 내장 마이크로 바꿔 주세요."
        default: nil
        }
    }
}

extension KaraokeEngine.SingingState {
    var isListening: Bool {
        if case .listening = self { true } else { false }
    }
}
