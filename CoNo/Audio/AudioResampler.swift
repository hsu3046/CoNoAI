// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 스트리밍 샘플레이트 변환 (AVAudioConverter, 플래너 1~2채널). 워커 스레드 전용 — IO 스레드에서 쓰지 말 것.

import AVFoundation

final class AudioResampler {
    let channelCount: Int
    let inputRate: Double
    let outputRate: Double

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let maxInputFrames: Int

    init(inputRate: Double, outputRate: Double, channelCount: Int = 2, maxInputFrames: Int) throws {
        precondition(channelCount == 1 || channelCount == 2)
        let channels = AVAudioChannelCount(channelCount)
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: channels, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: channels, interleaved: false),
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

        self.channelCount = channelCount
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
        precondition(channelCount == 2)
        try convert([left, right]) { try emit($0[0], $0[1]) }
    }

    /// 모노 입력을 변환해 `emit` 으로 넘긴다.
    func process(mono: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        precondition(channelCount == 1)
        try convert([mono]) { try emit($0[0]) }
    }

    private func convert(
        _ inputs: [UnsafeBufferPointer<Float>],
        emit: ([UnsafeBufferPointer<Float>]) throws -> Void
    ) throws {
        let total = inputs[0].count
        var offset = 0
        while offset < total {
            let n = min(maxInputFrames, total - offset)
            guard let inChannels = inputBuffer.floatChannelData else { return }
            for channel in 0..<channelCount {
                inChannels[channel].update(from: inputs[channel].baseAddress! + offset, count: n)
            }
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
            try emit((0..<channelCount).map { UnsafeBufferPointer(start: outChannels[$0], count: produced) })
        }
    }
}
