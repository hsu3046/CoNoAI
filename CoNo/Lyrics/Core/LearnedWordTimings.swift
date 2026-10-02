// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import CryptoKit
import Foundation
import Synchronization

struct WordTimingIdentity: Codable, Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
    let candidateKey: String
    let lyricsFingerprint: String
    let modelVersion: String

    init(track: TrackInfo, candidateKey: String, lyrics: TimedLyrics, modelVersion: String) {
        trackID = track.id
        title = track.title
        artist = track.artist
        self.candidateKey = candidateKey
        self.modelVersion = modelVersion
        var hash = SHA256()
        func add(_ value: String) { hash.update(data: Data("\(value.utf8.count):\(value)".utf8)) }
        for line in lyrics.lines {
            add(String(line.start.bitPattern)); add(line.text)
            add(line.explicitEnd.map { String($0.bitPattern) } ?? "nil")
            for segment in line.segments {
                add("\(segment.characterStart),\(segment.characterCount),\(segment.start.bitPattern),\(segment.end.map { String($0.bitPattern) } ?? "nil")")
            }
            add("end-line")
        }
        lyricsFingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var storageKey: String {
        let fields = [trackID, title, artist, candidateKey, lyricsFingerprint, modelVersion]
        let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct LearnedWordTiming: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let characterStart: Int
        let characterCount: Int
        let start: Double
        let end: Double
    }
    let lineIndex: Int
    let text: String
    let sourceStart: Double
    let sourceEnd: Double
    /// 학습 당시 (자동 지연 − 수동 오프셋). 다른 시각 창에서 얻은 결과를 잘못 재사용하지 않는다.
    let timingShift: Double
    let confidence: Double
    let textMatch: Double
    let segments: [Segment]

    var lyricLine: LyricLine {
        LyricLine(start: sourceStart, text: text,
                  segments: segments.map { LyricSegment(characterStart: $0.characterStart, characterCount: $0.characterCount,
                                                        start: $0.start, end: $0.end) }, explicitEnd: sourceEnd)
    }

    func applies(to line: LyricLine, end: Double, shift: Double) -> Bool {
        line.segments.isEmpty && line.text == text && line.start == sourceStart && end == sourceEnd
            && shift.isFinite && abs(shift - timingShift) < 0.025
    }

    func validate() throws {
        guard (0..<4_000).contains(lineIndex), !text.isEmpty, text.count <= 500,
              sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0, sourceEnd > sourceStart, sourceEnd <= 86_400,
              sourceEnd - sourceStart <= 20.001, timingShift.isFinite, abs(timingShift) <= 120,
              confidence.isFinite, (0.35...1).contains(confidence), textMatch.isFinite, (0.5...1).contains(textMatch),
              !segments.isEmpty, segments.count <= 500 else { throw LearnedWordTimingError.invalidRecord }
        var previousCharacter = 0
        var previousEnd = sourceStart
        for segment in segments {
            guard segment.characterStart >= previousCharacter, segment.characterCount > 0,
                  segment.characterStart <= text.count, segment.characterCount <= text.count - segment.characterStart,
                  segment.start.isFinite, segment.end.isFinite, segment.start >= previousEnd,
                  segment.end > segment.start, segment.end <= sourceEnd else { throw LearnedWordTimingError.invalidRecord }
            previousCharacter = segment.characterStart + segment.characterCount
            previousEnd = segment.end
        }
    }
}

enum LearnedWordTimingError: LocalizedError {
    case invalidRecord, invalidStore, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRecord: "신뢰할 수 있는 단어 시각을 얻지 못해 기존 가사를 유지합니다."
        case .invalidStore: "학습한 가사 파일을 읽지 못했어요. 원본은 보존했습니다. 학습 기록을 지우고 다시 시도할 수 있습니다."
        case .tooLarge: "학습한 가사 파일이 저장 한도를 넘었습니다. 기존 가사는 그대로입니다."
        }
    }
}

/// 오디오 없이 텍스트 식별자·시각·신뢰도만 저장한다. 손상 파일을 무음 초기화하지 않는다.
actor LearnedWordTimingsStore {
    nonisolated let directoryURL: URL
    private var epoch: UInt64 = 0
    private static let maximumBytes = 2_097_152
    private struct Document: Codable {
        let schemaVersion: Int
        let identity: WordTimingIdentity
        let lines: [LearnedWordTiming]
    }

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("space.knowai.cono/learned-word-timings", isDirectory: true)
    }

    func load(for identity: WordTimingIdentity) throws -> [Int: LearnedWordTiming] {
        let file = url(for: identity)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        do {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maximumBytes else {
                throw LearnedWordTimingError.invalidStore
            }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.schemaVersion == 1, document.identity == identity, document.lines.count <= 4_000,
                  Set(document.lines.map(\.lineIndex)).count == document.lines.count else { throw LearnedWordTimingError.invalidStore }
            for line in document.lines { try line.validate() }
            return Dictionary(uniqueKeysWithValues: document.lines.map { ($0.lineIndex, $0) })
        } catch { throw LearnedWordTimingError.invalidStore }
    }

    func snapshot(for identity: WordTimingIdentity) throws -> (epoch: UInt64, lines: [Int: LearnedWordTiming]) {
        (epoch, try load(for: identity))
    }

    func save(_ line: LearnedWordTiming, for identity: WordTimingIdentity, expectedEpoch: UInt64? = nil, permit: AlignmentWritePermit? = nil) throws {
        if let expectedEpoch, expectedEpoch != epoch { throw CancellationError() }
        if let permit, !permit.isValid { throw CancellationError() }
        try line.validate()
        var lines = try load(for: identity)
        lines[line.lineIndex] = line
        let document = Document(schemaVersion: 1, identity: identity, lines: lines.values.sorted { $0.lineIndex < $1.lineIndex })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumBytes else { throw LearnedWordTimingError.tooLarge }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let file = url(for: identity)
        let previous = try FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file) : nil
        if let permit, !permit.isValid { throw CancellationError() }
        try data.write(to: file, options: .atomic)
        // 디스크 쓰기 도중 취소된 작업도 결과를 남기지 않는다. 다음 쓰기보다 먼저 복구한다.
        if let permit, !permit.isValid {
            if let previous { try previous.write(to: file, options: .atomic) }
            else { try FileManager.default.removeItem(at: file) }
            throw CancellationError()
        }
    }

    func removeAll() throws {
        // 삭제가 먼저 실행되면 큐에서 나중에 도착하는 옛 저장도 거절한다.
        epoch &+= 1
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", stem.count == 64, stem.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func url(for identity: WordTimingIdentity) -> URL { directoryURL.appendingPathComponent(identity.storageKey + ".json") }
}

/// 실행 중인 모델은 즉시 멈출 수 없어도 저장 권한은 동기적으로 철회할 수 있다.
final class AlignmentWritePermit: Sendable {
    private let valid = Atomic<Bool>(true)
    var isValid: Bool { valid.load(ordering: .acquiring) }
    func revoke() { valid.store(false, ordering: .releasing) }
}

/// MainActor 조립부에서 쓰는 세대 게이트. 취소한 작업이 실제 종료되기 전에는 다음 작업을 받지 않는다.
struct AlignmentWorkGate: Sendable {
    struct Ticket: Equatable, Sendable { let id: UUID; let generation: UInt64; let context: String }
    private(set) var generation: UInt64 = 0
    private(set) var active: Ticket?
    private(set) var context = ""

    mutating func changeContext(_ next: String) {
        guard next != context else { return }
        context = next
        generation &+= 1
    }
    mutating func invalidate() { generation &+= 1 }
    mutating func begin() -> Ticket? {
        guard active == nil else { return nil }
        let ticket = Ticket(id: UUID(), generation: generation, context: context)
        active = ticket
        return ticket
    }
    func accepts(_ ticket: Ticket) -> Bool { active == ticket && ticket.generation == generation && ticket.context == context }
    mutating func finish(_ ticket: Ticket) { if active == ticket { active = nil } }
}
