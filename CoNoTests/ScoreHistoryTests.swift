// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import Foundation
import Testing

struct ScoreArchiveTests {
    static func fixture() throws -> ScoreArchive {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try ScoreArchive.decode(Data(contentsOf: root.appendingPathComponent("docs/fixtures/score-v1.json")))
    }
    @Test func sharedSchemaRoundTripAndValidation() throws {
        let archive = try Self.fixture()
        #expect(try ScoreArchive.decode(archive.encoded()).records == archive.records)
        var record = try #require(archive.records.first)
        record.notesHit = record.notesTotal + 1
        #expect(throws: (any Error).self) { try record.validated() }
        record = archive.records[0]
        record.score = 101
        #expect(throws: (any Error).self) { try record.validated() }
        record = archive.records[0]
        record.createdAt = "2099-01-01T00:00:00Z"
        #expect(throws: (any Error).self) { try record.validated() }
        #expect(throws: (any Error).self) { try ScoreArchive(schemaVersion: 2, records: archive.records).encoded() }
        #expect(throws: (any Error).self) { try ScoreArchive(records: archive.records + archive.records).encoded() }
    }
    @Test @MainActor func persistenceImportAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scores.json")
        let archive = try Self.fixture()
        let history = ScoreHistory(fileURL: file)
        history.record(archive.records[0])
        #expect(history.errorMessage == nil)
        try history.importData(archive.encoded())
        #expect(history.records.count == 1) // 같은 결과를 두 번 세지 않는다
        let reopened = ScoreHistory(fileURL: file)
        #expect(reopened.records == history.records)
        #expect(try ScoreArchive.decode(reopened.exportData()).records == archive.records)
        try reopened.delete(id: archive.records[0].id)
        #expect(ScoreHistory(fileURL: file).records.isEmpty)
    }
    @Test @MainActor func corruptFilePreservesOriginalAndPendingResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scores.json")
        let original = Data("{ broken".utf8)
        try original.write(to: file)
        let history = ScoreHistory(fileURL: file)
        history.record(try Self.fixture().records[0])
        #expect(history.errorMessage != nil)
        #expect(history.pending.count == 1)
        #expect(try Data(contentsOf: file) == original)
        try ScoreArchive().encoded().write(to: file)
        history.retryPending()
        #expect(history.pending.isEmpty)
        #expect(history.records.count == 1)
    }
    @Test func conflictingImportIsAtomic() throws {
        var archive = try Self.fixture()
        let original = archive.records
        var conflict = original[0]
        conflict.score = 80
        #expect(throws: (any Error).self) { try archive.merge([conflict]) }
        #expect(archive.records == original)
    }
}
