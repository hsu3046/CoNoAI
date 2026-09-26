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

// MARK: - AI 보컬 분리

/// 분리 결과 중 무엇을 들려줄지 (실행 중에도 바꿀 수 있다 — 셋 다 같은 시점으로 정렬돼 있음)
enum SeparationOutput: Int, CaseIterable, Sendable {
    case accompaniment = 0
    case vocals = 1
    case original = 2

    var label: String {
        switch self {
        case .accompaniment: "반주"
        case .vocals: "보컬"
        case .original: "원곡"
        }
    }
}

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

            let selection = output
            let guide = guideVocalLevel
            for i in 0..<n {
                switch selection {
                case .accompaniment:
                    selectedLeft[i] = out.accompanimentLeft[i] + vocalLeft[i] * guide
                    selectedRight[i] = out.accompanimentRight[i] + vocalRight[i] * guide
                case .vocals:
                    selectedLeft[i] = vocalLeft[i]
                    selectedRight[i] = vocalRight[i]
                case .original:
                    selectedLeft[i] = out.mixLeft[i]
                    selectedRight[i] = out.mixRight[i]
                }
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
