// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import CryptoKit
import Foundation

enum LocalLyricsError: LocalizedError {
    case unsupportedFile, invalidEncoding, tooLarge, noTimedLyrics, noLyrics, invalidStore

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "TXT·LRC·TTML·SRT·KRC·QRC 가사 파일 하나를 선택해 주세요."
        case .invalidEncoding: "가사 파일을 읽지 못했어요. UTF-8 또는 UTF-16 형식으로 저장해 주세요."
        case .tooLarge: "가사는 1 MB, 4,000줄 이하이고 한 줄은 500글자 이하여야 해요."
        case .noTimedLyrics: "시간 정보가 있는 가사를 찾지 못했어요. 파일의 가사 형식을 확인해 주세요."
        case .noLyrics: "가사 내용을 입력해 주세요."
        case .invalidStore: "저장된 가사 파일을 읽지 못했어요. 원본은 보존했습니다. 가사 폴더에서 확인해 주세요."
        }
    }
}

struct LocalLyricsDocument: Codable, Sendable {
    let schemaVersion: Int
    let trackID: String
    let title: String
    let artist: String
    let fileName: String
    let format: String
    let contents: String
}

struct LoadedLocalLyrics: Sendable {
    let document: LocalLyricsDocument
    let lyrics: TimedLyrics

    var isSynced: Bool { document.format != "txt" }
    var plainLyrics: String { isSynced ? lyrics.lines.filter { !$0.isInterlude }.map(\.text).joined(separator: "\n") : document.contents }
    var lineCount: Int { isSynced ? lyrics.lines.filter { !$0.isInterlude }.count : document.contents.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    var preciseLineCount: Int { lyrics.lines.filter { !$0.segments.isEmpty }.count }
}

/// 사용자가 고른 가사는 캐시가 아닌 Application Support에 원본과 함께 곡별로 저장한다.
/// 파일 읽기·파싱·원자적 쓰기는 actor에서 실행해 재생/UI 스레드와 분리한다.
actor LocalLyricsStore {
    nonisolated let directoryURL: URL
    private static let maximumInputBytes = 1_048_576
    private static let maximumStoredBytes = 2_097_152

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("space.knowai.cono/lyrics", isDirectory: true)
    }

    func load(for track: TrackInfo) throws -> LoadedLocalLyrics? {
        let url = fileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumStoredBytes else { throw LocalLyricsError.invalidStore }
            let document = try JSONDecoder().decode(LocalLyricsDocument.self, from: Data(contentsOf: url))
            guard document.schemaVersion == 1, document.trackID == track.id,
                  document.title == track.title, document.artist == track.artist,
                  !document.fileName.isEmpty, document.fileName.count <= 255 else { throw LocalLyricsError.invalidStore }
            return LoadedLocalLyrics(document: document, lyrics: try Self.parse(document.contents, format: document.format))
        } catch {
            throw LocalLyricsError.invalidStore
        }
    }

    func importFile(at url: URL, for track: TrackInfo) throws -> LoadedLocalLyrics {
        guard url.isFileURL else { throw LocalLyricsError.unsupportedFile }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true else { throw LocalLyricsError.unsupportedFile }
        let size = attributes.fileSize ?? 0
        guard size <= Self.maximumInputBytes else { throw LocalLyricsError.tooLarge }
        return try save(data: Data(contentsOf: url), fileName: url.lastPathComponent, for: track)
    }

    func save(data: Data, fileName: String, for track: TrackInfo) throws -> LoadedLocalLyrics {
        guard data.count <= Self.maximumInputBytes else { throw LocalLyricsError.tooLarge }
        let format = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard ["txt", "lrc", "ttml", "srt", "krc", "qrc"].contains(format) else { throw LocalLyricsError.unsupportedFile }
        let decoded: String?
        if format == "krc" || format == "qrc" {
            // 바이너리 원본도 손실 없이 JSON 사본에 보존한다.
            decoded = data.base64EncodedString()
        } else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data, encoding: .utf16)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard var contents = decoded else { throw LocalLyricsError.invalidEncoding }
        if contents.first == "\u{feff}" { contents.removeFirst() }
        let lyrics = try Self.parse(contents, format: format)
        // 손상된 기존 파일을 새 가져오기로 조용히 덮어쓰지 않는다.
        _ = try load(for: track)
        let document = LocalLyricsDocument(schemaVersion: 1, trackID: track.id, title: track.title, artist: track.artist,
                                           fileName: String(URL(fileURLWithPath: fileName).lastPathComponent.prefix(255)),
                                           format: format, contents: contents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(document)
        guard encoded.count <= Self.maximumStoredBytes else { throw LocalLyricsError.tooLarge }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoded.write(to: fileURL(for: track), options: .atomic)
        return LoadedLocalLyrics(document: document, lyrics: lyrics)
    }

    func remove(for track: TrackInfo) throws {
        guard try load(for: track) != nil else { return }
        try FileManager.default.removeItem(at: fileURL(for: track))
    }

    /// 파일 이름에는 제목/경로를 넣지 않는다. 동일 제목의 다른 가수나 다른 플레이어 곡과 섞이지 않는다.
    private func fileURL(for track: TrackInfo) -> URL {
        let identity = [track.id, track.title, track.artist]
        let data = Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(digest).json")
    }

    static func parse(_ contents: String, format: String) throws -> TimedLyrics {
        let isBinaryFormat = format == "krc" || format == "qrc"
        guard contents.utf8.count <= (isBinaryFormat ? 1_398_104 : maximumInputBytes) else { throw LocalLyricsError.tooLarge }
        let lrc: String
        let lyrics: TimedLyrics
        switch format {
        case "txt":
            try validatePlain(contents)
            return TimedLyrics(lines: [])
        case "lrc": lrc = contents
        case "ttml":
            // 사용자 파일의 DTD/entity 확장이나 외부 리소스를 해석할 이유가 없다.
            guard contents.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  let converted = TTMLLyrics.lrc(from: contents) else { throw LocalLyricsError.noTimedLyrics }
            lrc = converted
        case "srt":
            return try validated(SRTParser.parse(contents))
        case "krc", "qrc":
            guard let data = Data(base64Encoded: contents), data.count <= maximumInputBytes else { throw LocalLyricsError.noTimedLyrics }
            if format == "krc" { lrc = try KRCLyrics.enhancedLRC(from: data) }
            else { lrc = try QRCLyrics.enhancedLRC(from: data) }
        default: throw LocalLyricsError.unsupportedFile
        }
        lyrics = LRCParser.parse(lrc)
        return try validated(lyrics)
    }

    /// 일반 가사는 시각을 만들어 붙이지 않는다. 원문은 JSON에 그대로 보관한다.
    static func validatePlain(_ contents: String) throws {
        guard contents.utf8.count <= maximumInputBytes else { throw LocalLyricsError.tooLarge }
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalLyricsError.noLyrics }
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        guard lines.count <= 4_000, lines.allSatisfy({ $0.count <= 500 }) else { throw LocalLyricsError.tooLarge }
        guard !contents.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw LocalLyricsError.invalidEncoding
        }
    }

    private static func validated(_ lyrics: TimedLyrics) throws -> TimedLyrics {
        guard lyrics.lines.contains(where: { !$0.isInterlude }) else { throw LocalLyricsError.noTimedLyrics }
        guard lyrics.lines.count <= 4_000, lyrics.lines.allSatisfy({ $0.text.count <= 500 }) else { throw LocalLyricsError.tooLarge }
        return lyrics
    }
}
