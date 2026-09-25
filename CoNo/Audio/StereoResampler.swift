// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 스트리밍 스테레오 샘플레이트 변환 (AVAudioConverter). 워커 스레드 전용 — IO 스레드에서 쓰지 말 것.

import AVFoundation

final class StereoResampler {
    let inputRate: Double
    let outputRate: Double

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let maxInputFrames: Int

    init(inputRate: Double, outputRate: Double, maxInputFrames: Int) throws {
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 2, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw CoreAudioError("샘플레이트 변환기 생성 실패 (\(Int(inputRate)) → \(Int(outputRate)) Hz)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let outCapacity = Int((Double(maxInputFrames) * outputRate / inputRate).rounded(.up)) + 64
        guard
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(maxInputFrames)),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outCapacity))
        else {
            throw CoreAudioError("샘플레이트 변환 버퍼 할당 실패")
        }

        self.inputRate = inputRate
        self.outputRate = outputRate
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.maxInputFrames = maxInputFrames
    }

    /// 플래너 스테레오 입력을 변환해 `emit(left, right)` 로 넘긴다 (0 프레임이면 호출 안 함).
    func process(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        emit: (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) throws -> Void
    ) throws {
        var offset = 0
        while offset < left.count {
            let n = min(maxInputFrames, left.count - offset)
            guard let inChannels = inputBuffer.floatChannelData else { return }
            inChannels[0].update(from: left.baseAddress! + offset, count: n)
            inChannels[1].update(from: right.baseAddress! + offset, count: n)
            inputBuffer.frameLength = AVAudioFrameCount(n)
            offset += n

            var supplied = false
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            // 스트림이 이어지므로 endOfStream 이 아니라 noDataNow 로 돌려준다 (변환기 내부 상태 유지)
            let status = converter.convert(to: outputBuffer, error: &conversionError) { [inputBuffer] _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw CoreAudioError("샘플레이트 변환 실패: \(conversionError?.localizedDescription ?? "unknown")")
            }

            let produced = Int(outputBuffer.frameLength)
            guard produced > 0, let outChannels = outputBuffer.floatChannelData else { continue }
            try emit(
                UnsafeBufferPointer(start: outChannels[0], count: produced),
                UnsafeBufferPointer(start: outChannels[1], count: produced)
            )
        }
    }
}
