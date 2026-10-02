// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// LRCLIB (https://lrclib.net, 무료·API 키 없음) 싱크 가사 조회.
// 실측(2026-09-25, 12곡)에서 본 성질:
//   - 한국어·일본어 인기곡도 싱크 가사가 대부분 있다
//   - 아티스트 표기에 민감 ("아이유" 0건, "IU" 있음) → 표기를 바꿔 여러 번 검색 + 곡 길이로 거른다
//   - 같은 곡에 로마자 표기 항목이 섞임 → LyricsSelector 가 원문 문자를 우선
//   - 서비스 실패와 유효한 빈 결과를 구분하며, Retry-After 동안 재요청하지 않는다.

import CryptoKit
import Foundation

enum LyricsLookupResult: Codable, Sendable {
    /// 싱크 가사 후보 (점수순, 최대 5). 재생 중 보컬과 비교해 가장 잘 맞는 것을 고른다.
    case synced([LyricsCandidate])
    /// 싱크 가사는 없고 일반 가사만
    case plainOnly(LyricsCandidate)
    case notFound
}

actor LRCLIBClient {
    private let http: LyricsHTTPClient
    private let cacheDirectory: URL?
    /// 못 찾았거나 일반 가사만 있던 결과를 다시 묻기까지의 시간 (싱크 가사가 새로 등록될 수 있으므로)
    private let incompleteResultTTL: TimeInterval = 24 * 60 * 60
    private static let baseURL = URL(string: "https://lrclib.net/api")!
    init(http: LyricsHTTPClient = .shared, cacheDirectory: URL? = nil) {
        self.http = http
        // Older versions could cache a malformed HTTP 200 body as a valid empty result.
        self.cacheDirectory = cacheDirectory ?? Self.cacheRoot?.appendingPathComponent("lyrics-v4", isDirectory: true)
    }

    private static var cacheRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("space.knowai.cono", isDirectory: true)
    }

    /// 가사 캐시를 모두 지운다 (옛 형식 lyrics-v* 포함). 다음 재생 때 다시 받는다.
    static func clearCache() {
        guard let root = cacheRoot,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for item in items where item.lastPathComponent.hasPrefix("lyrics") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func lyrics(for track: TrackInfo, bypassCache: Bool = false) async throws -> LyricsLookupResult {
        try Task.checkCancellation()
        let operation = LyricsServiceOperation.Context(service: .lrclib, id: await LyricsServiceMonitor.shared.begin(.lrclib))
        return try await LyricsServiceOperation.$current.withValue(operation) {
            do {
                let result = try await lookup(track, bypassCache: bypassCache)
                try Task.checkCancellation()
                return result
            } catch {
                if Task.isCancelled || error is CancellationError {
                    await LyricsServiceMonitor.shared.record(.lrclib, .idle)
                    throw CancellationError()
                }
                throw error
            }
        }
    }

    private func lookup(_ track: TrackInfo, bypassCache: Bool) async throws -> LyricsLookupResult {
        try Task.checkCancellation()
        if !bypassCache, let cached = readCache(for: track) {
            // 옛 캐시에 섞인 다른 곡 후보도 거른다 (제목 필터 도입 전 캐시)
            if case let .synced(list) = cached {
                let filtered = LyricsSelector.syncedCandidates(list, for: track)
                if !filtered.isEmpty {
                    await LyricsServiceMonitor.shared.record(.lrclib, .cached)
                    return .synced(filtered)
                }
            } else {
                await LyricsServiceMonitor.shared.record(.lrclib, .cached)
                return cached
            }
        }

        var candidates: [LyricsCandidate] = []
        // 1) 정확 조회 + 제목·아티스트 검색은 항상 (후보를 여러 개 모아 소리로 고르기 위해)
        do {
            if let exact = try await getExact(track) { candidates.append(exact) }
            var query = ["track_name": track.title]
            if !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query["artist_name"] = track.artist }
            candidates += try await search(query)
        // 2) 싱크 후보가 모자라면 표기를 바꿔 더 찾는다 ("아이유" 0건 / "IU" 있음)
            for query in [["q": "\(track.artist) \(track.title)"], ["track_name": track.title]] {
                if LyricsSelector.syncedCandidates(candidates, for: track).count >= 2 { break }
                candidates += try await search(query)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let issue = error as? LyricsAccessError { await LyricsServiceMonitor.shared.record(.lrclib, .failed(issue)) }
            // A later search failure must not hide an exact match already fetched, or poison the disk cache.
            let usable = LyricsSelector.syncedCandidates(candidates, for: track)
            if !usable.isEmpty { return .synced(usable) }
            if let plain = LyricsSelector.best(candidates, targetDuration: track.duration, targetArtist: track.artist),
               !(plain.plainLyrics ?? "").isEmpty { return .plainOnly(plain) }
            throw error
        }
        try Task.checkCancellation()
        let synced = LyricsSelector.syncedCandidates(candidates, for: track)
        if !synced.isEmpty { return store(.synced(synced), for: track) }
        if let plain = LyricsSelector.best(candidates, targetDuration: track.duration, targetArtist: track.artist) {
            return store(.plainOnly(plain), for: track)
        }
        return store(.notFound, for: track)
    }

    // MARK: - HTTP

    private func getExact(_ track: TrackInfo) async throws -> LyricsCandidate? {
        guard !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
        ]
        // The official exact endpoint accepts duration only in 1...3600 seconds; search has no such requirement.
        if track.duration.isFinite, (1...3_600).contains(track.duration.rounded()) {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        components.queryItems = items
        guard let data = try await fetch(components.urlEncodingPlus, allowNotFound: true) else { return nil }
        do { return try validatedCandidate(JSONDecoder().decode(LyricsCandidate.self, from: data)) }
        catch { throw LyricsAccessError.invalidBody }
    }

    private func search(_ query: [String: String]) async throws -> [LyricsCandidate] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let data = try await fetch(components.urlEncodingPlus, allowNotFound: true) else { return [] }
        do { return try JSONDecoder().decode([LyricsCandidate].self, from: data).map(validatedCandidate) }
        catch { throw LyricsAccessError.invalidBody }
    }

    /// A structurally valid JSON record may still contain a changed/malformed lyric format.
    /// Validate before caching so a non-LRC string cannot become an everlasting synced hit.
    private func validatedCandidate(_ candidate: LyricsCandidate) throws -> LyricsCandidate {
        let synced = candidate.syncedLyrics.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let plain = candidate.plainLyrics.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let synced { _ = try LocalLyricsStore.parse(synced, format: "lrc") }
        if let plain { try LocalLyricsStore.validatePlain(plain) }
        return LyricsCandidate(id: candidate.id, trackName: candidate.trackName, artistName: candidate.artistName,
            albumName: candidate.albumName, duration: candidate.duration, instrumental: candidate.instrumental,
            plainLyrics: plain, syncedLyrics: synced)
    }

    /// 404 is a valid absence. Other failures never become a negative cache entry.
    private func fetch(_ url: URL, allowNotFound: Bool) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("CoNo/0.2 (https://www.aib.vote)", forHTTPHeaderField: "Lrclib-Client")
        let (data, response) = try await http.data(for: request, service: .lrclib,
                                                 acceptedStatus: allowNotFound ? [200, 404] : [200])
        return response.statusCode == 404 ? nil : data
    }

    // MARK: - Cache

    private struct CacheEntry: Codable {
        let result: LyricsLookupResult
        let fetchedAt: Date
    }

    private func cacheURL(for track: TrackInfo) -> URL? {
        // 제목·아티스트·길이로 키를 만든다 (persistent ID 는 기기·재설치마다 바뀔 수 있어 쓰지 않는다)
        let duration = track.duration.isFinite && (0...86_400).contains(track.duration) ? Int(track.duration.rounded()) : 0
        let key = [track.title, track.artist, String(duration)].map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("\(digest).json")
    }

    private func readCache(for track: TrackInfo) -> LyricsLookupResult? {
        guard let url = cacheURL(for: track),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152,
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        switch entry.result {
        case .notFound, .plainOnly:
            if Date().timeIntervalSince(entry.fetchedAt) > incompleteResultTTL { return nil }
        case .synced:
            break
        }
        return entry.result
    }

    private func store(_ result: LyricsLookupResult, for track: TrackInfo) -> LyricsLookupResult {
        if !Task.isCancelled, let url = cacheURL(for: track),
           let data = try? JSONEncoder().encode(CacheEntry(result: result, fetchedAt: Date())), data.count <= 2_097_152 {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return result
    }
}
