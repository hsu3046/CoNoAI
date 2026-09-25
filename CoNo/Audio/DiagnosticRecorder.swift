// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 진단 녹음: 처리기에 들어간 소리(입력, 탭 레이트)와 나온 소리(출력, 장치 레이트)를 최근 N초씩 들고 있다가
// 요청하면 WAV 로 저장한다. 틱 소리가 "원본에 이미 있는지 / CoNo 처리에서 생기는지 / 출력 이후인지" 를 가르기 위함.
// 워커 스레드에서만 쓴다 (오디오 IO 스레드 아님). 저장은 메인 스레드에서 잠금 후 복사.

import AVFoundation
import Synchronization

final class DiagnosticRecorder: @unchecked Sendable {
    let seconds: Double
    private let input: RollingBuffer
    private let output: RollingBuffer

    init(inputSampleRate: Double, outputSampleRate: Double, seconds: Double = 30) {
        self.seconds = seconds
        input = RollingBuffer(sampleRate: inputSampleRate, seconds: seconds)
        output = RollingBuffer(sampleRate: outputSampleRate, seconds: seconds)
    }

    /// 워커: 처리기 입력 (인터리브 스테레오)
    func recordInput(_ samples: UnsafeBufferPointer<Float>) { input.append(samples) }
    /// 워커: 처리기 출력 (인터리브 스테레오)
    func recordOutput(_ samples: UnsafeBufferPointer<Float>) { output.append(samples) }

    /// 최근 녹음을 16-bit WAV 두 개로 저장하고 폴더 URL 을 돌려준다.
    func save() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/CoNo-diagnostic-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try input.write(to: folder.appendingPathComponent("input-\(Int(input.sampleRate)).wav"))
        try output.write(to: folder.appendingPathComponent("output-\(Int(output.sampleRate)).wav"))
        return folder
    }
}

/// 인터리브 스테레오 최근 N초 (가득 차면 오래된 것부터 덮어씀)
private final class RollingBuffer: @unchecked Sendable {
    let sampleRate: Double
    private let storage: Mutex<(samples: [Float], writeIndex: Int, filled: Bool)>

    init(sampleRate: Double, seconds: Double) {
        self.sampleRate = sampleRate
        storage = Mutex(([Float](repeating: 0, count: Int(sampleRate * seconds) * 2), 0, false))
    }

    func append(_ source: UnsafeBufferPointer<Float>) {
        storage.withLock { state in
            let capacity = state.samples.count
            for value in source {
                state.samples[state.writeIndex] = value
                state.writeIndex += 1
                if state.writeIndex == capacity {
                    state.writeIndex = 0
                    state.filled = true
                }
            }
        }
    }

    func write(to url: URL) throws {
        // 시간 순서로 펼친 복사본
        let ordered: [Float] = storage.withLock { state in
            state.filled
                ? Array(state.samples[state.writeIndex...] + state.samples[..<state.writeIndex])
                : Array(state.samples[..<state.writeIndex])
        }
        let frames = ordered.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw CoreAudioError("녹음된 소리가 없습니다") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = ordered[i * 2]
            buffer.floatChannelData![1][i] = ordered[i * 2 + 1]
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
