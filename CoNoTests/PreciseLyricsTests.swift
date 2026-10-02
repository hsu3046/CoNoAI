// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct PreciseLyricsTests {
    @Test func enhancedTimingPreservesPausesAndCanSeekBackwards() throws {
        let lyrics = LRCParser.parse("[00:10]<00:10>안녕<00:11> <00:12>세계<00:14>")
        let line = try #require(lyrics.lines.first)
        #expect(line.text == "안녕 세계")
        #expect(line.segments == [
            LyricSegment(characterStart: 0, characterCount: 2, start: 10, end: 11),
            LyricSegment(characterStart: 3, characterCount: 2, start: 12, end: 14),
        ])
        #expect(line.highlightedCharacters(at: 10.5, lineEnd: 14) == 1)
        #expect(line.highlightedCharacters(at: 11.5, lineEnd: 14) == 2, "숨 구간에는 칠해진 글자 수 유지")
        #expect(line.highlightedCharacters(at: 12.5, lineEnd: 14) == 3.5)
        #expect(line.highlightedCharacters(at: 10.25, lineEnd: 14) == 0.5, "되감기 시 캐시한 진행률을 쓰지 않는다")
        #expect(lyrics.lineIndex(at: 14) == nil)
    }

    @Test func multipleLineTagsAndOffsetMoveWordTimingTogether() throws {
        let lyrics = LRCParser.parse("[offset:+500]\n[00:10][01:10]<00:10>반<00:11>복<00:12>")
        #expect(lyrics.lines.count == 2)
        let repeated = try #require(lyrics.lines.last)
        #expect(repeated.start == 69.5)
        #expect(repeated.segments.map(\.start) == [69.5, 70.5])
        #expect(repeated.explicitEnd == 71.5)
        #expect(repeated.highlightedCharacters(at: 70, lineEnd: 71.5) == 0.5)
    }

    @Test func enhancedTextKeepsGraphemeRangesAndLiteralAngleBrackets() throws {
        let line = try #require(LRCParser.parse("[00:01] <00:01>👨‍👩‍👧‍👦<00:02> 한글<00:03> <love>").lines.first)
        #expect(line.text == "👨‍👩‍👧‍👦 한글 <love>")
        #expect(line.segments[0].characterCount == 1)
        #expect(line.segments[1].characterStart == 2)
        #expect(line.segments[2].characterStart == 5)
    }

    @Test func unclosedFinalWordUsesNextLineWhileExplicitLongTimingIsPreserved() throws {
        let lyrics = LRCParser.parse("[00:01]<00:01>첫<00:02>줄\n[00:05]다음\n[00:20]<00:20>아아<00:35>")
        #expect(lyrics.lines[0].highlightedCharacters(at: 3.5, lineEnd: lyrics.end(of: 0)) == 1.5)
        #expect(lyrics.end(of: 1) == 15, "일반 LRC 10초 상한 유지")
        #expect(lyrics.end(of: 2) == 35, "실제 단어 종료 시각은 10초로 자르지 않는다")
        #expect(lyrics.lineIndex(at: 34) == 2)
    }

    @Test func backwardsAndNonfiniteTimesNeverBecomePreciseTiming() throws {
        let line = try #require(LRCParser.parse("[00:10]<00:11>순서<00:09>오류").lines.first)
        #expect(line.text == "순서오류")
        #expect(line.segments.isEmpty)
        #expect(line.highlightedCharacters(at: 11, lineEnd: 20) == nil)
        #expect(LRCParser.parseTime("00:nan") == nil)
        #expect(LRCParser.parseTime("999999999999:01") == nil)
        #expect(LRCParser.parse("[offset:inf]\n[00:01]정상").lines.first?.start == 1)
    }

    @Test func ttmlRoundTripPreservesMillisecondsWordEndsAndRoleFiltering() throws {
        let ttml = """
        <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
        <p begin="00:12.345" end="00:18.000"><span begin="00:12.345" end="00:13.001">안녕</span> <span begin="00:14.200" end="00:16.789" ttm:role="x-emphasis">세상</span><span ttm:role="x-bg"><span begin="00:16.8" end="00:17">우우</span></span><span ttm:role="x-translation">Hello world</span></p>
        </div></body></tt>
        """
        let lrc = try #require(TTMLLyrics.lrc(from: ttml))
        let line = try #require(LRCParser.parse(lrc).lines.first)
        #expect(line.text == "안녕 세상")
        #expect(line.start == 12.345)
        #expect(line.segments.map(\.start) == [12.345, 14.2])
        #expect(line.segments.map(\.end) == [13.001, 16.789])
        #expect(line.highlightedCharacters(at: 14, lineEnd: 16.789) == 2)
    }

    @Test func nestedTTMLSpansDoNotInventSpacesBetweenSyllables() throws {
        let ttml = """
        <tt><body><p begin="1s" end="4s"><span><span begin="1s" end="2s">노</span><span begin="2s" end="3s"><span>래</span></span></span></p></body></tt>
        """
        let lrc = try #require(TTMLLyrics.lrc(from: ttml))
        let line = try #require(LRCParser.parse(lrc).lines.first)
        #expect(line.text == "노래")
        #expect(line.segments.count == 2)
        #expect(line.explicitEnd == 3)
    }

    @Test func lineOnlyAndInvalidTTMLTimingFallBackWithoutLosingWords() throws {
        for body in [
            "그냥 가사",
            "<span begin=\"nan\" end=\"2s\">잘못된</span> 가사",
            "<span begin=\"1s\" end=\"3s\">겹친</span> <span begin=\"2s\" end=\"4s\">시각</span>",
        ] {
            let lrc = try #require(TTMLLyrics.lrc(from: "<tt><body><p begin=\"1s\" end=\"5s\">\(body)</p></body></tt>"))
            let line = try #require(LRCParser.parse(lrc).lines.first)
            #expect(!line.text.isEmpty)
            #expect(line.segments.isEmpty)
        }
        #expect(TTMLLyrics.seconds("nan") == nil)
        #expect(TTMLLyrics.seconds("inf") == nil)
        #expect(TTMLLyrics.seconds("-1s") == nil)
        #expect(TTMLLyrics.seconds("999999999999s") == nil)
        #expect(TTMLLyrics.seconds("00:61.0") == nil)
        #expect(TTMLLyrics.seconds("12345ms") == 12.345)
    }

    @Test func lineOnlyTTMLPreservesShortAndLongExplicitEndsWithoutInventingWordTiming() throws {
        let ttml = """
        <tt><body>
        <p begin="1s" end="4s">짧은 줄</p>
        <p begin="12s" end="30s">길게 부르는 줄</p>
        </body></tt>
        """
        let lyrics = LRCParser.parse(try #require(TTMLLyrics.lrc(from: ttml)))
        #expect(lyrics.lines.map(\.text) == ["짧은 줄", "길게 부르는 줄"])
        #expect(lyrics.lines.allSatisfy { $0.segments.isEmpty })
        #expect(lyrics.lines[0].highlightedCharacters(at: 2, lineEnd: 4) == nil)
        #expect(lyrics.end(of: 0) == 4)
        #expect(lyrics.lineIndex(at: 5) == nil, "원본 종료 뒤에 10초 기본값까지 남아 있으면 안 된다")
        #expect(lyrics.end(of: 1) == 30)
        #expect(lyrics.lineIndex(at: 29) == 1, "명시된 긴 줄 종료를 10초로 자르지 않는다")
        #expect(lyrics.lineIndex(at: 30) == nil)
    }

    @Test func terminalOnlyTagKeepsLineEndWhileExplicitWordStartKeepsPreciseTiming() throws {
        let lineOnly = try #require(LRCParser.parse("[00:01]줄 시각만 있는 가사<00:15>").lines.first)
        #expect(lineOnly.explicitEnd == 15)
        #expect(lineOnly.segments.isEmpty)
        let word = try #require(LRCParser.parse("[00:01]<00:01>길게<00:15>").lines.first)
        #expect(word.explicitEnd == 15)
        #expect(word.segments.count == 1)
        #expect(word.highlightedCharacters(at: 8, lineEnd: 15) == 1)
    }
}
