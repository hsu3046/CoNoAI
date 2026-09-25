// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 가사(LRC) 줄 시작 시각과 분리된 보컬의 "쉬었다가 노래를 시작하는 지점" 을 맞춰
// 곡마다 가사 시각 오차를 자동으로 잰다.
// (실측: LRCLIB 가사는 곡마다 품질이 달라 First Love 는 약 1초 이르게 만들어져 있었다 — docs/DECISIONS.md)
//
// 점수(δ) = 줄마다 (LRC 시작 + δ) 근처 ±3 프레임의 "발성 시작 세기" 최댓값의 평균
//   발성 시작 세기(프레임 k) = [k, k+160ms) 유성 비율 × [k−240ms, k) 무성 비율
// 가장 높은 δ 를 고르고, 평균 대비 돋보이는 정도와 줄 수로 신뢰도를 낸다.

import Foundation

struct AutoSyncEstimate: Equatable, Sendable {
    /// 가사를 늦춰야 하는 시간 (초). + = LRC 가 실제 노래보다 이르다.
    let lyricsDelay: Double
    /// 0~1
    let confidence: Double
    /// 평가한 줄 수
    let lineCount: Int
    /// 최고 점수 (0~1) — 가사 후보끼리 비교할 때 쓴다
    let score: Double
}

enum LyricsAutoSync {
    static let searchRange: ClosedRange<Double> = -2.5...2.5
    static let minimumLines = 3

    /// - Parameters:
    ///   - lineStarts: 평가할 LRC 줄 시작 (곡 초). ±searchRange 만큼 frames 로 덮여 있어야 한다.
    ///   - frames: 곡 초 기준 연속 프레임 (간격 framePeriod)
    static func estimate(lineStarts: [Double], frames: [VocalFrame], framePeriod: Double) -> AutoSyncEstimate? {
        guard let first = frames.first, !frames.isEmpty else { return nil }
        let origin = first.time
        let count = frames.count

        // 발성 시작 세기
        var voicedPrefix = [0]
        for frame in frames { voicedPrefix.append(voicedPrefix.last! + (frame.voiced ? 1 : 0)) }
        func voicedFraction(_ from: Int, _ to: Int) -> Double {
            let a = max(0, from)
            let b = min(count, to)
            guard b > a else { return 0 }
            return Double(voicedPrefix[b] - voicedPrefix[a]) / Double(b - a)
        }
        let after = max(1, Int((0.16 / framePeriod).rounded()))
        let before = max(1, Int((0.24 / framePeriod).rounded()))
        var onset = [Double](repeating: 0, count: count)
        for k in 0..<count where frames[k].voiced && k >= before {
            onset[k] = voicedFraction(k, k + after) * (1 - voicedFraction(k - before, k))
        }

        // 탐색 범위 전체가 프레임 안에 드는 줄만
        let usable = lineStarts.filter { start in
            start + searchRange.lowerBound >= origin && start + searchRange.upperBound < origin + Double(count) * framePeriod
        }
        guard usable.count >= minimumLines else { return nil }

        let step = framePeriod
        var scores: [(delta: Double, score: Double)] = []
        var delta = searchRange.lowerBound
        while delta <= searchRange.upperBound + 1e-9 {
            var total = 0.0
            for start in usable {
                let center = Int(((start + delta - origin) / framePeriod).rounded())
                var best = 0.0
                for k in max(0, center - 3)...min(count - 1, center + 3) { best = max(best, onset[k]) }
                total += best
            }
            scores.append((delta, total / Double(usable.count)))
            delta += step
        }

        // 최고 점수 (거의 같으면 0 에 가까운 쪽 — 반복되는 박자에 끌려 멀리 튀지 않게)
        let top = scores.map(\.score).max() ?? 0
        guard top > 0,
              let best = scores.filter({ $0.score >= top - 0.02 }).min(by: { abs($0.delta) < abs($1.delta) })
        else { return nil }
        let mean = scores.reduce(0) { $0 + $1.score } / Double(scores.count)
        let prominence = min(max((best.score - mean) / 0.3, 0), 1)
        let coverage = min(1, Double(usable.count) / 6)
        return AutoSyncEstimate(
            lyricsDelay: best.delta,
            confidence: prominence * coverage,
            lineCount: usable.count,
            score: best.score
        )
    }
}
