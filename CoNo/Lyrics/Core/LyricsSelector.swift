// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// LRCLIB 후보 중 지금 곡에 맞는 가사 고르기.
// 실측에서 본 함정: 같은 곡에 한글 원문 대신 로마자 표기 항목이 섞여 있고(Hype Boy),
// 아티스트 표기가 달라 엉뚱한 곡이 걸린다 → 길이 일치 필수 + 싱크 우선 + 원문 문자 우선.

import Foundation

struct LyricsCandidate: Equatable, Sendable, Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    /// 초 (LRCLIB `duration`)
    let duration: Double?
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsSelector {
    /// 길이 차가 이보다 크면 다른 곡(다른 버전)으로 본다
    static let maxDurationDifference: Double = 3

    /// 가장 알맞은 후보. 곡 길이를 알면 길이가 맞는 후보만 고른다.
    static func best(_ candidates: [LyricsCandidate], targetDuration: Double?, targetArtist: String? = nil) -> LyricsCandidate? {
        let target = validDuration(targetDuration)
        return candidates
            .filter { candidate in
                guard !candidate.instrumental, candidate.syncedLyrics != nil || candidate.plainLyrics != nil else { return false }
                guard let target, let duration = candidate.duration else { return true }
                return abs(duration - target) <= maxDurationDifference
            }
            .max { score($0, targetDuration: target, targetArtist: targetArtist) < score($1, targetDuration: target, targetArtist: targetArtist) }
    }

    /// 싱크 가사 후보를 점수순으로 (제목·길이 일치, 중복 제거). 소리로 다시 고를 수 있게 여러 개를 남긴다.
    /// 제목 필터가 없으면 같은 앨범의 비슷한 길이 다른 곡이 섞인다 (First Love 검색에 "B&C -Album Edit-" 260.9초).
    static func rankedSynced(_ candidates: [LyricsCandidate], targetDuration: Double?, targetTitle: String?,
                             targetArtist: String? = nil, limit: Int = 5) -> [LyricsCandidate] {
        let target = validDuration(targetDuration)
        var seen = Set<String>()
        return candidates
            .filter { candidate in
                guard !candidate.instrumental, let synced = candidate.syncedLyrics, !synced.isEmpty else { return false }
                if let targetTitle, !titlesMatch(candidate.trackName, targetTitle) { return false }
                guard let target, let duration = candidate.duration else { return true }
                return abs(duration - target) <= maxDurationDifference
            }
            .sorted { score($0, targetDuration: target, targetArtist: targetArtist) > score($1, targetDuration: target, targetArtist: targetArtist) }
            .filter { seen.insert($0.syncedLyrics ?? "").inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// 플레이어가 길이를 못 줄 때 0 이 온다 → 0 을 목표로 삼으면 모든 후보가 걸러져 "못 찾음" 이 캐시된다
    private static func validDuration(_ duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// 제목 비교: 공백·문장부호·대소문자와 버전 표기를 무시하고, 괄호 안의 원제도 대체 제목으로 본다.
    ///   "First Love (Remastered 2014)" ≈ "First Love"   "Good day (좋은 날)" ≈ "좋은 날"
    ///   "B&C -Album Edit-" ≠ "First Love"   "(Remastered 2014)" 만 같은 두 곡은 다른 곡
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let x = titleVariants(a)
        let y = titleVariants(b)
        guard !x.isEmpty, !y.isEmpty else { return true } // 비교할 수 없으면 거르지 않는다
        for p in x {
            for q in y {
                if p == q { return true }
                let (shorter, longer) = p.count <= q.count ? (p, q) : (q, p)
                if shorter.count >= 3, longer.contains(shorter) { return true }
            }
        }
        return false
    }

    /// 버전 표기 단어 — 괄호 안이 이런 것뿐이면 대체 제목으로 쓰지 않는다
    private static let versionWords = ["remaster", "live", "version", "ver", "edit", "mix", "instrumental", "inst",
                                       "acoustic", "feat", "prod", "mono", "stereo", "demo", "radio", "karaoke", "off vocal"]

    /// 비교용 제목들: 버전 표기를 뺀 본제목 + 괄호 안 원제(버전 표기가 아닌 것)
    static func titleVariants(_ title: String) -> [String] {
        let lowered = title.lowercased()
        var variants: [String] = []
        let bracketPatterns = [#"\(([^)]*)\)"#, #"\[([^\]]*)\]"#, #"（([^）]*)）"#, #"「([^」]*)」"#]
        // 괄호 안 내용 → 대체 제목 (버전 표기 제외)
        for pattern in bracketPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(lowered.startIndex..., in: lowered)
            for match in regex.matches(in: lowered, range: range) {
                guard let inner = Range(match.range(at: 1), in: lowered) else { continue }
                let content = String(lowered[inner])
                if !versionWords.contains(where: content.contains) { variants.append(normalized(content)) }
            }
        }
        // 본제목: 괄호와 " -…-" / " - …" 꼬리를 뺀 나머지
        var main = lowered
        for pattern in bracketPatterns + [#"\s-[^-]+-\s*$"#, #"\s-\s.*$"#] {
            main = main.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        variants.insert(normalized(main), at: 0)
        return variants.filter { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func score(_ candidate: LyricsCandidate, targetDuration: Double?, targetArtist: String? = nil) -> Double {
        var score = 0.0
        if candidate.syncedLyrics != nil { score += 100 }
        if let target = validDuration(targetDuration), let duration = candidate.duration {
            score -= abs(duration - target) * 5
        }
        // 가수 일치 가점. 표기가 다를 수 있어("아이유"/"IU") 거르지는 않는다 — 제목만으로 찾은 다른 가수의 같은 제목 곡을 뒤로 민다.
        if let targetArtist, artistsMatch(candidate.artistName, targetArtist) { score += 15 }
        let text = candidate.syncedLyrics ?? candidate.plainLyrics ?? ""
        score += nativeScriptRatio(text) * 20
        // 원문 줄 + 번역 줄을 같은 시각에 겹쳐 둔 병기 가사는 뒤로 (원문 문자 가점을 번역이 받아 가는 것도 막는다)
        if let synced = candidate.syncedLyrics, LRCParser.sharedTimestampRatio(synced) >= 0.3 { score -= 40 }
        return score
    }

    /// 가수 비교: 공백·문장부호·대소문자 무시, 한쪽이 다른 쪽을 포함하면 같은 가수로 본다 ("IU" ⊂ "IU, SUGA").
    static func artistsMatch(_ a: String, _ b: String) -> Bool {
        let x = normalized(a.lowercased())
        let y = normalized(b.lowercased())
        guard !x.isEmpty, !y.isEmpty else { return false }
        let (shorter, longer) = x.count <= y.count ? (x, y) : (y, x)
        return longer.contains(shorter)
    }

    /// 글자 중 한글·가나·한자 비율 (로마자 표기 항목보다 원문 항목을 우선하기 위해)
    static func nativeScriptRatio(_ text: String) -> Double {
        var letters = 0
        var native = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F, // 한글
                 0x3040...0x30FF, // 히라가나·가타카나
                 0x4E00...0x9FFF: // 한자
                native += 1
            default:
                break
            }
        }
        return letters == 0 ? 0 : Double(native) / Double(letters)
    }
}
