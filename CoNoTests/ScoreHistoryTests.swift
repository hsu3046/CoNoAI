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

    @Test @MainActor func fullArchiveCanBeBackedUpWhilePendingFailureSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scores.json")
        let template = try #require(Self.fixture().records.first)
        let saved = (0..<1000).map { _ in
            var record = template
            record.id = UUID().uuidString.lowercased()
            return record
        }
        try ScoreArchive(records: saved).encoded().write(to: file)
        let history = ScoreHistory(fileURL: file)
        var newRecord = template
        newRecord.id = UUID().uuidString.lowercased()
        history.record(newRecord)
        #expect(history.pending == [newRecord])
        #expect(history.errorMessage != nil)

        history.reload()
        #expect(history.pending == [newRecord])
        #expect(history.errorMessage != nil) // 읽기 성공은 미저장 결과의 저장 성공이 아니다.
        #expect(try ScoreArchive.decode(history.exportData()).records == saved)
        let pendingFiles = try history.exportPendingData()
        #expect(pendingFiles.count == 1)
        #expect(try ScoreArchive.decode(pendingFiles[0]).records == [newRecord])

        try history.delete(id: saved[0].id)
        #expect(history.records.count == 1000)
        #expect(history.records.contains(newRecord))
        #expect(history.pending.isEmpty)
        #expect(history.errorMessage == nil)
    }

    @Test @MainActor func pendingBackupAndDeletionDoNotTouchCorruptOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scores.json")
        let original = Data("{ broken".utf8)
        try original.write(to: file)
        let history = ScoreHistory(fileURL: file)
        let record = try #require(Self.fixture().records.first)
        history.record(record)

        let pendingFiles = try history.exportPendingData()
        #expect(try ScoreArchive.decode(pendingFiles[0]).records == [record])
        history.discardPending(id: record.id)
        #expect(history.pending.isEmpty)
        #expect(history.errorMessage != nil) // 파일 손상 오류는 대기 기록과 별도로 유지한다.
        #expect(try Data(contentsOf: file) == original)
        #expect(try history.exportPendingData().isEmpty)
    }

    @Test @MainActor func pendingBackupSplitsIntoImportableArchives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scores.json")
        let original = Data("{ broken".utf8)
        try original.write(to: file)
        let template = try #require(Self.fixture().records.first)

        // 곡 수 한도와 JSON 바이트 한도를 각각 넘겨도 모든 대기 기록이 복원 가능해야 한다.
        for oversizedText in [false, true] {
            let history = ScoreHistory(fileURL: file)
            let count = oversizedText ? 220 : 1001
            for _ in 0..<count {
                var record = template
                record.id = UUID().uuidString.lowercased()
                if oversizedText {
                    record.songId = String(repeating: "\u{1}", count: 500)
                    record.title = String(repeating: "\u{1}", count: 200)
                    record.artist = String(repeating: "\u{1}", count: 200)
                }
                history.record(record)
            }
            let batches = try history.exportPendingData()
            #expect(batches.count > 1)
            let restored = try batches.flatMap { try ScoreArchive.decode($0).records }
            #expect(restored == history.pending)
            #expect(restored.count == count)
            #expect(try Data(contentsOf: file) == original)
        }
    }
}
