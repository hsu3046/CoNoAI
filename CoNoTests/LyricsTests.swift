// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation
import Testing

struct LRCParserTests {
    @Test func parsesTagsMultipleTimesOffsetAndWordTags() {
        let lrc = """
        [ar:IU]
        [ti:Good Day]
        [offset:+500]
        [00:16.25] 어쩜 이렇게 하늘은 더 파란 건지
        [00:23.620]오늘따라 <00:24.10>왜 <00:24.50>바람은
        [01:00.00][02:00.00]후렴
        [00:30.00]
        not a lyric line
        """
        let lyrics = LRCParser.parse(lrc)
        #expect(lyrics.lines.map(\.text) == ["어쩜 이렇게 하늘은 더 파란 건지", "오늘따라 왜 바람은", "", "후렴", "후렴"])
        // offset +500ms → 모든 줄 0.5초 앞당김
        #expect(abs(lyrics.lines[0].start - 15.75) < 1e-9)
        #expect(abs(lyrics.lines[1].start - 23.12) < 1e-9)
        #expect(abs(lyrics.lines[2].start - 29.5) < 1e-9)
        #expect(abs(lyrics.lines[4].start - 119.5) < 1e-9)
    }

    @Test func lineLookupSkipsInterludesAndCapsLongGaps() {
        let lyrics = LRCParser.parse("""
        [00:10.00]첫 줄
        [00:14.00]둘째 줄
        [00:18.00]
        [00:40.00]간주 뒤
        """)
        #expect(lyrics.lineIndex(at: 9.9) == nil)
        #expect(lyrics.lineIndex(at: 10) == 0)
        #expect(lyrics.lineIndex(at: 13.99) == 0)
        #expect(lyrics.lineIndex(at: 14) == 1)
        #expect(lyrics.lineIndex(at: 20) == nil, "빈 줄은 간주")
        #expect(lyrics.nextLineIndex(after: 20) == 3)
        // 마지막 줄은 최대 10초까지만
        #expect(lyrics.lineIndex(at: 49.9) == 3)
        #expect(lyrics.lineIndex(at: 50.1) == nil)
    }

    @Test func timeFormats() {
        #expect(LRCParser.parseTime("01:02") == 62)
        #expect(LRCParser.parseTime("01:02.5") == 62.5)
        #expect(LRCParser.parseTime("01:02:50") == 62.5)
        #expect(LRCParser.parseTime("ar:IU") == nil)
        #expect(LRCParser.parseTime("00:61.00") == nil)
    }
}

struct LyricsSelectorTests {
    private func candidate(_ id: Int, duration: Double?, synced: String?, plain: String? = "x", instrumental: Bool = false) -> LyricsCandidate {
        LyricsCandidate(id: id, trackName: "t", artistName: "a", albumName: nil, duration: duration,
                        instrumental: instrumental, plainLyrics: plain, syncedLyrics: synced)
    }

    @Test func prefersSyncedNativeScriptWithMatchingDuration() {
        let romanized = candidate(1, duration: 179, synced: "[00:23.15]Ppajyeobeorineun daydream")
        let hangul = candidate(2, duration: 180, synced: "[00:23.15]빠져버리는 daydream")
        let plainOnly = candidate(3, duration: 179, synced: nil, plain: "빠져버리는")
        let otherVersion = candidate(4, duration: 210, synced: "[00:23.15]빠져버리는")
        let best = LyricsSelector.best([romanized, plainOnly, otherVersion, hangul], targetDuration: 179.4)
        #expect(best?.id == 2)
    }

    @Test func rejectsDurationMismatchAndInstrumental() {
        let wrong = candidate(1, duration: 240, synced: "[00:01.00]a")
        let instrumental = candidate(2, duration: 180, synced: nil, plain: nil, instrumental: true)
        #expect(LyricsSelector.best([wrong, instrumental], targetDuration: 180) == nil)
        // 길이를 모르면 길이 조건 없이 고른다
        #expect(LyricsSelector.best([wrong], targetDuration: nil)?.id == 1)
    }
}

struct SongClockTests {
    @Test func usesAnchorBeforeHeardTimeAcrossPauseSeekAndTrackChange() {
        var clock = SongClock()
        clock.add(PlaybackAnchor(captureTime: 100, songPosition: 30, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 101, songPosition: 31, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 102, songPosition: 31.5, isPlaying: false, trackID: "A")) // 일시정지
        clock.add(PlaybackAnchor(captureTime: 105, songPosition: 60, isPlaying: true, trackID: "A"))   // 재개 + 되감기
        clock.add(PlaybackAnchor(captureTime: 110, songPosition: 0.2, isPlaying: true, trackID: "B"))  // 다음 곡

        #expect(clock.position(atCaptureTime: 99.9) == nil, "첫 앵커 이전은 모름")
        #expect(clock.position(atCaptureTime: 101.5) == SongPosition(trackID: "A", seconds: 31.5, isPlaying: true))
        #expect(clock.position(atCaptureTime: 103) == SongPosition(trackID: "A", seconds: 31.5, isPlaying: false))
        #expect(clock.position(atCaptureTime: 106) == SongPosition(trackID: "A", seconds: 61, isPlaying: true))
        #expect(clock.position(atCaptureTime: 111) == SongPosition(trackID: "B", seconds: 1.2, isPlaying: true))
    }

    @Test func dropsOldAnchorsAndBackwardsAnchors() {
        var clock = SongClock(retentionSeconds: 10)
        clock.add(PlaybackAnchor(captureTime: 0, songPosition: 0, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 20, songPosition: 20, isPlaying: true, trackID: "A"))
        clock.add(PlaybackAnchor(captureTime: 15, songPosition: 99, isPlaying: true, trackID: "A")) // 역행 → 무시
        #expect(clock.anchors.count == 1)
        #expect(clock.anchors.first?.captureTime == 20)
    }
}
