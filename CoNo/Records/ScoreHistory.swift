// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import Foundation
import Observation

@MainActor
@Observable
final class ScoreHistory {
    private(set) var records: [ScoreRecord] = []
    private(set) var pending: [ScoreRecord] = []
    private(set) var errorMessage: String?
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("space.knowai.cono", isDirectory: true).appendingPathComponent("scores.json")
        reload()
    }

    private func read() throws -> ScoreArchive {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ScoreArchive() }
        do {
            guard (try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw ScoreArchiveError.tooLarge }
            return try ScoreArchive.decode(Data(contentsOf: fileURL))
        }
        catch { throw ScoreArchiveError.unreadable }
    }

    func reload() {
        do { records = try read().records.sorted { $0.createdAt > $1.createdAt }; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    /// 먼저 파일 쓰기가 성공해야 메모리도 갱신한다. 손상 파일은 빈 파일로 대체하지 않는다.
    private func write(_ archive: ScoreArchive) throws {
        let data = try archive.encoded()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        records = archive.records
        errorMessage = nil
    }

    func record(_ score: ScoreRecord) {
        if !pending.contains(where: { $0.id == score.id }) { pending.append(score) }
        retryPending()
    }

    func retryPending() {
        do {
            var archive = try read()
            try archive.merge(pending)
            try write(archive)
            pending.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }

    func importData(_ data: Data) throws {
        let imported = try ScoreArchive.decode(data)
        var archive = try read()
        try archive.merge(imported.records)
        try archive.merge(pending)
        try write(archive)
        pending.removeAll()
    }

    func delete(id: String) throws {
        var archive = try read()
        archive.records.removeAll { $0.id == id }
        try write(archive)
        if !pending.isEmpty { retryPending() }
    }

    func exportData() throws -> Data {
        var archive = try read()
        try archive.merge(pending)
        return try archive.encoded()
    }
}
