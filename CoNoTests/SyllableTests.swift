// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation
import Testing

struct LyricTokenizerTests {
    private func pieces(_ text: String) -> [String] {
        let characters = Array(text)
        return LyricTokenizer.units(text).map { String(characters[$0.charStart..<$0.charEnd]) }
    }

    @Test func koreanJapaneseAndLatin() {
        #expect(pieces("사랑해 요!") == ["사", "랑", "해 ", "요!"])
        #expect(pieces("しゃしん") == ["しゃ", "し", "ん"])
        #expect(pieces("ラーメン") == ["ラー", "メ", "ン"])
        #expect(pieces("  Baby, I love you") == ["  Baby, ", "I ", "love ", "you"])
        #expect(LyricTokenizer.units("Baby").first?.weight == 2)
    }
}

struct SyllableAlignerTests {
    private let period = 0.016

    /// (길이 초, MIDI 또는 nil=무성) 구간들을 프레임으로
    private func frames(_ spec: [(seconds: Double, midi: Double?)]) -> [VocalFrame] {
        var result: [VocalFrame] = []
        for part in spec {
            let count = Int((part.seconds / period).rounded())
            for _ in 0..<count {
                result.append(VocalFrame(time: Double(result.count) * period, voiced: part.midi != nil, midi: part.midi))
            }
        }
        return result
    }

    private func starts(_ text: String, _ spec: [(seconds: Double, midi: Double?)]) -> [Double]? {
        let f = frames(spec)
        return SyllableAligner.align(text: text, frames: f, framePeriod: period, lineStart: 0, lineEnd: f.last!.time + period)?
            .timings.map(\.start)
    }

    private func expectClose(_ actual: [Double]?, _ expected: [Double], tolerance: Double = 0.05, _ comment: Comment? = nil) {
        guard let actual else {
            Issue.record("정렬 실패 (nil)")
            return
        }
        #expect(actual.count == expected.count, comment)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a - e) <= tolerance, "\(a) vs \(e) \(comment?.rawValue ?? "")")
        }
    }

    @Test func breathsBetweenSyllablesBecomeBoundaries() {
        let result = starts("가나다", [(0.3, 60), (0.05, nil), (0.25, 60), (0.05, nil), (0.35, 60)])
        expectClose(result, [0, 0.35, 0.65])
    }

    @Test func pitchChangesBecomeBoundaries() {
        let result = starts("도레미", [(0.4, 60), (0.4, 62), (0.4, 64)])
        expectClose(result, [0, 0.4, 0.8])
    }

    @Test func sustainedLastNoteKeepsShortSyllablesShort() {
        // "사-랑-해~~~" : 짧은 음 둘 + 1.5초 끄는 음. 균등 분할(0, 0.67, 1.33)로 뭉개면 안 된다
        let result = starts("사랑해", [(0.25, 60), (0.25, 62), (1.5, 64)])
        expectClose(result, [0, 0.25, 0.5])
    }

    @Test func sameNoteSyllablesSplitEvenly() {
        // 같은 음으로 이어 부르는 다섯 음절 → 시작점 단서가 없으니 발성 시간을 고르게
        let result = starts("안녕하세요", [(1.0, 62)])
        expectClose(result, [0, 0.2, 0.4, 0.6, 0.8], tolerance: 0.06)
    }

    @Test func melismaStaysOneSyllable() {
        // "아" 한 글자를 세 음으로 꺾는다 → 단위 하나가 전체를 덮는다
        let f = frames([(0.3, 60), (0.3, 62), (0.3, 60)])
        let wipe = SyllableAligner.align(text: "아", frames: f, framePeriod: period, lineStart: 0, lineEnd: 1)
        #expect(wipe?.timings == [UnitTiming(start: 0, end: f.last!.time + period)])
    }

    @Test func wipePausesDuringBreaths() throws {
        let f = frames([(0.3, 60), (0.1, nil), (0.3, 60)])
        let wipe = try #require(SyllableAligner.align(text: "가나", frames: f, framePeriod: period, lineStart: 0, lineEnd: 1))
        #expect(abs(wipe.highlightedCharacters(at: 0.15) - 0.5) < 0.06)
        // 숨 쉬는 동안(0.3~0.4)은 첫 글자가 다 칠해진 상태로 멈춘다
        #expect(abs(wipe.highlightedCharacters(at: 0.35) - 1.0) < 0.06)
        #expect(abs(wipe.highlightedCharacters(at: 0.55) - 1.5) < 0.06)
        #expect(wipe.highlightedCharacters(at: 2) == 2)
    }

    @Test func silentLineGivesNil() {
        let f = frames([(1.0, nil)])
        #expect(SyllableAligner.align(text: "가사", frames: f, framePeriod: period, lineStart: 0, lineEnd: 1) == nil)
    }
}

struct SongClockInverseTests {
    @Test func songPositionToCaptureTimeUsesHeardAnchor() {
        var clock = SongClock()
        clock.add(PlaybackAnchor(captureTime: 100, songPosition: 30, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 105, songPosition: 80, isPlaying: true, trackID: "A")) // 되감기 후
        // 들리는 시점이 102 (되감기 전 구간) → 그 구간의 앵커로 곡 32초 = 캡처 102
        #expect(clock.captureTime(forSongPosition: 32, heardAt: 102) == 102)
        #expect(clock.captureTime(forSongPosition: 81, heardAt: 106) == 106)
        // 일시정지 앵커로는 역산하지 않는다
        clock.add(PlaybackAnchor(captureTime: 110, songPosition: 85, isPlaying: false, trackID: "A"))
        #expect(clock.captureTime(forSongPosition: 85, heardAt: 111) == nil)
    }
}
