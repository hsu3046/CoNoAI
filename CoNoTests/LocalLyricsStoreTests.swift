// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct LocalLyricsStoreTests {
    private let track = TrackInfo(id: "test-song", title: "로컬 테스트", artist: "CoNo", album: "", duration: 180)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cono-lyrics-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savedLyricsReloadWithOriginalTimingAndDeleteOnlyTheirOwnCopy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalLyricsStore(directoryURL: directory)
        let data = Data("[00:10]<00:10>로컬<00:11> <00:12>노래<00:14>".utf8)
        let saved = try await store.save(data: data, fileName: "원본.lrc", for: track)
        #expect(saved.lineCount == 1)
        #expect(saved.preciseLineCount == 1)
        let reloaded = try #require(try await LocalLyricsStore(directoryURL: directory).load(for: track))
        #expect(reloaded.document.contents == String(data: data, encoding: .utf8))
        #expect(reloaded.lyrics == saved.lyrics)
        let another = TrackInfo(id: "another-song", title: track.title, artist: track.artist, album: "", duration: 180)
        #expect(try await store.load(for: another) == nil, "같은 제목이어도 다른 플레이어 곡을 덮어쓰지 않는다")
        _ = try await store.save(data: data, fileName: "다른 곡.lrc", for: another)
        try await store.remove(for: track)
        #expect(try await store.load(for: track) == nil)
        #expect(try await store.load(for: another) != nil)
    }

    @Test func invalidImportPreservesExistingValidLyrics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalLyricsStore(directoryURL: directory)
        let original = "[00:01]기존 가사"
        _ = try await store.save(data: Data(original.utf8), fileName: "valid.lrc", for: track)
        await #expect(throws: LocalLyricsError.self) {
            _ = try await store.save(data: Data("시간 없는 가사".utf8), fileName: "invalid.lrc", for: track)
        }
        await #expect(throws: LocalLyricsError.self) {
            _ = try await store.save(data: Data(repeating: 0x61, count: 1_048_577), fileName: "large.lrc", for: track)
        }
        await #expect(throws: LocalLyricsError.self) {
            _ = try await store.save(data: Data(original.utf8), fileName: "lyrics.txt", for: track)
        }
        #expect(try await store.load(for: track)?.document.contents == original)
    }

    @Test func corruptOrFutureStoreIsPreservedAndCannotBeSilentlyReplaced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalLyricsStore(directoryURL: directory)
        let input = Data("[00:01]처음 가사".utf8)
        _ = try await store.save(data: input, fileName: "first.lrc", for: track)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        for broken in [Data("broken JSON".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            try broken.write(to: file, options: .atomic)
            await #expect(throws: LocalLyricsError.self) { _ = try await store.load(for: track) }
            await #expect(throws: LocalLyricsError.self) {
                _ = try await store.save(data: input, fileName: "replace.lrc", for: track)
            }
            #expect(try Data(contentsOf: file) == broken)
        }
    }

    @Test func importsUTF16TTMLWithoutNetworkAndRejectsDTD() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalLyricsStore(directoryURL: directory)
        let ttml = "<tt><body><p begin=\"1s\" end=\"3s\"><span begin=\"1s\" end=\"2s\">한글</span></p></body></tt>"
        let data = try #require(ttml.data(using: .utf16))
        let saved = try await store.save(data: data, fileName: "Korean.TTML", for: track)
        #expect(saved.lyrics.lines.first?.text == "한글")
        #expect(saved.preciseLineCount == 1)
        await #expect(throws: LocalLyricsError.self) {
            _ = try await store.save(data: Data("<!DOCTYPE tt SYSTEM \"https://example.invalid/test.dtd\">\(ttml)".utf8), fileName: "entity.ttml", for: track)
        }
        #expect(try await store.load(for: track)?.document.contents == ttml)
    }
}
