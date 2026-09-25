// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import Foundation
import Testing

struct LRCParserTests {
    @Test func parsesTagsMultipleTimesOffsetAndWordTags() {
        let lrc = """
        [ar:Test Artist]
        [ti:Sample Song]
        [offset:+500]
        [00:16.25] 오늘은 하늘이 참 맑은 날
        [00:23.620]창문을 <00:24.10>열면 <00:24.50>바람이
        [01:00.00][02:00.00]후렴
        [00:30.00]
        not a lyric line
        """
        let lyrics = LRCParser.parse(lrc)
        #expect(lyrics.lines.map(\.text) == ["오늘은 하늘이 참 맑은 날", "창문을 열면 바람이", "", "후렴", "후렴"])
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
        let romanized = candidate(1, duration: 179, synced: "[00:23.15]Haneureul boneun daydream")
        let hangul = candidate(2, duration: 180, synced: "[00:23.15]하늘을 보는 daydream")
        let plainOnly = candidate(3, duration: 179, synced: nil, plain: "하늘을 보는")
        let otherVersion = candidate(4, duration: 210, synced: "[00:23.15]하늘을 보는")
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

        // 부동소수점 끝자리 차이는 허용 (계산 순서에 따라 1.2 vs 1.2000000000000028)
        func expectPosition(_ c: Double, _ trackID: String, _ seconds: Double, playing: Bool) {
            let position = clock.position(atCaptureTime: c)
            #expect(position?.trackID == trackID && position?.isPlaying == playing, "c=\(c)")
            #expect(abs((position?.seconds ?? .nan) - seconds) < 1e-9, "c=\(c)")
        }
        #expect(clock.position(atCaptureTime: 99.9) == nil, "첫 앵커 이전은 모름")
        expectPosition(101.5, "A", 31.5, playing: true)
        expectPosition(103, "A", 31.5, playing: false)
        expectPosition(106, "A", 61, playing: true)
        expectPosition(111, "B", 1.2, playing: true)
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

struct AppleMusicScriptTests {
    /// 앱에서는 실행 순간에야 컴파일되므로, 구문 오류(예약어 변수 등)를 여기서 먼저 잡는다.
    /// 컴파일만 하고 실행하지 않으므로 음악 앱을 제어하지 않는다 (자동화 권한 불필요).
    @Test func compiles() {
        let script = NSAppleScript(source: AppleMusicScript.source)
        var error: NSDictionary?
        let compiled = script?.compileAndReturnError(&error) ?? false
        #expect(compiled, "AppleScript 컴파일 실패: \(error ?? [:])")
    }
}

struct TitleMatchTests {
    @Test func versionSuffixesIgnoredButOtherSongsRejected() {
        #expect(LyricsSelector.titlesMatch("First Love (Remastered 2014)", "First Love"))
        #expect(LyricsSelector.titlesMatch("Good day (좋은 날)", "좋은 날"))
        #expect(LyricsSelector.titlesMatch("Hype Boy", "Hype Boy"))
        #expect(LyricsSelector.titlesMatch("Dynamite - Instrumental", "Dynamite"))
        #expect(!LyricsSelector.titlesMatch("B&C -Album Edit-", "First Love"))
        #expect(!LyricsSelector.titlesMatch("Automatic", "First Love"))
        // 버전 표기만 같은 두 곡은 다른 곡
        #expect(!LyricsSelector.titlesMatch("B&C (Remastered 2014)", "First Love (Remastered 2014)"))
        #expect(LyricsSelector.titlesMatch("Love Always Run Away (사랑은 늘 도망가)", "사랑은 늘 도망가"))
    }

    @Test func rankedSyncedDropsOtherSongWithSimilarDuration() {
        let right = LyricsCandidate(id: 1, trackName: "First Love (Remastered 2014)", artistName: "a", albumName: nil,
                                    duration: 258, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:21.32]x")
        let other = LyricsCandidate(id: 2, trackName: "B&C -Album Edit-", artistName: "a", albumName: "First Love",
                                    duration: 260.9, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:11.27]y")
        let ranked = LyricsSelector.rankedSynced([other, right], targetDuration: 259, targetTitle: "First Love")
        #expect(ranked.map(\.id) == [1])
    }
}

struct SongClockSmoothingTests {
    @Test func jitteryReportsGiveSmoothMonotonicPosition() {
        // 0.5초마다 보고, 실제 (곡 − 캡처) = 30, 보고값에 ±30 ms 흔들림
        var clock = SongClock()
        let jitter: [Double] = [0.03, -0.02, 0.01, -0.03, 0.02, -0.01, 0.03, -0.02, 0.0, 0.02, -0.03, 0.01]
        for (i, noise) in jitter.enumerated() {
            let capture = 100 + Double(i) * 0.5
            clock.add(PlaybackAnchor(captureTime: capture, songPosition: capture - 70 + noise, isPlaying: true, trackID: "A"))
        }
        var previous = -Double.infinity
        var maxError = 0.0
        var c = 102.0 // 앵커가 몇 개 쌓인 뒤부터
        while c < 105.9 {
            let position = clock.position(atCaptureTime: c)!.seconds
            maxError = max(maxError, abs(position - (c - 70)))
            #expect(position >= previous - 0.005, "곡 위치가 뒤로 튐: c=\(c)")
            previous = position
            c += 0.05
        }
        #expect(maxError <= 0.015, "중앙값으로 흔들림이 줄어야 한다 (최대 오차 \(maxError))")
    }
}
