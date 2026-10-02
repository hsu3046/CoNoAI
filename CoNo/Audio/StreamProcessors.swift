// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Synchronization

// MARK: - AI 보컬 분리

/// 추론 시간 통계 (워커가 쓰고 UI 가 읽는다)
struct InferenceStats: Sendable {
    var count = 0
    var lastMilliseconds: Double = 0
    var averageMilliseconds: Double = 0
    var maxMilliseconds: Double = 0
}

final class SeparationProcessor: StreamProcessor, @unchecked Sendable {
    let streamOffsetSeconds: Double
    let maxWaitSeconds: Double
    let vocalAudioBuffer: VocalAudioBuffer

    private let compensate: Float
    private let streaming: StreamingSeparator
    private let timedSeparator: TimedSeparator
    /// 입력·출력 레이트가 모델 레이트와 다를 때만 존재
    private let downsampler: AudioResampler?
    private let upsampler: AudioResampler?

    private let outputSelection = Atomic<Int>(SeparationOutput.accompaniment.rawValue)
    /// 가이드 보컬: 반주에 섞을 원곡 보컬 비율 (0 = 순수 반주). Float 비트로 저장 (UI ↔ 워커)
    private let guideVocalBits = Atomic<UInt32>(Float(0).bitPattern)

    // 스크래치 (워커 스레드 전용)
    private var planarLeft: [Float] = []
    private var planarRight: [Float] = []
    private var selectedLeft: [Float] = []
    private var selectedRight: [Float] = []
    private var vocalLeft: [Float] = []
    private var vocalRight: [Float] = []
    private var interleaved: [Float] = []
    private var outputMix: SeparationMix
    private var vocalFrameOffset = 0

    /// 분리된 보컬의 음정을 추적 (없으면 음정 바 없이 분리만)
    private let pitchTracker: PitchTracker?

    init(
        separator: MDXSeparator,
        settings: StreamingSeparatorSettings,
        inputSampleRate: Double,
        outputSampleRate: Double,
        pitchDetector: SwiftF0Detector?
    ) throws {
        let modelRate = separator.config.sampleRate
        vocalAudioBuffer = VocalAudioBuffer(sampleRate: modelRate)
        outputMix = SeparationMix(sampleRate: modelRate)
        timedSeparator = TimedSeparator(separator)
        streaming = try StreamingSeparator(separator: timedSeparator, settings: settings)
        compensate = separator.config.compensate
        pitchTracker = try pitchDetector.map { try PitchTracker(detector: $0, inputSampleRate: modelRate) }
        streamOffsetSeconds = Double(streaming.streamOffsetSamples) / modelRate
        maxWaitSeconds = Double(streaming.maxWaitSamples) / modelRate

        // 입력(탭) → 모델, 모델 → 출력(장치) 은 서로 다른 레이트일 수 있어 따로 판단한다
        downsampler = abs(inputSampleRate - modelRate) > 0.5
            ? try AudioResampler(inputRate: inputSampleRate, outputRate: modelRate, maxInputFrames: 4_096)
            : nil
        upsampler = abs(outputSampleRate - modelRate) > 0.5
            ? try AudioResampler(inputRate: modelRate, outputRate: outputSampleRate, maxInputFrames: 4_096)
            : nil
    }

    var output: SeparationOutput {
        get { SeparationOutput(rawValue: outputSelection.load(ordering: .relaxed)) ?? .accompaniment }
        set { outputSelection.store(newValue.rawValue, ordering: .relaxed) }
    }

    /// 반주에 섞을 원곡 보컬 비율 (0...0.5). 노래방 기계의 멜로디 가이드처럼 부를 줄을 살짝 들려준다.
    var guideVocalLevel: Float {
        get { Float(bitPattern: guideVocalBits.load(ordering: .relaxed)) }
        set { guideVocalBits.store(min(max(newValue, 0), 0.5).bitPattern, ordering: .relaxed) }
    }

    var inferenceStats: InferenceStats { timedSeparator.stats }

    var pitchTimeline: PitchTimeline? { pitchTracker?.timeline }

    func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) -> Void) throws {
        let frames = input.count / 2
        if planarLeft.count < frames {
            planarLeft = [Float](repeating: 0, count: frames)
            planarRight = planarLeft
        }
        for i in 0..<frames {
            planarLeft[i] = input[i * 2]
            planarRight[i] = input[i * 2 + 1]
        }

        try planarLeft.withUnsafeBufferPointer { l in
            try planarRight.withUnsafeBufferPointer { r in
                let left = UnsafeBufferPointer(rebasing: l[0..<frames])
                let right = UnsafeBufferPointer(rebasing: r[0..<frames])
                if let downsampler {
                    try downsampler.process(left: left, right: right) { dl, dr in
                        try separate(left: dl, right: dr, emit: emit)
                    }
                } else {
                    try separate(left: left, right: right, emit: emit)
                }
            }
        }
    }

    /// 모델 레이트 입력 → 분리 → 선택 출력 → (업샘플) → 인터리브 emit
    private func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        emit: (UnsafeBufferPointer<Float>) -> Void
    ) throws {
        var pendingError: Error?
        try streaming.push(left: left, right: right) { out in
            let n = out.accompanimentLeft.count
            if selectedLeft.count < n {
                selectedLeft = [Float](repeating: 0, count: n)
                selectedRight = selectedLeft
                vocalLeft = selectedLeft
                vocalRight = selectedLeft
            }
            // 보컬 = 원곡 − 반주 × 보정계수 (들려줄 출력과 무관하게 음정 추적용으로 항상 계산)
            for i in 0..<n {
                vocalLeft[i] = out.mixLeft[i] - out.accompanimentLeft[i] * compensate
                vocalRight[i] = out.mixRight[i] - out.accompanimentRight[i] * compensate
            }
            // 분리 워커에서만 메모리 링을 채운다. IO 콜백과 추론 작업은 이 경로에 들어오지 않는다.
            vocalLeft.withUnsafeBufferPointer { l in
                vocalRight.withUnsafeBufferPointer { r in
                    vocalAudioBuffer.append(left: UnsafeBufferPointer(rebasing: l[0..<n]),
                                            right: UnsafeBufferPointer(rebasing: r[0..<n]), startFrame: vocalFrameOffset)
                }
            }
            vocalFrameOffset += n
            if let pitchTracker {
                vocalLeft.withUnsafeBufferPointer { l in
                    vocalRight.withUnsafeBufferPointer { r in
                        pitchTracker.push(
                            vocalLeft: UnsafeBufferPointer(rebasing: l[0..<n]),
                            vocalRight: UnsafeBufferPointer(rebasing: r[0..<n])
                        )
                    }
                }
            }

            outputMix.select(output, guide: guideVocalLevel)
            for i in 0..<n {
                let pair = outputMix.next(accompanimentLeft: out.accompanimentLeft[i], accompanimentRight: out.accompanimentRight[i],
                                          vocalLeft: vocalLeft[i], vocalRight: vocalRight[i],
                                          originalLeft: out.mixLeft[i], originalRight: out.mixRight[i])
                selectedLeft[i] = pair.0
                selectedRight[i] = pair.1
            }
            do {
                try selectedLeft.withUnsafeBufferPointer { sl in
                    try selectedRight.withUnsafeBufferPointer { sr in
                        let l = UnsafeBufferPointer(rebasing: sl[0..<n])
                        let r = UnsafeBufferPointer(rebasing: sr[0..<n])
                        if let upsampler {
                            try upsampler.process(left: l, right: r) { ul, ur in emitInterleaved(ul, ur, emit) }
                        } else {
                            emitInterleaved(l, r, emit)
                        }
                    }
                }
            } catch {
                pendingError = error
            }
        }
        if let pendingError { throw pendingError }
    }

    private func emitInterleaved(
        _ left: UnsafeBufferPointer<Float>,
        _ right: UnsafeBufferPointer<Float>,
        _ emit: (UnsafeBufferPointer<Float>) -> Void
    ) {
        let n = left.count
        if interleaved.count < n * 2 { interleaved = [Float](repeating: 0, count: n * 2) }
        for i in 0..<n {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }
        interleaved.withUnsafeBufferPointer { emit(UnsafeBufferPointer(rebasing: $0[0..<(n * 2)])) }
    }
}

/// 추론 시간을 재는 래퍼
private final class TimedSeparator: ChunkSeparating, @unchecked Sendable {
    private let inner: ChunkSeparating
    private let statsLock = Mutex(InferenceStats())

    init(_ inner: ChunkSeparating) {
        self.inner = inner
    }

    var chunkSize: Int { inner.chunkSize }
    var edgeTrim: Int { inner.edgeTrim }
    var stats: InferenceStats { statsLock.withLock { $0 } }

    func separate(
        left: UnsafeBufferPointer<Float>,
        right: UnsafeBufferPointer<Float>,
        outLeft: UnsafeMutableBufferPointer<Float>,
        outRight: UnsafeMutableBufferPointer<Float>
    ) throws {
        let start = ContinuousClock.now
        try inner.separate(left: left, right: right, outLeft: outLeft, outRight: outRight)
        let ms = (ContinuousClock.now - start).milliseconds
        statsLock.withLock { stats in
            stats.count += 1
            stats.lastMilliseconds = ms
            stats.maxMilliseconds = max(stats.maxMilliseconds, ms)
            stats.averageMilliseconds += (ms - stats.averageMilliseconds) / Double(stats.count)
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
