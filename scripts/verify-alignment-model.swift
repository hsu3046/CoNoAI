// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// verify-alignment-model.sh가 기존 ORT 산출물과 함께 컴파일한다. 입력 오디오/전사는 출력하지 않는다.

import AVFoundation
import Foundation

@main struct AlignmentModelVerification {
    struct Report: Encodable {
        let modelVersion: String
        let cpuThreads: Int
        let inputRate: Double
        let audioSeconds: Double
        let loadSeconds: Double
        let greedySeconds: Double
        let greedyCharacterCount: Int
        let greedyConfidence: Double
        let forcedSeconds: Double?
        let forcedConfidence: Double?
        let textMatch: Double?
        let forcedSegments: Int?
        let resamplingChecks: Int
        let silenceRejected: Bool
        let cancellationRejected: Bool
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "AlignmentVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("가사 모델 검증 실패: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard (3...4).contains(arguments.count) else {
            throw NSError(domain: "AlignmentVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: verify-alignment-model model-directory audio-file [expected-text]"])
        }
        let modelURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
        let rate = file.processingFormat.sampleRate
        try require(file.length > 0 && Double(file.length) / rate <= 20, "검증 입력은 0.1–20초 오디오여야 합니다.")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CTCAlignmentError.invalidAudio
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CTCAlignmentError.invalidAudio }
        let count = Int(buffer.frameLength)
        let channelCount = Int(file.processingFormat.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for frame in 0..<count { mono[frame] += channels[channel][frame] / Float(channelCount) }
        }
        var resamplingChecks = 0
        for sourceRate in [8_000.0, 44_100, 48_000, 192_000] {
            var impulse = [Float](repeating: 0, count: Int(sourceRate))
            impulse[Int(sourceRate / 2)] = 0.75
            let prepared = try OmniASRCTC.prepareAudio(impulse, sampleRate: sourceRate)
            let peak = prepared.indices.max(by: { abs(prepared[$0]) < abs(prepared[$1]) })!
            try require(prepared.count == 16_000 && abs(peak - 8_000) <= 1, "리샘플링 길이/임펄스 시각이 보존되지 않았습니다.")
            try require(prepared.allSatisfy { $0.isFinite }, "리샘플링 출력에 비유한 수치가 있습니다.")
            resamplingChecks += 1
        }
        var silenceRejected = false
        do { _ = try OmniASRCTC.prepareAudio([Float](repeating: 0, count: 16_000), sampleRate: 16_000) }
        catch CTCAlignmentError.insufficientAudio { silenceRejected = true }
        try require(silenceRejected, "침묵 입력이 거부되지 않았습니다.")

        let loadStart = Date()
        let model = try OmniASRCTC(modelDirectory: modelURL, threads: 1)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let greedyStart = Date()
        let greedy = try await model.align(CTCAlignmentRequest(audio: mono, sampleRate: rate, text: nil, startTime: 10))
        let greedySeconds = Date().timeIntervalSince(greedyStart)
        var forced: CTCAlignmentResult?
        var forcedSeconds: Double?
        if arguments.count == 4 {
            let forcedStart = Date()
            forced = try await model.align(CTCAlignmentRequest(audio: mono, sampleRate: rate, text: arguments[3], startTime: 10))
            forcedSeconds = Date().timeIntervalSince(forcedStart)
            try require(forced!.text == arguments[3] && forced!.textMatch >= 0.8, "자체 음성 문장의 전사/정렬 일치도가 80% 미만입니다.")
        }
        let duration = Double(count) / rate
        for result in [greedy, forced].compactMap({ $0 }) {
            try require(result.confidence.isFinite && (0...1).contains(result.confidence), "confidence 범위 오류")
            var end = 10.0
            for segment in result.segments {
                try require(segment.characterStart >= 0 && segment.characterCount > 0 &&
                            segment.characterStart + segment.characterCount <= result.text.count &&
                            segment.start >= end && (segment.end ?? 0) > segment.start &&
                            (segment.end ?? .infinity) <= 10 + duration + 1.0 / 16_000,
                            "출력 문자 범위/절대 시각 순서가 올바르지 않습니다.")
                end = segment.end!
            }
        }
        let cancelled = Task {
            try Task.checkCancellation()
            return try await model.align(CTCAlignmentRequest(audio: mono, sampleRate: rate, text: nil, startTime: 0))
        }
        cancelled.cancel()
        var cancellationRejected = false
        do { _ = try await cancelled.value }
        catch is CancellationError { cancellationRejected = true }
        try require(cancellationRejected, "취소한 요청이 결과를 반환했습니다.")

        let report = Report(modelVersion: OmniASRCTC.modelVersion, cpuThreads: 1, inputRate: rate, audioSeconds: duration,
                            loadSeconds: loadSeconds, greedySeconds: greedySeconds, greedyCharacterCount: greedy.text.count,
                            greedyConfidence: greedy.confidence, forcedSeconds: forcedSeconds,
                            forcedConfidence: forced?.confidence, textMatch: forced?.textMatch,
                            forcedSegments: forced?.segments.count, resamplingChecks: resamplingChecks,
                            silenceRejected: silenceRejected, cancellationRejected: cancellationRejected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
