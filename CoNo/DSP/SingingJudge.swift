// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 마이크 채점의 순수 계산 (오디오·UI 없음 → 단위 테스트 대상).
//   - 옥타브 무관 음정 차이: 남자가 여자 노래를 한 옥타브 낮게 불러도 맞은 것
//   - 기준(원곡) 음 찾기: 반응이 조금 빠르거나 늦어도 되도록 앞뒤 여유를 둔다
//   - 반주 누설 게이트: 스피커 소리가 마이크로 새어 들어온 것을 내 목소리로 치지 않는다
//   - 곡 점수: 끝난 음표마다 한 번씩, 음표 길이만큼 가중
//
// 시간축은 모두 "출력 스트림 초" (음정 바·PitchTimeline 과 같다).

import Foundation

enum SingingJudge {
    /// 판정 난이도 — 반음 단위 허용 폭
    enum Difficulty: Int, CaseIterable, Sendable {
        /// ±50센트: 가장 가까운 반음이 맞으면 맞음
        case normal = 0
        /// ±30센트
        case hard = 1

        var tolerance: Double { self == .normal ? 0.5 : 0.3 }
    }

    /// 부른 음 − 기준 음 (반음). 옥타브를 접어 [-6, 6) 로.
    static func foldedOffset(sung: Double, reference: Double) -> Double {
        var offset = (sung - reference).truncatingRemainder(dividingBy: 12)
        if offset >= 6 { offset -= 12 } else if offset < -6 { offset += 12 }
        return offset
    }
}

/// 기준(원곡 보컬) 음정 조회. `frames` 는 PitchTimeline.snapshot 처럼 프레임 번호가 연속이어야 한다.
struct ReferencePitch {
    let frames: [PitchFrame]
    let framePeriod: Double
    /// 키 조절 반음 — 지금 들리는 반주의 키로 옮겨 비교한다
    let keyShift: Int
    var voicedThreshold: Float = 0.5

    /// 시각 t 주변 ±window 의 유성 기준 음 중 부른 음과 (옥타브 무관) 가장 가까운 것
    func nearest(to sung: Double, at t: Double, window: Double) -> (reference: Double, offset: Double)? {
        var best: (reference: Double, offset: Double)?
        for frame in voicedFrames(from: t - window, to: t + window) {
            let reference = NoteSegmenter.midi(fromHz: frame.pitchHz) + Double(keyShift)
            let offset = SingingJudge.foldedOffset(sung: sung, reference: reference)
            if best.map({ abs(offset) < abs($0.offset) }) ?? true { best = (reference, offset) }
        }
        return best
    }

    /// t 주변 ±window 에 원곡 가수가 소리를 내고 있는지
    func isVoiced(near t: Double, window: Double) -> Bool {
        voicedFrames(from: t - window, to: t + window).contains { _ in true }
    }

    private func voicedFrames(from: Double, to: Double) -> some Sequence<PitchFrame> {
        let slice: ArraySlice<PitchFrame>
        if let first = frames.first, framePeriod > 0, from.isFinite, to.isFinite {
            let lower = max(0, Int((from / framePeriod).rounded(.down)) - first.index)
            let upper = min(frames.count, Int((to / framePeriod).rounded(.up)) - first.index + 1)
            slice = lower < upper ? frames[lower..<upper] : []
        } else {
            slice = []
        }
        return slice.lazy.filter { $0.confidence >= voicedThreshold && $0.pitchHz > 0 }
    }
}

/// 스피커 → 마이크 누설 게이트.
/// 원곡 가수가 쉬는 동안(사람도 안 부른다고 보는 구간) 마이크 레벨 ÷ 출력 레벨로 누설 비율을 배우고,
/// 지금 출력 레벨로 예상한 누설보다 확실히 큰 소리만 목소리로 인정한다. 헤드폰이면 누설 ≈ 0 이라 다 통과한다.
struct LeakageGate {
    /// 누설 예상치의 몇 배를 넘어야 목소리인지 (2 = +6 dB)
    var margin: Double = 2
    /// 마이크 잡음 바닥의 몇 배를 넘어야 하는지
    var floorMargin: Double = 3
    /// 이보다 작은 소리는 무시 (약 −54 dBFS)
    var minimumLevel: Double = 0.002

    /// 배운 누설 비율 (마이크 진폭 ÷ 출력 진폭). 아직 모르면 nil
    private(set) var leakage: Double?
    /// 마이크 잡음 바닥 (진폭) — 출력이 거의 무음일 때만 잰다 (음악이 나오는 동안 재면 누설을 잡음으로 오인해
    /// 큰 전주 뒤 조용한 절에서 목소리를 막는다. 누설은 출력에 비례하는 `leakage` 가 맡는다)
    private(set) var noiseFloor: Double = 0

    private var ratios: [Double] = []
    private var levels: [Double] = []
    private var updates = 0
    private static let ratioWindow = 400
    private static let levelWindow = 600
    /// 누설을 믿기 시작할 최소 표본 (16 ms 프레임 → 약 0.5초)
    private static let minimumRatios = 30
    /// 이보다 작은 출력은 "무음" (약 −50 dBFS)
    private static let quietOutput = 0.003

    mutating func learn(mic: Double, output: Double, referenceSilent: Bool) {
        // 출력이 거의 무음이면 잡음 바닥을, 소리가 나면 누설 비율을 배운다 (무음에서의 비율은 잡음 ÷ 0 에 가깝다)
        if output < Self.quietOutput {
            Self.push(mic, into: &levels, limit: Self.levelWindow)
        } else if referenceSilent {
            Self.push(mic / output, into: &ratios, limit: Self.ratioWindow)
        }
        updates += 1
        // 정렬은 가끔만 (25 프레임 = 0.4초마다)
        if updates % 25 == 0 { recompute() }
    }

    func accepts(mic: Double, output: Double) -> Bool {
        let threshold = max(minimumLevel, noiseFloor * floorMargin, (leakage ?? 0) * output * margin)
        return mic > threshold
    }

    private mutating func recompute() {
        // 사람이 쉬는 구간에도 가끔 소리를 내므로 평균 대신 중앙값
        leakage = ratios.count >= Self.minimumRatios ? Self.percentile(ratios, 0.5) : nil
        noiseFloor = levels.isEmpty ? 0 : Self.percentile(levels, 0.2)
    }

    private static func push(_ value: Double, into values: inout [Double], limit: Int) {
        guard value.isFinite else { return }
        values.append(value)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}

/// 한 곡의 점수 (끝난 음표 기준)
struct SongScore: Equatable, Sendable {
    var notesTotal = 0
    var notesHit = 0
    /// 음표 길이로 가중한 득점 (초)
    var creditSeconds = 0.0
    var totalSeconds = 0.0

    /// 0…100
    var score: Int {
        totalSeconds > 0 ? Int((creditSeconds / totalSeconds * 100).rounded()) : 0
    }
}

/// 끝난 음표를 한 번씩만 채점한다.
/// 음표 하나: 음표 구간 안에서 "맞음" 판정을 받은 마이크 프레임 비율 → 60% 면 만점, 50% 이상이면 맞춘 음표.
struct NoteScorer {
    /// 이 비율이면 음표 만점 (첫소리·끝소리가 조금 어긋나도 되게)
    var fullCreditRatio = 0.6
    var hitRatio = 0.5

    private(set) var score = SongScore()
    /// 이미 채점한 마지막 음표 끝 (같은 음표를 두 번 세지 않게 — 창마다 음표 경계가 조금씩 달라질 수 있다)
    private var scoredUntil: Double

    /// - Parameter start: 이 시각 뒤에 시작한 음표만 (마이크를 켠 시각)
    init(start: Double) {
        scoredUntil = start
    }

    /// - Parameters:
    ///   - notes: 기준 음표 (시작 순)
    ///   - hitTimes: "맞음" 판정 마이크 프레임 시각 (오름차순)
    ///   - stableUntil: 이 시각 전에 끝난 음표만 확정
    mutating func score(notes: [SungNote], framePeriod: Double, hitTimes: [Double], stableUntil: Double) {
        for note in notes {
            let start = Double(note.startFrame) * framePeriod
            let end = Double(note.endFrame) * framePeriod
            guard start >= scoredUntil, end <= stableUntil, end > start else { continue }
            let frames = Double(note.endFrame - note.startFrame)
            let hits = Double(Self.count(hitTimes, from: start, to: end))
            let ratio = hits / frames
            score.notesTotal += 1
            if ratio >= hitRatio { score.notesHit += 1 }
            score.totalSeconds += end - start
            score.creditSeconds += (end - start) * min(1, ratio / fullCreditRatio)
            scoredUntil = end
        }
    }

    /// 오름차순 배열에서 [from, to) 안의 개수
    static func count(_ times: [Double], from: Double, to: Double) -> Int {
        lowerBound(times, to) - lowerBound(times, from)
    }

    private static func lowerBound(_ times: [Double], _ value: Double) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// 2차 버터워스 하이패스 (RBJ). 마이크의 저음(베이스·킥 누설, 험)을 걷어낸다. 한 스레드 전용.
struct HighPassFilter {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(cutoff: Double, sampleRate: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * 0.7071067811865476)
        let cosw = cos(w)
        let a0 = 1 + alpha
        b0 = (1 + cosw) / 2 / a0
        b1 = -(1 + cosw) / a0
        b2 = (1 + cosw) / 2 / a0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        for i in samples.indices {
            let x = Double(samples[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            samples[i] = Float(y)
        }
    }
}
