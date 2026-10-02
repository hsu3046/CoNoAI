// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 가사 소스: LRCLIB 외에 NetEase 云音乐(일본·한국·중국 곡이 많다) · AMLL TTML DB(커뮤니티가 손으로 만든 단어 싱크, CC0).
// 여기엔 네트워크 없는 순수 변환만 둔다 (NetEase 크레딧 줄 걸러내기, TTML → LRC, AMLL 색인 찾기).

import Foundation

enum LyricsSource: String, Codable, CaseIterable, Sendable {
    case lrclib
    case netease
    case amll
    case appleMusic
    case localFile

    var label: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .netease: "NetEase 云音乐"
        case .amll: "AMLL"
        case .appleMusic: "Apple Music"
        case .localFile: "내 가사 파일"
        }
    }

    /// 후보 점수 가산: 공식 음절 싱크(Apple Music)·사람이 맞춘 단어 싱크(AMLL) 를 조금 앞에.
    /// 최종 선택은 여전히 보컬과 대 본 자동 싱크가 한다.
    var trustBonus: Double {
        switch self {
        case .appleMusic: 12
        case .amll: 8
        case .lrclib, .netease, .localFile: 0
        }
    }
}

extension LyricsCandidate {
    /// 출처 (LRCLIB 응답에는 없어서 nil = LRCLIB)
    var origin: LyricsSource { source ?? .lrclib }
    /// 소스를 넘나들어 겹치지 않는 식별자 ("netease:625096") — 곡별로 기억한 싱크가 가리키는 값
    var key: String { "\(origin.rawValue):\(id)" }
}

// MARK: - NetEase

enum NetEaseLyrics {
    /// 줄 앞 크레딧 ("作词 : …", "Composer : …") — 곡 앞 몇 초에 가사처럼 들어 있어 자동 싱크를 헷갈리게 한다
    private static let creditPattern = #"^\s*(作词|作詞|作曲|编曲|編曲|制作人|製作人|监制|混音|录音|和声|吉他|贝斯|鼓|弦乐|词|曲|lyricist|lyrics|composer|arranger|producer|written by)\s*[:：]"#

    /// LRC 에서 크레딧 줄과 JSON 크레딧 줄({"t":0,"c":[…]})을 뺀다. 가사 줄이 없으면 nil (순수 음악 등).
    static func cleaned(_ lrc: String) -> String? {
        var kept: [String] = []
        var lyricLines = 0
        for line in lrc.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue } // JSON 크레딧·빈 줄
            let text = trimmed.replacingOccurrences(of: #"^(\[[^\]]*\])+"#, with: "", options: .regularExpression)
            if text.range(of: creditPattern, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if text.contains("纯音乐") { return nil } // "纯音乐，请欣赏" = 가사 없는 곡
            kept.append(trimmed)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, LRCParser.parseTime(trimmed.dropFirst().prefix { $0 != "]" }) != nil {
                lyricLines += 1
            }
        }
        return lyricLines >= 3 ? kept.joined(separator: "\n") : nil
    }
}

// MARK: - TTML (AMLL · Apple Music 형식)

enum TTMLLyrics {
    /// 단어/음절 span의 begin·end를 enhanced LRC로 보존한다. 배경 보컬·번역·발음 표기는 뺀다.
    /// 단어 시각이 없거나 순서가 잘못된 줄만 일반 LRC로 내려 기존 보컬 기반 추정을 쓴다.
    static func lrc(from ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let collector = LineCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !collector.lines.isEmpty else { return nil }
        return collector.lines
            .joined(separator: "\n")
    }

    /// "1:02.345" · "00:01:02.345" · "62.345s" · "62.345"
    static func seconds(_ value: String) -> Double? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("ms") {
            text.removeLast(2)
            guard let milliseconds = Double(text), milliseconds.isFinite, milliseconds >= 0,
                  milliseconds <= 86_400_000 else { return nil }
            return milliseconds / 1000
        }
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0,
                  index == 0 || number < 60 else { return nil }
            total = total * 60 + number
        }
        return total <= 86_400 ? total : nil
    }

    private static func format(_ seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
    }

    private final class LineCollector: NSObject, XMLParserDelegate {
        struct Timing: Equatable {
            var begin: Double?
            var end: Double?
        }
        struct Piece {
            var text: String
            let timing: Timing
        }
        var lines: [String] = []
        private var lineBegin: Double?
        private var lineEnd: Double?
        private var pieces: [Piece] = []
        private var spanTimings: [Timing] = []
        private var invalidTiming = false
        /// 지금 건너뛰는 중인 요소 깊이 (배경 보컬·번역 span)
        private var skipDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if skipDepth > 0 {
                skipDepth += 1
                return
            }
            if local == "p" {
                lineBegin = attributes["begin"].flatMap(TTMLLyrics.seconds)
                lineEnd = attributes["end"].flatMap(TTMLLyrics.seconds)
                pieces = []
                spanTimings = []
                invalidTiming = false
            } else if local == "span", lineBegin != nil {
                let ignoredRoles: Set<String> = ["x-bg", "x-translation", "x-roman", "x-romanization", "translation"]
                if attributes.contains(where: { $0.key.split(separator: ":").last == "role" && ignoredRoles.contains($0.value) }) {
                    skipDepth = 1
                    return
                }
                var timing = spanTimings.last ?? Timing()
                if let begin = attributes["begin"] {
                    timing.begin = TTMLLyrics.seconds(begin)
                    if timing.begin == nil { invalidTiming = true }
                }
                if let end = attributes["end"] {
                    timing.end = TTMLLyrics.seconds(end)
                    if timing.end == nil { invalidTiming = true }
                }
                spanTimings.append(timing)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            if local == "span", !spanTimings.isEmpty {
                spanTimings.removeLast()
            } else if local == "p", let begin = lineBegin {
                if let line = enhancedLine(begin: begin) { lines.append(line) }
                lineBegin = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0, lineBegin != nil else { return }
            let timing = spanTimings.last ?? Timing()
            if pieces.last?.timing == timing {
                pieces[pieces.count - 1].text += string
            } else {
                pieces.append(Piece(text: string, timing: timing))
            }
        }

        private func enhancedLine(begin: Double) -> String? {
            // XMLParser가 글자를 임의로 나누므로 요소 사이까지 이어서 공백을 정규화한다.
            var previousWasSpace = false
            let normalized = pieces.map { piece -> Piece in
                var text = ""
                for character in piece.text {
                    if character.isWhitespace {
                        if !previousWasSpace { text.append(" ") }
                        previousWasSpace = true
                    } else {
                        text.append(character)
                        previousWasSpace = false
                    }
                }
                return Piece(text: text, timing: piece.timing)
            }
            let plain = normalized.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { return nil }
            let prefix = "[\(TTMLLyrics.format(begin))]"
            let sung = normalized.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            var previousEnd = begin
            let valid = !invalidTiming && sung.allSatisfy { piece in
                guard let start = piece.timing.begin, start >= previousEnd,
                      piece.timing.end.map({ $0 >= start }) ?? true,
                      lineEnd.map({ (piece.timing.end ?? start) <= $0 }) ?? true else { return false }
                previousEnd = piece.timing.end ?? start
                return true
            }
            guard valid else {
                // 단어 시각을 추정해야 하는 줄도 원본의 명시적인 줄 종료는 유지한다.
                let endTag = lineEnd.flatMap { $0 >= begin ? "<\(TTMLLyrics.format($0))>" : nil } ?? ""
                return prefix + plain + endTag
            }

            var content = ""
            for piece in normalized {
                guard !piece.text.trimmingCharacters(in: .whitespaces).isEmpty,
                      let start = piece.timing.begin else { content += piece.text; continue }
                content += "<\(TTMLLyrics.format(start))>\(piece.text)"
                if let end = piece.timing.end { content += "<\(TTMLLyrics.format(end))>" }
            }
            // 마지막 단어가 먼저 끝나도 문장 끝까지 표시한다. 두 종료 태그 사이에는
            // 글자가 없으므로 단어의 길이는 유지되고 LRCParser가 마지막 태그를 줄 끝으로 쓴다.
            if let end = lineEnd, end >= previousEnd {
                content += "<\(TTMLLyrics.format(end))>"
            }
            return prefix + content
        }
    }
}

// MARK: - AMLL 색인

struct AMLLEntry: Equatable, Sendable {
    let titles: [String]
    let artists: [String]
    let neteaseIDs: [String]
    /// raw-lyrics/ 안의 TTML 파일 이름
    let file: String

    /// 소스를 넘나드는 후보 번호 (파일 이름에서 안정적으로 만든다)
    var candidateID: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in file.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(truncatingIfNeeded: hash & 0x7fff_ffff_ffff)
    }
}

enum AMLLIndex {
    /// metadata/raw-lyrics-index.jsonl — 한 줄 = {"metadata":[["musicName",[…]],["artists",[…]],…],"rawLyricFile":"….ttml"}
    static func parse(_ jsonl: String) -> [AMLLEntry] {
        var entries: [AMLLEntry] = []
        for line in jsonl.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let file = object["rawLyricFile"] as? String,
                  let metadata = object["metadata"] as? [[Any]]
            else { continue }
            var fields: [String: [String]] = [:]
            for pair in metadata where pair.count == 2 {
                if let key = pair[0] as? String, let values = pair[1] as? [String] { fields[key] = values }
            }
            guard let titles = fields["musicName"], !titles.isEmpty else { continue }
            entries.append(AMLLEntry(titles: titles, artists: fields["artists"] ?? [], neteaseIDs: fields["ncmMusicId"] ?? [], file: file))
        }
        return entries
    }

    /// 이 곡의 항목: NetEase 곡 번호가 같거나, 제목과 가수가 모두 맞는 것 (길이 정보가 없어 가수까지 맞아야 한다).
    /// 같은 곡을 여러 사람이 만든 경우가 있어 뒤쪽(나중에 올린 것)을 먼저.
    static func matches(_ entries: [AMLLEntry], title: String, artist: String, neteaseIDs: [String] = []) -> [AMLLEntry] {
        let ids = Set(neteaseIDs)
        return entries.reversed().filter { entry in
            if !ids.isEmpty, entry.neteaseIDs.contains(where: ids.contains) { return true }
            return entry.titles.contains { LyricsSelector.titlesMatch($0, title) }
                && entry.artists.contains { LyricsSelector.artistsMatch($0, artist) }
        }
    }
}
