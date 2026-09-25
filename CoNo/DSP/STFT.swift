// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// torch.stft / torch.istft 와 같은 결과를 내는 STFT.
//   center=True (양끝 n_fft/2 를 reflect 패딩), periodic Hann 창, onesided, normalized=False.
// MDX-Net 계열 모델은 이 규칙으로 학습됐으므로 한 가지라도 다르면 분리 품질이 무너진다.
//
// vDSP 실수 DFT 스케일 (실측): 정방향 = 2 × DFT, 역방향 = N × 원신호 (DFT 입력 기준).

import Accelerate

final class STFT {
    let nFFT: Int
    let hop: Int
    /// onesided 주파수 빈 수 = nFFT/2 + 1
    let bins: Int

    private let window: [Float]
    private let forwardDFT: vDSP.DiscreteFourierTransform<Float>
    private let inverseDFT: vDSP.DiscreteFourierTransform<Float>

    // 재사용 스크래치 (할당 최소화)
    private var frame: [Float]
    private var evenIn: [Float]
    private var oddIn: [Float]
    private var packedReal: [Float]
    private var packedImag: [Float]
    private var padded: [Float]
    private var overlap: [Float]
    private var envelopeCache: (frames: Int, values: [Float])?

    init(nFFT: Int, hop: Int) throws {
        precondition(nFFT % 2 == 0 && hop > 0 && hop <= nFFT)
        self.nFFT = nFFT
        self.hop = hop
        bins = nFFT / 2 + 1
        // periodic Hann: 0.5 - 0.5 cos(2πn/N)
        window = (0..<nFFT).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nFFT)) }
        forwardDFT = try vDSP.DiscreteFourierTransform(count: nFFT, direction: .forward, transformType: .complexReal, ofType: Float.self)
        inverseDFT = try vDSP.DiscreteFourierTransform(count: nFFT, direction: .inverse, transformType: .complexReal, ofType: Float.self)
        frame = [Float](repeating: 0, count: nFFT)
        evenIn = [Float](repeating: 0, count: nFFT / 2)
        oddIn = evenIn
        packedReal = evenIn
        packedImag = evenIn
        padded = []
        overlap = []
    }

    /// center=True 일 때 프레임 수.
    func frameCount(forSampleCount count: Int) -> Int {
        1 + count / hop
    }

    /// 정방향 STFT. 결과는 주파수 우선 배열 `real[f * frames + t]` 로 쓰고, `maxBins` 개 빈만 기록한다.
    /// - Precondition: `count > nFFT / 2` (reflect 패딩 조건)
    func forward(
        _ signal: UnsafeBufferPointer<Float>,
        maxBins: Int,
        real: UnsafeMutablePointer<Float>,
        imag: UnsafeMutablePointer<Float>
    ) {
        let count = signal.count
        let half = nFFT / 2
        precondition(count > half, "reflect 패딩에는 신호가 n_fft/2 보다 길어야 한다")
        let frames = frameCount(forSampleCount: count)
        let usedBins = min(maxBins, bins)

        // reflect 패딩 (가장자리 샘플은 반복하지 않음 — numpy/torch 'reflect')
        let paddedCount = count + nFFT
        if padded.count < paddedCount { padded = [Float](repeating: 0, count: paddedCount) }
        for i in 0..<paddedCount {
            var j = i - half
            if j < 0 { j = -j } else if j >= count { j = 2 * count - 2 - j }
            padded[i] = signal[j]
        }

        for t in 0..<frames {
            let start = t * hop
            for n in 0..<half {
                evenIn[n] = padded[start + 2 * n] * window[2 * n]
                oddIn[n] = padded[start + 2 * n + 1] * window[2 * n + 1]
            }
            forwardDFT.transform(inputReal: evenIn, inputImaginary: oddIn, outputReal: &packedReal, outputImaginary: &packedImag)

            // 언팩 + 스케일 보정(½). packedImag[0] 은 나이퀴스트 빈의 실수부.
            for f in 0..<usedBins {
                let re: Float
                let im: Float
                if f == 0 {
                    re = packedReal[0] * 0.5
                    im = 0
                } else if f == half {
                    re = packedImag[0] * 0.5
                    im = 0
                } else {
                    re = packedReal[f] * 0.5
                    im = packedImag[f] * 0.5
                }
                real[f * frames + t] = re
                imag[f * frames + t] = im
            }
        }
    }

    /// 역방향 STFT. 입력은 `forward` 와 같은 주파수 우선 배열이며 `providedBins` 개만 있고 나머지 빈은 0 으로 본다.
    /// 출력 길이 = hop × (frames − 1) (torch.istft center=True, length 미지정과 동일).
    func inverse(
        real: UnsafePointer<Float>,
        imag: UnsafePointer<Float>,
        providedBins: Int,
        frames: Int,
        output: UnsafeMutableBufferPointer<Float>
    ) {
        let half = nFFT / 2
        let outCount = hop * (frames - 1)
        precondition(output.count >= outCount)
        let usedBins = min(providedBins, bins)

        let totalCount = nFFT + hop * (frames - 1)
        if overlap.count < totalCount { overlap = [Float](repeating: 0, count: totalCount) }
        overlap.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }

        let scale = 1 / Float(nFFT)
        for t in 0..<frames {
            // 팩: DC·나이퀴스트의 허수부는 버린다 (irfft 동작)
            for f in 0..<half {
                if f < usedBins {
                    packedReal[f] = real[f * frames + t]
                    packedImag[f] = f == 0 ? 0 : imag[f * frames + t]
                } else {
                    packedReal[f] = 0
                    packedImag[f] = 0
                }
            }
            packedImag[0] = half < usedBins ? real[half * frames + t] : 0

            inverseDFT.transform(inputReal: packedReal, inputImaginary: packedImag, outputReal: &evenIn, outputImaginary: &oddIn)
            for n in 0..<half {
                frame[2 * n] = evenIn[n] * scale
                frame[2 * n + 1] = oddIn[n] * scale
            }
            let start = t * hop
            for n in 0..<nFFT {
                overlap[start + n] += frame[n] * window[n]
            }
        }

        let envelope = windowEnvelope(frames: frames)
        for i in 0..<outCount {
            let e = envelope[i + half]
            output[i] = e > 1e-11 ? overlap[i + half] / e : 0
        }
    }

    /// Σ window² 오버랩 엔벨로프 (프레임 수별 캐시)
    private func windowEnvelope(frames: Int) -> [Float] {
        if let cache = envelopeCache, cache.frames == frames { return cache.values }
        var values = [Float](repeating: 0, count: nFFT + hop * (frames - 1))
        for t in 0..<frames {
            for n in 0..<nFFT {
                values[t * hop + n] += window[n] * window[n]
            }
        }
        envelopeCache = (frames, values)
        return values
    }
}
