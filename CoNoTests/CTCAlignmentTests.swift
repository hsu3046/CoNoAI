// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 합성 logits만 사용한다. 실제 가사/음성/모델 파일은 테스트 fixture에 포함하지 않는다.

import Foundation
import Testing

struct CTCAlignmentTests {
    private let contents = "<s> 0\n<pad> 1\n<unk> 2\n  3\na 4\nb 5\ne 6\né 7\n가 8\n\u{0301} 9\n"

    private func align(_ path: [Int], text: String? = nil, start: Double = 0) throws -> CTCAlignmentResult {
        let vocabulary = try CTCVocabulary(contents: contents)
        var logits = [Float](repeating: -8, count: path.count * vocabulary.tokens.count)
        for (frame, token) in path.enumerated() { logits[frame * vocabulary.tokens.count + token] = 8 }
        return try logits.withUnsafeBufferPointer {
            try CTCAlignment.align(logits: $0, frameCount: path.count, vocabulary: vocabulary,
                                   text: text, startTime: start, audioDuration: Double(path.count) * 0.02)
        }
    }

    @Test func keepsForcedOriginalTextAndAbsoluteCharacterTimes() throws {
        let result = try align([0, 4, 4, 3, 0, 5, 0], text: "A b!", start: 12)
        #expect(result.text == "A b!")
        #expect(result.textMatch == 1)
        #expect(result.confidence > 0.99)
        #expect(result.segments == [
            LyricSegment(characterStart: 0, characterCount: 1, start: 12.02, end: 12.06),
            LyricSegment(characterStart: 2, characterCount: 2, start: 12.1, end: 12.12)
        ])
    }

    @Test func repeatedLabelsNeedABlankAndRemainSeparate() throws {
        let result = try align([0, 4, 4, 0, 4, 0], text: "aa")
        #expect(result.segments == [
            LyricSegment(characterStart: 0, characterCount: 1, start: 0.02, end: 0.06),
            LyricSegment(characterStart: 1, characterCount: 1, start: 0.08, end: 0.1)
        ])
        #expect(throws: CTCAlignmentError.impossibleAlignment) { try align([4, 4], text: "aa") }
    }

    @Test func greedyDropsSpecialsTrimsSpacesAndMergesRepeatedFrames() throws {
        let result = try align([3, 3, 4, 4, 1, 4, 0, 3, 3, 0, 3, 5, 3])
        #expect(result.text == "aa b")
        #expect(result.segments.map { $0.characterStart } == [0, 1, 3])
        #expect(result.segments[0].start == 0.04)
        #expect(result.segments[0].end == 0.08)
    }

    @Test func greedyCombiningScalarsMapToOneCharacter() throws {
        let result = try align([6, 0, 9, 0])
        #expect(result.text == "e\u{0301}")
        #expect(result.text.count == 1)
        #expect(result.segments == [LyricSegment(characterStart: 0, characterCount: 1, start: 0, end: 0.06)])
    }

    @Test func forcedUnicodeNormalizationPreservesOriginalGraphemeRanges() throws {
        let original = "(가) e\u{0301}!"
        let result = try align([8, 0, 3, 0, 7, 0], text: original)
        #expect(result.text.unicodeScalars.map { $0.value } == original.unicodeScalars.map { $0.value })
        #expect(result.segments.map { $0.characterStart } == [0, 4])
        #expect(result.segments.map { $0.characterCount } == [3, 2])
    }

    @Test func independentGreedyMismatchIsNotHiddenByForcedPath() throws {
        let result = try align([4, 0, 5, 0], text: "aa")
        #expect(result.text == "aa")
        #expect(result.textMatch == 0.5)
        #expect(result.confidence < 0.01)
    }

    @Test func blankAudioDoesNotBecomeAConfidentForcedResult() throws {
        let greedy = try align([0, 0, 0, 0])
        #expect(greedy.text.isEmpty)
        #expect(greedy.segments.isEmpty)
        #expect(greedy.confidence == 0)
        let forced = try align([0, 0, 0, 0], text: "a")
        #expect(forced.textMatch == 0)
        #expect(forced.confidence < 0.001)
    }

    @Test func handlesSingleFrameAndWhitespaceOnlyText() throws {
        let result = try align([4], text: "a")
        #expect(result.segments == [LyricSegment(characterStart: 0, characterCount: 1, start: 0, end: 0.02)])
        #expect(throws: CTCAlignmentError.emptyText) { try align([4], text: " \n") }
    }

    @Test func rejectsUnsupportedLettersRatherThanSilentlyDroppingThem() throws {
        #expect(throws: CTCAlignmentError.unsupportedCharacter("나")) { try align([4, 0], text: "a나") }
        #expect(throws: CTCAlignmentError.tooLong) { try align([4], text: String(repeating: "a", count: 513)) }
    }

    @Test(arguments: ["<s> 0\na 2\n", "<s> 0\na 1\nb 1\n", "<s> 0\na 1\na 2\n", "<s> 0\n 16384\n", ""])
    func rejectsMalformedVocabulary(_ contents: String) {
        #expect(throws: CTCAlignmentError.invalidVocabulary) { try CTCVocabulary(contents: contents) }
    }

    @Test func vocabularyDelimiterIsNotAffectedByUnicodePrependCharacters() throws {
        let vocabulary = try CTCVocabulary(contents: "<s> 0\n\u{0D4E} 1\n  2\n")
        #expect(vocabulary.tokens == ["<s>", "\u{0D4E}", " "])
        #expect(try vocabulary.encode("\u{0D4E}").map { $0.id } == [1])
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func rejectsNonFiniteLogits(_ invalid: Float) throws {
        let vocabulary = try CTCVocabulary(contents: "<s> 0\na 1\n")
        let logits: [Float] = [0, invalid]
        #expect(throws: CTCAlignmentError.nonFinite) {
            try logits.withUnsafeBufferPointer {
                try CTCAlignment.align(logits: $0, frameCount: 1, vocabulary: vocabulary, text: "a", startTime: 0, audioDuration: 0.02)
            }
        }
    }

    @Test func extremeFiniteLogitsStillUseAStableSoftmax() throws {
        let vocabulary = try CTCVocabulary(contents: "<s> 0\na 1\n")
        let logits = [Float](repeating: .greatestFiniteMagnitude, count: 2)
        let result = try logits.withUnsafeBufferPointer {
            try CTCAlignment.align(logits: $0, frameCount: 1, vocabulary: vocabulary, text: "a", startTime: 0, audioDuration: 0.02)
        }
        #expect(abs(result.confidence - 0.5) < 1e-10)
    }

    @Test func rejectsShapeAndDurationBoundsBeforeReadingLogits() throws {
        let vocabulary = try CTCVocabulary(contents: "<s> 0\na 1\n")
        for (frames, duration) in [(0, 1.0), (2, 1.0), (1_025, 20.0), (1, 20.1), (1, Double.nan)] {
            #expect(throws: CTCAlignmentError.invalidShape) {
                try [Float](repeating: 0, count: 2).withUnsafeBufferPointer {
                    try CTCAlignment.align(logits: $0, frameCount: frames, vocabulary: vocabulary, text: "a", startTime: 0, audioDuration: duration)
                }
            }
        }
    }

    @Test func cancelsDuringDynamicProgramming() throws {
        let vocabulary = try CTCVocabulary(contents: "<s> 0\na 1\n")
        var checks = 0
        #expect(throws: CancellationError.self) {
            try [Float](repeating: 0, count: 40).withUnsafeBufferPointer {
                try CTCAlignment.align(logits: $0, frameCount: 20, vocabulary: vocabulary, text: "aaaa", startTime: 0, audioDuration: 0.4,
                                       isCancelled: { checks += 1; return checks > 23 })
            }
        }
        #expect(checks == 24)
    }
}
