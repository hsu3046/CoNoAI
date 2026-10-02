// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import Foundation

/// 웹과 공유하는 v1 형식. 녹음·원곡 음원·음정 프레임은 저장하지 않는다.
struct ScoreRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var songId: String
    var title: String
    var artist: String
    var source: String
    var difficulty: String
    var keyShift: Int
    var score: Int
    var notesHit: Int
    var notesTotal: Int
    var bestStreak: Int
    var createdAt: String

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 플레이어의 개인 보관함 ID 대신 곡·가수 이름으로 교환 가능한 챌린지 키를 만든다.
    static func songIdentifier(title: String?, artist: String?, fallback: UUID) -> String {
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCompatibilityMapping.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard let title, !normalized(title).isEmpty else { return "unknown:\(fallback.uuidString.lowercased())" }
        return "song:\(normalized(title))|\(normalized(artist ?? ""))"
    }

    func validated() throws -> Self {
        guard UUID(uuidString: id) != nil,
              !songId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, songId.utf16.count <= 500,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 200, artist.utf16.count <= 200,
              ["macos", "browser", "demo"].contains(source), ["normal", "hard"].contains(difficulty),
              (-6...6).contains(keyShift), (0...100).contains(score), (1...50_000).contains(notesTotal),
              (0...notesTotal).contains(notesHit), (0...notesHit).contains(bestStreak),
              let date, date.timeIntervalSince1970 >= 1_577_836_800, date <= Date().addingTimeInterval(300)
        else { throw ScoreArchiveError.invalid }
        var value = self
        value.id = id.lowercased()
        value.songId = songId.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        value.createdAt = Self.timestamp(date)
        return value
    }

    var shareText: String {
        "🎤 CoNo · \(title)\(artist.isEmpty ? "" : " — \(artist)")\n\(score)점 · 음표 \(notesHit)/\(notesTotal) · 최고 연속 \(bestStreak)\n\(source == "macos" ? "Mac" : source == "demo" ? "데모" : "브라우저") · \(difficulty == "hard" ? "어려움" : "보통")"
    }
}

struct ScoreArchive: Codable, Sendable {
    var schemaVersion = 1
    var records: [ScoreRecord] = []

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw ScoreArchiveError.tooLarge }
        var archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.schemaVersion == 1, archive.records.count <= 1000 else { throw ScoreArchiveError.invalid }
        archive.records = try archive.records.map { try $0.validated() }
        guard Set(archive.records.map(\.id)).count == archive.records.count else { throw ScoreArchiveError.conflict }
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // 웹과 같은 1 MB 한도: 사람이 읽기 위한 공백이 백업 용량을 바꾸지 않게 한다.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        _ = try Self.decode(data)
        return data
    }

    mutating func merge(_ incoming: [ScoreRecord]) throws {
        var next = records
        for record in incoming {
            let value = try record.validated()
            if let existing = next.first(where: { $0.id == value.id }) {
                guard existing == value else { throw ScoreArchiveError.conflict }
            } else { next.append(value) }
        }
        guard next.count <= 1000 else { throw ScoreArchiveError.tooLarge }
        records = next.sorted { $0.createdAt > $1.createdAt }
    }
}

enum ScoreArchiveError: LocalizedError {
    case invalid, conflict, tooLarge, unreadable
    var errorDescription: String? {
        switch self {
        case .invalid: "CoNo 점수 JSON v1 형식과 점수·날짜를 확인해 주세요."
        case .conflict: "같은 ID의 다른 기록이 있어요. 기존 기록은 보존했습니다."
        case .tooLarge: "최대 1,000곡·1 MB까지 저장할 수 있어요. JSON으로 백업한 뒤 기록을 정리해 주세요."
        case .unreadable: "저장 파일을 읽지 못했어요. 원본은 보존했습니다. 파일 권한과 JSON을 확인해 주세요."
        }
    }
}
