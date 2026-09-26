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
    /// 평소 추적 범위 (지금 적용 중인 지연 ± 이만큼)
    static let trackingHalfWidth: Double = 2.5
    static let searchRange: ClosedRange<Double> = -trackingHalfWidth...trackingHalfWidth
    /// 영상처럼 인트로 길이가 원곡과 다를 때 처음 한 번 넓게 찾는 범위
    static let coarseRange: ClosedRange<Double> = -30...30
    static let minimumLines = 3

    /// - Parameters:
    ///   - lineStarts: 평가할 LRC 줄 시작 (곡 초)
    ///   - frames: 곡 초 기준 연속 프레임 (간격 framePeriod)
    ///   - searchRange: 찾을 지연 범위. 점수가 거의 같으면 범위 가운데에 가까운 값을 고른다 (반복되는 박자에 끌려 튀지 않게).
    ///     좁은 범위(±2.5초 안팎)는 범위 전체가 프레임 안에 드는 줄만 쓰고,
    ///     넓은 범위는 지연마다 프레임 안에 드는 줄만 세고 가장 많이 센 지연의 줄 수로 나눈다 (적게 센 지연이 유리하지 않게).
    static func estimate(
        lineStarts: [Double],
        frames: [VocalFrame],
        framePeriod: Double,
        searchRange: ClosedRange<Double> = Self.searchRange
    ) -> AutoSyncEstimate? {
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

        let end = origin + Double(count) * framePeriod
        let wide = searchRange.upperBound - searchRange.lowerBound > 2 * trackingHalfWidth + 1
        // 좁은 범위: 탐색 범위 전체가 프레임 안에 드는 줄만 (모든 지연이 같은 줄로 겨룬다)
        let fixedLines = lineStarts.filter { start in
            start + searchRange.lowerBound >= origin && start + searchRange.upperBound < end
        }
        if !wide { guard fixedLines.count >= minimumLines else { return nil } }

        let step = framePeriod
        var sums: [(delta: Double, total: Double, lines: Int)] = []
        var delta = searchRange.lowerBound
        while delta <= searchRange.upperBound + 1e-9 {
            var total = 0.0
            var lines = 0
            for start in wide ? lineStarts : fixedLines {
                let shifted = start + delta
                guard shifted >= origin, shifted < end else { continue }
                let center = Int(((shifted - origin) / framePeriod).rounded())
                var best = 0.0
                for k in max(0, center - 3)...min(count - 1, center + 3) { best = max(best, onset[k]) }
                total += best
                lines += 1
            }
            sums.append((delta, total, lines))
            delta += step
        }
        let coveredLines = sums.map(\.lines).max() ?? 0
        guard coveredLines >= minimumLines else { return nil }
        let scores = sums.map { (delta: $0.delta, score: $0.total / Double(coveredLines)) }

        // 최고 점수 (거의 같으면 범위 가운데에 가까운 쪽)
        let middle = (searchRange.lowerBound + searchRange.upperBound) / 2
        let top = scores.map(\.score).max() ?? 0
        guard top > 0,
              let best = scores.filter({ $0.score >= top - 0.02 }).min(by: { abs($0.delta - middle) < abs($1.delta - middle) })
        else { return nil }
        let mean = scores.reduce(0) { $0 + $1.score } / Double(scores.count)
        let prominence = min(max((best.score - mean) / 0.3, 0), 1)
        let coverage = min(1, Double(coveredLines) / 6)
        return AutoSyncEstimate(
            lyricsDelay: best.delta,
            confidence: prominence * coverage,
            lineCount: coveredLines,
            score: best.score
        )
    }
}
