// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 선택형 로컬 가사 학습. 모델과 logits는 이 actor만 소유하며 오디오를 저장/전송하지 않는다.

import AVFoundation
import CryptoKit
import Foundation
import OnnxRuntimeBindings

actor OmniASRCTC {
    static let modelVersion = "omniASR-CTC-300M-int8@6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094"
    static let maximumAudioSeconds = CTCAlignment.maximumAudioSeconds
    private static let sampleRate = 16_000.0
    private static let files: [(name: String, bytes: Int, sha256: String)] = [
        ("model.int8.onnx", 365_352_120, "e7c4e54ee4c4c47829cc6667d5d00ed8ea7bef1dcfeef0fce766f77752a2726c"),
        ("tokens.txt", 86_423, "a7a044c52cb29cbe8b0dc1953e92cefd4ca16b0ed968177b6beab21f9a7d0b31"),
        ("LICENSE", 581, "a70a523bafbb595c2844104feb313d204904dac91c3d186c05f22a10a71c7a94")
    ]
    private let session: ORTSession
    private let vocabulary: CTCVocabulary

    enum ModelError: LocalizedError {
        case missingOrCorrupt(String)
        var errorDescription: String? {
            switch self {
            case let .missingOrCorrupt(file): "가사 학습 모델의 \(file) 파일이 없거나 검증에 실패했습니다. 모델을 다시 준비해 주세요."
            }
        }
    }

    /// 존재 확인은 빠르게, 365 MB SHA 검증/모델 로드는 별도 로더 작업에서 init할 때 한다.
    static func bundledModelDirectory(in bundle: Bundle = .main) -> URL? {
        guard let directory = bundle.resourceURL?.appendingPathComponent("Models/OmniASR-CTC-300M", isDirectory: true),
              files.allSatisfy({ file in
                  let url = directory.appendingPathComponent(file.name)
                  return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
              }) else { return nil }
        return directory
    }

    init(modelDirectory: URL, threads: Int = 2) throws {
        for file in Self.files {
            try Self.verify(modelDirectory.appendingPathComponent(file.name), bytes: file.bytes, sha256: file.sha256)
        }
        vocabulary = try CTCVocabulary(contents: String(contentsOf: modelDirectory.appendingPathComponent("tokens.txt"), encoding: .utf8))
        guard vocabulary.tokens.count == 9_812 else { throw CTCAlignmentError.invalidVocabulary }
        try Task.checkCancellation()
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(min(4, max(1, threads))))
        try options.setGraphOptimizationLevel(.all)
        // 학습 대기 중 ORT 스레드가 보컬 분리/재생 CPU 예산을 소모하지 않는다.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try options.addConfigEntry(withKey: "session.inter_op.allow_spinning", value: "0")
        session = try ORTSession(env: OnnxRuntimeEnvironment.env(),
                                 modelPath: modelDirectory.appendingPathComponent("model.int8.onnx").path,
                                 sessionOptions: options)
        guard try session.inputNames() == ["x"], try session.outputNames() == ["logits"] else {
            throw CTCAlignmentError.invalidShape
        }
        try Task.checkCancellation()
    }

    func align(_ request: CTCAlignmentRequest) throws -> CTCAlignmentResult {
        try Task.checkCancellation()
        guard request.startTime.isFinite, request.startTime >= 0,
              (request.startTime + Self.maximumAudioSeconds).isFinite else { throw CTCAlignmentError.invalidAudio }
        if let text = request.text { _ = try vocabulary.encode(text) }
        let samples = try Self.prepareAudio(request.audio, sampleRate: request.sampleRate)
        try Task.checkCancellation()
        let data = samples.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: samples.count)])
        // ObjC ORT 1.24.2에는 RunOptions terminate API가 없다. 실행 중 취소는 반환 직후 폐기한다.
        // 호출자는 이 bounded 작업이 끝날 때까지 다음 요청을 시작하지 않는다.
        let outputs = try session.run(withInputs: ["x": input], outputNames: ["logits"], runOptions: nil)
        try Task.checkCancellation()
        guard let output = outputs["logits"] else { throw CTCAlignmentError.invalidShape }
        let info = try output.tensorTypeAndShapeInfo()
        let shape = info.shape.map { $0.intValue }
        guard info.elementType == .float, shape.count == 3, shape[0] == 1, shape[2] == vocabulary.tokens.count,
              shape[1] > 0, shape[1] <= CTCAlignment.maximumFrames else { throw CTCAlignmentError.invalidShape }
        let tensor = try output.tensorData()
        let count = shape[1] * shape[2]
        guard tensor.length == count * MemoryLayout<Float>.stride else { throw CTCAlignmentError.invalidShape }
        // ORTValue 소유 메모리를 그대로 읽는다. 최대 약 40 MB logits를 중복 복사하지 않는다.
        return try withExtendedLifetime(output) {
            try CTCAlignment.align(logits: UnsafeBufferPointer(start: tensor.bytes.assumingMemoryBound(to: Float.self), count: count),
                                   frameCount: shape[1], vocabulary: vocabulary, text: request.text,
                                   startTime: request.startTime, audioDuration: Double(samples.count) / Self.sampleRate)
        }
    }

    private static func verify(_ url: URL, bytes: Int, sha256: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == bytes else { throw ModelError.missingOrCorrupt(url.lastPathComponent) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var read = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            read += chunk.count
            guard read <= bytes else { throw ModelError.missingOrCorrupt(url.lastPathComponent) }
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard read == bytes, actual == sha256 else { throw ModelError.missingOrCorrupt(url.lastPathComponent) }
    }

    /// 오프라인 클립 변환. 최대 20초/192 kHz 모노이며 분리 워커/IO 콜백에서는 호출하지 않는다.
    static func prepareAudio(_ audio: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), !audio.isEmpty else { throw CTCAlignmentError.invalidAudio }
        let duration = Double(audio.count) / sampleRate
        guard duration <= maximumAudioSeconds else { throw CTCAlignmentError.tooLong }
        guard duration >= 0.1 else { throw CTCAlignmentError.invalidAudio }
        for index in audio.indices {
            if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
            guard audio[index].isFinite else { throw CTCAlignmentError.nonFinite }
        }
        var samples: [Float]
        if sampleRate == Self.sampleRate {
            samples = audio
        } else {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.count)),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384),
                  let inputSamples = input.floatChannelData?[0] else { throw CTCAlignmentError.invalidAudio }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            input.frameLength = AVAudioFrameCount(audio.count)
            audio.withUnsafeBufferPointer { inputSamples.update(from: $0.baseAddress!, count: $0.count) }
            samples = []
            let expected = Int((duration * Self.sampleRate).rounded())
            samples.reserveCapacity(expected + 64)
            var supplied = false
            var finished = false
            // endOfStream를 전달해 마지막 필터 tail까지 비운다. 스트리밍 resampler와 수명을 공유하지 않는다.
            for _ in 0..<32 {
                try Task.checkCancellation()
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .endOfStream; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                if status == .error { throw error ?? CTCAlignmentError.invalidAudio as NSError }
                let produced = Int(output.frameLength)
                guard samples.count + produced <= expected + 64 else { throw CTCAlignmentError.invalidAudio }
                if produced > 0, let channel = output.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
                }
                if status == .endOfStream { finished = true; break }
                if produced == 0, status == .inputRanDry { throw CTCAlignmentError.invalidAudio }
            }
            guard finished, abs(samples.count - expected) <= 1, !samples.isEmpty else { throw CTCAlignmentError.invalidAudio }
            // 1/16 kHz 미만 반올림 차이를 제외하고 입력 클립 시각/길이를 보존한다.
            if samples.count > Int(maximumAudioSeconds * Self.sampleRate) { samples.removeLast() }
        }
        var mean = 0.0
        for sample in samples { mean += Double(sample) }
        mean /= Double(samples.count)
        var variance = 0.0
        for sample in samples { let centered = Double(sample) - mean; variance += centered * centered }
        variance /= Double(samples.count)
        // DC와 침묵을 정규화해 가짜 보컬처럼 증폭하지 않는다. 약 -80 dBFS RMS 이하만 제외한다.
        guard variance > 1e-8 else { throw CTCAlignmentError.insufficientAudio }
        let scale = sqrt(variance + 1e-5)
        for index in samples.indices {
            if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
            samples[index] = Float((Double(samples[index]) - mean) / scale)
            guard samples[index].isFinite else { throw CTCAlignmentError.nonFinite }
        }
        return samples
    }
}
