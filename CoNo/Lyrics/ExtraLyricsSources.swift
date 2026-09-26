// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// LRCLIB 외의 가사 소스 (#2): NetEase 云音乐 · AMLL TTML DB. 후보를 모아 LyricsController 가 LRCLIB 후보와 함께
// 제목·가수·길이로 거르고, 분리된 보컬과 대 보아 가장 잘 맞는 것을 고른다.
// NetEase 는 비공식 API(인증 없음, 2026-09-26 확인) — 실패는 조용히 빈 결과 (LRCLIB 만으로 동작).
// AMLL 은 GitHub 공개 저장소(CC0) — 색인(1.6MB)을 하루 단위로 캐시하고 제목·가수·NetEase 번호로 찾는다.

import CryptoKit
import Foundation

actor ExtraLyricsSources {
    private let session: URLSession
    private let cacheDirectory: URL?
    private var amllEntries: [AMLLEntry]?
    private var amllLoadedAt: Date?

    private static let neteaseSearch = URL(string: "https://music.163.com/api/cloudsearch/pc")!
    private static let neteaseLyric = URL(string: "https://music.163.com/api/song/lyric/v1")!
    private static let amllRaw = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/"
    /// 찾은 결과는 오래, 못 찾은 결과는 하루 (새로 올라올 수 있다)
    private static let foundTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let emptyTTL: TimeInterval = 24 * 60 * 60

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) CoNo/0.1"]
        session = URLSession(configuration: configuration)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("space.knowai.cono/lyrics-extra-v1", isDirectory: true)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// 켜 둔 소스들의 싱크 가사 후보
    func candidates(for track: TrackInfo, sources: Set<LyricsSource>) async -> [LyricsCandidate] {
        let wanted = sources.subtracting([.lrclib])
        guard !wanted.isEmpty, !track.title.isEmpty else { return [] }
        let cacheKey = "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))|\(wanted.map(\.rawValue).sorted().joined(separator: ","))"
        if let cached = readCache(cacheKey) { return cached }

        var found: [LyricsCandidate] = []
        var neteaseIDs: [String] = []
        if wanted.contains(.netease) {
            let result = await neteaseCandidates(for: track)
            found += result.candidates
            neteaseIDs = result.songIDs
        }
        if wanted.contains(.amll) {
            found += await amllCandidates(for: track, neteaseIDs: neteaseIDs)
        }
        store(found, key: cacheKey)
        return found
    }

    // MARK: - NetEase

    private struct NetEaseSearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String }
            struct Album: Decodable { let name: String? }
            let id: Int
            let name: String
            let ar: [Artist]?
            let al: Album?
            /// 밀리초
            let dt: Double?
        }
        let result: Result?
    }

    private struct NetEaseLyric: Decodable {
        struct Body: Decodable { let lyric: String? }
        let lrc: Body?
    }

    /// 제목·가수가 맞는 상위 3곡의 가사. 그 곡 번호들도 돌려준다 (AMLL 을 번호로 찾는 데 쓴다 —
    /// 검색 결과 전체를 넘기면 같은 가수의 다른 곡 AMLL 가사가 붙는다).
    private func neteaseCandidates(for track: TrackInfo) async -> (candidates: [LyricsCandidate], songIDs: [String]) {
        var components = URLComponents(url: Self.neteaseSearch, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let data = await fetch(components.urlEncodingPlus),
              let songs = (try? JSONDecoder().decode(NetEaseSearch.self, from: data))?.result?.songs
        else { return ([], []) }

        let matching = songs.filter { song in
            guard LyricsSelector.titlesMatch(song.name, track.title) else { return false }
            // 커버·합창·sped up 판이 많다 → 가수가 맞아야 (표기가 달라 놓치는 건 LRCLIB 이 맡는다)
            guard (song.ar ?? []).contains(where: { LyricsSelector.artistsMatch($0.name, track.artist) }) else { return false }
            // 음원 길이를 믿을 수 있으면 길이도 맞아야 (다른 버전 방지)
            guard track.durationIsReliable, track.duration > 0, let ms = song.dt else { return true }
            return abs(ms / 1000 - track.duration) <= LyricsSelector.maxDurationDifference
        }
        let picked = Array(matching.prefix(3))
        let candidates = await withTaskGroup(of: LyricsCandidate?.self) { group in
            for song in picked {
                group.addTask { await self.neteaseLyric(for: song) }
            }
            var result: [LyricsCandidate] = []
            for await candidate in group { if let candidate { result.append(candidate) } }
            return result
        }
        return (candidates, matching.map { String($0.id) })
    }

    private func neteaseLyric(for song: NetEaseSearch.Song) async -> LyricsCandidate? {
        var components = URLComponents(url: Self.neteaseLyric, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(song.id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let data = await fetch(components.urlEncodingPlus),
              let raw = (try? JSONDecoder().decode(NetEaseLyric.self, from: data))?.lrc?.lyric,
              let synced = NetEaseLyrics.cleaned(raw)
        else { return nil }
        return LyricsCandidate(
            id: song.id,
            trackName: song.name,
            artistName: (song.ar ?? []).map(\.name).joined(separator: ", "),
            albumName: song.al?.name,
            duration: song.dt.map { $0 / 1000 },
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: synced,
            source: .netease
        )
    }

    // MARK: - AMLL

    private func amllCandidates(for track: TrackInfo, neteaseIDs: [String]) async -> [LyricsCandidate] {
        guard let entries = await loadAMLLIndex() else { return [] }
        let matches = AMLLIndex.matches(entries, title: track.title, artist: track.artist, neteaseIDs: neteaseIDs).prefix(2)
        var result: [LyricsCandidate] = []
        for entry in matches {
            let path = "raw-lyrics/" + (entry.file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.file)
            guard let url = URL(string: Self.amllRaw + path), let data = await fetch(url),
                  let ttml = String(data: data, encoding: .utf8), let lrc = TTMLLyrics.lrc(from: ttml)
            else { continue }
            result.append(LyricsCandidate(
                id: entry.candidateID,
                trackName: entry.titles.first ?? track.title,
                artistName: entry.artists.joined(separator: ", "),
                albumName: nil,
                duration: nil,
                instrumental: false,
                plainLyrics: nil,
                syncedLyrics: lrc,
                source: .amll
            ))
        }
        return result
    }

    /// 색인: 메모리 → 디스크(하루) → 네트워크
    private func loadAMLLIndex() async -> [AMLLEntry]? {
        if let amllEntries, let amllLoadedAt, Date().timeIntervalSince(amllLoadedAt) < Self.emptyTTL { return amllEntries }
        let file = cacheDirectory?.appendingPathComponent("amll-index.jsonl")
        var text: String?
        if let file, let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < Self.emptyTTL {
            text = try? String(contentsOf: file, encoding: .utf8)
        }
        if text == nil, let url = URL(string: Self.amllRaw + "metadata/raw-lyrics-index.jsonl"), let data = await fetch(url) {
            text = String(data: data, encoding: .utf8)
            if let file { try? data.write(to: file, options: .atomic) }
        }
        // 네트워크가 안 되면 오래된 디스크 사본이라도
        if text == nil, let file { text = try? String(contentsOf: file, encoding: .utf8) }
        guard let text else { return nil }
        amllEntries = AMLLIndex.parse(text)
        amllLoadedAt = Date()
        return amllEntries
    }

    // MARK: - 공통

    private func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private struct CacheEntry: Codable {
        let candidates: [LyricsCandidate]
        let fetchedAt: Date
    }

    private func cacheURL(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("\(digest).json")
    }

    private func readCache(_ key: String) -> [LyricsCandidate]? {
        guard let url = cacheURL(key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        let ttl = entry.candidates.isEmpty ? Self.emptyTTL : Self.foundTTL
        return Date().timeIntervalSince(entry.fetchedAt) < ttl ? entry.candidates : nil
    }

    private func store(_ candidates: [LyricsCandidate], key: String) {
        guard let url = cacheURL(key), let data = try? JSONEncoder().encode(CacheEntry(candidates: candidates, fetchedAt: Date())) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
