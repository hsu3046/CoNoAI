// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Synchronization

struct VocalAudioClip: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let startTime: Double
    let generation: UInt64
}

/// 분리 워커 전용 입력, 분석 작업 전용 복사. IO 콜백에서는 절대로 호출하지 않는다.
/// 켜 둔 동안만 최근 60초의 모노 보컬을 메모리에 보관하며 파일로 쓰는 API는 없다.
final class VocalAudioBuffer: @unchecked Sendable {
    let sampleRate: Double
    let capacity: Int
    private struct State {
        var enabled = false
        var generation: UInt64 = 0
        var samples: [Float] = []
        var nextFrame: Int?
        var count = 0
    }
    private let state = Mutex(State())

    init(sampleRate: Double, keepSeconds: Double = 60) {
        precondition(sampleRate.isFinite && (1...192_000).contains(sampleRate))
        precondition(keepSeconds.isFinite && (0.1...120).contains(keepSeconds))
        self.sampleRate = sampleRate
        capacity = max(1, Int((sampleRate * keepSeconds).rounded(.up)))
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { value in
            guard value.enabled != enabled else { return }
            value.enabled = enabled
            value.generation &+= 1
            value.nextFrame = nil
            value.count = 0
            value.samples = enabled ? [Float](repeating: 0, count: capacity) : []
        }
    }

    func clear() {
        state.withLock { value in
            value.generation &+= 1
            value.nextFrame = nil
            value.count = 0
            value.samples = value.enabled ? [Float](repeating: 0, count: capacity) : []
        }
    }

    /// startFrame은 분리 출력의 누적 모델 레이트 프레임. 꺼진 구간도 호출자가 카운트한다.
    func append(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, startFrame: Int) {
        guard startFrame >= 0, left.count == right.count, !left.isEmpty,
              startFrame <= Int.max - left.count else { return }
        state.withLock { value in
            guard value.enabled else { return }
            if let previous = value.nextFrame, previous != startFrame {
                value.generation &+= 1
                value.count = 0
            }
            let skip = max(0, left.count - capacity)
            for index in skip..<left.count {
                let mono = left[index] * 0.5 + right[index] * 0.5
                guard mono.isFinite else {
                    value.generation &+= 1
                    value.count = 0
                    value.nextFrame = nil
                    return
                }
                value.samples[(startFrame + index) % capacity] = mono
            }
            value.nextFrame = startFrame + left.count
            value.count = min(capacity, value.count + left.count)
        }
    }

    var availableRange: Range<Double>? {
        state.withLock { value in
            guard value.enabled, value.count > 0, let end = value.nextFrame else { return nil }
            return Double(end - value.count) / sampleRate..<Double(end) / sampleRate
        }
    }

    /// 빠진 샘플이 없는 창만 반환한다. 큰 시각을 Int로 바꾸기 전에 보관 범위로 검증한다.
    func snapshot(from start: Double, to end: Double, maximumSeconds: Double = 20) -> VocalAudioClip? {
        guard start.isFinite, end.isFinite, end > start, end - start <= maximumSeconds + 1e-9,
              maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 20 else { return nil }
        return state.withLock { value in
            guard value.enabled, let next = value.nextFrame, value.count > 0 else { return nil }
            let first = next - value.count
            guard start >= Double(first) / sampleRate, end <= Double(next) / sampleRate,
                  start * sampleRate < Double(Int.max), end * sampleRate < Double(Int.max) else { return nil }
            let upper = min(next, Int((end * sampleRate).rounded(.up)))
            // 양 끝을 바깥쪽 샘플로 반올림해도 모델의 20초 상한은 넘지 않는다.
            // 필요하면 첫 샘플을 건너뛰고 반환 startTime으로 실제 시작을 전달한다.
            let maximumFrames = Int((maximumSeconds * sampleRate).rounded(.down))
            let lower = max(first, Int((start * sampleRate).rounded(.down)), upper - maximumFrames)
            guard upper > lower, upper - lower <= capacity else { return nil }
            let count = upper - lower
            let offset = lower % capacity
            let firstCount = min(count, capacity - offset)
            var copied = [Float](repeating: 0, count: count)
            copied.withUnsafeMutableBufferPointer { destination in
                value.samples.withUnsafeBufferPointer { source in
                    destination.baseAddress!.update(from: source.baseAddress! + offset, count: firstCount)
                    if firstCount < count {
                        (destination.baseAddress! + firstCount).update(from: source.baseAddress!, count: count - firstCount)
                    }
                }
            }
            return VocalAudioClip(samples: copied, sampleRate: sampleRate,
                                  startTime: Double(lower) / sampleRate, generation: value.generation)
        }
    }
}
