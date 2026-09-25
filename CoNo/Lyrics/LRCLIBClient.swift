// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// LRCLIB (https://lrclib.net, 무료·API 키 없음) 싱크 가사 조회.
// 실측(2026-09-25, 12곡)에서 본 성질:
//   - 한국어·일본어 인기곡도 싱크 가사가 대부분 있다
//   - 아티스트 표기에 민감 ("아이유" 0건, "IU" 있음) → 표기를 바꿔 여러 번 검색 + 곡 길이로 거른다
//   - 같은 곡에 로마자 표기 항목이 섞임 → LyricsSelector 가 원문 문자를 우선
//   - 간헐적 503 → 재시도 1회, 결과(없음 포함)는 디스크에 캐시

import CryptoKit
import Foundation

enum LyricsLookupResult: Codable, Sendable {
    /// 싱크 가사 후보 (점수순, 최대 5). 재생 중 보컬과 비교해 가장 잘 맞는 것을 고른다.
    case synced([LyricsCandidate])
    /// 싱크 가사는 없고 일반 가사만
    case plainOnly(LyricsCandidate)
    case notFound
}

enum LRCLIBError: LocalizedError {
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .http(code): "가사 서버 응답 오류 (HTTP \(code))"
        case let .network(message): "가사 서버에 연결하지 못했습니다: \(message)"
        }
    }
}

actor LRCLIBClient {
    private let session: URLSession
    private let cacheDirectory: URL?
    /// 못 찾은 결과를 다시 묻기까지의 시간 (새 가사가 등록될 수 있으므로)
    private let notFoundTTL: TimeInterval = 24 * 60 * 60
    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let userAgent = "CoNo/0.1 (https://knowai.space)"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: configuration)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("space.knowai.cono/lyrics-v2", isDirectory: true) // v2: 후보 목록 형식
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    func lyrics(for track: TrackInfo) async throws -> LyricsLookupResult {
        if let cached = readCache(for: track) {
            // 옛 캐시에 섞인 다른 곡 후보도 거른다 (제목 필터 도입 전 캐시)
            if case let .synced(list) = cached {
                let filtered = LyricsSelector.rankedSynced(list, targetDuration: track.duration, targetTitle: track.title)
                if !filtered.isEmpty { return .synced(filtered) }
            } else {
                return cached
            }
        }

        var candidates: [LyricsCandidate] = []
        // 1) 정확 조회 + 제목·아티스트 검색은 항상 (후보를 여러 개 모아 소리로 고르기 위해)
        if let exact = try await getExact(track) { candidates.append(exact) }
        candidates += try await search(["track_name": track.title, "artist_name": track.artist])
        // 2) 싱크 후보가 모자라면 표기를 바꿔 더 찾는다 ("아이유" 0건 / "IU" 있음)
        for query in [["q": "\(track.artist) \(track.title)"], ["track_name": track.title]] {
            if LyricsSelector.rankedSynced(candidates, targetDuration: track.duration, targetTitle: track.title).count >= 2 { break }
            candidates += try await search(query)
        }

        let synced = LyricsSelector.rankedSynced(candidates, targetDuration: track.duration, targetTitle: track.title)
        if !synced.isEmpty { return store(.synced(synced), for: track) }
        if let plain = LyricsSelector.best(candidates, targetDuration: track.duration) {
            return store(.plainOnly(plain), for: track)
        }
        return store(.notFound, for: track)
    }

    // MARK: - HTTP

    private func getExact(_ track: TrackInfo) async throws -> LyricsCandidate? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard let data = try await fetch(components.url!, allowNotFound: true) else { return nil }
        return try? JSONDecoder().decode(LyricsCandidate.self, from: data)
    }

    private func search(_ query: [String: String]) async throws -> [LyricsCandidate] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let data = try await fetch(components.url!, allowNotFound: true) else { return [] }
        return (try? JSONDecoder().decode([LyricsCandidate].self, from: data)) ?? []
    }

    /// 404 는 nil (allowNotFound), 503·429 는 1초 뒤 한 번 재시도
    private func fetch(_ url: URL, allowNotFound: Bool) async throws -> Data? {
        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .seconds(1)); continue }
                throw LRCLIBError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return data
            case 404 where allowNotFound: return nil
            case 429 where attempt == 0, 500...599 where attempt == 0:
                try? await Task.sleep(for: .seconds(1))
            default:
                throw LRCLIBError.http(status)
            }
        }
        throw LRCLIBError.http(503)
    }

    // MARK: - Cache

    private struct CacheEntry: Codable {
        let result: LyricsLookupResult
        let fetchedAt: Date
    }

    private func cacheURL(for track: TrackInfo) -> URL? {
        // 제목·아티스트·길이로 키를 만든다 (persistent ID 는 기기·재설치마다 바뀔 수 있어 쓰지 않는다)
        let key = "\(track.title)|\(track.artist)|\(Int(track.duration.rounded()))"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent("\(digest).json")
    }

    private func readCache(for track: TrackInfo) -> LyricsLookupResult? {
        guard let url = cacheURL(for: track),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data)
        else { return nil }
        if case .notFound = entry.result, Date().timeIntervalSince(entry.fetchedAt) > notFoundTTL { return nil }
        return entry.result
    }

    private func store(_ result: LyricsLookupResult, for track: TrackInfo) -> LyricsLookupResult {
        if let url = cacheURL(for: track), let data = try? JSONEncoder().encode(CacheEntry(result: result, fetchedAt: Date())) {
            try? data.write(to: url, options: .atomic)
        }
        return result
    }
}
