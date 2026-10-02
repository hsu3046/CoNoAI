// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import CryptoKit
import Foundation

/// 곡이 끝났을 때 보여줄 채점 결과. 앱에서 만든 기록의 메타데이터만 저장 형식에 맞춘다.
struct SingingResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let trackID: String?
    let title: String?
    let artist: String?
    let score: SongScore
    var keyShift: Int = 0
    var difficulty: String = "normal"
    var createdAt: String = ScoreRecord.timestamp()

    var record: ScoreRecord {
        ScoreRecord(
            id: id.uuidString.lowercased(), songId: songIdentifier,
            title: Self.displayText(title, fallback: "제목 없는 곡"), artist: Self.displayText(artist, fallback: ""),
            source: "macos", difficulty: difficulty, keyShift: keyShift, score: score.score,
            notesHit: score.notesHit, notesTotal: score.notesTotal, bestStreak: score.bestStreak, createdAt: createdAt
        )
    }

    private var songIdentifier: String {
        let original = ScoreRecord.songIdentifier(title: title, artist: artist, fallback: id)
        if original == "unknown:\(id.uuidString.lowercased())",
           let trackID = trackID?.trimmingCharacters(in: .whitespacesAndNewlines), !trackID.isEmpty {
            // 제목을 받지 못해도 원본 ID가 있으면 같은 곡이다. 개인 보관함 ID 자체는 공유하지 않는다.
            return "track-sha256:\(Self.digest(trackID))"
        }
        // 표시 제목을 자르기 전에 원본 전체로 키를 만든다. 같은 200자 접두사인 곡도 구분한다.
        return original.utf16.count <= 500 ? original : "song-sha256:\(Self.digest(original))"
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JSON의 UTF-16 한도를 지키되 surrogate·결합 문자·emoji 한 글자의 중간을 자르지 않는다.
    private static func displayText(_ text: String?, fallback: String) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var units = 0
        let prefix = trimmed.prefix { character in
            let count = String(character).utf16.count
            guard units + count <= 200 else { return false }
            units += count
            return true
        }
        let value = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}
