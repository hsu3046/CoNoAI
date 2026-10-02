// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import AVFoundation
import Foundation
import Testing

struct AudioPipelineTests {
    private func buffer(frames: Int, rate: Double = 48_000, value: Float = 0) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: value, count: frames) }
        return buffer
    }

    private func stamp(sample: Double = 0) -> AudioTimeStamp {
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.hostTimeValid, .sampleTimeValid]
        timestamp.mHostTime = mach_absolute_time()
        timestamp.mSampleTime = sample
        return timestamp
    }

    @Test func oversizedRenderClearsEntireBufferIncludingTail() throws {
        let pipeline = DelayPipeline(inputSampleRate: 48_000, outputSampleRate: 48_000, delaySeconds: 1, processor: PassthroughProcessor())
        let output = try buffer(frames: 20_000, value: 0.75)
        var timestamp = stamp()
        pipeline.renderPlayback(frameCount: 20_000, output: output.mutableAudioBufferList, timestamp: &timestamp)
        for channel in 0..<2 {
            let samples = UnsafeBufferPointer(start: output.floatChannelData![channel], count: 20_000)
            #expect(samples.allSatisfy { $0 == 0 }, "프리롤은 스크래치 한도를 넘는 꼬리까지 무음이어야 한다")
        }
        #expect(pipeline.takeStats().oversizedPlaybackCallbacks == 1)
    }

    @Test func outputReplacementFreezesClockAndScoringUntilFirstRender() async throws {
        let pipeline = DelayPipeline(inputSampleRate: 48_000, outputSampleRate: 48_000, delaySeconds: 0.01, processor: PassthroughProcessor())
        let input = try buffer(frames: 4_096, value: 0.4)
        var timestamp = stamp()
        pipeline.renderCapture(input: input.audioBufferList, inputTime: &timestamp, tapChannelCount: 2)
        pipeline.startWorker()
        defer { pipeline.stopWorker() }
        for _ in 0..<100 where pipeline.takeStats().bufferedSeconds < 0.08 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(pipeline.takeStats().bufferedSeconds >= 0.08)
        let output = try buffer(frames: 256)
        pipeline.renderPlayback(frameCount: 256, output: output.mutableAudioBufferList, timestamp: &timestamp)
        #expect(pipeline.isAdvancing)
        pipeline.suspendPlayback()
        let frozen = pipeline.playbackPosition()
        let buffered = pipeline.takeStats().bufferedSeconds
        #expect(!pipeline.isAdvancing)
        try await Task.sleep(for: .milliseconds(3))
        #expect(pipeline.playbackPosition() == frozen)
        timestamp = stamp(sample: 256)
        pipeline.renderPlayback(frameCount: 256, output: output.mutableAudioBufferList, timestamp: &timestamp)
        #expect(output.floatChannelData![0][100] == 0)
        #expect(pipeline.takeStats().bufferedSeconds == buffered)
        pipeline.resumePlaybackOnNextRender()
        #expect(!pipeline.isAdvancing, "엔진 시작 요청만으로 채점이 재개되면 안 된다")
        pipeline.renderPlayback(frameCount: 256, output: output.mutableAudioBufferList, timestamp: &timestamp)
        #expect(pipeline.isAdvancing)
        #expect(output.floatChannelData![0][0] > 0 && output.floatChannelData![0][0] < 0.01)
        #expect(abs(output.floatChannelData![0][100] - 0.4) < 1e-6)
        #expect(pipeline.takeStats().playback.skippedCycles == 0)
        pipeline.setPaused(true)
        pipeline.suspendPlayback()
        pipeline.resumePlaybackOnNextRender()
        pipeline.renderPlayback(frameCount: 256, output: output.mutableAudioBufferList, timestamp: &timestamp)
        #expect(pipeline.isPaused && !pipeline.isAdvancing, "장치 변경은 사용자의 일시정지를 풀지 않는다")
    }

    @Test func diagnosticArchiveIncludesBoundedTraceAndWaveRanges() throws {
        let recorder = DiagnosticRecorder(inputSampleRate: 8_000, outputSampleRate: 16_000, seconds: 0.01)
        let samples = (0..<200).flatMap { index -> [Float] in
            let value = Float(index) / 400
            return [value, -value]
        }
        samples.withUnsafeBufferPointer { recorder.recordInput($0); recorder.recordOutput($0) }
        for tick in 0..<10 {
            var stats = PipelineStats()
            stats.bufferedSeconds = Double(tick) / 100
            recorder.recordStats(stats, playbackPosition: Double(tick) / 100, outputHardwareSampleRate: 48_000, elapsedSeconds: Double(tick) / 1000)
        }
        let context = DiagnosticContext(mode: "passthrough", inputSampleRate: 8_000, streamSampleRate: 16_000,
                                        outputHardwareSampleRate: 48_000, outputDeviceName: "Test output", delaySeconds: 1,
                                        keyShift: 0, displayLatencyMilliseconds: 0, separationStreamOffsetSeconds: 0)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try recorder.save(context: context, directory: parent)
        let second = try recorder.save(context: context, directory: parent)
        #expect(first != second, "빠른 두 번 저장이 기존 파일을 덮어쓰지 않아야 한다")
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: Data(contentsOf: first.appendingPathComponent("diagnostics.json")))
        #expect(report.schemaVersion == 1)
        #expect(report.input.startFrame == 120 && report.input.endFrame == 200)
        #expect(report.output.startFrame == 40 && report.output.endFrame == 200)
        #expect(report.output.stage == "worker-output-before-playback")
        #expect(report.recentStats.count == 2)
        #expect(report.recentStats.last?.stats.bufferedSeconds == 0.09)
        #expect(report.context.streamSampleRate == 16_000 && report.context.outputHardwareSampleRate == 48_000)
        let inputFile = try AVAudioFile(forReading: first.appendingPathComponent(report.input.fileName))
        #expect(inputFile.length == 80)
    }
}

/// 단일 offline 렌더 스레드가 소유하며, 호출한 뒤에만 테스트가 읽는다.
private final class TestToneBurst: @unchecked Sendable {
    let rate: Double
    var renderedFrames = 0
    init(rate: Double) { self.rate = rate }
    func render(frames: Int, output: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            for frame in 0..<frames {
                let time = Double(renderedFrames + frame) / rate
                // 0.25초 무음 뒤 정확히 1초 동안만 신호. 출력 신호의 길이로 재생 속도를 검증한다.
                let value = time >= 0.25 && time < 1.25 ? Float(0.5 * sin(2 * Double.pi * 440 * time)) : 0
                for channel in 0..<channels { pointer[frame * channels + channel] = value }
            }
        }
        renderedFrames += frames
    }
}

struct PlaybackGraphTests {
    @Test func queuedNotificationFromReplacedOutputCannotStopNewOutput() {
        let previousOutput = PlaybackConfigurationGate()
        let previousRegistration = previousOutput.activate()
        let queuedNotification = { previousOutput.isCurrent(previousRegistration) }
        #expect(queuedNotification())
        previousOutput.invalidate() // observer 제거 전에 stop 이 무효화
        let newOutput = PlaybackConfigurationGate()
        let newRegistration = newOutput.activate()
        #expect(!queuedNotification(), "새 출력 설치 뒤 도착한 옛 알림은 reconnect를 호출하면 안 된다")
        #expect(newOutput.isCurrent(newRegistration))
        let restartedRegistration = previousOutput.activate()
        #expect(!queuedNotification(), "같은 출력 객체를 재사용해도 이전 등록 토큰은 계속 무효")
        #expect(previousOutput.isCurrent(restartedRegistration))
    }

    @Test(arguments: [(48_000.0, 96_000.0), (96_000.0, 48_000.0), (44_100.0, 48_000.0)])
    func graphKeepsPitchAndDurationAcrossOutputRates(rates: (Double, Double)) throws {
        let (sourceRate, hardwareRate) = rates
        let engine = AVAudioEngine()
        let pitch = AVAudioUnitTimePitch()
        pitch.bypass = true
        let tone = TestToneBurst(rate: sourceRate)
        _ = try PlaybackOutput.connectGraph(engine: engine, timePitch: pitch, sourceSampleRate: sourceRate) { frames, output, _ in
            tone.render(frames: frames, output: output)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let target = Int(hardwareRate * 1.6)
        var samples: [Float] = []
        var attempts = 0
        while samples.count < target, attempts < 200 {
            attempts += 1
            let count = min(4_096, target - samples.count)
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: output)
            #expect(status != .error)
            if output.frameLength > 0 {
                samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            }
        }
        #expect(samples.count == target)
        // 로컬 대조 실험에서 TimePitch 는 bypass 때도 66.7~91.7ms를 선읽기했다(노드 제거 시 0).
        // 따라서 입력 콜백의 소비량은 재생 길이가 아니다. 실제 출력의 1초 신호 구간을 측정한다.
        let audible = samples.indices.filter { abs(samples[$0]) > 0.1 }
        let onset = try #require(audible.first)
        let offset = try #require(audible.last)
        let duration = Double(offset - onset + 1) / hardwareRate
        #expect(abs(duration - 1) < 0.002, "출력 레이트가 달라도 1초 입력 신호의 재생 길이는 유지되어야 한다")
        // 시작·끝 필터 과도 응답을 뺀 유성 구간에서 양의 영교차 간격으로 주파수를 잰다.
        let begin = onset + Int(hardwareRate * 0.05)
        let end = offset - Int(hardwareRate * 0.05)
        try #require(end > begin)
        var crossings: [Int] = []
        for index in max(1, begin)..<end where samples[index - 1] <= 0 && samples[index] > 0 {
            crossings.append(index)
        }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        try #require(last > first)
        let frequency = Double(crossings.count - 1) * hardwareRate / Double(last - first)
        #expect(abs(frequency - 440) < 0.2)
        #expect(samples.allSatisfy { $0.isFinite })
    }
}

struct SingingScoreSessionTests {
    @Test func preferenceChangesCannotRelabelAccumulatedScore() {
        var requestedDifficulty = SingingJudge.Difficulty.normal
        var session = SingingScoreSession(difficulty: requestedDifficulty)
        session.beginIfNeeded(at: 0)
        let note = SungNote(startFrame: 0, endFrame: 10, midi: 60)
        for frame in 0..<10 where session.accepts(offset: 0.4) { session.hitTimes.append(Double(frame) * 0.016) }
        session.score(notes: [note], framePeriod: 0.016, stableUntil: 1)
        requestedDifficulty = .hard // 곡 끝 직전 UI 설정을 변경한 상황
        #expect(session.difficulty == .normal)
        #expect(session.score.score == 100)
        let previousResult = (difficulty: session.difficulty, score: session.score)
        // 실제 전환은 채점 큐에서 이 세션 전체를 교체한 뒤 공개한다.
        session = SingingScoreSession(difficulty: requestedDifficulty)
        #expect(session.difficulty == .hard && session.score.notesTotal == 0)
        #expect(session.hitTimes.isEmpty)
        #expect(previousResult.difficulty == .normal && previousResult.score.notesTotal == 1)
        session.beginIfNeeded(at: 0)
        for frame in 0..<10 where session.accepts(offset: 0.4) { session.hitTimes.append(Double(frame) * 0.016) }
        session.score(notes: [note], framePeriod: 0.016, stableUntil: 1)
        #expect(session.score.score == 0 && session.score.notesTotal == 1)
    }
}
