// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Apple 웹 플레이어의 비공개 가사 경로와 호환하는 선택 기능. 공식 MusicKit 가사 API가 아니다.
// 기존 music.apple.com JS의 개발자 JWT → amp-api 카탈로그/TTML 흐름만 유지한다.
// 새 토큰 발급·접근 제한 우회는 하지 않으며 사용자의 Music User Token을 로그/디스크 캐시에 남기지 않는다.

import Foundation
import Security

/// 기존 키체인 식별자는 사용자 연결을 보존하기 위해 그대로 쓴다.
enum AppleMusicCredentials {
    static let store = AppleMusicCredentialStore(persistence: KeychainPersistence())

    private struct KeychainPersistence: AppleMusicCredentialPersistence {
        private static let service = "space.knowai.cono.applemusic"
        private static let account = "media-user-token"
        private static let defaultsPrefix = "space.knowai.cono.applemusic."

        private var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
        }

        func readToken() throws -> String? {
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw AppleMusicCredentialError.keychain(operation: "읽기", status: status) }
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
                throw AppleMusicCredentialError.invalidToken
            }
            return token
        }

        func writeToken(_ token: String) throws {
            let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                attributes.forEach { item[$0.key] = $0.value }
                status = SecItemAdd(item as CFDictionary, nil)
                // 다른 프로세스가 같은 항목을 먼저 만든 경우에도 기존 항목을 지우지 않는다.
                if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
            }
            guard status == errSecSuccess else { throw AppleMusicCredentialError.keychain(operation: "저장", status: status) }
        }

        func deleteToken() throws {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppleMusicCredentialError.keychain(operation: "삭제", status: status)
            }
        }

        func readMetadata() -> AppleMusicCredentialMetadata {
            let defaults = UserDefaults.standard
            return AppleMusicCredentialMetadata(storefront: defaults.string(forKey: Self.defaultsPrefix + "storefront") ?? "",
                savedAt: defaults.object(forKey: Self.defaultsPrefix + "savedAt") as? Date,
                rejected: defaults.bool(forKey: Self.defaultsPrefix + "rejected"))
        }

        func writeMetadata(_ metadata: AppleMusicCredentialMetadata) {
            let defaults = UserDefaults.standard
            defaults.set(metadata.storefront, forKey: Self.defaultsPrefix + "storefront")
            defaults.set(metadata.savedAt, forKey: Self.defaultsPrefix + "savedAt")
            defaults.set(metadata.rejected, forKey: Self.defaultsPrefix + "rejected")
        }
    }
}

actor AppleMusicCatalog {
    static let shared = AppleMusicCatalog()
    private let http: LyricsHTTPClient
    private let credentials: AppleMusicCredentialStore
    private var developerToken: String?
    private static let web = "https://music.apple.com"
    private static let api = "https://amp-api.music.apple.com/v1/"

    init(http: LyricsHTTPClient = .shared, credentials: AppleMusicCredentialStore = AppleMusicCredentials.store) {
        self.http = http
        self.credentials = credentials
    }

    func candidates(for track: TrackInfo) async throws -> [LyricsCandidate] {
        var snapshot = try credentials.snapshot()
        guard snapshot.userToken != nil else { throw LyricsAccessError.needsConnection }
        try requireCurrent(snapshot)
        guard !track.title.isEmpty else { return [] }
        let devToken = try await ensureDeveloperToken(snapshot: snapshot)
        snapshot = try await ensureStorefront(devToken: devToken, snapshot: snapshot)
        let storefront = snapshot.storefront
        var components = URLComponents(string: Self.api + "catalog/\(storefront)/search")!
        components.queryItems = [URLQueryItem(name: "types", value: "songs"), URLQueryItem(name: "limit", value: "10"),
                                 URLQueryItem(name: "term", value: "\(track.title) \(track.artist)")]
        let (data, _) = try await get(components.urlEncodingPlus, devToken: devToken, snapshot: snapshot, subscriber: false)
        let response: SearchResponse = try decode(data)
        let matching = (response.results.songs?.data ?? []).filter { song in
            let attributes = song.attributes
            guard attributes.hasTimeSyncedLyrics == true, LyricsSelector.titlesMatch(attributes.name, track.title),
                  LyricsSelector.artistsMatch(attributes.artistName, track.artist) else { return false }
            guard track.durationIsReliable, track.duration > 0, let milliseconds = attributes.durationInMillis else { return true }
            return abs(milliseconds / 1000 - track.duration) <= LyricsSelector.maxDurationDifference
        }
        var candidates: [LyricsCandidate] = []
        for song in matching.prefix(2) {
            // 응답 ID가 URL 경로를 바꾸지 못하게 숫자 식별자만 받는다.
            guard !song.id.isEmpty, song.id.utf8.count <= 20, song.id.utf8.allSatisfy({ (48...57).contains($0) }),
                  let identifier = Int(song.id), identifier > 0 else { throw LyricsAccessError.invalidBody }
            guard let lrc = try await lyrics(songID: song.id, devToken: devToken, snapshot: snapshot) else { continue }
            candidates.append(LyricsCandidate(id: identifier, trackName: song.attributes.name,
                artistName: song.attributes.artistName, albumName: song.attributes.albumName,
                duration: song.attributes.durationInMillis.map { $0 / 1000 }, instrumental: false,
                plainLyrics: nil, syncedLyrics: lrc, source: .appleMusic))
        }
        try requireCurrent(snapshot)
        return candidates
    }

    private func lyrics(songID: String, devToken: String, snapshot: AppleMusicCredentialSnapshot) async throws -> String? {
        for kind in ["syllable-lyrics", "lyrics"] {
            let url = URL(string: Self.api + "catalog/\(snapshot.storefront)/songs/\(songID)/\(kind)")!
            let (data, response) = try await get(url, devToken: devToken, snapshot: snapshot, subscriber: true,
                                                acceptedStatus: [200, 404])
            if response.statusCode == 404 { continue }
            let decoded: LyricsResponse = try decode(data)
            guard let ttml = decoded.data.first?.attributes.ttml, !ttml.isEmpty,
                  let lrc = TTMLLyrics.lrc(from: ttml) else { throw LyricsAccessError.invalidBody }
            return lrc
        }
        return nil
    }

    /// 기존 호환 경로를 유지하되 후보 검증 요청은 최대 3회다. 401/403을 사용자 토큰 거부로 기록하지 않는다.
    private func ensureDeveloperToken(snapshot: AppleMusicCredentialSnapshot) async throws -> String {
        try requireCurrent(snapshot)
        if let developerToken, let expiry = Self.expiry(of: developerToken), expiry > Date().addingTimeInterval(3600) {
            return developerToken
        }
        developerToken = nil
        let (home, _) = try await get(URL(string: Self.web + "/us/browse")!, snapshot: snapshot)
        guard let html = String(data: home, encoding: .utf8),
              let range = html.range(of: #"/assets/index[~-][A-Za-z0-9_-]+\.js"#, options: .regularExpression) else {
            throw LyricsAccessError.invalidBody
        }
        let (bundle, _) = try await get(URL(string: Self.web + String(html[range]))!, snapshot: snapshot, maximumBytes: 8_388_608)
        guard let javascript = String(data: bundle, encoding: .utf8) else { throw LyricsAccessError.invalidBody }
        let candidates = Self.jwtCandidates(in: javascript)
        guard !candidates.isEmpty else { throw LyricsAccessError.invalidBody }
        var lastFailure: LyricsAccessError = .invalidBody
        for candidate in candidates.prefix(3) {
            do {
                let url = URL(string: Self.api + "catalog/us/search?types=songs&limit=1&term=a")!
                let (probe, _) = try await get(url, devToken: candidate, snapshot: snapshot)
                let _: SearchResponse = try decode(probe)
                try requireCurrent(snapshot)
                developerToken = candidate
                return candidate
            } catch let error as LyricsAccessError {
                switch error {
                case .authorization: lastFailure = error
                default: throw error
                }
            }
        }
        throw lastFailure
    }

    private func ensureStorefront(devToken: String, snapshot: AppleMusicCredentialSnapshot) async throws -> AppleMusicCredentialSnapshot {
        try requireCurrent(snapshot)
        if AppleMusicCredentialPolicy.validStorefront(snapshot.storefront) { return snapshot }
        let (data, _) = try await get(URL(string: Self.api + "me/storefront")!, devToken: devToken, snapshot: snapshot, subscriber: true)
        let response: StorefrontResponse = try decode(data)
        guard let id = response.data.first?.id, AppleMusicCredentialPolicy.validStorefront(id) else { throw LyricsAccessError.invalidBody }
        guard let updated = try credentials.setStorefront(id, matching: snapshot) else { throw CancellationError() }
        return updated
    }

    private func requireCurrent(_ snapshot: AppleMusicCredentialSnapshot) throws {
        try Task.checkCancellation()
        guard try credentials.isCurrent(snapshot) else { throw CancellationError() }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LyricsAccessError.invalidBody }
    }

    /// Origin은 기존 웹 플레이어 호환에 필요하다. 브라우저 UA를 사칭하지 않는다.
    private func get(_ url: URL, devToken: String? = nil, snapshot: AppleMusicCredentialSnapshot,
                     subscriber: Bool = false, maximumBytes: Int = 1_048_576,
                     acceptedStatus: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
        try requireCurrent(snapshot)
        var request = URLRequest(url: url)
        request.setValue("CoNo/0.2 (https://www.aib.vote)", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.web, forHTTPHeaderField: "Origin")
        if let devToken { request.setValue("Bearer \(devToken)", forHTTPHeaderField: "Authorization") }
        if subscriber { request.setValue(snapshot.userToken, forHTTPHeaderField: "Media-User-Token") }
        do {
            let result = try await http.data(for: request, service: .appleMusic, maximumBytes: maximumBytes, acceptedStatus: acceptedStatus)
            try requireCurrent(snapshot)
            return result
        } catch {
            // 재연결/해제 뒤 도착한 응답은 새 연결의 인증 상태나 가사에 영향을 주지 않는다.
            try requireCurrent(snapshot)
            if case LyricsAccessError.authorization = error {
                if subscriber { _ = try credentials.reject(snapshot) }
                else { developerToken = nil }
            }
            throw error
        }
    }

    static func jwtCandidates(in javascript: String) -> [String] {
        guard javascript.utf8.count <= 8_388_608 else { return [] }
        let pattern = #"eyJ[A-Za-z0-9_-]{10,2048}\.[A-Za-z0-9_-]{50,8192}\.[A-Za-z0-9_-]{20,2048}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: javascript, range: NSRange(javascript.startIndex..., in: javascript)).compactMap { match -> (String, Date)? in
            guard let range = Range(match.range, in: javascript) else { return nil }
            let token = String(javascript[range])
            guard seen.insert(token).inserted, let expiry = expiry(of: token), expiry > Date() else { return nil }
            return (token, expiry)
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func expiry(of token: String) -> Date? {
        guard token.utf8.count <= 16_384 else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = json["exp"] as? Double, expiry.isFinite, expiry > 0 else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    private struct SearchResponse: Decodable {
        struct Results: Decodable { let songs: Songs? }
        struct Songs: Decodable { let data: [Song] }
        struct Song: Decodable {
            struct Attributes: Decodable {
                let name: String
                let artistName: String
                let albumName: String?
                let durationInMillis: Double?
                let hasTimeSyncedLyrics: Bool?
            }
            let id: String
            let attributes: Attributes
        }
        let results: Results
    }
    private struct LyricsResponse: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable { let ttml: String }
            let attributes: Attributes
        }
        let data: [Item]
    }
    private struct StorefrontResponse: Decodable {
        struct Item: Decodable { let id: String }
        let data: [Item]
    }
}
