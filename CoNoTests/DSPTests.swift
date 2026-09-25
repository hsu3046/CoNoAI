// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation
import Testing

// MARK: - STFT (torch 호환성)

struct STFTTests {
    /// 결정적 테스트 신호
    private func signal(count: Int) -> [Float] {
        (0..<count).map { i in
            let t = Double(i)
            return Float(0.6 * sin(t * 0.031) + 0.3 * cos(t * 0.47 + 1) + 0.05 * sin(t * 2.9))
        }
    }

    /// torch.stft 정의를 그대로 옮긴 naive 계산 (reflect 패딩 + periodic Hann + DFT)
    private func naiveBin(_ x: [Float], nFFT: Int, hop: Int, frame t: Int, bin f: Int) -> (Double, Double) {
        let half = nFFT / 2
        var re = 0.0
        var im = 0.0
        for n in 0..<nFFT {
            var j = t * hop + n - half
            if j < 0 { j = -j } else if j >= x.count { j = 2 * x.count - 2 - j }
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(nFFT))
            let angle = -2 * Double.pi * Double(f * n) / Double(nFFT)
            re += Double(x[j]) * w * cos(angle)
            im += Double(x[j]) * w * sin(angle)
        }
        return (re, im)
    }

    @Test func forwardMatchesTorchDefinition() throws {
        let nFFT = 5120, hop = 1024
        let x = signal(count: hop * 12)
        let stft = try STFT(nFFT: nFFT, hop: hop)
        let frames = stft.frameCount(forSampleCount: x.count)
        var real = [Float](repeating: 0, count: stft.bins * frames)
        var imag = real
        x.withUnsafeBufferPointer { stft.forward($0, maxBins: stft.bins, real: &real, imag: &imag) }

        // 가장자리(reflect) 프레임, 가운데 프레임, 마지막 프레임 × DC·일반·나이퀴스트 빈
        for t in [0, 1, frames / 2, frames - 1] {
            for f in [0, 3, 57, 1000, stft.bins - 1] {
                let (expRe, expIm) = naiveBin(x, nFFT: nFFT, hop: hop, frame: t, bin: f)
                let tolerance = 1e-3 * max(1, abs(expRe) + abs(expIm))
                #expect(abs(Double(real[f * frames + t]) - expRe) < tolerance, "real t=\(t) f=\(f)")
                #expect(abs(Double(imag[f * frames + t]) - expIm) < tolerance, "imag t=\(t) f=\(f)")
            }
        }
    }

    @Test func inverseRoundTrips() throws {
        let nFFT = 5120, hop = 1024
        let frames = 64
        let x = signal(count: hop * (frames - 1))
        let stft = try STFT(nFFT: nFFT, hop: hop)
        #expect(stft.frameCount(forSampleCount: x.count) == frames)

        var real = [Float](repeating: 0, count: stft.bins * frames)
        var imag = real
        x.withUnsafeBufferPointer { stft.forward($0, maxBins: stft.bins, real: &real, imag: &imag) }

        var y = [Float](repeating: 0, count: x.count)
        y.withUnsafeMutableBufferPointer { out in
            stft.inverse(real: real, imag: imag, providedBins: stft.bins, frames: frames, output: out)
        }
        let maxError = zip(x, y).map { abs($0 - $1) }.max() ?? 0
        #expect(maxError < 1e-4)
    }
}

// MARK: - StreamingSeparator (정렬·연속성)

/// 호출마다 (호출 번호 × 1000) 상수를 내는 분리기 대역 (오른쪽은 절반) — 크로스페이드 검증용
private final class StepConstantSeparator: ChunkSeparating {
    let chunkSize: Int
    let edgeTrim: Int
    private var calls = 0

    init(chunkSize: Int, edgeTrim: Int) {
        self.chunkSize = chunkSize
        self.edgeTrim = edgeTrim
    }

    func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        outLeft: UnsafeMutableBufferPointer<Float>,
        outRight: UnsafeMutableBufferPointer<Float>
    ) throws {
        calls += 1
        for i in 0..<chunkSize {
            outLeft[i] = Float(calls) * 1000
            outRight[i] = Float(calls) * 500
        }
    }
}

/// 입력을 그대로 돌려주는 분리기 대역 — 반주 == 원곡 이어야 하고, 출력은 입력을 정확히 지연시킨 것이어야 한다.
private final class IdentitySeparator: ChunkSeparating {
    let chunkSize: Int
    let edgeTrim: Int
    private(set) var calls = 0

    init(chunkSize: Int, edgeTrim: Int) {
        self.chunkSize = chunkSize
        self.edgeTrim = edgeTrim
    }

    func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        outLeft: UnsafeMutableBufferPointer<Float>,
        outRight: UnsafeMutableBufferPointer<Float>
    ) throws {
        calls += 1
        for i in 0..<chunkSize {
            outLeft[i] = left[i]
            outRight[i] = right[i] * 0.5 // 오른쪽은 절반으로: 채널이 섞이지 않는지 확인
        }
    }
}

struct StreamingSeparatorTests {
    @Test func outputIsExactlyDelayedInput() throws {
        let separator = IdentitySeparator(chunkSize: 1000, edgeTrim: 50)
        let settings = StreamingSeparatorSettings(step: 120, rightContext: 200, fade: 40)
        let streaming = try StreamingSeparator(separator: separator, settings: settings)

        let total = 5000
        let inputLeft = (0..<total).map { Float($0 + 1) }
        let inputRight = inputLeft.map { -$0 }
        var accLeft: [Float] = []
        var accRight: [Float] = []
        var mixLeft: [Float] = []

        // 일부러 step 과 안 맞는 크기로 잘라 넣는다
        var offset = 0
        for size in [37, 250, 1, 999, 400, 13].cycled(until: total) {
            let n = min(size, total - offset)
            guard n > 0 else { break }
            try inputLeft[offset..<(offset + n)].withUnsafeBufferPointer { l in
                try inputRight[offset..<(offset + n)].withUnsafeBufferPointer { r in
                    try streaming.push(left: l, right: r) { out in
                        accLeft += out.accompanimentLeft
                        accRight += out.accompanimentRight
                        mixLeft += out.mixLeft
                    }
                }
            }
            offset += n
        }

        // 출력 o = 입력 (o − rightContext). step 은 대기 시간일 뿐 위치 오프셋이 아니다.
        let latency = streaming.streamOffsetSamples
        #expect(latency == 200)
        #expect(streaming.maxWaitSamples == 320)
        // 스텝 단위로만 출력되므로 출력 길이 = 소비한 스텝 수 × step
        #expect(accLeft.count == (total / settings.step) * settings.step)
        #expect(separator.calls == total / settings.step)

        for i in 0..<accLeft.count {
            let expected: Float = i >= latency ? inputLeft[i - latency] : 0
            #expect(mixLeft[i] == expected, "mix i=\(i)")
            // 첫 스텝의 페이드인(이전 꼬리가 0) 이후에는 크로스페이드가 원래 값을 보존해야 한다
            if i >= settings.fade {
                #expect(abs(accLeft[i] - expected) < 1e-3, "acc L i=\(i)")
                #expect(abs(accRight[i] - (-expected * 0.5)) < 1e-3, "acc R i=\(i)")
            }
        }
    }

    @Test func stepSeamsAreCrossfadedLinearly() throws {
        // 창마다 다른 상수를 내는 분리기 → 이음매가 "이전 꼬리 → 이번 값" 선형 혼합인지 본다.
        // (항등 분리기는 모든 창이 같은 값이라 크로스페이드를 지워도 통과한다)
        let separator = StepConstantSeparator(chunkSize: 1000, edgeTrim: 50)
        let settings = StreamingSeparatorSettings(step: 120, rightContext: 200, fade: 40)
        let streaming = try StreamingSeparator(separator: separator, settings: settings)

        let total = 2400
        let inputLeft = [Float](repeating: 0, count: total)
        let inputRight = (0..<total).map { Float($0 + 1) }
        var accLeft: [Float] = []
        var accRight: [Float] = []
        var mixRight: [Float] = []
        try inputLeft.withUnsafeBufferPointer { l in
            try inputRight.withUnsafeBufferPointer { r in
                try streaming.push(left: l, right: r) { out in
                    accLeft += out.accompanimentLeft
                    accRight += out.accompanimentRight
                    mixRight += out.mixRight
                }
            }
        }

        let step = settings.step
        let fade = settings.fade
        #expect(accLeft.count == (total / step) * step)
        for i in 0..<accLeft.count {
            let call = Float(i / step + 1)      // 이 스텝을 만든 호출 번호 (값 = 번호 × 1000)
            let k = i % step
            var expected = call * 1000
            if k < fade {
                let a = (Float(k) + 0.5) / Float(fade)
                expected = (call - 1) * 1000 * (1 - a) + call * 1000 * a
            }
            #expect(abs(accLeft[i] - expected) < 1e-2, "L i=\(i)")
            #expect(abs(accRight[i] - expected * 0.5) < 1e-2, "R i=\(i)")
            // 원곡(오른쪽)도 같은 스트림 오프셋으로
            let delayed: Float = i >= settings.rightContext ? inputRight[i - settings.rightContext] : 0
            #expect(mixRight[i] == delayed, "mixR i=\(i)")
        }
        // 창 사이 값 차이(1000)가 한 샘플에 몰리지 않고 fade 로 나뉜다
        let maxJump = zip(accLeft.dropFirst(step), accLeft.dropFirst(step + 1)).map { abs($1 - $0) }.max() ?? 0
        #expect(maxJump <= 1000 / Float(fade) + 1e-2, "이음매 점프 \(maxJump)")
    }

    @Test func rejectsRightContextInsideEdgeTrim() {
        let separator = IdentitySeparator(chunkSize: 1000, edgeTrim: 100)
        #expect(throws: StreamingSeparatorError.self) {
            _ = try StreamingSeparator(separator: separator, settings: .init(step: 100, rightContext: 120, fade: 40))
        }
    }
}

private extension Array {
    /// 합이 `total` 이상이 될 때까지 원소를 반복
    func cycled(until total: Int) -> [Element] where Element == Int {
        var result: [Int] = []
        var sum = 0
        while sum < total {
            for value in self {
                result.append(value)
                sum += value
            }
        }
        return result
    }
}
