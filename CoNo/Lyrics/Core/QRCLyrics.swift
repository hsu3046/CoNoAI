// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// QRC cipher adapted from QQMusicDecoder, Copyright (c) 2023 WXRIW (MIT).
// Local-file XOR adapted from qmc-decode, Copyright (c) 2019 Jixun Wu (MIT).
// Both upstream copyright/permission notices are preserved in THIRD_PARTY_NOTICES.md.
// No service token or network access is used. The constants belong to the file format.

import Foundation
import zlib

enum QRCLyrics {
    static let maximumFileBytes = 1_048_576
    static let maximumExpandedBytes = 2_097_152
    private static let maximumMilliseconds = 86_400_000
    private static let marker = try! NSRegularExpression(pattern: #"\((\d+),(\d+)\)"#)
    private static let angleTag = try! NSRegularExpression(pattern: #"<([^<>]*)>"#)
    private static let localMagic: [UInt8] = [0x98, 0x25, 0xB0, 0xAC, 0xE3, 0x02, 0x83, 0x68, 0xE8, 0xFC, 0x6C]

    enum DecodeError: LocalizedError, Equatable {
        case fileTooLarge, invalidFormat, invalidCiphertext, invalidCompression, expandedTooLarge
        case invalidUTF8, invalidXML, invalidStructure, invalidTiming, tooComplex, ambiguousText, noLyrics

        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "QRC 파일은 1MB까지 가져올 수 있습니다."
            case .invalidFormat: "지원하는 QRC 파일 형식이 아닙니다."
            case .invalidCiphertext: "QRC 암호화 데이터의 길이가 올바르지 않습니다."
            case .invalidCompression: "QRC 파일이 손상되어 압축을 풀 수 없습니다."
            case .expandedTooLarge: "압축을 푼 QRC 가사가 2MB를 넘습니다."
            case .invalidUTF8: "QRC 가사의 문자 인코딩을 읽을 수 없습니다."
            case .invalidXML: "QRC 가사의 XML 내용을 읽을 수 없습니다."
            case .invalidStructure: "QRC 가사의 줄 또는 단어 표시가 올바르지 않습니다."
            case .invalidTiming: "QRC 가사에 순서가 맞지 않거나 범위를 벗어난 시각이 있습니다."
            case .tooComplex: "QRC 가사의 줄 또는 단어 수가 지원 범위를 넘습니다."
            case .ambiguousText: "QRC 본문에 가사 시각 태그와 구분할 수 없는 문자가 있습니다."
            case .noLyrics: "QRC 파일에 표시할 가사가 없습니다."
            }
        }
    }

    /// 로컬 QRC 바이너리, 내보낸 16진수 암호문, 복호화된 QRC XML/본문을 받는다.
    static func enhancedLRC(from data: Data) throws -> String {
        guard data.count <= maximumFileBytes else { throw DecodeError.fileTooLarge }
        let decoded: String
        if data.starts(with: localMagic) {
            let unwrapped = QRCLocalMask.transform(Array(data))
            decoded = try decryptText(Array(unwrapped.dropFirst(localMagic.count)))
        } else if var text = String(data: data, encoding: .utf8) {
            if text.first == "\u{FEFF}" { text.removeFirst() }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("<") || text.hasPrefix("[") {
                decoded = text
            } else {
                let hex = text.utf8.filter { ![9, 10, 13, 32].contains($0) }
                guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy({ hexValue($0) != nil }) else {
                    throw DecodeError.invalidFormat
                }
                let encrypted = stride(from: 0, to: hex.count, by: 2).map { hexValue(hex[$0])! << 4 | hexValue(hex[$0 + 1])! }
                decoded = try decryptText(encrypted)
            }
        } else { throw DecodeError.invalidFormat }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmed.hasPrefix("<") ? try xmlContent(trimmed) : trimmed
        return try convert(content)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func decryptText(_ encrypted: [UInt8]) throws -> String {
        let compressed = try QRCBlockCipher.decrypt(encrypted)
        var expanded = [UInt8](repeating: 0, count: maximumExpandedBytes + 1)
        var expandedSize = uLongf(expanded.count)
        var consumedSize = uLong(compressed.count)
        let status = expanded.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                uncompress2(destination.baseAddress!, &expandedSize, source.baseAddress!, &consumedSize)
            }
        }
        if status == Z_BUF_ERROR || expandedSize > maximumExpandedBytes { throw DecodeError.expandedTooLarge }
        // 마지막 8바이트 블록의 패딩만 허용한다. 원본 디코더는 zlib 뒤 패딩 값을 검사하지 않는다.
        guard status == Z_OK, compressed.count - Int(consumedSize) < 8 else { throw DecodeError.invalidCompression }
        guard var text = String(bytes: expanded.prefix(Int(expandedSize)), encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text
    }

    private static func xmlContent(_ xml: String) throws -> String {
        guard xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw DecodeError.invalidXML }
        // XML은 속성 안의 원시 줄바꿈을 공백으로 정규화한다. QRC의 LyricContent 줄 구분을
        // 잃지 않도록 따옴표 안 공백 문자만 문자 참조로 바꾼 뒤 정상 XML 파서로 검증한다.
        var escaped = ""
        var inTag = false
        var quote: Character?
        var index = xml.startIndex
        while index < xml.endIndex {
            if !inTag, xml[index...].hasPrefix("<!--") || xml[index...].hasPrefix("<![CDATA[") {
                let ending = xml[index...].hasPrefix("<!--") ? "-->" : "]]>"
                guard let end = xml[index...].range(of: ending) else { throw DecodeError.invalidXML }
                escaped += xml[index..<end.upperBound]
                index = end.upperBound
                continue
            }
            let character = xml[index]
            if let delimiter = quote {
                if character == delimiter { quote = nil }
                switch character {
                case "\r\n": escaped += "&#13;&#10;"
                case "\n": escaped += "&#10;"
                case "\r": escaped += "&#13;"
                case "\t": escaped += "&#9;"
                default: escaped.append(character)
                }
            } else {
                if inTag, character == "\"" || character == "'" { quote = character }
                if character == "<" { inTag = true }
                if character == ">" { inTag = false }
                escaped.append(character)
            }
            index = xml.index(after: index)
        }
        let collector = XMLCollector()
        let parser = XMLParser(data: Data(escaped.utf8))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse(), !collector.invalid, let content = collector.content else { throw DecodeError.invalidXML }
        return content
    }

    private final class XMLCollector: NSObject, XMLParserDelegate {
        var content: String?
        var invalid = false
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            guard depth <= 32 else { invalid = true; parser.abortParsing(); return }
            if name == "Lyric_1" {
                guard content == nil, attributes["LyricType"] == "1", let value = attributes["LyricContent"] else {
                    invalid = true; parser.abortParsing(); return
                }
                content = value
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
    }

    private static func convert(_ content: String) throws -> String {
        var output: [String] = []
        var lineCount = 0
        var wordCount = 0
        var hasText = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= 65_536 else { throw DecodeError.tooComplex }
            guard line.first == "[", let close = line.firstIndex(of: "]") else { throw DecodeError.invalidStructure }
            let header = line[line.index(after: line.startIndex)..<close]
            if header.lowercased().hasPrefix("offset:") {
                guard let offset = Int(header.dropFirst(7).trimmingCharacters(in: .whitespaces)),
                      (-maximumMilliseconds...maximumMilliseconds).contains(offset) else { throw DecodeError.invalidTiming }
                output.append("[offset:\(offset)]")
                continue
            }
            if header.contains(":") { continue }
            let fields = header.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2, let start = milliseconds(fields[0]), let duration = milliseconds(fields[1]),
                  start <= maximumMilliseconds - duration else { throw DecodeError.invalidTiming }
            lineCount += 1
            guard lineCount <= 10_000 else { throw DecodeError.tooComplex }
            let end = start + duration
            let body = String(line[line.index(after: close)...])
            let nsBody = body as NSString
            let matches = marker.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            wordCount += matches.count
            guard wordCount <= 50_000 else { throw DecodeError.tooComplex }
            var converted = "[\(format(start))]"
            if matches.isEmpty {
                try validateText(body)
                // 태그 뒤 공백은 LRC의 추가 태그 탐색만 끊고 화면 본문에서는 trim된다.
                // [후렴], [offset:500] 같은 실제 본문을 메타데이터로 소비하지 않는다.
                converted += " " + body
                if !body.trimmingCharacters(in: .whitespaces).isEmpty { hasText = true }
            } else {
                var previousTextEnd = 0
                var previousTimeEnd = start
                for match in matches {
                    guard let wordStart = milliseconds(nsBody.substring(with: match.range(at: 1))),
                          let wordDuration = milliseconds(nsBody.substring(with: match.range(at: 2))),
                          wordStart >= previousTimeEnd, wordStart <= end, wordDuration <= end - wordStart else { throw DecodeError.invalidTiming }
                    let text = nsBody.substring(with: NSRange(location: previousTextEnd, length: match.range.location - previousTextEnd))
                    try validateText(text)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { hasText = true }
                    converted += "<\(format(wordStart))>\(text)<\(format(wordStart + wordDuration))>"
                    previousTextEnd = NSMaxRange(match.range)
                    previousTimeEnd = wordStart + wordDuration
                }
                guard nsBody.substring(from: previousTextEnd).trimmingCharacters(in: .whitespaces).isEmpty else { throw DecodeError.invalidStructure }
            }
            output.append(converted + "<\(format(end))>")
        }
        guard hasText else { throw DecodeError.noLyrics }
        return output.joined(separator: "\n")
    }

    private static func validateText(_ text: String) throws {
        if text.range(of: #"\([-+]?\d+,"#, options: .regularExpression) != nil { throw DecodeError.invalidStructure }
        let nsText = text as NSString
        for tag in angleTag.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            if LRCParser.parseTime(nsText.substring(with: tag.range(at: 1))) != nil { throw DecodeError.ambiguousText }
        }
    }

    private static func milliseconds<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(text), value <= maximumMilliseconds else { return nil }
        return value
    }

    private static func format(_ ms: Int) -> String { String(format: "%02d:%02d.%03d", ms / 60_000, ms / 1_000 % 60, ms % 1_000) }
}

/// QQMusicDecoder의 DESHelper.cs 이식. 표준 DES와 S-box·키 배치·바이트 순서가 다르다.
/// Copyright (c) 2023 WXRIW — MIT (full notice in THIRD_PARTY_NOTICES.md).
enum QRCBlockCipher {
    private static let key = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)
    private static let schedules = [schedule(Array(key[16...]), decrypt: true), schedule(Array(key[8...]), decrypt: false), schedule(key, decrypt: true)]
    private static let initialLeft = [57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
    private static let initialRight = initialLeft.map { $0 - 1 }
    private static let permutation = [15,6,19,20,28,11,27,16,0,14,22,25,4,17,30,9,1,7,23,13,31,26,2,8,18,12,29,5,21,10,3,24]
    // S-box와 뒤 순열을 한 번만 합쳐 라운드마다 표 8회 조회로 처리한다.
    private static let substituted: [[UInt32]] = boxes.enumerated().map { box, values in
        (0..<64).map { six in
            let index = (six & 32) | ((six & 31) >> 1) | ((six & 1) << 4)
            let value = UInt32(values[index]) << (28 - box * 4)
            return permutation.enumerated().reduce(UInt32(0)) { $0 | ((value >> (31 - $1.element)) & 1) << (31 - $1.offset) }
        }
    }

    static func decrypt(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 8), bytes.count <= QRCLyrics.maximumFileBytes else { throw QRCLyrics.DecodeError.invalidCiphertext }
        var result = [UInt8](repeating: 0, count: bytes.count)
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            var left: UInt32 = 0
            var right: UInt32 = 0
            for index in 0..<32 {
                left |= byteBit(bytes, offset: offset, bit: initialLeft[index]) << (31 - index)
                right |= byteBit(bytes, offset: offset, bit: initialRight[index]) << (31 - index)
            }
            // 각 단계의 역 IP→IP는 항등 변환이므로 단계 사이 배열 할당을 생략한다.
            for keys in schedules {
                for round in 0..<15 {
                    (left, right) = (right, left ^ f(right, key: keys[round]))
                }
                left ^= f(right, key: keys[15])
            }
            for index in 0..<32 {
                let leftBit = initialLeft[index]
                let rightBit = initialRight[index]
                result[offset + leftBit / 32 * 4 + 3 - leftBit % 32 / 8] |= UInt8((left >> (31 - index)) & 1) << (7 - leftBit % 8)
                result[offset + rightBit / 32 * 4 + 3 - rightBit % 32 / 8] |= UInt8((right >> (31 - index)) & 1) << (7 - rightBit % 8)
            }
        }
        return result
    }

    private static func byteBit(_ bytes: [UInt8], offset: Int, bit: Int) -> UInt32 {
        UInt32((bytes[offset + bit / 32 * 4 + 3 - bit % 32 / 8] >> (7 - bit % 8)) & 1)
    }

    private static func f(_ state: UInt32, key: UInt64) -> UInt32 {
        var result = substituted[0][Int(((state & 1) << 5 | state >> 27) ^ UInt32(key >> 42 & 63))]
        for box in 1...6 {
            let six = (state >> (27 - box * 4)) & 63
            result |= substituted[box][Int(six ^ UInt32(key >> (42 - box * 6) & 63))]
        }
        return result | substituted[7][Int(((state & 31) << 1 | state >> 31) ^ UInt32(key & 63))]
    }

    private static func schedule(_ bytes: [UInt8], decrypt: Bool) -> [UInt64] {
        let shifts = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
        let pc = [56,48,40,32,24,16,8,0,57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35]
        let pd = [62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,60,52,44,36,28,20,12,4,27,19,11,3]
        let compression = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,40,51,30,36,46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31]
        var c: UInt32 = 0
        var d: UInt32 = 0
        for i in 0..<28 {
            c |= byteBit(bytes, offset: 0, bit: pc[i]) << (31 - i)
            d |= byteBit(bytes, offset: 0, bit: pd[i]) << (31 - i)
        }
        var keys = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            c = ((c << shifts[i]) | (c >> (28 - shifts[i]))) & 0xFFFFFFF0
            d = ((d << shifts[i]) | (d >> (28 - shifts[i]))) & 0xFFFFFFF0
            var key: UInt64 = 0
            for j in 0..<48 {
                // 원본의 -27을 표준 DES의 -28로 바꾸면 QRC를 복호화할 수 없다.
                let bit = j < 24 ? (c >> (31 - compression[j])) & 1 : (d >> (31 - (compression[j] - 27))) & 1
                key = key << 1 | UInt64(bit)
            }
            keys[decrypt ? 15 - i : i] = key
        }
        return keys
    }

    private static let boxes: [[UInt8]] = [
        [
            14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
            0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
            4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
            15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13
        ],
        [
            15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
            3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
            0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
            13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9
        ],
        [
            10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
            13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
            13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
            1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12
        ],
        [
            7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
            13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
            10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
            3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14
        ],
        [
            2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
            14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
            4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
            11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3
        ],
        [
            12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
            10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
            9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
            4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13
        ],
        [
            4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
            13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
            1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
            6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12
        ],
        [
            13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
            1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
            7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
            2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11
        ]
    ]
}

/// qmc-decode/src/qmc_crypto.c의 로컬 파일 XOR 이식.
/// Copyright (c) 2019 Jixun Wu — MIT (full notice in THIRD_PARTY_NOTICES.md).
enum QRCLocalMask {
    static func transform(_ bytes: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { index, byte in byte ^ mask[(index > 0x7FFF ? index % 0x7FFF : index) & 0x7F] }
    }

    private static let mask: [UInt8] = [
        0xc3, 0x4a, 0xd6, 0xca, 0x90, 0x67, 0xf7, 0x52, 0xd8, 0xa1, 0x66, 0x62, 0x9f, 0x5b, 0x09, 0x00,
        0xc3, 0x5e, 0x95, 0x23, 0x9f, 0x13, 0x11, 0x7e, 0xd8, 0x92, 0x3f, 0xbc, 0x90, 0xbb, 0x74, 0x0e,
        0xc3, 0x47, 0x74, 0x3d, 0x90, 0xaa, 0x3f, 0x51, 0xd8, 0xf4, 0x11, 0x84, 0x9f, 0xde, 0x95, 0x1d,
        0xc3, 0xc6, 0x09, 0xd5, 0x9f, 0xfa, 0x66, 0xf9, 0xd8, 0xf0, 0xf7, 0xa0, 0x90, 0xa1, 0xd6, 0xf3,
        0xc3, 0xf3, 0xd6, 0xa1, 0x90, 0xa0, 0xf7, 0xf0, 0xd8, 0xf9, 0x66, 0xfa, 0x9f, 0xd5, 0x09, 0xc6,
        0xc3, 0x1d, 0x95, 0xde, 0x9f, 0x84, 0x11, 0xf4, 0xd8, 0x51, 0x3f, 0xaa, 0x90, 0x3d, 0x74, 0x47,
        0xc3, 0x0e, 0x74, 0xbb, 0x90, 0xbc, 0x3f, 0x92, 0xd8, 0x7e, 0x11, 0x13, 0x9f, 0x23, 0x95, 0x5e,
        0xc3, 0x00, 0x09, 0x5b, 0x9f, 0x62, 0x66, 0xa1, 0xd8, 0x52, 0xf7, 0x67, 0x90, 0xca, 0xd6, 0x4a
    ]
}
