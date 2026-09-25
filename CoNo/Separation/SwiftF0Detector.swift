// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// SwiftF0 (lars76/swift-f0, MIT) 음정 검출 모델 래퍼.
// 입력: 16 kHz 모노 오디오 + fmin/fmax 스칼라 → 출력: 256 샘플(16 ms)마다 음정(Hz) · 신뢰도.
// 원본 규칙: 프레임 구간 최대 진폭이 1e-3 미만이면 신뢰도 0 (디지털 무음에서 가짜 유성음 방지).
// 모델이 작아(135 KB) CoreML 로 넘기는 오버헤드가 더 커서 CPU 로 돌린다.

import Foundation
import OnnxRuntimeBindings

final class SwiftF0Detector: FramePitchEstimating, @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let framePeriod: Double = 256 / 16_000
    static let minHz: Float = 46.875
    static let maxHz: Float = 2_093.75
    private static let silencePeak: Float = 1e-3

    let hop = 256
    private let session: ORTSession
    private let fminData: NSMutableData
    private let fmaxData: NSMutableData

    /// - Parameters: fmin/fmax 로 노래 음역을 좁히면 옥타브 오류가 준다 (기본: 약 E2 ~ C6)
    init(fmin: Float = 80, fmax: Float = 1_100) throws {
        guard let url = Bundle.main.url(forResource: "swift_f0", withExtension: "onnx") else {
            throw MDXSeparatorError.modelNotFound("swift_f0")
        }
        do {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            // 스트리밍 호출 사이에 스레드가 바쁜 대기하지 않도록
            try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
            session = try ORTSession(env: OnnxRuntimeEnvironment.env(), modelPath: url.path, sessionOptions: options)
        } catch {
            throw MDXSeparatorError.onnx("SwiftF0 세션 생성 실패", underlying: error)
        }
        var low = max(fmin, Self.minHz)
        var high = min(fmax, Self.maxHz)
        fminData = NSMutableData(bytes: &low, length: MemoryLayout<Float>.size)
        fmaxData = NSMutableData(bytes: &high, length: MemoryLayout<Float>.size)
    }

    func estimate(_ audio: UnsafeBufferPointer<Float>) throws -> (pitchHz: [Double], confidence: [Float]) {
        guard audio.count >= hop, let base = audio.baseAddress else { return ([], []) }
        let pitchData: NSMutableData
        let confidenceData: NSMutableData
        do {
            let audioData = NSMutableData(bytes: base, length: audio.count * MemoryLayout<Float>.size)
            let inputs: [String: ORTValue] = [
                "audio": try ORTValue(tensorData: audioData, elementType: .float, shape: [1, NSNumber(value: audio.count)]),
                "fmin": try ORTValue(tensorData: fminData, elementType: .float, shape: []),
                "fmax": try ORTValue(tensorData: fmaxData, elementType: .float, shape: []),
            ]
            let outputs = try session.run(withInputs: inputs, outputNames: ["pitch", "confidence"], runOptions: nil)
            guard let pitch = outputs["pitch"], let confidence = outputs["confidence"] else {
                throw MDXSeparatorError.onnx("SwiftF0 출력 없음", underlying: nil)
            }
            pitchData = try pitch.tensorData()
            confidenceData = try confidence.tensorData()
        } catch let error as MDXSeparatorError {
            throw error
        } catch {
            throw MDXSeparatorError.onnx("SwiftF0 추론 실패", underlying: error)
        }

        // 원본 모델의 pitch 는 double 이지만 ORT ObjC API 가 double 을 못 읽어서
        // scripts/convert_swiftf0.py 로 Cast(float) 를 붙인 모델을 쓴다 → 둘 다 float
        let frames = min(pitchData.length, confidenceData.length) / MemoryLayout<Float>.size
        let pitchPointer = pitchData.bytes.assumingMemoryBound(to: Float.self)
        let confidencePointer = confidenceData.bytes.assumingMemoryBound(to: Float.self)
        let pitch = UnsafeBufferPointer(start: pitchPointer, count: frames).map(Double.init)
        var confidence = Array(UnsafeBufferPointer(start: confidencePointer, count: frames))

        // 무음 프레임 신뢰도 0
        for frame in 0..<frames {
            let start = frame * hop
            guard start + hop <= audio.count else { break }
            var peak: Float = 0
            for i in start..<(start + hop) { peak = max(peak, abs(audio[i])) }
            if peak < Self.silencePeak { confidence[frame] = 0 }
        }
        return (pitch, confidence)
    }
}
