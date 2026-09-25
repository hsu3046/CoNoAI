// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 줄 단위 싱크 가사 + 분리된 보컬 음정(16 ms 프레임) → 음절별 시작·끝 시각.
//
// 1) 발성 시작점 후보
//    - 강(1.0): 무성 틈 뒤 다시 소리가 시작되는 프레임 (자음·숨으로 끊기는 음절 경계)
//    - 중(0.7): 음표가 바뀌는 지점 (같은 흐름 안에서 음높이가 바뀜)
//    - 약(0.0): 발성 구간 안 48 ms 격자 (같은 음으로 이어 부르는 음절도 경계를 놓을 수 있게)
// 2) 동적 계획법으로 음절 경계를 후보 중에서 고른다. 비용 =
//      α·(ln(실제 발성 시간 / 예상 발성 시간))²   — 음절 무게에 비례하게 (약하게 — 노래 음절 길이는 들쭉날쭉)
//    + β·(음절 안에 삼킨 시작점들의 세기 합)      — 강한 시작점은 경계가 되게 (꺾기는 허용하되 벌점)
//    − γ·(음절 시작점의 세기)
//    + δ·(격자 후보에 경계를 놓음)                — 긴 음 한가운데를 공짜로 자르지 못하게
// 3) 음절 안에서는 소리 내는 동안만 진행한다 (숨 쉬는 틈에선 색칠이 멈춤).

import Foundation

struct VocalFrame: Equatable, Sendable {
    /// 곡 안 시각 (초) — 프레임 시작
    let time: Double
    let voiced: Bool
    /// 음높이 (MIDI, 유성일 때)
    let midi: Double?
}

struct UnitTiming: Equatable, Sendable {
    let start: Double
    let end: Double
}

/// 한 줄의 음절별 타이밍과 진행률 계산
struct LineWipe: Sendable {
    let units: [LyricUnit]
    let timings: [UnitTiming]
    let totalCharacters: Int
    fileprivate let frameTimes: [Double]
    fileprivate let voicedPrefix: [Int] // voicedPrefix[k] = 프레임 0..<k 중 유성 수
    fileprivate let framePeriod: Double

    /// 곡 시각 t 에서 칠해진 글자 수 (소수 = 현재 글자의 일부)
    func highlightedCharacters(at t: Double) -> Double {
        guard let first = timings.first, let last = timings.last else { return 0 }
        if t <= first.start { return Double(units.first?.charStart ?? 0) }
        if t >= last.end { return Double(totalCharacters) }
        guard let index = timings.lastIndex(where: { $0.start <= t }) else { return 0 }
        let unit = units[index]
        let timing = timings[index]
        let total = voicedSeconds(from: timing.start, to: timing.end)
        let done = voicedSeconds(from: timing.start, to: min(t, timing.end))
        let fraction = total > 0 ? min(max(done / total, 0), 1) : 1
        return Double(unit.charStart) + fraction * Double(unit.charCount)
    }

    private func voicedSeconds(from a: Double, to b: Double) -> Double {
        guard b > a else { return 0 }
        let i = frameIndex(atOrAfter: a)
        let j = frameIndex(atOrAfter: b)
        return Double(voicedPrefix[j] - voicedPrefix[i]) * framePeriod
    }

    private func frameIndex(atOrAfter t: Double) -> Int {
        var low = 0
        var high = frameTimes.count
        while low < high {
            let mid = (low + high) / 2
            if frameTimes[mid] < t - 1e-9 { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

enum SyllableAligner {
    struct Weights: Sendable {
        /// α — 노래는 음절 길이가 원래 들쭉날쭉하다. 크면 "짧은 음 둘 + 긴 음" 을 균등 분할로 뭉갠다 (1.0 에서 실패)
        var duration = 0.3
        /// β — 음절 안에 삼킨 시작점 (꺾기는 허용하되 벌점)
        var swallowedOnset = 2.0
        /// γ — 실제 시작점에 경계를 놓는 보상
        var onsetReward = 0.5
        /// δ — 실제 시작점이 아닌 격자에 경계를 놓는 벌점 (긴 음 한가운데를 공짜로 자르지 못하게)
        var gridBoundaryPenalty = 0.2
        /// 음절 최소 발성 시간 (초)
        var minimumUnitSeconds = 0.04
        /// 약한 격자 후보 간격 (프레임)
        var gridFrames = 3
    }

    /// - Parameters:
    ///   - frames: 줄 구간을 덮는 연속 프레임 (시각 오름차순, 간격 framePeriod)
    ///   - lineStart/lineEnd: 이 줄의 곡 시각 범위 (LRC)
    /// - Returns: 발성이 없거나 음절이 없으면 nil (호출자는 비례 색칠로 대체)
    /// - Parameter analyzedUntil: 보컬 분석이 끝난 곡 시각. 줄 끝보다 이르면(줄이 시작됐는데 뒷부분이 아직 분석 전)
    ///   그 뒤부터 줄 끝 − 0.3초까지를 "노래가 이어진다"고 가정한 임시 구간으로 채운다.
    ///   안 채우면 분석된 앞부분에 모든 음절을 욱여넣어 초반에 너무 빨리 칠해지고, 나중에 뒤로 고쳐진다.
    static func align(
        text: String,
        frames: [VocalFrame],
        framePeriod: Double,
        lineStart: Double,
        lineEnd: Double,
        analyzedUntil: Double? = nil,
        weights: Weights = Weights()
    ) -> LineWipe? {
        let units = LyricTokenizer.units(text)
        var inLine = frames.filter { $0.time >= lineStart - 1e-9 && $0.time < lineEnd }
        if let analyzedUntil, analyzedUntil < lineEnd - 0.3 {
            // 임시 구간: 음높이 없이 유성으로만 채운다 → 격자 후보만 생겨 남은 음절이 고르게 놓인다
            var t = max(analyzedUntil, (inLine.last?.time ?? lineStart - framePeriod) + framePeriod)
            while t < lineEnd - 0.3 {
                inLine.append(VocalFrame(time: t, voiced: true, midi: nil))
                t += framePeriod
            }
        }
        guard !units.isEmpty, let firstVoiced = inLine.firstIndex(where: \.voiced),
              let lastVoiced = inLine.lastIndex(where: \.voiced)
        else { return nil }

        let lineFrames = Array(inLine[firstVoiced...lastVoiced])
        let endTime = lineFrames[lineFrames.count - 1].time + framePeriod
        var voicedPrefix = [0]
        for frame in lineFrames { voicedPrefix.append(voicedPrefix.last! + (frame.voiced ? 1 : 0)) }
        let totalVoiced = Double(voicedPrefix.last!) * framePeriod

        // 1) 후보 (프레임 인덱스, 세기)
        var strength = [Double](repeating: -1, count: lineFrames.count) // -1 = 후보 아님
        strength[0] = 1
        for k in 1..<lineFrames.count where lineFrames[k].voiced && !lineFrames[k - 1].voiced {
            strength[k] = 1
        }
        let noteFrames = lineFrames.enumerated().map { index, frame in
            PitchFrame(index: index, pitchHz: frame.midi.map { 440 * pow(2, ($0 - 69) / 12) } ?? 0, confidence: frame.voiced ? 1 : 0)
        }
        for note in NoteSegmenter().segment(noteFrames) where note.startFrame > 0 {
            // 강한 후보 ±2 프레임 안이면 중복으로 보고 건너뜀
            let nearStrong = (max(0, note.startFrame - 2)...min(lineFrames.count - 1, note.startFrame + 2)).contains { strength[$0] >= 1 }
            if !nearStrong { strength[note.startFrame] = max(strength[note.startFrame], 0.7) }
        }
        for k in stride(from: 0, to: lineFrames.count, by: weights.gridFrames) where lineFrames[k].voiced && strength[k] < 0 {
            strength[k] = 0
        }
        let candidates = strength.indices.filter { strength[$0] >= 0 }
        let m = units.count
        guard candidates.count >= m else { return uniform(units: units, text: text, frames: lineFrames, prefix: voicedPrefix, period: framePeriod, end: endTime) }

        // 후보 사이에 삼켜진 세기 합을 빠르게 구하기 위한 누적합 (세기 > 0 만)
        var strongPrefix = [0.0]
        for c in candidates { strongPrefix.append(strongPrefix.last! + max(0, strength[c])) }

        let totalWeight = units.reduce(0) { $0 + $1.weight }
        func voicedSeconds(_ fromFrame: Int, _ toFrame: Int) -> Double {
            Double(voicedPrefix[toFrame] - voicedPrefix[fromFrame]) * framePeriod
        }
        func unitCost(_ unit: Int, from ci: Int, to cj: Int?) -> Double {
            let startFrame = candidates[ci]
            let endFrame = cj.map { candidates[$0] } ?? lineFrames.count
            let actual = voicedSeconds(startFrame, endFrame)
            guard actual >= weights.minimumUnitSeconds else { return .infinity }
            let expected = max(totalVoiced * units[unit].weight / totalWeight, weights.minimumUnitSeconds)
            let ratio = log(actual / expected)
            // 여러 박자짜리 단위(誰=2)는 안쪽에 (무게−1)개 정도의 시작점이 있는 게 정상 → 그만큼 벌점 면제
            let allowance = max(0, units[unit].weight - 1) * 0.85
            let swallowed = max(0, strongPrefix[cj ?? candidates.count] - strongPrefix[ci + 1] - allowance)
            let gridPenalty = unit > 0 && strength[startFrame] == 0 ? weights.gridBoundaryPenalty : 0
            return weights.duration * ratio * ratio
                + weights.swallowedOnset * swallowed
                - weights.onsetReward * max(0, strength[startFrame])
                + gridPenalty
        }

        // 2) DP: best[u][c] = 단위 u 가 후보 c 에서 시작할 때 u..끝의 최소 비용
        let n = candidates.count
        var best = [[Double]](repeating: [Double](repeating: .infinity, count: n), count: m)
        var nextChoice = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        for c in 0..<n { best[m - 1][c] = unitCost(m - 1, from: c, to: nil) }
        if m >= 2 {
            for u in stride(from: m - 2, through: 0, by: -1) {
                // 남은 단위 수만큼 후보가 뒤에 남아 있어야 한다
                for c in 0..<(n - (m - 1 - u)) {
                    var bestValue = Double.infinity
                    var bestNext = -1
                    for next in (c + 1)..<n where best[u + 1][next].isFinite {
                        let value = unitCost(u, from: c, to: next) + best[u + 1][next]
                        if value < bestValue {
                            bestValue = value
                            bestNext = next
                        }
                    }
                    best[u][c] = bestValue
                    nextChoice[u][c] = bestNext
                }
            }
        }
        guard best[0][0].isFinite else {
            return uniform(units: units, text: text, frames: lineFrames, prefix: voicedPrefix, period: framePeriod, end: endTime)
        }

        // 3) 경로 복원 (첫 단위는 첫 발성 프레임에서 시작)
        var starts = [0]
        var c = 0
        for u in 0..<(m - 1) {
            c = nextChoice[u][c]
            starts.append(c)
        }
        var timings: [UnitTiming] = []
        for u in 0..<m {
            let start = lineFrames[candidates[starts[u]]].time
            let end = u + 1 < m ? lineFrames[candidates[starts[u + 1]]].time : endTime
            timings.append(UnitTiming(start: start, end: end))
        }
        return LineWipe(
            units: units,
            timings: timings,
            totalCharacters: Array(text).count,
            frameTimes: lineFrames.map(\.time),
            voicedPrefix: voicedPrefix,
            framePeriod: framePeriod
        )
    }

    /// 후보가 모자라면 발성 시간을 무게 비례로 나눈다
    private static func uniform(units: [LyricUnit], text: String, frames: [VocalFrame], prefix: [Int], period: Double, end: Double) -> LineWipe {
        let totalWeight = units.reduce(0) { $0 + $1.weight }
        let totalVoiced = prefix.last!
        var timings: [UnitTiming] = []
        var accumulated = 0.0
        func time(atVoicedCount target: Double) -> Double {
            guard let k = prefix.firstIndex(where: { Double($0) >= target }), k > 0 else { return frames.first?.time ?? 0 }
            return frames[k - 1].time
        }
        for unit in units {
            let start = time(atVoicedCount: accumulated / totalWeight * Double(totalVoiced))
            accumulated += unit.weight
            let unitEnd = accumulated >= totalWeight ? end : time(atVoicedCount: accumulated / totalWeight * Double(totalVoiced))
            timings.append(UnitTiming(start: start, end: max(unitEnd, start)))
        }
        return LineWipe(
            units: units,
            timings: timings,
            totalCharacters: Array(text).count,
            frameTimes: frames.map(\.time),
            voicedPrefix: prefix,
            framePeriod: period
        )
    }
}
