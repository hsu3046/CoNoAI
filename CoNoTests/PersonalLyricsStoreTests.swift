// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct PersonalLyricsStoreTests {
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("personal-lyrics-\(UUID().uuidString)") }
    private var input: PersonalLyricsInput { PersonalLyricsInput(title: "  내가 만든 곡  ", artist: "  CoNo  ", album: "", contents: "첫 줄\n\n둘째 줄") }

    @Test func registersPlainLyricsWithoutPlaybackOrDurationAndExportsOriginalText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLyricsStore(directoryURL: directory)
        let saved = try await store.save(input)
        #expect(saved.lyrics.title == "내가 만든 곡")
        #expect(saved.lyrics.artist == "CoNo")
        #expect(saved.lyrics.duration == nil)
        #expect(saved.lyrics.contents == input.contents)
        #expect(saved.track.duration == 0 && !saved.track.durationIsReliable)
        #expect(try LocalLyricsStore.parse(saved.lyrics.contents, format: saved.lyrics.format.rawValue).lines.isEmpty)
        let reloaded = try await PersonalLyricsStore(directoryURL: directory).list()
        #expect(reloaded.documents == [saved])
        #expect(reloaded.issues.isEmpty)
        #expect(saved.lyrics.plainLyrics == input.contents)
    }

    @Test func importUTF16PlainAndEnhancedLRCWithoutLosingTiming() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersonalLyricsStore(directoryURL: directory.appendingPathComponent("store"))
        let txt = directory.appendingPathComponent("한글.txt")
        let text = "[후렴]\r\n일반 가사 그대로"
        try #require(text.data(using: .utf16)).write(to: txt)
        let imported = try await store.importedInput(at: txt)
        #expect(imported.contents == text)
        #expect(imported.format == .plain)
        #expect(imported.artist.isEmpty)
        await #expect(throws: PersonalLyricsError.self) { _ = try await store.save(imported) }
        var ready = imported; ready.artist = "CoNo"
        #expect(try await store.save(ready).lyrics.contents == text)
        let timed = PersonalLyricsInput(title: "정밀 가사", artist: "CoNo", format: .synced, contents: "[00:01]<00:01>첫<00:02> 줄<00:03>")
        let saved = try await store.save(timed)
        #expect(saved.lyrics.contents == timed.contents)
        #expect(try LocalLyricsStore.parse(saved.lyrics.contents, format: "lrc").lines.first?.segments.count == 2)
        #expect(saved.lyrics.plainLyrics == "첫 줄")
    }

    @Test func revisionConflictAndDeletedDocumentNeverLoseNewerChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLyricsStore(directoryURL: directory)
        let original = try await store.save(input)
        var first = original.lyrics; first.contents = "먼저 저장"
        let newer = try await store.save(first, id: original.id, expectedRevision: original.revision)
        await #expect(throws: PersonalLyricsError.self) { _ = try await store.save(input, id: original.id, expectedRevision: original.revision) }
        await #expect(throws: PersonalLyricsError.self) { try await store.remove(original) }
        #expect(try await store.list().documents == [newer])
        try await store.remove(newer)
        await #expect(throws: PersonalLyricsError.self) { _ = try await store.save(input, id: newer.id, expectedRevision: newer.revision) }
        #expect(try await store.list().documents.isEmpty)
    }

    @Test func corruptOrFutureDocumentIsReportedAndNeverOverwrittenOrDeleted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLyricsStore(directoryURL: directory)
        let original = try await store.save(input)
        let file = directory.appendingPathComponent(original.id.uuidString + ".json")
        for broken in [Data("broken JSON".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            try broken.write(to: file, options: .atomic)
            let listing = try await store.list()
            #expect(listing.documents.isEmpty && listing.issues.count == 1)
            await #expect(throws: PersonalLyricsError.self) { _ = try await store.save(input, id: original.id, expectedRevision: original.revision) }
            await #expect(throws: PersonalLyricsError.self) { try await store.remove(original) }
            #expect(try Data(contentsOf: file) == broken)
        }
    }

    @Test func saveCompletionKeepsTypingAndUsesLatestRevisionForTheNextSave() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalLyricsStore(directoryURL: directory)
        var editor = PersonalLyricsEditingState(input: input)
        let snapshot = editor.input
        let saved = try await store.save(snapshot)
        editor.input.contents += "\n저장 중 입력"
        editor.didSave(saved, snapshot: snapshot)
        #expect(editor.input.contents.hasSuffix("저장 중 입력"))
        #expect(editor.isDirty)
        #expect(editor.saved?.revision == saved.revision)
        let latestSnapshot = editor.input
        let next = try await store.save(latestSnapshot, id: editor.saved?.id, expectedRevision: editor.saved?.revision)
        editor.didSave(next, snapshot: latestSnapshot)
        #expect(!editor.isDirty)
        #expect(next.lyrics.contents.hasSuffix("저장 중 입력"))
    }

    @Test func invalidMetadataOversizedTextAndFakeTimedInputAreRejected() {
        #expect(throws: PersonalLyricsError.self) { try PersonalLyricsInput(contents: "가사").validated() }
        #expect(throws: PersonalLyricsError.self) { try PersonalLyricsInput(title: "곡", artist: "  ", contents: "가사").validated() }
        #expect(throws: PersonalLyricsError.self) { try PersonalLyricsInput(title: "곡", artist: "CoNo", duration: .infinity, contents: "가사").validated() }
        #expect(throws: LocalLyricsError.self) { try PersonalLyricsInput(title: "곡", artist: "CoNo", format: .synced, contents: "시각 없는 가사").validated() }
        #expect(throws: LocalLyricsError.self) { try PersonalLyricsInput(title: "곡", artist: "CoNo", contents: String(repeating: "가", count: 501)).validated() }
        #expect(throws: LocalLyricsError.self) { try PersonalLyricsInput(title: "곡", artist: "CoNo", contents: "보이지 않는\u{0}문자").validated() }
    }
}
