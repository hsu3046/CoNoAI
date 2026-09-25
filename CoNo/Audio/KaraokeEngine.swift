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
}

@MainActor
@Observable
final class KaraokeEngine {
    enum Status: Equatable {
        case idle
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
    private(set) var sampleRate: Double = 0
    private(set) var outputDeviceName = ""
    /// 탭과 출력 장치 샘플레이트가 다르면 경고
    private(set) var sampleRateWarning: String?
    /// 실행 중인 모드 (시작 시 고정)
    private(set) var runningMode: ProcessingMode?
    /// AI 모드일 때 출력 스트림 오프셋과 최대 대기 (초)
    private(set) var separationTiming: (streamOffset: Double, maxWait: Double)?

    /// AI 모드에서 들려줄 출력 — 실행 중에도 바꿀 수 있다
    var separationOutput: SeparationOutput = .accompaniment {
        didSet { separationProcessor?.output = separationOutput }
    }

    private let modelConfig = MDXModelConfig.karaoke2
    private var separator: MDXSeparator?
    private var separationProcessor: SeparationProcessor?
    private var session: ProcessTapSession?
    private var pipeline: DelayPipeline?
    private var statsTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = status { return true }
        return false
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

        let result = await Task.detached(priority: .userInitiated) { () -> Result<(MDXSeparator, ModelBenchmark), Error> in
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
                let benchmark = ModelBenchmark(
                    backend: backend,
                    loadSeconds: loadSeconds,
                    firstInferenceMilliseconds: timings[0],
                    steadyInferenceMilliseconds: steady,
                    steadyModelMilliseconds: steadyModel
                )
                return .success((separator, benchmark))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case let .success((loaded, benchmark)):
            separator = loaded
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

        if mode == .aiSeparation {
            guard await prepareModel(backend: separation.backend), separator != nil else {
                if case let .failed(message) = modelState { status = .failed(message) }
                return
            }
        }

        let session = ProcessTapSession()
        // catch 에서 워커 스레드를 확실히 멈추기 위해 do 바깥에 둔다
        var createdPipeline: DelayPipeline?
        do {
            try session.prepare(source: source, muteOriginal: muteOriginal)

            let tapRate = session.tapFormat.mSampleRate
            let outputRate = session.outputSampleRate
            sampleRateWarning = abs(tapRate - outputRate) > 1
                ? "탭(\(Int(tapRate)) Hz)과 출력 장치(\(Int(outputRate)) Hz)의 샘플레이트가 다릅니다. 음정이 틀어지면 출력 장치 레이트를 맞춰 주세요."
                : nil

            let processor: StreamProcessor
            var burstSeconds = 0.0
            separationProcessor = nil
            separationTiming = nil
            switch mode {
            case .passthrough:
                processor = PassthroughProcessor()
            case .centerCancel:
                processor = CenterCancelProcessor()
            case .aiSeparation:
                guard let separator else { throw CoreAudioError("분리 모델이 준비되지 않았습니다") }
                let separation = try SeparationProcessor(
                    separator: separator,
                    settings: separation.streamingSettings(for: modelConfig),
                    deviceSampleRate: outputRate
                )
                separation.output = separationOutput
                separationProcessor = separation
                separationTiming = (separation.streamOffsetSeconds, separation.maxWaitSeconds)
                burstSeconds = separation.maxWaitSeconds
                processor = separation
            }

            // 파이프라인 시간축은 출력 장치(=애그리게이트 클럭) 기준
            let pipeline = DelayPipeline(sampleRate: outputRate, delaySeconds: delaySeconds, processor: processor, burstSeconds: burstSeconds)
            createdPipeline = pipeline
            pipeline.startWorker()

            let tapChannels = max(1, Int(session.tapFormat.mChannelsPerFrame))
            try session.start { [pipeline] _, inputData, _, outputData, _ in
                pipeline.renderIO(input: inputData, output: outputData, tapChannelCount: tapChannels)
            }

            self.session = session
            self.pipeline = pipeline
            sampleRate = outputRate
            outputDeviceName = session.outputDeviceName
            stats = PipelineStats()
            inferenceStats = InferenceStats()
            runningMode = mode
            status = .running(sourceName: source.name)
            startStatsPolling()
        } catch {
            session.teardown()
            createdPipeline?.stopWorker()
            separationProcessor = nil
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        // IO 를 먼저 멈춰야 파이프라인 버퍼 해제 중에 콜백이 돌지 않는다
        session?.teardown()
        session = nil
        pipeline?.stopWorker()
        pipeline = nil
        separationProcessor = nil
        runningMode = nil
        if isRunning { status = .idle }
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
