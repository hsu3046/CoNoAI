// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 프레임 단위 음정 곡선 → 노래방 음정 바용 음표(반음 단위 막대).
//   1) 신뢰도 ≥ 0.5 인 프레임만 유성음 → MIDI 음높이(실수)
//   2) 유성 구간 안에서 5 프레임 중앙값으로 튐 제거
//   3) 음표 기준음에서 ±maxDeviation 반음 안이면 같은 음표 (비브라토 흡수), 짧은 무성 틈은 이어 붙임
//   4) minFrames 보다 짧은 음표는 버리고(꾸밈음·슬라이드), 같은 음 사이 짧은 틈은 병합

import Foundation

struct SungNote: Equatable, Sendable {
    /// 시작 프레임 번호 (포함)
    let startFrame: Int
    /// 끝 프레임 번호 (미포함)
    let endFrame: Int
    /// 반음 단위로 반올림한 MIDI 음 (60 = C4)
    let midi: Int
}

struct NoteSegmenter: Sendable {
    var voicedThreshold: Float = 0.5
    /// 같은 음표로 볼 최대 편차 (반음)
    var maxDeviation: Double = 0.8
    /// 음표 안에서 이어 붙일 수 있는 무성 틈 (프레임)
    var maxGapFrames = 2
    /// 음표 최소 길이 (프레임, 16 ms 단위 → 5 = 80 ms)
    var minFrames = 5
    /// 같은 음 두 음표를 합칠 최대 틈 (프레임)
    var mergeGapFrames = 3

    static func midi(fromHz hz: Double) -> Double {
        69 + 12 * log2(hz / 440)
    }

    /// `frames` 는 프레임 번호가 연속이어야 한다 (빈 번호가 있으면 무성으로 취급하지 않고 그대로 이어 붙이므로 주의).
    func segment(_ frames: [PitchFrame]) -> [SungNote] {
        guard !frames.isEmpty else { return [] }

        // 1) 유성 MIDI (무성 = nil)
        let raw: [Double?] = frames.map { frame in
            frame.confidence >= voicedThreshold && frame.pitchHz > 0 ? Self.midi(fromHz: frame.pitchHz) : nil
        }

        // 2) 유성 프레임끼리 5 프레임 중앙값
        var smooth = raw
        for i in raw.indices {
            guard raw[i] != nil else { continue }
            var window: [Double] = []
            for j in max(0, i - 2)...min(raw.count - 1, i + 2) {
                if let value = raw[j] { window.append(value) }
            }
            window.sort()
            smooth[i] = window[window.count / 2]
        }

        // 3) 음표 묶기
        var notes: [SungNote] = []
        var current: (start: Int, end: Int, sum: Double, count: Int)?
        var gap = 0

        func finish() {
            guard let note = current else { return }
            current = nil
            let length = note.end - note.start
            guard length >= minFrames else { return }
            let midi = Int((note.sum / Double(note.count)).rounded())
            let candidate = SungNote(startFrame: frames[note.start].index, endFrame: frames[note.end - 1].index + 1, midi: midi)
            // 4) 같은 음이 짧은 틈을 두고 이어지면 병합
            if let previous = notes.last, previous.midi == candidate.midi, candidate.startFrame - previous.endFrame <= mergeGapFrames {
                notes[notes.count - 1] = SungNote(startFrame: previous.startFrame, endFrame: candidate.endFrame, midi: midi)
            } else {
                notes.append(candidate)
            }
        }

        for i in smooth.indices {
            guard let value = smooth[i] else {
                if current != nil {
                    gap += 1
                    if gap > maxGapFrames { finish() }
                }
                continue
            }
            if let note = current, abs(value - note.sum / Double(note.count)) <= maxDeviation {
                current = (note.start, i + 1, note.sum + value, note.count + 1)
            } else {
                finish()
                current = (i, i + 1, value, 1)
            }
            gap = 0
        }
        finish()
        return notes
    }
}
