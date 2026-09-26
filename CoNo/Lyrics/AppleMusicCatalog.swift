// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Apple Music 음절 가사 (#4, 설정에서 켜는 선택 기능 — 비공개 엔드포인트).
// 공식 음절 단위 싱크라 품질이 가장 좋다. 앱(음악 앱) 을 가로채는 길은 없다: 가사는 디스크에 남지 않고,
// AppleScript `lyrics` 는 스트리밍 곡에서 빈 문자열이다 (lyrimuse 실측, GPL-3 — 이 파일의 흐름은 그 조사를 참고했다).
//
//   ① 개발자 토큰: music.apple.com 이 공개로 내려주는 JS 번들 안의 JWT 후보 중 카탈로그 검색이 되는 것 (계정 불필요)
//   ② 카탈로그 검색: /v1/catalog/{storefront}/search — 개발자 토큰만 (hasTimeSyncedLyrics 로 미리 거른다)
//   ③ 가사: /songs/{id}/syllable-lyrics (음절) → 없으면 /lyrics (줄). 구독자의 media-user-token 필요
//      (없으면 404 "No related resources" — 401 이 아님). 토큰은 6개월, 연장 불가 → 401/403 이면 다시 연결.
// storefront 는 사용자의 구독 지역이어야 한다 (가사 요청의 인증 조건).

import Foundation
import Security

/// 사용자 토큰(키체인)과 지역·저장 시각(UserDefaults). 토큰은 로그에 남기지 않는다.
enum AppleMusicCredentials {
    private static let service = "space.knowai.cono.applemusic"
    private static let account = "media-user-token"
    private static let defaultsPrefix = "space.knowai.cono.applemusic."
    /// Apple 이 정한 사용자 토큰 수명 (연장 불가)
    static let lifetime: TimeInterval = 180 * 24 * 60 * 60

    static var userToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var storefront: String {
        get { UserDefaults.standard.string(forKey: defaultsPrefix + "storefront") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultsPrefix + "storefront") }
    }

    static var savedAt: Date? {
        UserDefaults.standard.object(forKey: defaultsPrefix + "savedAt") as? Date
    }

    /// 토큰이 거부된 적 있음 (만료·취소) — 설정 창이 "다시 연결" 을 안내한다
    static var rejected: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsPrefix + "rejected") }
        set { UserDefaults.standard.set(newValue, forKey: defaultsPrefix + "rejected") }
    }

    static func save(userToken: String, storefront: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(userToken.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
        self.storefront = storefront
        UserDefaults.standard.set(Date(), forKey: defaultsPrefix + "savedAt")
        rejected = false
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        for key in ["storefront", "savedAt", "rejected"] {
            UserDefaults.standard.removeObject(forKey: defaultsPrefix + key)
        }
    }
}

actor AppleMusicCatalog {
    static let shared = AppleMusicCatalog()

    private let session: URLSession
    private var developerToken: String?
    private static let web = "https://music.apple.com"
    private static let api = "https://amp-api.music.apple.com/v1/"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    /// 이 곡의 Apple Music 싱크 가사 후보 (연결 안 됐거나 실패하면 빈 목록)
    func candidates(for track: TrackInfo) async -> [LyricsCandidate] {
        guard let userToken = AppleMusicCredentials.userToken, !track.title.isEmpty,
              let devToken = await ensureDeveloperToken(),
              let storefront = await ensureStorefront(devToken: devToken, userToken: userToken)
        else { return [] }

        // ② 검색 (가사 시간 정보가 있는 곡만)
        var components = URLComponents(string: Self.api + "catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "term", value: "\(track.title) \(track.artist)"),
        ]
        guard let (data, status) = await get(components.urlEncodingPlus, devToken: devToken, userToken: nil), status == 200,
              let songs = try? JSONDecoder().decode(SearchResponse.self, from: data).results.songs?.data
        else { return [] }
        let matching = songs.filter { song in
            let a = song.attributes
            guard a.hasTimeSyncedLyrics == true,
                  LyricsSelector.titlesMatch(a.name, track.title),
                  LyricsSelector.artistsMatch(a.artistName, track.artist)
            else { return false }
            guard track.durationIsReliable, track.duration > 0, let ms = a.durationInMillis else { return true }
            return abs(ms / 1000 - track.duration) <= LyricsSelector.maxDurationDifference
        }

        // ③ 가사 (음절 → 줄)
        var result: [LyricsCandidate] = []
        for song in matching.prefix(2) {
            guard let lrc = await lyrics(songID: song.id, storefront: storefront, devToken: devToken, userToken: userToken) else { continue }
            result.append(LyricsCandidate(
                id: Int(song.id) ?? 0,
                trackName: song.attributes.name,
                artistName: song.attributes.artistName,
                albumName: song.attributes.albumName,
                duration: song.attributes.durationInMillis.map { $0 / 1000 },
                instrumental: false,
                plainLyrics: nil,
                syncedLyrics: lrc,
                source: .appleMusic
            ))
        }
        return result
    }

    private func lyrics(songID: String, storefront: String, devToken: String, userToken: String) async -> String? {
        for kind in ["syllable-lyrics", "lyrics"] {
            guard let url = URL(string: Self.api + "catalog/\(storefront)/songs/\(songID)/\(kind)"),
                  let (data, status) = await get(url, devToken: devToken, userToken: userToken)
            else { continue }
            switch status {
            case 200:
                if let ttml = try? JSONDecoder().decode(LyricsResponse.self, from: data).data.first?.attributes.ttml,
                   let lrc = TTMLLyrics.lrc(from: ttml) {
                    return lrc
                }
            case 401, 403:
                // 사용자 토큰 만료·취소 (6개월, 연장 불가) → 다시 연결 안내
                AppleMusicCredentials.rejected = true
                return nil
            default:
                continue // 404 = 이 종류의 가사가 없음 (정상)
            }
        }
        return nil
    }

    // MARK: - 토큰·지역

    /// ① music.apple.com 의 JS 번들에서 JWT 후보를 뽑아, 카탈로그 검색이 되는 첫 번째를 쓴다
    /// (번들엔 용도가 다른 JWT 가 여러 개 있어 모양만으론 못 가린다).
    private func ensureDeveloperToken() async -> String? {
        if let developerToken, let expiry = Self.expiry(of: developerToken), expiry > Date().addingTimeInterval(3600) {
            return developerToken
        }
        developerToken = nil
        guard let (home, _) = await get(URL(string: Self.web + "/us/browse")!, devToken: nil, userToken: nil),
              let html = String(data: home, encoding: .utf8),
              let asset = html.range(of: #"/assets/index[~-][A-Za-z0-9_-]+\.js"#, options: .regularExpression).map({ String(html[$0]) }),
              let (bundle, _) = await get(URL(string: Self.web + asset)!, devToken: nil, userToken: nil),
              let js = String(data: bundle, encoding: .utf8)
        else { return nil }
        for candidate in Self.jwtCandidates(in: js) {
            let probe = URL(string: Self.api + "catalog/us/search?types=songs&limit=1&term=a")!
            if let (_, status) = await get(probe, devToken: candidate, userToken: nil), status == 200 {
                developerToken = candidate
                return candidate
            }
        }
        return nil
    }

    /// 구독 지역. 로그인 때 쿠키(itua)로 못 얻었으면 계정에 묻는다.
    private func ensureStorefront(devToken: String, userToken: String) async -> String? {
        let saved = AppleMusicCredentials.storefront
        if !saved.isEmpty { return saved }
        guard let (data, status) = await get(URL(string: Self.api + "me/storefront")!, devToken: devToken, userToken: userToken),
              status == 200,
              let id = try? JSONDecoder().decode(StorefrontResponse.self, from: data).data.first?.id
        else { return nil }
        AppleMusicCredentials.storefront = id
        return id
    }

    static func jwtCandidates(in js: String) -> [String] {
        let pattern = #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{50,}\.[A-Za-z0-9_-]{20,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        let found = regex.matches(in: js, range: NSRange(js.startIndex..., in: js)).compactMap { match -> String? in
            guard let range = Range(match.range, in: js) else { return nil }
            let token = String(js[range])
            return seen.insert(token).inserted ? token : nil
        }
        // 만료가 늦은 것부터, 이미 만료된 것은 뺀다
        return found
            .compactMap { token in expiry(of: token).map { (token, $0) } }
            .filter { $0.1 > Date() }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// JWT 의 exp
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - HTTP

    /// amp-api 는 Origin 이 Apple 사이트여야 한다 (없으면 403)
    private func get(_ url: URL, devToken: String?, userToken: String?) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.web, forHTTPHeaderField: "Origin")
        if let devToken { request.setValue("Bearer \(devToken)", forHTTPHeaderField: "Authorization") }
        if let userToken { request.setValue(userToken, forHTTPHeaderField: "Media-User-Token") }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
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
