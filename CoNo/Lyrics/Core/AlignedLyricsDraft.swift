// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

/// 최근 구간에서 얻은 검토용 초안. 생성 자체에는 파일·현재 가사를 바꾸는 동작이 없다.
struct AlignedLyricsDraft: Sendable {
    let lyrics: TimedLyrics
    let isTranscription: Bool
    var plainLyrics: String { lyrics.lines.map(\.text).joined(separator: "\n") }

    static func requestText(_ input: String) throws -> String? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = try LyricsTapSync(trackID: "draft", plainLyrics: input).plainLyrics
        guard normalized.count <= 512 else { throw CTCAlignmentError.tooLong }
        return normalized
    }

    init(result: CTCAlignmentResult, expectedText: String?) throws {
        guard result.confidence.isFinite, result.confidence >= 0.35, result.confidence <= 1,
              expectedText == nil || (result.text == expectedText && result.textMatch.isFinite && result.textMatch >= 0.5 && result.textMatch <= 1),
              !result.text.isEmpty, result.text.count <= 512, !result.segments.isEmpty else {
            throw LearnedWordTimingError.invalidRecord
        }
        let normalized = try LyricsTapSync(trackID: "draft", plainLyrics: result.text)
        guard normalized.plainLyrics == result.text else { throw LearnedWordTimingError.invalidRecord }
        let characters = Array(result.text)
        var previousCharacter = 0
        var previousEnd = 0.0
        for segment in result.segments {
            guard segment.characterStart >= previousCharacter, segment.characterCount > 0,
                  segment.characterStart <= characters.count, segment.characterCount <= characters.count - segment.characterStart,
                  segment.start.isFinite, segment.start >= previousEnd, let end = segment.end,
                  end.isFinite, end > segment.start, end <= 86_400 else { throw LearnedWordTimingError.invalidRecord }
            previousCharacter = segment.characterStart + segment.characterCount
            previousEnd = end
        }
        var offset = 0
        var lines: [LyricLine] = []
        for text in normalized.lines {
            let endOffset = offset + text.count
            let matches = result.segments.filter { $0.characterStart >= offset && $0.characterStart < endOffset }
            guard let first = matches.first, let end = matches.last?.end,
                  matches.allSatisfy({ $0.characterStart + $0.characterCount <= endOffset }),
                  lines.last.map({ first.start > $0.start }) ?? true else { throw LearnedWordTimingError.invalidRecord }
            lines.append(LyricLine(start: first.start, text: text, segments: matches.map {
                LyricSegment(characterStart: $0.characterStart - offset, characterCount: $0.characterCount, start: $0.start, end: $0.end)
            }, explicitEnd: end))
            offset = endOffset + 1
        }
        guard lines.reduce(0, { $0 + $1.segments.count }) == result.segments.count else { throw LearnedWordTimingError.invalidRecord }
        lyrics = TimedLyrics(lines: lines)
        isTranscription = expectedText == nil
    }

    func lrc() throws -> String {
        let contents = lyrics.lines.map { line -> String in
            let characters = Array(line.text)
            var row = "[\(LyricsTapSync.timestamp(line.start))] "
            var cursor = 0
            for segment in line.segments {
                row += String(characters[cursor..<segment.characterStart])
                row += "<\(LyricsTapSync.timestamp(segment.start))>"
                cursor = segment.characterStart + segment.characterCount
                row += String(characters[segment.characterStart..<cursor])
                row += "<\(LyricsTapSync.timestamp(segment.end ?? segment.start))>"
            }
            row += String(characters[cursor...])
            return row
        }.joined(separator: "\n") + "\n"
        let roundTrip = LRCParser.parse(contents)
        guard roundTrip.lines.map(\.text) == lyrics.lines.map(\.text),
              zip(roundTrip.lines, lyrics.lines).allSatisfy({ lhs, rhs in
                  lhs.segments.count == rhs.segments.count && abs(lhs.start - rhs.start) <= 0.001
                    && zip(lhs.segments, rhs.segments).allSatisfy { a, b in
                        a.characterStart == b.characterStart && a.characterCount == b.characterCount
                            && abs(a.start - b.start) <= 0.001 && abs((a.end ?? 0) - (b.end ?? 0)) <= 0.001
                    }
              }) else { throw LyricsTapSyncError.invalidText }
        return contents
    }
}
