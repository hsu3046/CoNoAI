// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct SingingResultTests {
    private static let score = SongScore(notesTotal: 10, notesHit: 8, creditSeconds: 8, totalSeconds: 10, streak: 2, bestStreak: 5)

    private static func result(title: String?, artist: String? = nil, trackID: String? = nil) -> SingingResult {
        SingingResult(trackID: trackID, title: title, artist: artist, score: score)
    }

    @Test func emptyMetadataUsesSchemaSafeFallbackWithoutChangingScore() throws {
        for title in [nil, "", " \n\t", "\u{00a0}"] as [String?] {
            let result = Self.result(title: title, artist: " \n ")
            let record = try result.record.validated()
            #expect(record.title == "제목 없는 곡")
            #expect(record.artist.isEmpty)
            #expect(record.songId == "unknown:\(result.id.uuidString.lowercased())")
            #expect(record.score == 80)
            #expect(record.notesHit == 8 && record.notesTotal == 10 && record.bestStreak == 5)
            #expect(result.record == result.record)
        }
    }

    @Test func displayBoundsPreserveNonBMPAndComposedCharacterBoundaries() throws {
        let family = "👨‍👩‍👧‍👦"
        let result = Self.result(title: String(repeating: "🎤", count: 101), artist: String(repeating: family, count: 19))
        let record = try result.record.validated()
        #expect(record.title == String(repeating: "🎤", count: 100))
        #expect(record.artist == String(repeating: family, count: 18))
        #expect(record.title.utf16.count == 200)
        #expect(record.artist.utf16.count == 198)
        #expect(!record.title.contains("\u{fffd}") && !record.artist.contains("\u{fffd}"))

        // 한 글자에 결합 문자가 너무 많아도 글자 중간을 잘라 손상시키지 않는다.
        let oversizedCharacter = "a" + String(repeating: "\u{0301}", count: 210)
        let fallback = try Self.result(title: oversizedCharacter, artist: oversizedCharacter).record.validated()
        #expect(fallback.title == "제목 없는 곡")
        #expect(fallback.artist.isEmpty)
    }

    @Test func longOriginalIdentityRemainsStableAndDistinctAfterDisplayTruncation() throws {
        let prefix = String(repeating: "가", count: 600)
        let first = Self.result(title: prefix + "첫 곡", artist: String(repeating: "수", count: 201)).record
        let second = Self.result(title: prefix + "다른 곡", artist: String(repeating: "수", count: 201)).record
        let repeated = Self.result(title: prefix + "첫 곡", artist: String(repeating: "수", count: 201)).record
        _ = try first.validated()
        _ = try second.validated()
        #expect(first.title == second.title)
        #expect(first.songId != second.songId)
        #expect(first.songId == repeated.songId)
        #expect(first.songId.utf16.count <= 500)

        // 표시 문자열은 짧아도 NFKC로 키가 길어지는 원본을 기준으로 검사한다.
        let expanded = Self.result(title: String(repeating: "㍍", count: 150)).record
        _ = try expanded.validated()
        #expect(expanded.title.utf16.count == 150)
        #expect(expanded.songId.utf16.count <= 500)
        #expect(Self.result(title: "  Ordinary Song ", artist: " Artist ").record.songId == "song:ordinary song|artist")
    }

    @Test func missingTitleUsesOriginalTrackIdentityBeforePerResultFallback() throws {
        let originalID = String(repeating: "source:🎤", count: 100)
        let first = Self.result(title: " ", trackID: originalID).record
        let repeated = Self.result(title: nil, trackID: originalID).record
        let different = Self.result(title: "", trackID: originalID + "other").record
        _ = try first.validated()
        #expect(first.songId == repeated.songId)
        #expect(first.songId != different.songId)
        #expect(first.songId.utf16.count <= 500)
        #expect(Self.result(title: nil).record.songId != Self.result(title: nil).record.songId)
    }

    @Test @MainActor func generatedMetadataCanBeSavedAndExportedEvenWhenStorageIsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scores.json")
        let records = [
            Self.result(title: "", artist: "").record,
            Self.result(title: String(repeating: "🎤", count: 300), artist: String(repeating: "가", count: 201)).record,
            Self.result(title: String(repeating: "㍍", count: 150)).record,
        ]
        let history = ScoreHistory(fileURL: file)
        for record in records { history.record(record) }
        #expect(history.pending.isEmpty)
        #expect(history.errorMessage == nil)
        let restored = try ScoreArchive.decode(history.exportData()).records
        #expect(Set(restored.map(\.id)) == Set(records.map(\.id)))
        for record in records { #expect(restored.contains(record)) }

        let corruptFile = directory.appendingPathComponent("corrupt.json")
        let original = Data("{ broken".utf8)
        try original.write(to: corruptFile)
        let unavailableHistory = ScoreHistory(fileURL: corruptFile)
        for record in records { unavailableHistory.record(record) }
        #expect(unavailableHistory.pending.count == records.count)
        let recovered = try unavailableHistory.exportPendingData().flatMap { try ScoreArchive.decode($0).records }
        #expect(recovered == records)
        #expect(try Data(contentsOf: corruptFile) == original)
    }

    @Test func importedRecordsStillRejectEmptyAndOversizedMetadata() throws {
        let valid = Self.result(title: "정상 곡").record
        let cases: [(WritableKeyPath<ScoreRecord, String>, String)] = [
            (\.title, " \n "), (\.title, String(repeating: "🎤", count: 101)),
            (\.artist, String(repeating: "가", count: 201)), (\.songId, String(repeating: "x", count: 501)),
        ]
        for (keyPath, value) in cases {
            var invalid = valid
            invalid[keyPath: keyPath] = value
            let data = try JSONEncoder().encode(ScoreArchive(records: [invalid]))
            #expect(throws: (any Error).self) { try ScoreArchive.decode(data) }
        }
    }
}
