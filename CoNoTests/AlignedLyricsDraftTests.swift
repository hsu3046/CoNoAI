// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct AlignedLyricsDraftTests {
    @Test func plainLyricsKeepTheirLineBoundariesAndRoundTripWordTimes() throws {
        let text = "첫 줄\n둘째 줄"
        let result = CTCAlignmentResult(text: text, segments: [
            LyricSegment(characterStart: 0, characterCount: 1, start: 1.1, end: 1.4),
            LyricSegment(characterStart: 2, characterCount: 1, start: 1.5, end: 2),
            LyricSegment(characterStart: 4, characterCount: 2, start: 2.5, end: 3),
            LyricSegment(characterStart: 7, characterCount: 1, start: 3.2, end: 3.8)
        ], confidence: 0.8, textMatch: 0.9)
        let draft = try AlignedLyricsDraft(result: result, expectedText: text)
        #expect(draft.lyrics.lines.map(\.text) == ["첫 줄", "둘째 줄"])
        #expect(draft.lyrics.lines.map(\.start) == [1.1, 2.5])
        #expect(draft.lyrics.lines[1].segments.map(\.characterStart) == [0, 3])
        #expect(!draft.isTranscription)
        #expect(LRCParser.parse(try draft.lrc()) == draft.lyrics)
    }

    @Test func transcriptionRemainsADraftAndPreservesLongExplicitEnding() throws {
        let result = CTCAlignmentResult(text: "가나다", segments: [
            LyricSegment(characterStart: 0, characterCount: 3, start: 40, end: 57)
        ], confidence: 0.6, textMatch: 1)
        let draft = try AlignedLyricsDraft(result: result, expectedText: nil)
        #expect(draft.isTranscription)
        #expect(draft.plainLyrics == "가나다")
        #expect(LRCParser.parse(try draft.lrc()).end(of: 0) == 57)
    }

    @Test func rejectsLostLinesWrongTextTimestampMarkupAndLowQuality() throws {
        let segment = LyricSegment(characterStart: 0, characterCount: 1, start: 1, end: 2)
        for result in [
            CTCAlignmentResult(text: "가\n나", segments: [segment], confidence: 0.8, textMatch: 0.9),
            CTCAlignmentResult(text: "다", segments: [segment], confidence: 0.8, textMatch: 0.9),
            CTCAlignmentResult(text: "가\n나", segments: [segment], confidence: 0.1, textMatch: 1),
            CTCAlignmentResult(text: "가\n나", segments: [segment], confidence: 1, textMatch: 0.1)
        ] {
            #expect(throws: LearnedWordTimingError.self) { try AlignedLyricsDraft(result: result, expectedText: "가\n나") }
        }
        #expect(throws: LyricsTapSyncError.self) { try AlignedLyricsDraft.requestText("가 < 00:05 > 나") }
        #expect(try AlignedLyricsDraft.requestText("  \n") == nil)
        #expect(try AlignedLyricsDraft.requestText(" 첫 줄\u{2028}둘째 줄 ") == "첫 줄\n둘째 줄")
        #expect(throws: CTCAlignmentError.self) {
            try AlignedLyricsDraft.requestText(String(repeating: "가", count: 300) + "\n" + String(repeating: "나", count: 300))
        }
    }
}
