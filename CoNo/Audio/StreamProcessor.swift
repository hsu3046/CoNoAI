// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 워커 스레드에서 도는 처리 단계. 입력 = 캡처(탭) 레이트, 출력 = 재생(장치) 레이트의 인터리브 스테레오.
// 처리 방식은 시작할 때 정한다 (방식마다 지연이 달라서 실행 중에 바꾸면 싱크가 깨진다).

import Foundation
import Synchronization

protocol StreamProcessor: AnyObject {
    /// 입력을 처리하고 결과를 `emit` 으로 넘긴다. 출력 길이는 입력과 다를 수 있다 (분리기는 step 단위로 몰아서 낸다).
    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws
}
/// 그대로 통과 (캡처·지연 검증용)
final class PassthroughProcessor: StreamProcessor {
    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws {
        emit(input)
    }
}

/// 고전적인 L−R 센터 캔슬. 가운데 정위된 보컬이 줄지만 베이스·킥도 같이 빠진다.
final class CenterCancelProcessor: StreamProcessor {
    private var scratch: [Float] = []

    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws {
        if scratch.count < input.count { scratch = [Float](repeating: 0, count: input.count) }
        let frames = input.count / 2
        for frame in 0..<frames {
            let side = (input[frame * 2] - input[frame * 2 + 1]) * 0.7
            scratch[frame * 2] = side
            scratch[frame * 2 + 1] = side
        }
        scratch.withUnsafeBufferPointer { emit(UnsafeBufferPointer(rebasing: $0[0..<input.count])) }
    }
}

/// 입력 레이트에서 도는 처리기 뒤에 출력 레이트 변환을 붙인다 (그대로 / L−R 용).
final class ResamplingProcessor: StreamProcessor {
    private let inner: StreamProcessor
    private let resampler: AudioResampler
    private var left: [Float] = []
    private var right: [Float] = []
    private var interleaved: [Float] = []

    init(wrapping inner: StreamProcessor, inputRate: Double, outputRate: Double) throws {
        self.inner = inner
        resampler = try AudioResampler(inputRate: inputRate, outputRate: outputRate, maxInputFrames: 4_096)
    }

    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws {
        var pendingError: Error?
        try inner.process(input) { processed in
            do {
                try resample(processed, emit: emit)
            } catch {
                pendingError = error
            }
        }
        if let pendingError { throw pendingError }
    }

    private func resample(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws {
        let frames = input.count / 2
        if left.count < frames {
            left = [Float](repeating: 0, count: frames)
            right = left
        }
        for i in 0..<frames {
            left[i] = input[i * 2]
            right[i] = input[i * 2 + 1]
        }
        try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                try resampler.process(
                    left: UnsafeBufferPointer(rebasing: l[0..<frames]),
                    right: UnsafeBufferPointer(rebasing: r[0..<frames])
                ) { outLeft, outRight in
                    let n = outLeft.count
                    if interleaved.count < n * 2 { interleaved = [Float](repeating: 0, count: n * 2) }
                    for i in 0..<n {
                        interleaved[i * 2] = outLeft[i]
                        interleaved[i * 2 + 1] = outRight[i]
                    }
                    interleaved.withUnsafeBufferPointer { emit(UnsafeBufferPointer(rebasing: $0[0..<(n * 2)])) }
                }
            }
        }
    }
}
