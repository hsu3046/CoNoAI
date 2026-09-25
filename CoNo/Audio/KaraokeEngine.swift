// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// UI 가 쓰는 파사드: 탭 세션 + 지연 파이프라인 + (AI 모드) 분리 모델을 묶어 시작/정지하고 통계를 갱신한다.

import AudioToolbox
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
        let range = PlaybackOutput.keyShiftRange
        let next = min(max(keyShift + semitones, range.lowerBound), range.upperBound)
        if next != keyShift { keyShift = next }
    }

    func resetKey() {
        if keyShift != 0 { keyShift = 0 }
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
        status = .starting

        if mode == .aiSeparation {
            guard await prepareModel(backend: separation.backend), self.separator != nil else {
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
            status = .failed(error.localizedDescription)
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
            createdPipeline = pipeline
            pipeline.startWorker()

            // 3) 재생 (출력 장치가 바뀌면 엔진이 멈추므로 안전하게 정지하고 안내)
            playback.setKeyShift(keyShift)
            try playback.start(
                render: { [pipeline] frames, buffers, timestamp in
                    pipeline.renderPlayback(frameCount: frames, output: buffers, timestamp: timestamp)
                },
                onConfigurationChange: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isRunning else { return }
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

            // 시작 대기 중에 사용자가 정지를 눌렀으면 정리
            guard status == .starting else {
                playback.stop()
                session.teardown()
                pipeline.stopWorker()
                return
            }

            self.session = session
            self.output = playback
            self.pipeline = pipeline
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
        } catch {
            playback.stop()
            session.teardown()
            createdPipeline?.stopWorker()
            separationProcessor = nil
            pitchTimeline = nil
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        lyrics.stop()
        // 캡처·재생을 먼저 멈춰야 파이프라인 버퍼 해제 중에 콜백이 돌지 않는다
        output?.stop()
        output = nil
        session?.teardown()
        session = nil
        pipeline?.stopWorker()
        pipeline = nil
        separationProcessor = nil
        pitchTimeline = nil
        runningMode = nil
        if isBusy { status = .idle }
    }

    /// 지금 들리는 출력 스트림 위치 (초, 화면 싱크 보정 반영). 음정 타임라인과 같은 시간축.
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
        let extraLatency = (output?.processingLatencySeconds ?? 0) + displayLatencyMilliseconds / 1000
        return pipeline?.playbackPosition().map { $0 - extraLatency }
    }

    private func startStatsPolling() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pipeline = self.pipeline else { return }
                self.stats = pipeline.takeStats()
                if let separationProcessor = self.separationProcessor {
                    self.inferenceStats = separationProcessor.inferenceStats
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
