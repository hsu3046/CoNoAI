// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Darwin
import Foundation
import Testing

struct LyricsPrivacyMigrationTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cono-privacy-\(UUID().uuidString)", isDirectory: true)
        var caches: URL { root.appendingPathComponent("Caches/space.knowai.cono", isDirectory: true) }
        var support: URL { root.appendingPathComponent("Application Support/space.knowai.cono", isDirectory: true) }
        var learned: URL { support.appendingPathComponent("learned-word-timings", isDirectory: true) }
        func directory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        func write(_ text: String, at url: URL) throws { try directory(url.deletingLastPathComponent()); try Data(text.utf8).write(to: url) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func run() -> LyricsPrivacyMigration.Report { LyricsPrivacyMigration.run(cachesRoot: caches, learnedDirectory: learned) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    private func identity(_ key: String) -> WordTimingIdentity {
        WordTimingIdentity(track: TrackInfo(id: "fixture", title: "직접 만든 테스트", artist: "CoNo", album: "", duration: 10),
                           candidateKey: key, lyrics: TimedLyrics(lines: [LyricLine(start: 1, text: "합성 문장")]), modelVersion: "synthetic-model")
    }
    private var line: LearnedWordTiming {
        LearnedWordTiming(lineIndex: 0, text: "합성 문장", sourceStart: 1, sourceEnd: 3, timingShift: 0,
                          confidence: 0.8, textMatch: 0.9,
                          segments: [.init(characterStart: 0, characterCount: 2, start: 1.1, end: 1.9)])
    }
    private func writeDocument(_ identity: WordTimingIdentity, line: LearnedWordTiming? = nil,
                               schema: Int = 1, name: String? = nil, fixture: Fixture) throws -> URL {
        struct Document: Encodable { let schemaVersion: Int; let identity: WordTimingIdentity; let lines: [LearnedWordTiming] }
        try fixture.directory(fixture.learned)
        let file = fixture.learned.appendingPathComponent((name ?? identity.storageKey) + ".json")
        try JSONEncoder().encode(Document(schemaVersion: schema, identity: identity, lines: [line ?? self.line])).write(to: file)
        return file
    }

    @Test func removesOnlyExactLegacyCachesAndValidAppleLearnedDocuments() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        for name in ["lyrics-extra-v1", "lyrics-extra-v2", "lyrics-extra-v3", "lyrics-extra-v4", "lyrics-extra-v30", "lyrics-v3"] {
            try fixture.write("synthetic cache", at: fixture.caches.appendingPathComponent(name).appendingPathComponent("fixture.json"))
        }
        let personal = fixture.support.appendingPathComponent("lyrics/personal.json")
        try fixture.write("user-created synthetic lyrics", at: personal)
        let apple = try writeDocument(identity("appleMusic:42"), fixture: fixture)
        let local = try writeDocument(identity("local:fixture"), fixture: fixture)
        let lrclib = try writeDocument(identity("lrclib:42"), fixture: fixture)
        let report = fixture.run()
        #expect(report.removedCacheDirectories == 3 && report.removedLearnedFiles == 1 && !report.needsAttention)
        #expect(!fixture.exists(apple))
        #expect(fixture.exists(local) && fixture.exists(lrclib) && fixture.exists(personal))
        for name in ["lyrics-extra-v4", "lyrics-extra-v30", "lyrics-v3"] { #expect(fixture.exists(fixture.caches.appendingPathComponent(name))) }
        #expect(fixture.run() == LyricsPrivacyMigration.Report(), "재실행은 개인 파일이나 다른 출처 학습을 건드리지 않는다")
    }

    @Test func preservesMalformedUnsupportedMismatchedAndOversizedLearnedFiles() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let corrupt = fixture.learned.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try fixture.write("{ broken JSON", at: corrupt)
        let future = try writeDocument(identity("appleMusic:43"), schema: 2, fixture: fixture)
        let wrongName = try writeDocument(identity("appleMusic:44"), name: String(repeating: "b", count: 64), fixture: fixture)
        let large = fixture.learned.appendingPathComponent(String(repeating: "c", count: 64) + ".json")
        try Data(repeating: 32, count: 2_097_153).write(to: large)
        let malformedLine = LearnedWordTiming(lineIndex: 0, text: line.text, sourceStart: 1, sourceEnd: 3, timingShift: 0,
                                             confidence: 0.1, textMatch: 0.9, segments: line.segments)
        let invalid = try writeDocument(identity("appleMusic:45"), line: malformedLine, fixture: fixture)
        let report = fixture.run()
        #expect(report.removedLearnedFiles == 0 && report.unreadablePaths == 5 && report.failedRemovals == 0)
        for file in [corrupt, future, wrongName, large, invalid] { #expect(fixture.exists(file)) }
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "{ broken JSON")
    }

    @Test func preservesSymlinkRootsTreesAndLearnedFilesWithoutTouchingTargets() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let outside = fixture.root.appendingPathComponent("untouched")
        try fixture.write("personal data", at: outside.appendingPathComponent("original.txt"))
        try fixture.directory(fixture.caches)
        try FileManager.default.createSymbolicLink(at: fixture.caches.appendingPathComponent("lyrics-extra-v1"), withDestinationURL: outside)
        let nested = fixture.caches.appendingPathComponent("lyrics-extra-v2")
        try fixture.directory(nested)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("keep-link"), withDestinationURL: outside)
        try fixture.directory(fixture.learned)
        let linkedFile = fixture.learned.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outside.appendingPathComponent("original.txt"))
        let report = fixture.run()
        #expect(report.removedCacheDirectories == 0 && report.removedLearnedFiles == 0 && report.preservedSymbolicLinks == 3)
        #expect(fixture.exists(linkedFile) && fixture.exists(nested.appendingPathComponent("keep-link")))
        #expect(try String(contentsOf: outside.appendingPathComponent("original.txt"), encoding: .utf8) == "personal data")
        let linkedRoot = fixture.root.appendingPathComponent("linked-cache-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.caches)
        let missing = fixture.root.appendingPathComponent("missing")
        #expect(LyricsPrivacyMigration.run(cachesRoot: linkedRoot, learnedDirectory: missing).preservedSymbolicLinks == 1)
    }

    @Test func missingDirectoriesAreANoOpAndInvalidRootsAreReported() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        #expect(fixture.run() == LyricsPrivacyMigration.Report())
        try fixture.write("regular file", at: fixture.caches)
        #expect(fixture.run().unreadablePaths == 1)
    }

    @Test(.enabled(if: geteuid() != 0))
    func removalAndReadFailuresAreCountedAndCanBeRetried() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let legacy = fixture.caches.appendingPathComponent("lyrics-extra-v1")
        try fixture.write("synthetic cache", at: legacy.appendingPathComponent("fixture.json"))
        try fixture.directory(fixture.learned)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.caches.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.learned.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.caches.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.learned.path)
        }
        let report = fixture.run()
        #expect(report.failedRemovals == 1 && report.unreadablePaths == 1)
        #expect(fixture.exists(legacy))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.caches.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.learned.path)
        #expect(fixture.run().removedCacheDirectories == 1)
    }
}
