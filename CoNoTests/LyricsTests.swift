// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import AppKit
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

    @Test func seekScriptCompiles() {
        let script = NSAppleScript(source: AppleMusicScript.seek(to: 83.25))
        var error: NSDictionary?
        let compiled = script?.compileAndReturnError(&error) ?? false
        #expect(compiled, "seek 컴파일 실패: \(error ?? [:])")
        #expect(AppleMusicScript.seek(to: 83.25).contains("83.250"))
    }

    @Test func artworkScriptCompiles() {
        let script = NSAppleScript(source: AppleMusicScript.artwork)
        var error: NSDictionary?
        let compiled = script?.compileAndReturnError(&error) ?? false
        #expect(compiled, "artwork 컴파일 실패: \(error ?? [:])")
    }

    @Test func playerCommandsCompile() {
        for command in PlayerCommand.allCases {
            let script = NSAppleScript(source: AppleMusicScript.command(command))
            var error: NSDictionary?
            let compiled = script?.compileAndReturnError(&error) ?? false
            #expect(compiled, "\(command) 컴파일 실패: \(error ?? [:])")
        }
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

// MARK: - 코드 리뷰 반영 (가사 묶음)

struct LyricsReviewFixTests {
    private func synced(_ id: Int, title: String = "Love", artist: String, lrc: String, duration: Double = 200) -> LyricsCandidate {
        LyricsCandidate(id: id, trackName: title, artistName: artist, albumName: nil, duration: duration,
                        instrumental: false, plainLyrics: nil, syncedLyrics: lrc)
    }

    @Test func sameTimestampKeepsFirstLineOnly() {
        // 원문 줄 + 번역 줄이 같은 시각 → 첫 줄만 (앞 줄이 길이 0 으로 사라지지 않게)
        let lyrics = LRCParser.parse("""
        [00:10.00]창문을 열면 바람이
        [00:10.00]When I open the window
        [00:14.00]
        [00:14.00]하늘을 보는 daydream
        """)
        #expect(lyrics.lines.map(\.text) == ["창문을 열면 바람이", "하늘을 보는 daydream"])
        #expect(LRCParser.parse("[00:01.00]a\r\n[00:02.00]b\r\n").lines.map(\.text) == ["a", "b"], "CRLF")
    }

    @Test func bilingualLyricsRankBelowOriginal() {
        let original = synced(1, artist: "Band", lrc: "[00:10.00]When I open the window\n[00:14.00]the wind comes in\n[00:18.00]and I look up")
        let bilingual = synced(2, artist: "Band", lrc: """
        [00:10.00]When I open the window
        [00:10.00]창문을 열면
        [00:14.00]the wind comes in
        [00:14.00]바람이 들어와
        [00:18.00]and I look up
        [00:18.00]하늘을 봐
        """)
        #expect(LRCParser.sharedTimestampRatio(bilingual.syncedLyrics!) == 1)
        #expect(LRCParser.sharedTimestampRatio(original.syncedLyrics!) == 0)
        let ranked = LyricsSelector.rankedSynced([bilingual, original], targetDuration: 200, targetTitle: "Love", targetArtist: "Band")
        #expect(ranked.first?.id == 1)
        // 원문 문자 가점(로마자 표기보다 원문 우선)은 그대로
        let romanized = synced(3, artist: "Band", lrc: "[00:10.00]Haneureul boneun daydream")
        let hangul = synced(4, artist: "Band", lrc: "[00:10.00]하늘을 보는 daydream")
        #expect(LyricsSelector.rankedSynced([romanized, hangul], targetDuration: 200, targetTitle: "Love", targetArtist: "Band").first?.id == 4)
    }

    @Test func matchingArtistWinsOverSameTitleFromOtherArtist() {
        let other = synced(1, artist: "Someone Else", lrc: "[00:10.00]다른 노래의 가사", duration: 200)
        let right = synced(2, artist: "IU", lrc: "[00:10.00]맞는 노래의 가사", duration: 201)
        let ranked = LyricsSelector.rankedSynced([other, right], targetDuration: 200, targetTitle: "Love", targetArtist: "IU")
        #expect(ranked.first?.id == 2, "길이가 1초 더 어긋나도 가수가 맞는 쪽")
        #expect(LyricsSelector.artistsMatch("IU, SUGA", "iu"))
        #expect(!LyricsSelector.artistsMatch("아이유", "IU"), "표기가 다르면 가점만 없다 (거르지 않음)")
        #expect(ranked.count == 2)
    }

    @Test func unknownDurationDoesNotFilterEverything() {
        let candidate = synced(1, artist: "A", lrc: "[00:10.00]가사", duration: 200)
        #expect(LyricsSelector.rankedSynced([candidate], targetDuration: 0, targetTitle: "Love").count == 1)
        #expect(LyricsSelector.best([candidate], targetDuration: 0)?.id == 1)
    }

    @Test func learnedDelayFollowsCandidateIDNotPosition() throws {
        let suite = "space.knowai.cono.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LearnedLyricsDelays(defaults: defaults)
        let track = TrackInfo(id: "p1", title: "Love", artist: "IU", album: "", duration: 200)

        store.store(delay: 0.8, candidateKey: "netease:42", for: track)
        let learned = try #require(store.load(for: track))
        #expect(learned.delay == 0.8)
        // 캐시를 다시 받아 순서가 바뀌어도 같은 가사를 가리킨다
        #expect(learned.candidateIndex(in: ["lrclib:7", "netease:42", "amll:9"]) == 1)
        // 기억한 가사가 목록에 없으면 적용하지 않는다 (다른 가사에 지연을 얹지 않게)
        #expect(learned.candidateIndex(in: ["lrclib:7", "lrclib:42"]) == nil, "번호가 같아도 소스가 다르면 다른 가사")
        // 옛 형식(순번만)도 읽는다
        let legacy = LearnedLyricsDelays.Learned(delay: 0.5, candidateKey: nil, legacyIndex: 1)
        #expect(legacy.candidateIndex(in: ["lrclib:7", "lrclib:9"]) == 1)
        #expect(legacy.candidateIndex(in: ["lrclib:7"]) == nil)
        // 옛 형식(LRCLIB 번호만 저장)은 "lrclib:번호" 로 읽힌다
        let old = TrackInfo(id: "p2", title: "Old", artist: "A", album: "", duration: 100)
        defaults.set(["delay": 0.3, "candidateID": 77], forKey: "space.knowai.cono.lyricsDelay.Old|A|100")
        #expect(store.load(for: old)?.candidateKey == "lrclib:77")
    }

    @Test func plusSignIsPercentEncoded() throws {
        var components = try #require(URLComponents(string: "https://lrclib.net/api/search"))
        components.queryItems = [URLQueryItem(name: "q", value: "Florence + the Machine")]
        let query = try #require(components.urlEncodingPlus.query(percentEncoded: true))
        #expect(query == "q=Florence%20%2B%20the%20Machine")
    }
}

struct MediaTitleCleanerTests {
    private func clean(_ title: String, _ artist: String) -> [String] {
        let result = MediaTitleCleaner.clean(title: title, artist: artist)
        return [result.title, result.artist]
    }

    @Test func youTubeVideoTitlesBecomeSongAndArtist() {
        #expect(clean("中島美嘉 - 雪の華 / THE FIRST TAKE", "THE FIRST TAKE") == ["雪の華", "中島美嘉"])
        #expect(clean("YOASOBI「アイドル」 Official Music Video", "Ayase / YOASOBI") == ["アイドル", "YOASOBI"])
        #expect(clean("[MV] IU(아이유) _ Blueming(블루밍)", "1theK (원더케이)") == ["Blueming(블루밍)", "IU(아이유)"])
        #expect(clean("Artist - Song (Official Video) [4K]", "ArtistVEVO") == ["Song", "Artist"])
        #expect(clean("Hype Boy", "NewJeans - Topic") == ["Hype Boy", "NewJeans"])
    }

    @Test func cleanValuesAndMeaningfulParenthesesStay() {
        // YouTube Music 은 이미 곡·가수
        #expect(clean("First Love", "Hikaru Utada") == ["First Love", "Hikaru Utada"])
        // 원제·피처링 괄호는 남긴다
        #expect(clean("Good day (좋은 날)", "IU") == ["Good day (좋은 날)", "IU"])
        #expect(clean("Song (feat. Someone)", "Artist") == ["Song (feat. Someone)", "Artist"])
        // "곡 - 버전 표기" 는 가수·곡으로 나누지 않는다
        #expect(clean("First Love - Remastered 2014", "Hikaru Utada") == ["First Love - Remastered 2014", "Hikaru Utada"])
    }
}

struct VideoTrackLyricsTests {
    private func synced(_ id: Int, title: String, artist: String, duration: Double) -> LyricsCandidate {
        LyricsCandidate(id: id, trackName: title, artistName: artist, albumName: nil, duration: duration,
                        // 본문이 같으면 중복 제거로 빠지므로 후보마다 다르게
                        instrumental: false, plainLyrics: nil, syncedLyrics: "[00:10.00]가사 한 줄 \(id)")
    }

    @Test func videoLongerThanSongStillFindsLyricsOfSameArtist() {
        // 영상은 인트로·아웃트로로 원곡(290초)보다 25초 길다
        let studio = synced(1, title: "雪の華", artist: "中島美嘉", duration: 290)
        let otherArtist = synced(2, title: "雪の華", artist: "Someone Else", duration: 292)
        let video = TrackInfo(id: "v", title: "雪の華", artist: "中島美嘉", album: "", duration: 315, durationIsReliable: false)
        #expect(LyricsSelector.syncedCandidates([studio, otherArtist], for: video).map(\.id) == [1],
                "길이를 풀되 가수는 맞아야 한다")

        // 음악 앱 곡(길이 신뢰)은 예전처럼 길이로 거른다
        let musicAppTrack = TrackInfo(id: "m", title: "雪の華", artist: "中島美嘉", album: "", duration: 315)
        #expect(LyricsSelector.syncedCandidates([studio], for: musicAppTrack).isEmpty)
    }

    @Test func exactDurationMatchWinsOverLenientForVideo() {
        let exact = synced(1, title: "Song", artist: "Artist", duration: 200)
        let far = synced(2, title: "Song", artist: "Artist", duration: 240)
        let video = TrackInfo(id: "v", title: "Song", artist: "Artist", album: "", duration: 201, durationIsReliable: false)
        // 길이가 맞는 후보가 있으면 그것만 (완화 검색은 없을 때만)
        #expect(LyricsSelector.syncedCandidates([far, exact], for: video).map(\.id) == [1])
    }
}


struct AdDetectorTests {
    // 2026-09-26 실측: 광고 2개 뒤 본 영상. 광고 중에도 탭 제목은 본 영상 그대로였다.
    private let tabs = ["LEE JISOO - MISMATCH / THE FIRST TAKE - YouTube", "(3) Gmail", "새 탭"]

    @Test func nowPlayingTitleMissingFromTabsIsAnAd() {
        #expect(AdDetector.isAdvertisement(title: "여기어때, 해외여행 플랫폼으로 확장! 프로젝트 관리는 먼데이닷컴으로",
                                           artist: "monday.com", duration: 59.9, tabTitles: tabs))
        #expect(AdDetector.isAdvertisement(title: "1-click Hermes Agent", artist: "Hostinger.com/kr/hermes-agent",
                                           duration: 31.2, tabTitles: tabs))
        #expect(!AdDetector.isAdvertisement(title: "LEE JISOO - MISMATCH / THE FIRST TAKE", artist: "THE FIRST TAKE",
                                            duration: 244.2, tabTitles: tabs))
        // YouTube Music 탭: "곡 - YouTube Music" / 알림 개수 "(1) "
        #expect(!AdDetector.isAdvertisement(title: "Hype Boy", artist: "NewJeans", duration: 179,
                                            tabTitles: ["(1) Hype Boy - YouTube Music"]))
    }

    @Test func genericTabTitlesDoNotHideAds() {
        // 사이트 이름만 남은 탭("YouTube")은 모든 제목을 품는 것으로 오판하지 않는다 → 추정으로
        #expect(AdDetector.isAdvertisement(title: "1-click Hermes Agent", artist: "Hostinger.com/kr/hermes-agent",
                                           duration: 31.2, tabTitles: ["YouTube"]))
    }

    @Test func fallbackGuessWithoutTabTitles() {
        #expect(AdDetector.isAdvertisement(title: "여기어때 …", artist: "monday.com", duration: 59.9, tabTitles: nil))
        // 짧아도 가수 칸이 도메인이 아니면 곡으로
        #expect(!AdDetector.isAdvertisement(title: "짧은 곡", artist: "아이유", duration: 58, tabTitles: nil))
        // 도메인이어도 길면 곡으로 (가수 이름에 .com 이 든 경우 등)
        #expect(!AdDetector.isAdvertisement(title: "Song", artist: "artist.com", duration: 210, tabTitles: nil))
    }

    @Test func browserTabScriptsCompileForInstalledBrowsers() {
        for bundleID in ["com.google.Chrome", "com.apple.Safari"]
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            let script = NSAppleScript(source: BrowserTabScript.source(bundleID: bundleID)!)
            var error: NSDictionary?
            let compiled = script?.compileAndReturnError(&error) ?? false
            #expect(compiled, "\(bundleID) 탭 스크립트 컴파일 실패: \(error ?? [:])")
        }
        #expect(!BrowserTabScript.supports(bundleID: "com.apple.Music"))
    }
}

struct LyricsSourcesTests {
    @Test func netEaseCreditLinesAndJSONAreRemoved() throws {
        let raw = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"누군가"}]}
        [00:00.00] 作词 : 누군가
        [00:01.00] 作曲 : 다른 사람
        [00:02.00] Arranger : 편곡자
        [00:12.30]창문을 열면 바람이
        [00:16.80]하늘을 보는 daydream
        [00:21.10]오늘은 하늘이 참 맑은 날
        """
        let cleaned = try #require(NetEaseLyrics.cleaned(raw))
        #expect(LRCParser.parse(cleaned).lines.map(\.text) == ["창문을 열면 바람이", "하늘을 보는 daydream", "오늘은 하늘이 참 맑은 날"])
        // 가사가 없는 곡 ("纯音乐，请欣赏") 은 후보에서 뺀다
        #expect(NetEaseLyrics.cleaned("[00:00.00]纯音乐，请欣赏\n[00:10.00]x\n[00:20.00]y\n[00:30.00]z") == nil)
    }

    @Test func ttmlLinesBecomeLRCWithoutBackgroundVocals() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="00:12.345" end="00:15.000"><span begin="00:12.345" end="00:13.000">창문을</span> <span begin="00:13.100" end="00:14.000">열면</span><span ttm:role="x-bg"><span begin="00:14.1" end="00:14.9">(우우)</span></span></p>
        <p begin="1:02.5" end="1:05"><span begin="1:02.5" end="1:03">하늘을</span> <span begin="1:03.1" end="1:04">보는</span><span ttm:role="x-translation">looking at the sky</span></p>
        </div></body></tt>
        """
        let lrc = try #require(TTMLLyrics.lrc(from: ttml))
        let lines = LRCParser.parse(lrc).lines
        #expect(lines.map(\.text) == ["창문을 열면", "하늘을 보는"])
        #expect(abs(lines[0].start - 12.35) < 0.01)
        #expect(abs(lines[1].start - 62.5) < 0.01)
        #expect(TTMLLyrics.seconds("62.5s") == 62.5)
        #expect(TTMLLyrics.seconds("00:01:02.5") == 62.5)
    }

    @Test func amllIndexMatchesByTitleArtistOrNetEaseID() {
        let jsonl = """
        {"metadata":[["artists",["YOASOBI"]],["musicName",["Idol","アイドル"]],["ncmMusicId",["2048982668"]]],"rawLyricFile":"a.ttml"}
        {"metadata":[["artists",["Someone"]],["musicName",["Idol"]],["ncmMusicId",["111"]]],"rawLyricFile":"b.ttml"}
        {"metadata":[["artists",["Other"]],["musicName",["Different"]],["ncmMusicId",["222"]]],"rawLyricFile":"c.ttml"}
        not json
        """
        let entries = AMLLIndex.parse(jsonl)
        #expect(entries.count == 3)
        // 제목(별칭 포함)과 가수가 모두 맞아야 — 같은 제목 다른 가수는 빠진다
        #expect(AMLLIndex.matches(entries, title: "アイドル", artist: "YOASOBI").map(\.file) == ["a.ttml"])
        // NetEase 검색으로 찾은 곡 번호가 같으면 제목 표기가 달라도
        #expect(AMLLIndex.matches(entries, title: "전혀 다른 표기", artist: "?", neteaseIDs: ["222"]).map(\.file) == ["c.ttml"])
        #expect(entries[0].candidateID == entries[0].candidateID && entries[0].candidateID != entries[1].candidateID)
    }

    @Test func candidatesFromAllSourcesAreRankedTogether() {
        func candidate(_ id: Int, _ source: LyricsSource, duration: Double?, text: String) -> LyricsCandidate {
            LyricsCandidate(id: id, trackName: "Song", artistName: "Artist", albumName: nil, duration: duration,
                            instrumental: false, plainLyrics: nil, syncedLyrics: "[00:10.00]\(text)", source: source)
        }
        let track = TrackInfo(id: "t", title: "Song", artist: "Artist", album: "", duration: 200)
        let pool = [
            candidate(1, .lrclib, duration: 200, text: "한 줄"),
            candidate(1, .netease, duration: 200.5, text: "다른 줄"),
            candidate(9, .amll, duration: nil, text: "손으로 맞춘 줄"),
            candidate(2, .netease, duration: 260, text: "다른 버전"), // 길이가 달라 빠진다
            candidate(3, .netease, duration: 200, text: "한 줄"),     // LRCLIB 과 본문이 같아 중복으로 빠진다
        ]
        let keys = LyricsSelector.syncedCandidates(pool, for: track).map(\.key)
        #expect(Set(keys) == ["lrclib:1", "netease:1", "amll:9"])
    }
}
