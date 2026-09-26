// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 가사 소스: LRCLIB 외에 NetEase 云音乐(일본·한국·중국 곡이 많다) · AMLL TTML DB(커뮤니티가 손으로 만든 단어 싱크, CC0).
// 여기엔 네트워크 없는 순수 변환만 둔다 (NetEase 크레딧 줄 걸러내기, TTML → LRC, AMLL 색인 찾기).

import Foundation

enum LyricsSource: String, Codable, CaseIterable, Sendable {
    case lrclib
    case netease
    case amll

    var label: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .netease: "NetEase 云音乐"
        case .amll: "AMLL"
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
    /// TTML 의 줄(<p begin=…>)을 LRC 로. 배경 보컬·번역·발음 표기(ttm:role) 는 뺀다. 단어 시각은 지금은 쓰지 않는다 (#7).
    static func lrc(from ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let collector = LineCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), !collector.lines.isEmpty else { return nil }
        return collector.lines
            .map { "[\(format($0.begin))]\($0.text.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")
    }

    /// "1:02.345" · "00:01:02.345" · "62.345s" · "62.345"
    static func seconds(_ value: String) -> Double? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("s") { text.removeLast() }
        let parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let number = Double(part) else { return nil }
            total = total * 60 + number
        }
        return total
    }

    private static func format(_ seconds: Double) -> String {
        let centiseconds = Int((seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, (centiseconds / 100) % 60, centiseconds % 100)
    }

    private final class LineCollector: NSObject, XMLParserDelegate {
        var lines: [(begin: Double, text: String)] = []
        private var lineBegin: Double?
        private var text = ""
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
                text = ""
            } else if local == "span", attributes.contains(where: { $0.key.hasSuffix("role") }) {
                skipDepth = 1
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if skipDepth > 0 {
                skipDepth -= 1
                return
            }
            if local == "p", let begin = lineBegin {
                let line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append((begin, line)) }
                lineBegin = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0, lineBegin != nil else { return }
            text += string
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
