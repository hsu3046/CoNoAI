// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// 한 곡의 채점 기준과 누적 점수. 난이도는 생성할 때만 정하며 새 곡은 새 세션으로 교체한다.
/// SingingTracker의 직렬 큐 전용. 결과는 같은 스냅샷 안에 난이도와 점수를 함께 공개한다.
struct SingingScoreSession {
    let difficulty: SingingJudge.Difficulty
    private var scorer = NoteScorer(start: 0)
    private var waitingForFirstFrame = true
    var hitTimes: [Double] = []

    init(difficulty: SingingJudge.Difficulty) {
        self.difficulty = difficulty
    }

    var score: SongScore { scorer.score }

    mutating func beginIfNeeded(at time: Double) {
        guard waitingForFirstFrame else { return }
        scorer = NoteScorer(start: time)
        waitingForFirstFrame = false
    }

    func accepts(offset: Double) -> Bool { abs(offset) <= difficulty.tolerance }

    mutating func score(notes: [SungNote], framePeriod: Double, stableUntil: Double) {
        scorer.score(notes: notes, framePeriod: framePeriod, hitTimes: hitTimes, stableUntil: stableUntil)
    }
}
