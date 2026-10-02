// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 모든 토큰/TTML/응답은 합성값이다. URLProtocol이 요청을 가로채므로 외부 요청은 없다.

import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct AppleMusicCatalogTests {
    private let track = TrackInfo(id: "fixture", title: "Synthetic Song", artist: "CoNo", album: "", duration: 180)

    @Test func disconnectedAccountRequiresConnectionWithoutHTTP() async throws {
        let store = makeStore()
        let catalog = makeCatalog(store: store)
        await #expect(throws: LyricsAccessError.needsConnection) { try await catalog.candidates(for: track) }
        #expect(AppleCatalogStub.requests.isEmpty)
    }

    @Test func developerTokenProbesAreBoundedAndDoNotRejectUserToken() async throws {
        let store = makeStore()
        try store.save(userToken: "synthetic-user-token", storefront: "kr")
        let bundle = (0..<6).map { Self.token(expiry: Date().timeIntervalSince1970 + 7_200 + Double($0)) }.joined(separator: " ")
        let catalog = makeCatalog(store: store) { request in
            if request.url?.path.hasSuffix(".js") == true { return .init(data: Data(bundle.utf8)) }
            if request.url?.path.hasSuffix("/search") == true { return .init(status: 401) }
            return nil
        }
        await #expect(throws: LyricsAccessError.authorization(401)) { try await catalog.candidates(for: track) }
        #expect(AppleCatalogStub.requests.filter { $0.url?.path.hasSuffix("/search") == true }.count == 3)
        #expect(AppleCatalogStub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Media-User-Token") == nil })
        #expect(try !store.snapshot().rejected)
    }

    @Test(arguments: ["/us/browse", "/v1/catalog/us/search", "/v1/catalog/kr/songs/42/syllable-lyrics"])
    func malformedSuccessIsAnError(_ malformedPath: String) async throws {
        let store = makeStore()
        try store.save(userToken: "synthetic-user-token", storefront: "kr")
        let catalog = makeCatalog(store: store) { request in
            request.url?.path == malformedPath ? .init(data: Data("unexpected html".utf8)) : nil
        }
        await #expect(throws: LyricsAccessError.invalidBody) { try await catalog.candidates(for: track) }
    }

    @Test func missingSyllablesFallsBackToLineLyricsOnlyOn404() async throws {
        let store = makeStore()
        try store.save(userToken: "synthetic-user-token", storefront: "kr")
        let catalog = makeCatalog(store: store) { request in
            request.url?.path.hasSuffix("/syllable-lyrics") == true ? .init(status: 404) : nil
        }
        let candidates = try await catalog.candidates(for: track)
        #expect(candidates.count == 1)
        #expect(candidates.first?.source == .appleMusic)
        #expect(AppleCatalogStub.requests.contains { $0.url?.path.hasSuffix("/lyrics") == true })
        #expect(AppleCatalogStub.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("CoNo/") == true })
    }

    @Test func subscriberAuthenticationFailureMarksCurrentAccount() async throws {
        let store = makeStore()
        try store.save(userToken: "synthetic-user-token", storefront: "kr")
        let catalog = makeCatalog(store: store) { request in
            request.url?.path.hasSuffix("/syllable-lyrics") == true ? .init(status: 403) : nil
        }
        await #expect(throws: LyricsAccessError.authorization(403)) { try await catalog.candidates(for: track) }
        #expect(try store.snapshot().rejected)
        #expect(AppleCatalogStub.requests.last?.value(forHTTPHeaderField: "Media-User-Token") == "synthetic-user-token")
    }

    @Test(arguments: [200, 403])
    func staleLyricsCannotApplyOrRejectNewConnection(_ status: Int) async throws {
        let store = makeStore()
        try store.save(userToken: "old-synthetic-token", storefront: "kr")
        let catalog = makeCatalog(store: store) { request in
            guard request.url?.path.hasSuffix("/syllable-lyrics") == true else { return nil }
            do { try store.save(userToken: "new-synthetic-token", storefront: "us") }
            catch { Issue.record("합성 재연결 저장 실패") }
            return .init(status: status, data: Self.lyricsBody)
        }
        await #expect(throws: CancellationError.self) { try await catalog.candidates(for: track) }
        let current = try store.snapshot()
        #expect(current.userToken == "new-synthetic-token" && current.storefront == "us" && !current.rejected)
    }

    @Test func staleStorefrontCannotOverwriteReconnectedRegion() async throws {
        let store = makeStore()
        try store.save(userToken: "old-synthetic-token", storefront: "")
        let catalog = makeCatalog(store: store) { request in
            guard request.url?.path == "/v1/me/storefront" else { return nil }
            do { try store.save(userToken: "new-synthetic-token", storefront: "kr") }
            catch { Issue.record("합성 재연결 저장 실패") }
            return .init(data: Data(#"{"data":[{"id":"us"}]}"#.utf8))
        }
        await #expect(throws: CancellationError.self) { try await catalog.candidates(for: track) }
        #expect(try store.snapshot().storefront == "kr")
    }

    @Test func invalidStorefrontResponseCannotBecomeAURLPath() async throws {
        let store = makeStore()
        try store.save(userToken: "synthetic-user-token", storefront: "")
        let catalog = makeCatalog(store: store) { request in
            request.url?.path == "/v1/me/storefront" ? .init(data: Data(#"{"data":[{"id":"../us"}]}"#.utf8)) : nil
        }
        await #expect(throws: LyricsAccessError.invalidBody) { try await catalog.candidates(for: track) }
        #expect(try store.snapshot().storefront.isEmpty)
    }

    private func makeStore() -> AppleMusicCredentialStore {
        AppleMusicCredentialStore(persistence: AppleCredentialTestPersistence())
    }

    private func makeCatalog(store: AppleMusicCredentialStore,
                             override: @escaping @Sendable (URLRequest) -> AppleCatalogStub.Reply? = { _ in nil }) -> AppleMusicCatalog {
        let token = Self.token(expiry: Date().timeIntervalSince1970 + 7_200)
        AppleCatalogStub.configure { request in
            if let response = override(request) { return response }
            let path = request.url!.path
            if path == "/us/browse" { return .init(data: Data(#"<script src="/assets/index~fixture.js"></script>"#.utf8)) }
            if path.hasSuffix(".js") { return .init(data: Data(token.utf8)) }
            if path == "/v1/me/storefront" { return .init(data: Data(#"{"data":[{"id":"kr"}]}"#.utf8)) }
            if path.hasSuffix("/search") {
                return .init(data: Data(#"{"results":{"songs":{"data":[{"id":"42","attributes":{"name":"Synthetic Song","artistName":"CoNo","durationInMillis":180000,"hasTimeSyncedLyrics":true}}]}}}"#.utf8))
            }
            if path.hasSuffix("/lyrics") || path.hasSuffix("/syllable-lyrics") { return .init(data: Self.lyricsBody) }
            return .init(status: 404)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleCatalogStub.self]
        return AppleMusicCatalog(http: LyricsHTTPClient(configuration: configuration), credentials: store)
    }

    private static var lyricsBody: Data {
        Data(#"{"data":[{"attributes":{"ttml":"<tt><body><p begin='1s' end='2s'>직접 만든 합성 문장</p></body></tt>"}}]}"#.utf8)
    }

    private static func token(expiry: Double) -> String {
        func base64(_ string: String) -> String {
            Data(string.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return base64(#"{"alg":"ES256","kid":"synthetic-key"}"#) + "." +
            base64("{\"exp\":\(expiry),\"iss\":\"synthetic-fixture-team\"}") + ".synthetic-signature-no-credentials"
    }
}

private final class AppleCatalogStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var data = Data() }
    struct State { var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(status: 500) }; var requests: [URLRequest] = [] }
    private static let state = Mutex(State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func configure(_ handler: @escaping @Sendable (URLRequest) -> Reply) { state.withLock { $0 = State(handler: handler) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.withLock { value in value.requests.append(request); return value.handler }
        let reply = handler(request)
        guard let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
