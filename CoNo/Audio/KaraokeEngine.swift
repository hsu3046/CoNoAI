// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// UI 가 쓰는 파사드: 탭 세션 + 지연 파이프라인을 묶어 시작/정지하고 통계를 주기적으로 갱신한다.

import AudioToolbox
import Foundation
import Observation

@MainActor
@Observable
final class KaraokeEngine {
    enum Status: Equatable {
        case idle
        case running(sourceName: String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var stats = PipelineStats()
    private(set) var sampleRate: Double = 0
    private(set) var outputDeviceName = ""
    /// 탭과 출력 장치 샘플레이트가 다르면 경고 (드리프트 보정은 되지만 레이트 변환은 보장 안 됨)
    private(set) var sampleRateWarning: String?

    var processingMode: ProcessingMode = .passthrough {
        didSet { pipeline?.processingMode = processingMode }
    }

    private var session: ProcessTapSession?
    private var pipeline: DelayPipeline?
    private var statsTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func start(source: AudioSource, delaySeconds: Double, muteOriginal: Bool) {
        stop()

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

            // 파이프라인 시간축은 출력 장치(=애그리게이트 클럭) 기준
            let pipeline = DelayPipeline(sampleRate: outputRate, delaySeconds: delaySeconds)
            pipeline.processingMode = processingMode
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
            status = .running(sourceName: source.name)
            startStatsPolling()
        } catch {
            session.teardown()
            createdPipeline?.stopWorker()
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
        if isRunning { status = .idle }
    }

    private func startStatsPolling() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pipeline = self.pipeline else { return }
                self.stats = pipeline.takeStats()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
