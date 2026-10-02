// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import CryptoKit
import Foundation

/// Every provider has its own cache. A failed request must not become an empty search result,
/// and one successful provider must not hide another provider's failure for 30 days.
actor ExtraLyricsSources {
    private let http: LyricsHTTPClient
    private let cacheDirectory: URL?
    private var amllEntries: [AMLLEntry]?
    private var amllLoadedAt: Date?
    private static let amllRaw = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/"
    private static let foundTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let emptyTTL: TimeInterval = 24 * 60 * 60

    init(http: LyricsHTTPClient = .shared, cacheDirectory: URL? = nil) {
        self.http = http
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("space.knowai.cono/lyrics-extra-v4", isDirectory: true)
    }

    func candidates(for track: TrackInfo, sources: Set<LyricsSource>, bypassCache: Bool = false) async throws -> [LyricsCandidate] {
        try Task.checkCancellation()
        guard !track.title.isEmpty else { return [] }
        let duration = track.duration.isFinite && (0...86_400).contains(track.duration) ? Int(track.duration.rounded()) : 0
        let trackKey = [track.title, track.artist, String(duration)].map { "\($0.utf8.count):\($0)" }.joined()
        var found: [LyricsCandidate] = []
        var neteaseIDs: [String] = []
        var failure: LyricsAccessError?
        for (source, service) in [(LyricsSource.netease, LyricsServiceID.netease), (.amll, .amll), (.appleMusic, .appleMusic)] where sources.contains(source) {
            try Task.checkCancellation()
            let key = "\(service.rawValue):\(trackKey)"
            let operation = LyricsServiceOperation.Context(service: service, id: await LyricsServiceMonitor.shared.begin(service))
            let result = try await LyricsServiceOperation.$current.withValue(operation) {
                try await sourceResult(for: track, service: service, key: key, neteaseIDs: neteaseIDs, bypassCache: bypassCache)
            }
            found += result.candidates
            if service == .netease { neteaseIDs = result.songIDs }
            failure = failure ?? result.failure
        }
        try Task.checkCancellation()
        if found.isEmpty, let failure { throw failure }
        return found
    }

    private func sourceResult(for track: TrackInfo, service: LyricsServiceID, key: String,
                              neteaseIDs: [String], bypassCache: Bool) async throws -> SourceResult {
        do {
            try Task.checkCancellation()
            // Subscriber lyrics remain in memory only; reconnecting cannot reuse another account's disk cache.
            if !bypassCache, service != .appleMusic, let cached = readCache(key) {
                await LyricsServiceMonitor.shared.record(service, .cached)
                try Task.checkCancellation()
                return SourceResult(candidates: cached.candidates, songIDs: cached.songIDs)
            }
            let result: SourceResult
            switch service {
            case .netease: result = try await neteaseCandidates(for: track)
            case .amll: result = try await amllCandidates(for: track, neteaseIDs: neteaseIDs, refreshIndex: bypassCache)
            case .appleMusic: result = SourceResult(candidates: try await AppleMusicCatalog.shared.candidates(for: track))
            case .lrclib: return SourceResult(candidates: [])
            }
            try Task.checkCancellation()
            if let problem = result.failure {
                await LyricsServiceMonitor.shared.record(service, .failed(problem))
            } else if service != .appleMusic, result.cacheable {
                store(result, key: key)
            }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError {
                await LyricsServiceMonitor.shared.record(service, .idle)
                throw CancellationError()
            }
            let problem = (error as? LyricsAccessError) ?? .invalidBody
            await LyricsServiceMonitor.shared.record(service, .failed(problem))
            return SourceResult(candidates: [], cacheable: false, failure: problem)
        }
    }

    private struct SourceResult {
        var candidates: [LyricsCandidate]
        var songIDs: [String] = []
        var cacheable = true
        var failure: LyricsAccessError?
    }

    private struct NetEaseSearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String }
            struct Album: Decodable { let name: String? }
            let id: Int
            let name: String
            let ar: [Artist]?
            let al: Album?
            let dt: Double?
        }
        let code: Int
        let result: Result?
    }
    private struct NetEaseLyric: Decodable {
        struct Body: Decodable { let lyric: String? }
        let code: Int
        let lrc: Body?
        let nolyric: Bool?
        let uncollected: Bool?
    }

    private func neteaseCandidates(for track: TrackInfo) async throws -> SourceResult {
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        components.queryItems = [.init(name: "s", value: "\(track.title) \(track.artist)"), .init(name: "type", value: "1"), .init(name: "limit", value: "10")]
        let data = try await fetch(components.urlEncodingPlus, service: .netease)
        guard let decoded = try? JSONDecoder().decode(NetEaseSearch.self, from: data), decoded.code == 200,
              let result = decoded.result else { throw LyricsAccessError.invalidBody }
        let matching = (result.songs ?? []).filter { song in
            guard LyricsSelector.titlesMatch(song.name, track.title),
                  (song.ar ?? []).contains(where: { LyricsSelector.artistsMatch($0.name, track.artist) }) else { return false }
            guard track.durationIsReliable, track.duration > 0, let ms = song.dt else { return true }
            return abs(ms / 1000 - track.duration) <= LyricsSelector.maxDurationDifference
        }
        var output = SourceResult(candidates: [], songIDs: matching.map { String($0.id) })
        for song in matching.prefix(3) {
            do { if let candidate = try await neteaseLyric(for: song) { output.candidates.append(candidate) } }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                output.failure = (error as? LyricsAccessError) ?? .invalidBody
                output.cacheable = false
                break
            }
        }
        return output
    }

    private func neteaseLyric(for song: NetEaseSearch.Song) async throws -> LyricsCandidate? {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
        components.queryItems = [.init(name: "id", value: String(song.id)), .init(name: "lv", value: "1"), .init(name: "tv", value: "-1")]
        let data = try await fetch(components.urlEncodingPlus, service: .netease)
        guard let decoded = try? JSONDecoder().decode(NetEaseLyric.self, from: data), decoded.code == 200,
              decoded.lrc?.lyric != nil || decoded.nolyric == true || decoded.uncollected == true else { throw LyricsAccessError.invalidBody }
        if decoded.nolyric == true || decoded.uncollected == true { return nil }
        guard let raw = decoded.lrc?.lyric, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try LocalLyricsStore.parse(raw, format: "lrc") }
        catch { throw LyricsAccessError.invalidBody }
        guard let synced = NetEaseLyrics.cleaned(raw) else { return nil }
        return LyricsCandidate(id: song.id, trackName: song.name, artistName: (song.ar ?? []).map(\.name).joined(separator: ", "),
                               albumName: song.al?.name, duration: song.dt.map { $0 / 1000 }, instrumental: false,
                               plainLyrics: nil, syncedLyrics: synced, source: .netease)
    }

    private func amllCandidates(for track: TrackInfo, neteaseIDs: [String], refreshIndex: Bool) async throws -> SourceResult {
        let index = try await loadAMLLIndex(refresh: refreshIndex)
        var result = SourceResult(candidates: [], cacheable: index.fresh, failure: index.failure)
        for entry in AMLLIndex.matches(index.entries, title: track.title, artist: track.artist, neteaseIDs: neteaseIDs).prefix(2) {
            do {
                guard !entry.file.contains("/"), !entry.file.contains("\\"), entry.file.utf8.count <= 255,
                      entry.file.hasSuffix(".ttml") else { throw LyricsAccessError.invalidBody }
                let url = URL(string: Self.amllRaw + "raw-lyrics/")!.appendingPathComponent(entry.file)
                let data = try await fetch(url, service: .amll)
                guard let text = String(data: data, encoding: .utf8),
                      text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                      let lrc = TTMLLyrics.lrc(from: text) else { throw LyricsAccessError.invalidBody }
                result.candidates.append(LyricsCandidate(id: entry.candidateID, trackName: entry.titles.first ?? track.title,
                    artistName: entry.artists.joined(separator: ", "), albumName: nil, duration: nil,
                    instrumental: false, plainLyrics: nil, syncedLyrics: lrc, source: .amll))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                result.failure = (error as? LyricsAccessError) ?? .invalidBody
                result.cacheable = false
                break
            }
        }
        if !index.fresh, result.candidates.isEmpty { throw index.failure ?? LyricsAccessError.network }
        return result
    }

    private func loadAMLLIndex(refresh: Bool) async throws -> (entries: [AMLLEntry], fresh: Bool, failure: LyricsAccessError?) {
        if !refresh, let amllEntries, let amllLoadedAt, Date().timeIntervalSince(amllLoadedAt) < Self.emptyTTL { return (amllEntries, true, nil) }
        let file = cacheDirectory?.appendingPathComponent("amll-index.jsonl")
        let saved = file.flatMap { boundedRead($0, maximum: 8_388_608) }.flatMap(Self.validIndex)
        if !refresh, let saved, let file, let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < Self.emptyTTL {
            amllEntries = saved; amllLoadedAt = date
            return (saved, true, nil)
        }
        do {
            let data = try await fetch(URL(string: Self.amllRaw + "metadata/raw-lyrics-index.jsonl")!, service: .amll, maximumBytes: 8_388_608)
            guard let entries = Self.validIndex(data) else { throw LyricsAccessError.invalidBody }
            try Task.checkCancellation()
            // Parse first: a captive portal or changed response must not overwrite the last usable index.
            if let file {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            amllEntries = entries; amllLoadedAt = Date()
            return (entries, true, nil)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let problem = (error as? LyricsAccessError) ?? .invalidBody
            await LyricsServiceMonitor.shared.record(.amll, .failed(problem))
            if let saved { return (saved, false, problem) }
            throw problem
        }
    }

    private static func validIndex(_ data: Data) -> [AMLLEntry]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let entries = AMLLIndex.parse(text)
        return entries.isEmpty ? nil : entries
    }

    private func fetch(_ url: URL, service: LyricsServiceID, maximumBytes: Int = 1_048_576) async throws -> Data {
        try await http.data(for: URLRequest(url: url), service: service, maximumBytes: maximumBytes).0
    }

    private struct CacheEntry: Codable {
        let candidates: [LyricsCandidate]
        let songIDs: [String]
        let fetchedAt: Date
    }
    private func cacheURL(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("\(digest).json")
    }
    private func boundedRead(_ url: URL, maximum: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximum else { return nil }
        return try? Data(contentsOf: url)
    }
    private func readCache(_ key: String) -> CacheEntry? {
        guard let url = cacheURL(key), let data = boundedRead(url, maximum: 2_097_152),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        let ttl = entry.candidates.isEmpty ? Self.emptyTTL : Self.foundTTL
        return Date().timeIntervalSince(entry.fetchedAt) < ttl ? entry : nil
    }
    private func store(_ result: SourceResult, key: String) {
        guard !Task.isCancelled, let url = cacheURL(key),
              let data = try? JSONEncoder().encode(CacheEntry(candidates: result.candidates, songIDs: result.songIDs, fetchedAt: Date())),
              data.count <= 2_097_152 else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
