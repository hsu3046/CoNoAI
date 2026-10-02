// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation

enum PersonalLyricsFormat: String, Codable, CaseIterable, Sendable {
    case plain = "txt", synced = "lrc"
    var label: String { self == .plain ? "일반 가사" : "시간 있는 가사 (LRC)" }
}

struct PersonalLyricsInput: Codable, Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    /// 비어 있으면 길이 미지정. 가사 시각을 임의로 추정하지 않는다.
    var duration: Double?
    var format: PersonalLyricsFormat = .plain
    var contents = ""

    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        result.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty, !result.artist.isEmpty,
              [result.title, result.artist, result.album].allSatisfy({ $0.count <= 500 }),
              duration.map({ $0.isFinite && $0 > 0 && $0 <= 86_400 }) ?? true else { throw PersonalLyricsError.invalidMetadata }
        _ = try LocalLyricsStore.parse(contents, format: format.rawValue)
        return result
    }

    var plainLyrics: String {
        format == .plain ? contents : LRCParser.parse(contents).lines.filter { !$0.isInterlude }.map(\.text).joined(separator: "\n")
    }
}

struct PersonalLyricsDocument: Codable, Identifiable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let revision: UUID
    let createdAt: Date
    let updatedAt: Date
    let lyrics: PersonalLyricsInput

    var track: TrackInfo {
        TrackInfo(id: "personal:\(id.uuidString)", title: lyrics.title, artist: lyrics.artist, album: lyrics.album,
                  duration: lyrics.duration ?? 0, durationIsReliable: lyrics.duration != nil)
    }
}

enum PersonalLyricsError: LocalizedError {
    case invalidMetadata, invalidStore, conflict, missing, tooMany
    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "곡 제목·가수를 입력하고 곡 길이를 확인해 주세요. 길이는 비워 두거나 0초 초과·24시간 이하로 입력할 수 있습니다."
        case .invalidStore: "이 보관함 파일을 읽지 못했어요. 손상된 원본은 보존했습니다. 보관함 폴더에서 확인해 주세요."
        case .conflict: "다른 창에서 이 가사를 변경했어요. 현재 입력은 보존했습니다. 새 사본으로 저장하거나 닫은 뒤 다시 열어 주세요."
        case .missing: "이 가사가 보관함에서 삭제되었어요. 현재 입력을 새 사본으로 저장할 수 있습니다."
        case .tooMany: "보관함 한도에 도달했어요. 최대 500개·총 64 MB까지 보관합니다. 기존 가사를 내보낸 뒤 정리해 주세요."
        }
    }
}

struct PersonalLyricsListing: Sendable {
    let documents: [PersonalLyricsDocument]
    let issues: [String]
}

/// 저장 응답이 돌아와도 그 사이 편집한 입력을 덮어쓰거나 저장 완료로 표시하지 않는다.
struct PersonalLyricsEditingState: Equatable {
    var input: PersonalLyricsInput
    private(set) var saved: PersonalLyricsDocument?
    private let initial: PersonalLyricsInput
    init(document: PersonalLyricsDocument? = nil, input: PersonalLyricsInput = PersonalLyricsInput()) {
        self.input = document?.lyrics ?? input
        self.initial = self.input
        saved = document
    }
    var isDirty: Bool { saved.map { input != $0.lyrics } ?? (input != initial || !input.contents.isEmpty || !input.title.isEmpty) }
    mutating func didSave(_ document: PersonalLyricsDocument, snapshot: PersonalLyricsInput) {
        saved = document
        if input == snapshot { input = document.lyrics }
    }
}

actor PersonalLyricsStore {
    static let shared = PersonalLyricsStore()
    nonisolated let directoryURL: URL
    private static let maximumDocumentBytes = 2_097_152
    private static let maximumTotalBytes = 67_108_864
    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("space.knowai.cono/personal-lyrics", isDirectory: true)
    }

    func list() throws -> PersonalLyricsListing {
        let files = try ownedFiles()
        var documents: [PersonalLyricsDocument] = []
        var issues: [String] = []
        var total = 0
        for file in files {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                total += size
                guard documents.count < 500, total <= Self.maximumTotalBytes else { throw PersonalLyricsError.tooMany }
                let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)!
                documents.append(try read(id))
            } catch { issues.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return PersonalLyricsListing(documents: documents.sorted { $0.updatedAt > $1.updatedAt }, issues: issues)
    }

    func save(_ input: PersonalLyricsInput, id: UUID? = nil, expectedRevision: UUID? = nil) throws -> PersonalLyricsDocument {
        let validated = try input.validated()
        let id = id ?? UUID()
        let url = fileURL(id)
        let previous: PersonalLyricsDocument?
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try read(id)
            guard expectedRevision == old.revision else { throw PersonalLyricsError.conflict }
            previous = old
        } else {
            guard expectedRevision == nil else { throw PersonalLyricsError.missing }
            previous = nil
        }
        let now = Date()
        let document = PersonalLyricsDocument(schemaVersion: 1, id: id, revision: UUID(), createdAt: previous?.createdAt ?? now,
                                              updatedAt: now, lyrics: validated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else { throw LocalLyricsError.tooLarge }
        let files = try ownedFiles()
        guard previous != nil || files.count < 500 else { throw PersonalLyricsError.tooMany }
        var total = data.count
        for file in files where file != url { total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        guard total <= Self.maximumTotalBytes else { throw PersonalLyricsError.tooMany }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return document
    }

    func remove(_ document: PersonalLyricsDocument) throws {
        let current = try read(document.id)
        guard current.revision == document.revision else { throw PersonalLyricsError.conflict }
        try FileManager.default.removeItem(at: fileURL(document.id))
    }

    func importedInput(at url: URL) throws -> PersonalLyricsInput {
        guard url.isFileURL, let format = PersonalLyricsFormat(rawValue: url.pathExtension.lowercased()) else { throw LocalLyricsError.unsupportedFile }
        let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attrs.isRegularFile == true else { throw LocalLyricsError.unsupportedFile }
        guard (attrs.fileSize ?? 0) <= 1_048_576 else { throw LocalLyricsError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw LocalLyricsError.tooLarge }
        let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? .utf16 : .utf8
        guard var contents = String(data: data, encoding: encoding) else { throw LocalLyricsError.invalidEncoding }
        if contents.first == "\u{feff}" { contents.removeFirst() }
        // 가져오기는 편집 초안을 만든다. 가수는 사용자가 입력하며 저장할 때 필수 검증한다.
        _ = try LocalLyricsStore.parse(contents, format: format.rawValue)
        return PersonalLyricsInput(title: url.deletingPathExtension().lastPathComponent, format: format, contents: contents)
    }

    private func read(_ id: UUID) throws -> PersonalLyricsDocument {
        let file = fileURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw PersonalLyricsError.missing }
        do {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  (attributes.fileSize ?? 0) <= Self.maximumDocumentBytes else { throw PersonalLyricsError.invalidStore }
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumDocumentBytes else { throw PersonalLyricsError.invalidStore }
            let document = try JSONDecoder().decode(PersonalLyricsDocument.self, from: data)
            guard document.schemaVersion == 1, document.id == id,
                  document.createdAt.timeIntervalSince1970.isFinite, document.updatedAt.timeIntervalSince1970.isFinite,
                  try document.lyrics.validated() == document.lyrics else { throw PersonalLyricsError.invalidStore }
            return document
        } catch { throw PersonalLyricsError.invalidStore }
    }

    private func ownedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func fileURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent(id.uuidString + ".json") }
}
