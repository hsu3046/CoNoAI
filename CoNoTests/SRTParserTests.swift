// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Testing

struct SRTParserTests {
    @Test func preservesCueEndsGapsAndMultilineUnicodeText() throws {
        let srt = "1\r\n00:00:01,250 --> 00:00:03,500\r\n<i>첫 줄</i>\r\n두 번째 👩🏽‍🎤\r\n\r\n2\r\n00:01:10,000 --> 00:01:25,000\r\n긴 가사"
        let lyrics = try SRTParser.parse(srt)
        #expect(lyrics.lines[0].text == "첫 줄 두 번째 👩🏽‍🎤")
        #expect(lyrics.lines[0].start == 1.25)
        #expect(lyrics.end(of: 0) == 3.5)
        #expect(lyrics.lineIndex(at: 4) == nil)
        #expect(lyrics.end(of: 1) == 85, "10초보다 긴 자막도 원본 종료 시각을 보존한다")
        #expect(lyrics.lineIndex(at: 84) == 1)
        #expect(lyrics.lineIndex(at: 85) == nil)
    }

    @Test func acceptsUnnumberedCuesAndDotMilliseconds() throws {
        let lyrics = try SRTParser.parse("00:00:01.005 --> 00:00:02.000\n가사")
        #expect(lyrics.lines.first?.start == 1.005)
    }

    @Test(arguments: [
        "1\n00:00:03,000 --> 00:00:01,000\n역전",
        "1\n00:60:01,000 --> 00:60:02,000\n범위",
        "1\n00:00:01,000 --> 00:00:02,000",
        "1\n00:00:01,000 --> 00:00:02,000\n정상\n\n2\n깨진 시각\n가사",
        "1\n00:00:01,000 --> 00:00:03,000\n겹침\n\n2\n00:00:02,000 --> 00:00:04,000\n겹침"
    ])
    func rejectsMalformedCueRatherThanSilentlyImportingOnlyPart(_ text: String) {
        #expect(throws: SRTError.self) { try SRTParser.parse(text) }
    }
}
