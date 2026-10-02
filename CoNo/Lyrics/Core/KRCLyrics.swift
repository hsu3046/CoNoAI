// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 사용자가 선택한 로컬 KRC 파일을 enhanced LRC로 변환한다. 네트워크·계정 토큰은 사용하지 않는다.
// 형식 참고: LyricsKit KugouKrcDecrypter/Parser (MPL-2.0), lyrimuse kugou.go (GPL-3.0).
// 외부 구현/패키지를 포함하지 않고 macOS의 zlib로 새로 구현했다.

import Foundation
import zlib

enum KRCLyrics {
    static let maximumFileBytes = 1_048_576
    static let maximumExpandedBytes = 2_097_152
    private static let maximumMilliseconds = 86_400_000
    private static let maximumLines = 10_000
    private static let maximumSegments = 50_000
    private static let maximumLineBytes = 65_536
    /// KRC 형식의 고정 XOR 마스크. 서비스 인증 키가 아니다.
    private static let xorMask: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69]
    private static let marker = try! NSRegularExpression(pattern: #"<(\d+),(\d+),(\d+)>"#)
    private static let angleTag = try! NSRegularExpression(pattern: #"<([^<>]*)>"#)

    enum DecodeError: LocalizedError, Equatable {
        case fileTooLarge
        case invalidHeader
        case invalidCompression
        case expandedTooLarge
        case invalidUTF8
        case invalidStructure
        case invalidTiming
        case tooComplex
        case ambiguousText
        case noLyrics

        var errorDescription: String? {
            switch self {
            case .fileTooLarge: "KRC 파일은 1MB까지 가져올 수 있습니다."
            case .invalidHeader: "KRC 파일의 시작 표시(krc1)가 올바르지 않습니다."
            case .invalidCompression: "KRC 파일이 손상되어 압축을 풀 수 없습니다."
            case .expandedTooLarge: "압축을 푼 KRC 가사가 2MB를 넘습니다."
            case .invalidUTF8: "KRC 가사의 문자 인코딩을 읽을 수 없습니다."
            case .invalidStructure: "KRC 가사의 줄 또는 단어 표시가 올바르지 않습니다."
            case .invalidTiming: "KRC 가사에 순서가 맞지 않거나 범위를 벗어난 시각이 있습니다."
            case .tooComplex: "KRC 가사의 줄 또는 단어 수가 지원 범위를 넘습니다."
            case .ambiguousText: "KRC 본문에 가사 시각 태그와 구분할 수 없는 문자가 있습니다."
            case .noLyrics: "KRC 파일에 표시할 가사가 없습니다."
            }
        }
    }

    /// raw .krc 바이너리(krc1 + XOR + zlib)를 기존 LRCParser가 읽는 문자열로 변환한다.
    static func enhancedLRC(from data: Data) throws -> String {
        guard data.count <= maximumFileBytes else { throw DecodeError.fileTooLarge }
        guard data.count > 4, data.prefix(4).elementsEqual([0x6B, 0x72, 0x63, 0x31]) else {
            throw DecodeError.invalidHeader
        }
        let compressed = data.dropFirst(4).enumerated().map { index, byte in byte ^ xorMask[index % xorMask.count] }
        var expanded = [UInt8](repeating: 0, count: maximumExpandedBytes + 1)
        var expandedSize = uLongf(expanded.count)
        var consumedSize = uLong(compressed.count)
        let status = expanded.withUnsafeMutableBufferPointer { destination in
            compressed.withUnsafeBufferPointer { source in
                uncompress2(destination.baseAddress!, &expandedSize, source.baseAddress!, &consumedSize)
            }
        }
        if status == Z_BUF_ERROR || expandedSize > maximumExpandedBytes { throw DecodeError.expandedTooLarge }
        guard status == Z_OK, consumedSize == compressed.count else { throw DecodeError.invalidCompression }
        guard var plain = String(bytes: expanded.prefix(Int(expandedSize)), encoding: .utf8) else {
            throw DecodeError.invalidUTF8
        }
        if plain.first == "\u{FEFF}" { plain.removeFirst() }
        return try parse(plain)
    }

    private static func parse(_ plain: String) throws -> String {
        var output: [String] = []
        var totalSegments = 0
        var timedLineCount = 0
        var hasText = false
        for rawLine in plain.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= maximumLineBytes else { throw DecodeError.tooComplex }
            guard line.first == "[", let close = line.firstIndex(of: "]") else { throw DecodeError.invalidStructure }
            let header = line[line.index(after: line.startIndex)..<close]
            if header.lowercased().hasPrefix("offset:") {
                guard let milliseconds = Int(header.dropFirst(7).trimmingCharacters(in: .whitespaces)),
                      (-maximumMilliseconds...maximumMilliseconds).contains(milliseconds) else { throw DecodeError.invalidTiming }
                output.append("[offset:\(milliseconds)]")
                continue
            }
            // 제목·가수·번역/발음(language) 메타데이터는 본문이 아니다.
            if header.contains(":") { continue }
            let fields = header.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let start = boundedMilliseconds(fields[0]), let duration = boundedMilliseconds(fields[1]),
                  start <= maximumMilliseconds - duration else { throw DecodeError.invalidTiming }
            let end = start + duration
            timedLineCount += 1
            guard timedLineCount <= maximumLines else { throw DecodeError.tooComplex }
            let body = String(line[line.index(after: close)...])
            let nsBody = body as NSString
            let matches = marker.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
            totalSegments += matches.count
            guard totalSegments <= maximumSegments else { throw DecodeError.tooComplex }
            if matches.isEmpty {
                guard body.trimmingCharacters(in: .whitespaces).isEmpty else { throw DecodeError.invalidStructure }
                output.append("[\(format(start))]<\(format(end))>")
                continue
            }
            let prefix = nsBody.substring(to: matches[0].range.location)
            guard prefix.trimmingCharacters(in: .whitespaces).isEmpty else { throw DecodeError.invalidStructure }
            var converted = "[\(format(start))]"
            var previousEnd = start
            for (index, match) in matches.enumerated() {
                guard let relativeStart = boundedMilliseconds(nsBody.substring(with: match.range(at: 1))),
                      let wordDuration = boundedMilliseconds(nsBody.substring(with: match.range(at: 2))),
                      relativeStart <= duration, wordDuration <= duration - relativeStart else { throw DecodeError.invalidTiming }
                let wordStart = start + relativeStart
                let wordEnd = wordStart + wordDuration
                guard wordStart >= previousEnd else { throw DecodeError.invalidTiming }
                previousEnd = wordEnd
                let textStart = NSMaxRange(match.range)
                let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsBody.length
                let text = nsBody.substring(with: NSRange(location: textStart, length: textEnd - textStart))
                // 잘못된 KRC 마커를 본문으로 표시하거나 LRC 태그로 재해석해 글자를 잃지 않는다.
                if text.range(of: #"<[-+]?\d+,"#, options: .regularExpression) != nil { throw DecodeError.invalidStructure }
                // LRCParser가 허용하는 공백·콜론 소수 등도 동일하게 검사한다.
                // 별도 정규식으로 검사하면 < 00:05 > 같은 본문이 나중에 시각으로 사라진다.
                let nsText = text as NSString
                for tag in angleTag.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                    if LRCParser.parseTime(nsText.substring(with: tag.range(at: 1))) != nil {
                        throw DecodeError.ambiguousText
                    }
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { hasText = true }
                converted += "<\(format(wordStart))>\(text)<\(format(wordEnd))>"
            }
            converted += "<\(format(end))>"
            output.append(converted)
        }
        guard hasText else { throw DecodeError.noLyrics }
        return output.joined(separator: "\n")
    }

    private static func boundedMilliseconds<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), value <= maximumMilliseconds else { return nil }
        return value
    }

    private static func format(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d.%03d", milliseconds / 60_000, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }
}
