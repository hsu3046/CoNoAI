// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import Foundation
import Observation

@MainActor
@Observable
final class ScoreHistory {
    private(set) var records: [ScoreRecord] = []
    private(set) var pending: [ScoreRecord] = []
    private var readError: String?
    private var pendingSaveError: String?
    var errorMessage: String? {
        readError ?? pendingSaveError ?? (pending.isEmpty ? nil : "아직 저장하지 못한 기록이 있어요. 다시 저장하거나 JSON으로 내보내 주세요.")
    }
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
        do {
            records = try read().records.sorted { $0.createdAt > $1.createdAt }
            readError = nil
        } catch { readError = error.localizedDescription }
    }

    /// 먼저 파일 쓰기가 성공해야 메모리도 갱신한다. 손상 파일은 빈 파일로 대체하지 않는다.
    private func write(_ archive: ScoreArchive) throws {
        let data = try archive.encoded()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        records = archive.records
        readError = nil
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
            pendingSaveError = nil
        } catch { pendingSaveError = error.localizedDescription }
    }

    func importData(_ data: Data) throws {
        let imported = try ScoreArchive.decode(data)
        var archive = try read()
        try archive.merge(imported.records)
        try archive.merge(pending)
        try write(archive)
        pending.removeAll()
        pendingSaveError = nil
    }

    func delete(id: String) throws {
        var archive = try read()
        archive.records.removeAll { $0.id == id }
        try write(archive)
        if !pending.isEmpty { retryPending() }
    }

    /// 저장 완료분만 백업한다. 미저장 기록 때문에 저장 한도를 넘겨 백업까지 막히지 않게 한다.
    func exportData() throws -> Data {
        try read().encoded()
    }

    /// 미저장 기록은 손상된 원본 파일을 읽거나 수정하지 않고 독립적으로 백업한다.
    /// 각각 다시 가져올 수 있도록 1,000곡·1 MB 한도에 맞춰 JSON을 나눈다.
    func exportPendingData() throws -> [Data] {
        var batches: [Data] = []
        func append(_ records: ArraySlice<ScoreRecord>) throws {
            guard !records.isEmpty else { return }
            if records.count <= 1000 {
                do {
                    batches.append(try ScoreArchive(records: Array(records)).encoded())
                    return
                } catch ScoreArchiveError.tooLarge {
                    guard records.count > 1 else { throw ScoreArchiveError.tooLarge }
                }
            }
            let middle = records.index(records.startIndex, offsetBy: records.count / 2)
            try append(records[..<middle])
            try append(records[middle...])
        }
        try append(pending[...])
        return batches
    }

    /// 미저장 항목을 버릴 때는 원본 파일이 손상됐어도 디스크를 건드리지 않는다.
    func discardPending(id: String) {
        pending.removeAll { $0.id == id }
        if pending.isEmpty { pendingSaveError = nil }
    }
}
