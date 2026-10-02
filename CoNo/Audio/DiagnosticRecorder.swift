// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 워커 입력·출력 최근 30초와 메인 스레드의 통계 추세. 사용자가 저장을 눌렀을 때만 파일로 내보낸다.
// 출력 WAV 는 재생 링·키 조절·장치보다 앞 단계다. 렌더 이후의 잡음 유무를 이 파일만으로 단정하지 않는다.

import AVFoundation
import Synchronization

struct DiagnosticContext: Codable, Sendable {
    var mode: String
    var inputSampleRate: Double
    var streamSampleRate: Double
    var outputHardwareSampleRate: Double
    var outputDeviceName: String
    var delaySeconds: Double
    var keyShift: Int
    var displayLatencyMilliseconds: Double
    var separationStreamOffsetSeconds: Double
}

struct DiagnosticStatSample: Codable, Sendable {
    var elapsedSeconds: Double
    var playbackPosition: Double?
    var outputHardwareSampleRate: Double
    var stats: PipelineStats
}

struct DiagnosticWaveSummary: Codable, Sendable {
    var fileName: String
    var stage: String
    var sampleRate: Double
    var channels: Int = 2
    /// 각 워커 스트림의 누적 프레임 범위. 입력·출력을 별도로 스냅샷하므로 같은 길이라 가정하지 않는다.
    var startFrame: Int
    var endFrame: Int
    var peak: Float
    var clippedSamples: Int
    /// 인접한 같은 채널 샘플의 최대 차이. 타악기·고음에서도 커지므로 클릭 확정값이 아니다.
    var maxAdjacentDelta: Float
}

struct DiagnosticReport: Codable, Sendable {
    var schemaVersion = 1
    var savedAt: String
    var context: DiagnosticContext
    var input: DiagnosticWaveSummary
    var output: DiagnosticWaveSummary
    var recentStats: [DiagnosticStatSample]
    var recordingLimitations = "WAV files are worker input/output before playback rendering, pitch shifting and hardware. No microphone is recorded. Adjacent-sample deltas are observations, not a click diagnosis."
}

final class DiagnosticRecorder: @unchecked Sendable {
    let seconds: Double
    private let input: RollingBuffer
    private let output: RollingBuffer
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let recentStats = Mutex<[DiagnosticStatSample]>([])

    init(inputSampleRate: Double, outputSampleRate: Double, seconds: Double = 30) {
        self.seconds = seconds
        input = RollingBuffer(sampleRate: inputSampleRate, seconds: seconds)
        output = RollingBuffer(sampleRate: outputSampleRate, seconds: seconds)
    }

    /// 워커만 호출 (오디오 IO 스레드 아님).
    func recordInput(_ samples: UnsafeBufferPointer<Float>) { input.append(samples) }
    func recordOutput(_ samples: UnsafeBufferPointer<Float>) { output.append(samples) }

    /// UI 통계 폴링에서 호출. 링 점유량의 추세·언더런·IO 끊김을 WAV 와 함께 읽을 수 있게 한다.
    func recordStats(_ stats: PipelineStats, playbackPosition: Double?, outputHardwareSampleRate: Double, elapsedSeconds: Double? = nil) {
        let elapsed = elapsedSeconds ?? (ProcessInfo.processInfo.systemUptime - startedAt)
        let sample = DiagnosticStatSample(elapsedSeconds: elapsed, playbackPosition: playbackPosition,
                                          outputHardwareSampleRate: outputHardwareSampleRate, stats: stats)
        recentStats.withLock { samples in
            samples.append(sample)
            samples.removeAll { $0.elapsedSeconds < elapsed - seconds }
            let limit = max(2, Int(seconds * 20) + 1)
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
        }
    }

    /// 최근 녹음과 진단 JSON 을 고유 폴더에 저장한다. directory 는 독립 테스트용 출력 경로다.
    func save(context: DiagnosticContext, directory: URL? = nil) throws -> URL {
        let inputSnapshot = input.snapshot()
        let outputSnapshot = output.snapshot()
        guard !inputSnapshot.samples.isEmpty, !outputSnapshot.samples.isEmpty else {
            throw CoreAudioError("녹음된 소리가 없습니다")
        }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let parent = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        // 같은 초에 두 번 눌러도 기존 진단을 덮어쓰지 않는다.
        let folder = parent.appendingPathComponent("CoNo-diagnostic-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let inputName = "input-\(Int(input.sampleRate)).wav"
            let outputName = "output-\(Int(output.sampleRate)).wav"
            try inputSnapshot.write(to: folder.appendingPathComponent(inputName))
            try outputSnapshot.write(to: folder.appendingPathComponent(outputName))
            let report = DiagnosticReport(
                savedAt: now.ISO8601Format(), context: context,
                input: inputSnapshot.summary(fileName: inputName, stage: "worker-input"),
                output: outputSnapshot.summary(fileName: outputName, stage: "worker-output-before-playback"),
                recentStats: recentStats.withLock { $0 }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: folder.appendingPathComponent("diagnostics.json"), options: .atomic)
            return folder
        } catch {
            // 이 호출이 만든 고유 폴더만 정리한다. 이전 저장과 사용자 파일은 건드리지 않는다.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

private struct RecordingSnapshot {
    let sampleRate: Double
    let samples: [Float]
    let endFrame: Int

    func summary(fileName: String, stage: String) -> DiagnosticWaveSummary {
        var peak: Float = 0
        var clipped = 0
        var maxDelta: Float = 0
        for index in samples.indices {
            let value = abs(samples[index])
            peak = max(peak, value)
            if value >= 1 { clipped += 1 }
            if index >= 2 { maxDelta = max(maxDelta, abs(samples[index] - samples[index - 2])) }
        }
        return DiagnosticWaveSummary(fileName: fileName, stage: stage, sampleRate: sampleRate,
                                     startFrame: endFrame - samples.count / 2, endFrame: endFrame,
                                     peak: peak, clippedSamples: clipped, maxAdjacentDelta: maxDelta)
    }

    func write(to url: URL) throws {
        let frames = samples.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw CoreAudioError("녹음된 소리가 없습니다") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = samples[i * 2]
            buffer.floatChannelData![1][i] = samples[i * 2 + 1]
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// 인터리브 스테레오 최근 N초. 워커에서 쓰고 저장할 때만 복사한다.
private final class RollingBuffer: @unchecked Sendable {
    let sampleRate: Double
    private let storage: Mutex<(samples: [Float], writeIndex: Int, totalSamples: Int)>

    init(sampleRate: Double, seconds: Double) {
        self.sampleRate = sampleRate
        storage = Mutex(([Float](repeating: 0, count: max(2, Int(sampleRate * seconds) * 2)), 0, 0))
    }

    func append(_ source: UnsafeBufferPointer<Float>) {
        storage.withLock { state in
            let capacity = state.samples.count
            for value in source {
                state.samples[state.writeIndex] = value
                state.writeIndex += 1
                if state.writeIndex == capacity { state.writeIndex = 0 }
            }
            state.totalSamples += source.count
        }
    }

    func snapshot() -> RecordingSnapshot {
        storage.withLock { state in
            let ordered = state.totalSamples >= state.samples.count
                ? Array(state.samples[state.writeIndex...] + state.samples[..<state.writeIndex])
                : Array(state.samples[..<state.writeIndex])
            return RecordingSnapshot(sampleRate: sampleRate, samples: ordered, endFrame: state.totalSamples / 2)
        }
    }
}
