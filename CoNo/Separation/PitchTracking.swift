// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 분리된 보컬 → (16 kHz 모노) → SwiftF0 스트리밍 → PitchTimeline.
//
// 시간축: 모든 프레임 시각은 "처리기 출력 스트림의 초" 다. 보컬은 반주와 같은 출력 스트림에서 나오므로
// 프레임 i 의 시각 = i × 16 ms 이고, 재생 위치(DelayPipeline.playbackPosition)와 같은 축이다.
// (리샘플러 군지연 수 ms 는 무시 — 16 ms 프레임보다 작다)

import Foundation
import Synchronization

/// 워커가 쓰고 UI 가 읽는 음정 프레임 기록.
final class PitchTimeline: @unchecked Sendable {
    let framePeriod: Double
    /// 보관할 최대 프레임 (넘으면 앞 절반을 버린다)
    private let maxFrames: Int
    private let frames = Mutex<[PitchFrame]>([])
    private let lastError = Mutex<String?>(nil)

    init(framePeriod: Double, keepSeconds: Double = 180) {
        self.framePeriod = framePeriod
        maxFrames = Int(keepSeconds / framePeriod)
    }

    func append(_ newFrames: [PitchFrame]) {
        guard !newFrames.isEmpty else { return }
        frames.withLock { stored in
            stored.append(contentsOf: newFrames)
            if stored.count > maxFrames {
                stored.removeFirst(stored.count - maxFrames / 2)
            }
        }
    }

    func record(error: Error) {
        lastError.withLock { $0 = error.localizedDescription }
    }

    var error: String? { lastError.withLock { $0 } }

    /// [from, to) 초 구간의 연속 프레임과, 분석이 끝난 시각(마지막 프레임 끝).
    func snapshot(from: Double, to: Double) -> (frames: [PitchFrame], knownUntil: Double) {
        frames.withLock { stored in
            guard let first = stored.first, let last = stored.last else { return ([], 0) }
            let knownUntil = Double(last.index + 1) * framePeriod
            let fromIndex = max(first.index, Int((from / framePeriod).rounded(.down)))
            let toIndex = min(last.index + 1, Int((to / framePeriod).rounded(.up)))
            guard toIndex > fromIndex else { return ([], knownUntil) }
            // 프레임 번호가 연속이므로 배열 위치 = 번호 − 첫 번호
            let slice = stored[(fromIndex - first.index)..<(toIndex - first.index)]
            return (Array(slice), knownUntil)
        }
    }
}

/// 워커 스레드 전용: 모델 레이트 스테레오 보컬을 받아 음정 프레임을 타임라인에 쌓는다.
final class PitchTracker {
    let timeline: PitchTimeline
    private let resampler: AudioResampler?
    private let stream: PitchFrameStream
    private var mono: [Float] = []

    init(detector: SwiftF0Detector, inputSampleRate: Double) throws {
        stream = PitchFrameStream(estimator: detector)
        timeline = PitchTimeline(framePeriod: SwiftF0Detector.framePeriod)
        resampler = abs(inputSampleRate - SwiftF0Detector.sampleRate) > 0.5
            ? try AudioResampler(inputRate: inputSampleRate, outputRate: SwiftF0Detector.sampleRate, channelCount: 1, maxInputFrames: 8_192)
            : nil
    }

    /// 실패해도 오디오는 계속 돌아야 하므로 throw 하지 않고 타임라인에 오류만 남긴다.
    func push(vocalLeft: UnsafeBufferPointer<Float>, vocalRight: UnsafeBufferPointer<Float>) {
        let n = vocalLeft.count
        if mono.count < n { mono = [Float](repeating: 0, count: n) }
        for i in 0..<n { mono[i] = (vocalLeft[i] + vocalRight[i]) * 0.5 }

        do {
            try mono.withUnsafeBufferPointer { buffer in
                let input = UnsafeBufferPointer(rebasing: buffer[0..<n])
                if let resampler {
                    try resampler.process(mono: input) { timeline.append(try stream.push($0)) }
                } else {
                    timeline.append(try stream.push(input))
                }
            }
        } catch {
            timeline.record(error: error)
        }
    }
}
