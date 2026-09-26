// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 브라우저 영상(YouTube 등)의 "지금 재생 중" 제목·가수를 노래 제목·가수로 다듬는다.
// 영상은 가수 칸에 채널명이, 제목 칸에 "가수 - 곡 (Official MV)" 가 오는 경우가 많다.
//   "中島美嘉 - 雪の華 / THE FIRST TAKE" · THE FIRST TAKE   → 雪の華 · 中島美嘉
//   "YOASOBI「アイドル」 Official Music Video" · Ayase / YOASOBI → アイドル · YOASOBI
//   "[MV] IU(아이유) _ Blueming(블루밍)" · 1theK (원더케이)     → Blueming(블루밍) · IU(아이유)
//   "Hype Boy" · NewJeans - Topic                                  → Hype Boy · NewJeans
// YouTube Music 처럼 이미 깔끔한 값은 그대로 둔다.

import Foundation

enum MediaTitleCleaner {
    /// 제목에서 떼어 낼 괄호 꼬리표에 들어가는 말 (소문자)
    private static let tagWords = [
        "official", "mv", "m/v", "music video", "video", "lyric", "lyrics", "audio", "visualizer", "live",
        "performance", "4k", "hd", "hq", "remaster", "teaser", "color coded", "special clip", "dance practice",
        "뮤직비디오", "공식", "가사", "라이브", "4k",
    ]
    /// "곡 - ○○" 의 ○○ 가 이런 말이면 가수·곡 구분이 아니라 버전 표기
    private static let versionWords = ["remaster", "version", "ver.", "edit", "mix", "live", "acoustic", "instrumental", "inst.", "demo", "mono", "stereo"]
    /// "/ 시리즈명" 처럼 뒤에 붙는 채널·기획 이름 (소문자)
    private static let seriesWords = ["the first take", "the home take", "first take", "dingo", "it's live", "killing voice", "studio choom"]

    static func clean(title rawTitle: String, artist rawArtist: String) -> (title: String, artist: String) {
        var title = rawTitle.trimmingCharacters(in: .whitespaces)
        let channel = cleanChannel(rawArtist)

        title = removeTags(title)

        // 뒤에 붙은 "/ 시리즈" · "| 시리즈" 제거 (채널명과 같거나 알려진 기획명일 때만)
        for separator in [" / ", " | ", " ｜ "] {
            guard let range = title.range(of: separator, options: .backwards) else { continue }
            let tail = title[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if tail == channel.lowercased() || tail == rawArtist.lowercased() || seriesWords.contains(where: tail.contains) {
                title = String(title[..<range.lowerBound])
            }
        }

        // 가수「곡」
        if let match = title.firstMatch(of: /^(.+?)\s*[「『](.+?)[」』]/) {
            return (String(match.2).trimmingCharacters(in: .whitespaces), String(match.1).trimmingCharacters(in: .whitespaces))
        }
        // 가수 - 곡 / 가수 _ 곡
        for separator in [" - ", " – ", " — ", " _ "] {
            if let range = title.range(of: separator) {
                let artist = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let song = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // "곡 - Remastered 2014" 같은 버전 표기는 가수·곡 구분이 아니다
                let songLower = song.lowercased()
                if versionWords.contains(where: songLower.contains) { break }
                if !artist.isEmpty, !song.isEmpty { return (song, artist) }
            }
        }
        return (title.trimmingCharacters(in: .whitespaces), channel)
    }

    /// 괄호 꼬리표 중 꼬리표 말이 든 것만 뺀다 ("(feat. X)" 나 "(좋은 날)" 같은 원제는 남긴다)
    private static func removeTags(_ text: String) -> String {
        var result = text
        let brackets: [(Character, Character)] = [("(", ")"), ("[", "]"), ("【", "】"), ("〔", "〕")]
        for (open, close) in brackets {
            var output = ""
            var index = result.startIndex
            while index < result.endIndex {
                if result[index] == open, let end = result[index...].firstIndex(of: close) {
                    let inner = result[result.index(after: index)..<end].lowercased()
                    if tagWords.contains(where: { inner.contains($0) }) {
                        index = result.index(after: end)
                        continue
                    }
                }
                output.append(result[index])
                index = result.index(after: index)
            }
            result = output
        }
        // 괄호 없이 끝에 붙은 "Official Music Video" 류
        result = result.replacingOccurrences(
            of: #"\s+(official\s+)?(music\s+video|m/?v|lyric\s+video|audio)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 채널명 → 가수: "- Topic", "VEVO", "Official" 등을 뗀다. "작곡가 / 가수" 는 뒤쪽.
    static func cleanChannel(_ channel: String) -> String {
        var name = channel.trimmingCharacters(in: .whitespaces)
        if let range = name.range(of: " / ", options: .backwards) {
            name = String(name[range.upperBound...])
        }
        for suffix in [" - Topic", "VEVO", " Official YouTube Channel", " Official Channel", " Official", " official"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
