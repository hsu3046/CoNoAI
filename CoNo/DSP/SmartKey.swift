// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 내 키: 원곡 보컬의 음역(유성 프레임 음높이의 중앙값)을 재서,
// 남성·여성이 편한 음역 중심에 가장 가깝게 옮기는 키(반음, −6…+6)를 고른다.
//
// 옥타브는 같은 음으로 본다 — 남자가 여자 노래를 부르면 한 옥타브 아래로 부르기 때문이다.
//   여자 노래(중앙값 A4=69) · 남자키 → 목표 G3(55) 와 옥타브 무시 거리 → −2 (한 옥타브 아래 G3 로 부름)
//   남자 노래(중앙값 A3=57) · 여자키 → 목표 E4(64) → +7 은 범위 밖이므로 옥타브를 바꿔 −5

import Foundation

enum VoiceType: String, CaseIterable, Sendable {
    case male
    case female

    /// 편하게 부르는 음역의 중심 (MIDI). 비전문가 기준 남성 약 A2–E4, 여성 약 F3–C5 의 가운데.
    var comfortableCenter: Double {
        switch self {
        case .male: 55 // G3
        case .female: 64 // E4
        }
    }
}

/// 원곡 보컬 음역 추정
struct VocalRange: Equatable, Sendable {
    /// 유성 프레임 음높이의 중앙값 (MIDI)
    let medianMidi: Double
    /// 추정에 쓴 유성 구간 길이 (초)
    let voicedSeconds: Double
}

enum SmartKey {
    /// 추정을 믿기 시작하는 유성 구간 길이 (초) — 한두 줄만 듣고 판단하지 않게
    static let minimumVoicedSeconds: Double = 8

    /// 음정 프레임들로 원곡 보컬 음역을 잰다. 유성 구간이 모자라면 nil.
    static func estimate(frames: [PitchFrame], framePeriod: Double, voicedThreshold: Float = 0.5) -> VocalRange? {
        var midis: [Double] = []
        midis.reserveCapacity(frames.count)
        for frame in frames where frame.confidence >= voicedThreshold && frame.pitchHz > 0 {
            midis.append(NoteSegmenter.midi(fromHz: frame.pitchHz))
        }
        let voicedSeconds = Double(midis.count) * framePeriod
        guard voicedSeconds >= minimumVoicedSeconds else { return nil }
        midis.sort()
        let middle = midis.count / 2
        let median = midis.count % 2 == 1 ? midis[middle] : (midis[middle - 1] + midis[middle]) / 2
        return VocalRange(medianMidi: median, voicedSeconds: voicedSeconds)
    }

    /// 원곡 중앙값을 목표 음역 중심에 가장 가깝게 옮기는 키 (옥타브 무시, −6…+6).
    static func shift(forMedian median: Double, toward voice: VoiceType) -> Int {
        let raw = voice.comfortableCenter - median
        // 옥타브를 접어 −6…+6 로 (가장 가까운 옥타브의 목표로)
        let folded = raw - 12 * (raw / 12).rounded()
        return min(max(Int(folded.rounded()), -6), 6)
    }
}
