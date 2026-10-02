// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 모든 KRC 입력은 이 테스트가 만든 합성 문장이다. 실제 서비스 가사는 포함하지 않는다.

import Foundation
import Testing
import zlib

struct KRCLyricsTests {
    @Test func preservesUnicodeWordTimesAndGaps() throws {
        let data = try syntheticKRC("[1000,2500]<0,500,0>하늘 <800,700,0>👩🏽‍🚀 <1700,600,0>が & café (둘) <3")
        let lrc = try KRCLyrics.enhancedLRC(from: data)
        let lyrics = LRCParser.parse(lrc)
        let line = try #require(lyrics.lines.first)
        #expect(line.text == "하늘 👩🏽‍🚀 が & café (둘) <3")
        #expect(line.start == 1)
        #expect(line.explicitEnd == 3.5)
        #expect(line.segments == [
            LyricSegment(characterStart: 0, characterCount: 2, start: 1, end: 1.5),
            LyricSegment(characterStart: 3, characterCount: 1, start: 1.8, end: 2.5),
            LyricSegment(characterStart: 5, characterCount: "が & café (둘) <3".count, start: 2.7, end: 3.3)
        ])
        #expect(line.highlightedCharacters(at: 1.6, lineEnd: 3.5) == 2)
        #expect(lyrics.lineIndex(at: 3.49) == 0)
        #expect(lyrics.lineIndex(at: 3.5) == nil)
    }

    @Test func acceptsBOMMetadataCRLFAndOffset() throws {
        let data = try syntheticKRC("\u{FEFF}[ti:합성 시험]\r\n[language:unused-metadata]\r\n[offset:250]\r\n[1000,1000]<0,1000,0>별")
        let lrc = try KRCLyrics.enhancedLRC(from: data)
        let line = try #require(LRCParser.parse(lrc).lines.first)
        #expect(lrc.hasPrefix("[offset:250]"))
        #expect(!lrc.contains("language"))
        #expect(line.start == 0.75)
        #expect(line.segments.first?.start == 0.75)
        #expect(line.segments.first?.end == 1.75)
    }

    @Test func preservesLongLineEndAndLeadingInterlude() throws {
        let data = try syntheticKRC("[0,1000]\n[1000,15000]<0,15000,0>합성 긴 음")
        let lyrics = LRCParser.parse(try KRCLyrics.enhancedLRC(from: data))
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 15.9) == 1)
        #expect(lyrics.end(of: 1) == 16)
    }

    @Test(arguments: [Data(), Data("krc1".utf8), Data("lrc1fake".utf8)])
    func rejectsMissingOrInvalidHeader(_ data: Data) {
        #expect(throws: KRCLyrics.DecodeError.invalidHeader) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test func rejectsTruncatedAndCorruptCompressedData() throws {
        let valid = try syntheticKRC("[0,1000]<0,1000,0>합성")
        #expect(throws: KRCLyrics.DecodeError.invalidCompression) {
            try KRCLyrics.enhancedLRC(from: valid.dropLast())
        }
        var corrupt = valid
        corrupt[corrupt.count - 1] ^= 0x01
        #expect(throws: KRCLyrics.DecodeError.invalidCompression) { try KRCLyrics.enhancedLRC(from: corrupt) }
    }

    @Test func rejectsTrailingCompressedPayload() throws {
        let bytes = try compressedBytes(Data("[0,1000]<0,1000,0>합성".utf8)) + [0x00, 0x01]
        let data = wrappedKRC(bytes)
        #expect(throws: KRCLyrics.DecodeError.invalidCompression) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test func rejectsInvalidUTF8() throws {
        let data = wrappedKRC(try compressedBytes(Data([0xFF, 0xFE, 0xC0, 0x80])))
        #expect(throws: KRCLyrics.DecodeError.invalidUTF8) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test func boundsCompressedAndExpandedSizes() throws {
        let hugeFile = Data(repeating: 0, count: KRCLyrics.maximumFileBytes + 1)
        #expect(throws: KRCLyrics.DecodeError.fileTooLarge) { try KRCLyrics.enhancedLRC(from: hugeFile) }
        let bomb = try syntheticKRC(String(repeating: "x", count: KRCLyrics.maximumExpandedBytes + 1))
        #expect(bomb.count < KRCLyrics.maximumFileBytes)
        #expect(throws: KRCLyrics.DecodeError.expandedTooLarge) { try KRCLyrics.enhancedLRC(from: bomb) }
    }

    @Test(arguments: [
        "[-1,1000]<0,1000,0>별",
        "[86400000,1]<0,1,0>별",
        "[99999999999999999999999,1]<0,1,0>별",
        "[0,1000]<1001,0,0>별",
        "[0,1000]<500,501,0>별",
        "[0,1000]<0,600,0>앞<500,500,0>뒤",
        "[offset:86400001]\n[0,1000]<0,1000,0>별"
    ])
    func rejectsInvalidOrOverlappingTiming(_ text: String) throws {
        let data = try syntheticKRC(text)
        #expect(throws: KRCLyrics.DecodeError.invalidTiming) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test(arguments: [
        "not a line",
        "[0,1000]untimed text",
        "[0,1000]<-1,1000,0>별",
        "[0,1000]<0,1000,0>별<5,broken,0>"
    ])
    func rejectsMalformedStructure(_ text: String) throws {
        let data = try syntheticKRC(text)
        #expect(throws: KRCLyrics.DecodeError.invalidStructure) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test(arguments: ["<00:05.0>", "< 00:05 >", "<00:05:00>", "<00:5e0>", "<outer<00:05>>"])
    func rejectsTextThatWouldBeLostAsLRCTags(_ text: String) throws {
        let data = try syntheticKRC("[0,1000]<0,1000,0>합성 \(text)")
        #expect(throws: KRCLyrics.DecodeError.ambiguousText) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test func boundsLineLengthAndLineCount() throws {
        let longLine = try syntheticKRC("[0,1]<0,1,0>" + String(repeating: "x", count: 65_536))
        #expect(throws: KRCLyrics.DecodeError.tooComplex) { try KRCLyrics.enhancedLRC(from: longLine) }
        let manyLines = try syntheticKRC(Array(repeating: "[0,1]<0,1,0>x", count: 10_001).joined(separator: "\n"))
        #expect(throws: KRCLyrics.DecodeError.tooComplex) { try KRCLyrics.enhancedLRC(from: manyLines) }
    }

    @Test func boundsTotalWordCount() throws {
        let line = "[0,0]" + String(repeating: "<0,0,0>x", count: 1_000)
        let data = try syntheticKRC(Array(repeating: line, count: 51).joined(separator: "\n"))
        #expect(throws: KRCLyrics.DecodeError.tooComplex) { try KRCLyrics.enhancedLRC(from: data) }
    }

    @Test(arguments: ["", "[ti:합성 제목]", "[0,1000]", "[0,1000]<0,1000,0> "])
    func rejectsEmptyLyrics(_ text: String) throws {
        let data = try syntheticKRC(text)
        #expect(throws: KRCLyrics.DecodeError.noLyrics) { try KRCLyrics.enhancedLRC(from: data) }
    }

    private func syntheticKRC(_ text: String) throws -> Data {
        wrappedKRC(try compressedBytes(Data(text.utf8)))
    }

    private func compressedBytes(_ data: Data) throws -> [UInt8] {
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        var length = uLongf(compressed.count)
        let status = compressed.withUnsafeMutableBufferPointer { output in
            data.withUnsafeBytes { input in
                compress2(output.baseAddress!, &length, input.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
            }
        }
        try #require(status == Z_OK)
        return Array(compressed.prefix(Int(length)))
    }

    private func wrappedKRC(_ compressed: [UInt8]) -> Data {
        let mask: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]
        return Data("krc1".utf8) + Data(compressed.enumerated().map { $0.element ^ mask[$0.offset % mask.count] })
    }
}
