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
    static func best(_ candidates: [LyricsCandidate], targetDuration: Double?) -> LyricsCandidate? {
        candidates
            .filter { candidate in
                guard !candidate.instrumental, candidate.syncedLyrics != nil || candidate.plainLyrics != nil else { return false }
                guard let target = targetDuration, let duration = candidate.duration else { return true }
                return abs(duration - target) <= maxDurationDifference
            }
            .max { score($0, targetDuration: targetDuration) < score($1, targetDuration: targetDuration) }
    }

    static func score(_ candidate: LyricsCandidate, targetDuration: Double?) -> Double {
        var score = 0.0
        if candidate.syncedLyrics != nil { score += 100 }
        if let target = targetDuration, let duration = candidate.duration {
            score -= abs(duration - target) * 5
        }
        let text = candidate.syncedLyrics ?? candidate.plainLyrics ?? ""
        score += nativeScriptRatio(text) * 20
        return score
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
