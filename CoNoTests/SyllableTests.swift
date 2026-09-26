// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

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

    @Test func partiallyAnalyzedLineKeepsEarlySyllablesPaced() {
        // 6음절이 0.5초씩 음을 바꾸며 3초 동안 불리는 줄인데, 앞 1.5초만 분석된 상태
        let full = frames([(0.5, 60), (0.5, 62), (0.5, 64), (0.5, 65), (0.5, 67), (0.5, 69)])
        let analyzed = full.filter { $0.time < 1.5 }
        let early = SyllableAligner.align(text: "가나다라마바", frames: analyzed, framePeriod: period,
                                          lineStart: 0, lineEnd: 3.3, analyzedUntil: 1.5)?.timings.map(\.start)
        // 앞 세 음절은 실제 음 바뀜(0, 0.5, 1.0)에 — 1.5초 안에 여섯 음절을 욱여넣지 않는다
        expectClose(early.map { Array($0.prefix(3)) }, [0, 0.5, 1.0], tolerance: 0.06)
        // 대조: 임시 구간 없이 정렬하면 욱여넣어져 셋째 음절이 1.0 보다 훨씬 이르다
        let squeezed = SyllableAligner.align(text: "가나다라마바", frames: analyzed, framePeriod: period,
                                             lineStart: 0, lineEnd: 3.3)?.timings.map(\.start)
        #expect((squeezed?[2] ?? 1) < 0.8)
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

struct JapaneseReadingTests {
    private func weights(_ text: String) -> [String: Double] {
        let characters = Array(text)
        var result: [String: Double] = [:]
        for unit in LyricTokenizer.units(text) {
            result[String(characters[unit.charStart..<unit.charEnd])] = unit.weight
        }
        return result
    }

    @Test func kanjiGetMoraWeights() {
        let first = weights("誰を想って歩こう")
        #expect(first["誰"] == 2, "だれ")
        #expect(first["想っ"] == 3, "おも + っ")
        #expect(first["て"] == 1)
        let second = weights("明日の今頃は海")
        #expect(second["明"].map { $0 + (second["日"] ?? 0) } == 2, "あす")
        #expect(second["今"] == 2 && second["頃"] == 2, "いま·ごろ")
        #expect(weights("東京の空")["空"] == 2, "そら")
    }

    @Test func romajiMoraCounting() {
        #expect(JapaneseReading.morae(inRomaji: "toukyou") == 4)
        #expect(JapaneseReading.morae(inRomaji: "omo~tsu") == 3)
        #expect(JapaneseReading.morae(inRomaji: "shinbun") == 4, "し·ん·ぶ·ん")
        #expect(JapaneseReading.morae(inRomaji: "kanya") == 2, "n + y 는 ん 아님 (かにゃ 계열)")
    }

    @Test func koreanUnaffected() {
        #expect(LyricTokenizer.units("사랑해").map(\.weight) == [1, 1, 1])
    }
}

struct LyricsAutoSyncTests {
    private let period = 0.016

    /// 실제 노래가 actualStarts 에서 시작해 1.2초씩 부르고 쉬는 보컬
    private func vocals(actualStarts: [Double], total: Double) -> [VocalFrame] {
        let count = Int(total / period)
        return (0..<count).map { k in
            let t = Double(k) * period
            let singing = actualStarts.contains { t >= $0 && t < $0 + 1.2 }
            return VocalFrame(time: t, voiced: singing, midi: singing ? 62 : nil)
        }
    }

    @Test func findsLyricsThatAreOneSecondEarly() throws {
        let actual = [5.0, 7.3, 9.1, 11.8, 14.0, 16.5, 18.2]
        let lrc = actual.map { $0 - 1.0 } // First Love 처럼 가사가 1초 이르다
        let frames = vocals(actualStarts: actual, total: 24)
        let estimate = try #require(LyricsAutoSync.estimate(lineStarts: lrc, frames: frames, framePeriod: period))
        #expect(abs(estimate.lyricsDelay - 1.0) < 0.05)
        #expect(estimate.confidence > 0.5)
    }

    @Test func correctLyricsGiveZero() throws {
        let actual = [5.0, 7.3, 9.1, 11.8, 14.0, 16.5]
        let estimate = try #require(LyricsAutoSync.estimate(lineStarts: actual, frames: vocals(actualStarts: actual, total: 22), framePeriod: period))
        #expect(abs(estimate.lyricsDelay) < 0.05)
    }

    @Test func continuousSingingHasLowConfidence() {
        // 쉼 없이 계속 부르는 구간 → 줄 시작 단서가 없다
        let frames = (0..<Int(20 / period)).map { VocalFrame(time: Double($0) * period, voiced: true, midi: 62) }
        let estimate = LyricsAutoSync.estimate(lineStarts: [4, 6, 8, 10, 12, 14], frames: frames, framePeriod: period)
        #expect(estimate == nil || estimate!.confidence < 0.2)
    }

    @Test func coarseSearchFindsLongIntroOffset() throws {
        // 영상 인트로가 14초 더 길다: LRC 는 실제보다 14초 이르다. 30초 남짓 분석한 뒤에도 찾아야 한다.
        let actual = [18.0, 20.4, 22.1, 25.3, 27.0, 29.8, 31.5, 34.2, 36.9]
        let lrc = actual.map { $0 - 14 }
        let frames = vocals(actualStarts: actual, total: 40)
        // 평소 범위(±2.5초)로는 못 찾는다
        let narrow = LyricsAutoSync.estimate(lineStarts: lrc, frames: frames, framePeriod: period)
        #expect(narrow == nil || abs(narrow!.lyricsDelay - 14) > 1)
        let coarse = try #require(LyricsAutoSync.estimate(lineStarts: lrc, frames: frames, framePeriod: period, searchRange: LyricsAutoSync.coarseRange))
        #expect(abs(coarse.lyricsDelay - 14) < 0.05)
        #expect(coarse.confidence > 0.5)
    }

    @Test func trackingAroundAppliedDelayFollowsDrift() throws {
        // 14초 지연을 적용 중인데 라이브라 조금씩 늘어져 지금은 14.6초 → 14±2.5 범위에서 따라간다
        let actual = [18.0, 20.4, 22.1, 25.3, 27.0, 29.8, 31.5]
        let lrc = actual.map { $0 - 14.6 }
        let frames = vocals(actualStarts: actual, total: 36)
        let tracked = try #require(LyricsAutoSync.estimate(
            lineStarts: lrc, frames: frames, framePeriod: period,
            searchRange: (14 - LyricsAutoSync.trackingHalfWidth)...(14 + LyricsAutoSync.trackingHalfWidth)
        ))
        #expect(abs(tracked.lyricsDelay - 14.6) < 0.05)
    }

    @Test func tooFewLinesGivesNil() {
        let actual = [5.0, 7.0]
        #expect(LyricsAutoSync.estimate(lineStarts: actual, frames: vocals(actualStarts: actual, total: 12), framePeriod: period) == nil)
    }
}

struct SongClockSeekArrivalTests {
    @Test func arrivalIsWhenPlayerReportsTheTarget() {
        var clock = SongClock()
        // 2:00 부근을 부르다가 캡처 200초에 1:00 으로 이동 명령. 브라우저는 0.6초 뒤에야 실제로 옮겨 간다.
        clock.add(PlaybackAnchor(captureTime: 199.5, songPosition: 119.5, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 200.2, songPosition: 120.2, isPlaying: true, trackID: "A")) // 아직 옛 위치
        #expect(clock.captureTime(whenReaching: 60, after: 200) == nil, "아직 안 닿았다")
        clock.add(PlaybackAnchor(captureTime: 200.9, songPosition: 60.3, isPlaying: true, trackID: "A"))
        let arrival = clock.captureTime(whenReaching: 60, after: 200)
        #expect(arrival.map { abs($0 - 200.6) < 1e-9 } == true, "60.3 을 보고한 0.3초 전 = 200.6")
        // 도착~첫 새 앵커 사이의 소리가 옛 위치(2:00)로 계산되지 않아야 한다 (진행 막대가 되돌아가 보이던 문제)
        var settling = clock
        settling.add(PlaybackAnchor(captureTime: 200.95, songPosition: 60.35, isPlaying: true, trackID: "A"))
        var stale = SongClock()
        stale.add(PlaybackAnchor(captureTime: 199.5, songPosition: 119.5, isPlaying: true, trackID: "A"))
        stale.add(PlaybackAnchor(captureTime: 200.7, songPosition: 120.7, isPlaying: true, trackID: "A")) // 보고가 늦어 옛 위치를 외삽
        stale.add(PlaybackAnchor(captureTime: 200.9, songPosition: 60.3, isPlaying: true, trackID: "A"))
        #expect((stale.position(atCaptureTime: 200.75)?.seconds ?? 0) > 100, "보정 전에는 옛 위치로 계산된다")
        let settled = stale.settleSeek(toward: 60, after: 200)
        #expect(settled.map { abs($0 - 200.6) < 1e-9 } == true)
        let during = stale.position(atCaptureTime: 200.75)?.seconds ?? 0
        #expect(abs(during - 60.15) < 0.01, "도착 뒤는 새 위치: \(during)")
        #expect(stale.position(atCaptureTime: 200.5).map { $0.seconds > 100 } == true, "도착 전(옛 소리)은 그대로 옛 위치")
        #expect(settling.settleSeek(toward: 60, after: 200) != nil)

        // 명령 이전 앵커는 보지 않는다 / 일시정지 앵커는 보지 않는다
        var paused = SongClock()
        paused.add(PlaybackAnchor(captureTime: 201, songPosition: 60, isPlaying: false, trackID: "A"))
        #expect(paused.captureTime(whenReaching: 60, after: 200) == nil)
    }
}

struct SongClockContinuityTests {
    @Test func segmentStartsAfterSeek() {
        var clock = SongClock()
        clock.add(PlaybackAnchor(captureTime: 100, songPosition: 10, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 101, songPosition: 11, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 102, songPosition: 40, isPlaying: true, trackID: "A")) // 되감기(앞으로)
        clock.add(PlaybackAnchor(captureTime: 103, songPosition: 41.02, isPlaying: true, trackID: "A"))
        #expect(clock.continuousSegmentStart(heardAt: 103.5) == 102)
        #expect(clock.continuousSegmentStart(heardAt: 101.5) == 100)
    }
}
