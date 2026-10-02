// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Synchronization
import Testing

@Suite(.serialized)
struct LyricsAccessTests {
    private let track = TrackInfo(id: "fixture", title: "직접 만든 곡", artist: "CoNo", album: "", duration: 180)

    @Test func onlyKnownHTTPSOriginsReceiveRequestsAndCredentials() throws {
        #expect(LyricsHTTPPolicy.allows(URL(string: "https://lrclib.net/api/search")!, service: .lrclib))
        for raw in ["http://lrclib.net/api", "https://lrclib.net.evil.example/api", "https://lrclib.net:8443/api",
                    "https://secret@lrclib.net/api", "https://lrclib.net/api#token", "https://music.163.com/api"] {
            #expect(!LyricsHTTPPolicy.allows(URL(string: raw)!, service: .lrclib))
        }
        let original = URL(string: "https://amp-api.music.apple.com/v1/me")!
        #expect(LyricsHTTPPolicy.allowsRedirect(from: original, to: URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!))
        for raw in ["https://music.apple.com/", "https://example.com/", "http://amp-api.music.apple.com/", "https://amp-api.music.apple.com:8080/"] {
            #expect(!LyricsHTTPPolicy.allowsRedirect(from: original, to: URL(string: raw)!))
        }
    }

    @Test func retryAfterAcceptsSecondsAndHTTPDateWithoutOverflow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LyricsHTTPPolicy.retryDate("120", now: now, fallback: 30) == now.addingTimeInterval(120))
        #expect(LyricsHTTPPolicy.retryDate("Tue, 14 Nov 2023 22:15:20 GMT", now: now, fallback: 30) == now.addingTimeInterval(120))
        #expect(LyricsHTTPPolicy.retryDate("garbled", now: now, fallback: 30) == now.addingTimeInterval(30))
        #expect(LyricsHTTPPolicy.retryDate("0", now: now, fallback: 30) > now)
        #expect(LyricsHTTPPolicy.retryDate("1e300", now: now, fallback: 30).timeIntervalSince(now) == 31_536_000)
    }

    @Test func throttlingAndOutagesAreNotRetriedOnAnotherButtonPress() async throws {
        for status in [429, 503] {
            LyricsStubProtocol.configure { _ in .init(status: status, headers: ["Retry-After": "120"]) }
            let client = makeClient()
            for _ in 0..<2 {
                do { _ = try await client.data(for: request(), service: .lrclib); Issue.record("제한 응답이 성공이 되면 안 된다") }
                catch let error as LyricsAccessError {
                    switch (status, error) {
                    case (429, .rateLimited), (503, .unavailable): break
                    default: Issue.record("잘못 분류된 제한: \(error)")
                    }
                }
            }
            #expect(LyricsStubProtocol.requests.count == 1)
        }
    }

    @Test func laterShorterOutageDoesNotReduceAnActiveRateLimit() async throws {
        LyricsStubProtocol.configure { request in
            let limited = request.url?.lastPathComponent == "rate"
            return .init(status: limited ? 429 : 503, headers: ["Retry-After": limited ? "120" : "15"], deferred: true)
        }
        let client = makeClient()
        let first = Task { try? await client.data(for: URLRequest(url: URL(string: "https://lrclib.net/api/rate")!), service: .lrclib) }
        let second = Task { try? await client.data(for: URLRequest(url: URL(string: "https://lrclib.net/api/outage")!), service: .lrclib) }
        try await waitForRequests(2)
        LyricsStubProtocol.resume(pathComponent: "rate")
        _ = await first.value
        LyricsStubProtocol.resume(pathComponent: "outage")
        _ = await second.value
        do {
            _ = try await client.data(for: request(), service: .lrclib)
            Issue.record("기존 대기시간이 유지되어야 한다")
        } catch let issue as LyricsAccessError {
            guard case let .rateLimited(until) = issue else { Issue.record("긴 429 제한이 대체됐다: \(issue)"); return }
            #expect(until.timeIntervalSinceNow > 100)
        }
        #expect(LyricsStubProtocol.requests.count == 2, "대기 중 세 번째 요청은 전송하지 않는다")
    }

    @Test func authenticationTLSAndOversizedBodiesAreSeparateFailures() async throws {
        for status in [401, 403] {
            LyricsStubProtocol.configure { _ in .init(status: status) }
            await #expect(throws: LyricsAccessError.authorization(status)) { _ = try await makeClient().data(for: request(), service: .lrclib) }
        }
        LyricsStubProtocol.configure { _ in .init(failure: .serverCertificateUntrusted) }
        await #expect(throws: LyricsAccessError.secureConnection) { _ = try await makeClient().data(for: request(), service: .lrclib) }
        for declaredSize in [false, true] {
            LyricsStubProtocol.configure { _ in .init(data: Data(repeating: 65, count: 33), headers: declaredSize ? ["Content-Length": "33"] : [:]) }
            await #expect(throws: LyricsAccessError.responseTooLarge) {
                _ = try await makeClient().data(for: request(), service: .lrclib, maximumBytes: 32)
            }
        }
    }

    @Test func cancelledRequestDoesNotReachTransport() async throws {
        LyricsStubProtocol.configure { _ in .init() }
        let client = makeClient()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.data(for: request(), service: .lrclib)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(LyricsStubProtocol.requests.isEmpty)
    }

    @Test @MainActor func staleCompletionCannotOverwriteNewRequestStatus() {
        let monitor = LyricsServiceMonitor()
        let first = monitor.begin(.lrclib)
        let second = monitor.begin(.lrclib)
        monitor.record(.lrclib, .reachable, requestID: second)
        monitor.record(.lrclib, .failed(.authorization(401)), requestID: first)
        #expect(monitor.snapshots[.lrclib]?.state == .reachable)
    }

    @Test func staleProviderParsingCannotOverwriteANewerCachedLookupStatus() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = TrackInfo(id: "old", title: "이전 곡", artist: "CoNo", album: "", duration: 180)
        LyricsStubProtocol.configure { request in
            let title = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "track_name" }?.value
            if title == old.title { return .init(data: Data("broken JSON".utf8), deferred: true) }
            return .init(status: request.url?.lastPathComponent == "get" ? 404 : 200, data: Data("[]".utf8))
        }
        let client = LRCLIBClient(http: makeClient(), cacheDirectory: directory)
        let earlier = Task { try await client.lyrics(for: old) }
        try await waitForRequests(1)
        _ = try await client.lyrics(for: track)
        _ = try await client.lyrics(for: track)
        #expect(await LyricsServiceMonitor.shared.snapshots[.lrclib]?.state == .cached)
        LyricsStubProtocol.resume(pathComponent: "get")
        await #expect(throws: LyricsAccessError.invalidBody) { _ = try await earlier.value }
        #expect(await LyricsServiceMonitor.shared.snapshots[.lrclib]?.state == .cached,
                "예전 조회의 HTTP 성공과 파싱 실패가 최신 캐시 조회 상태를 덮지 않는다")
    }

    @Test @MainActor func implicitProviderReportsUseTheirLogicalOperationAcrossHTTPCalls() async throws {
        LyricsStubProtocol.configure { _ in .init(data: Data("[]".utf8)) }
        let client = makeClient()
        let monitor = LyricsServiceMonitor.shared
        let old = monitor.begin(.netease)
        let newest = monitor.begin(.netease)
        let request = URLRequest(url: URL(string: "https://music.163.com/api/search")!)
        try await LyricsServiceOperation.$current.withValue(.init(service: .netease, id: old)) {
            _ = try await client.data(for: request, service: .netease)
            monitor.record(.netease, .failed(.invalidBody))
            monitor.record(.netease, .idle)
        }
        #expect(monitor.snapshots[.netease]?.state == .loading)
        try await LyricsServiceOperation.$current.withValue(.init(service: .netease, id: newest)) {
            _ = try await client.data(for: request, service: .netease)
            monitor.record(.netease, .cached)
        }
        #expect(monitor.snapshots[.netease]?.state == .cached)
    }

    @Test func malformedSuccessNeverBecomesNegativeCache() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { _ in .init(data: Data("<html>service changed</html>".utf8)) }
        let client = LRCLIBClient(http: makeClient(), cacheDirectory: directory)
        for _ in 0..<2 { await #expect(throws: LyricsAccessError.invalidBody) { _ = try await client.lyrics(for: track) } }
        #expect(LyricsStubProtocol.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func validEmptySearchIsCachedButMetadataRestrictionsDoNotBreakFallback() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { request in .init(status: request.url?.lastPathComponent == "get" ? 404 : 200, data: Data("[]".utf8)) }
        let unknown = TrackInfo(id: "unknown", title: "직접 만든 곡", artist: "", album: "", duration: 7_200)
        let client = LRCLIBClient(http: makeClient(), cacheDirectory: directory)
        guard case .notFound = try await client.lyrics(for: unknown) else { Issue.record("빈 검색 결과"); return }
        let count = LyricsStubProtocol.requests.count
        #expect(count > 0)
        #expect(LyricsStubProtocol.requests.allSatisfy { $0.url?.lastPathComponent == "search" })
        guard case .notFound = try await client.lyrics(for: unknown) else { Issue.record("캐시된 빈 검색 결과"); return }
        #expect(LyricsStubProtocol.requests.count == count)
        _ = try await client.lyrics(for: unknown, bypassCache: true)
        #expect(LyricsStubProtocol.requests.count == count * 2, "사용자 재검색은 기존 빈 캐시를 건너뛴다")
    }

    @Test func invalidDurationIsOmittedFromExactRequest() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { request in .init(status: request.url?.lastPathComponent == "get" ? 404 : 200, data: Data("[]".utf8)) }
        let long = TrackInfo(id: "long", title: track.title, artist: track.artist, album: "", duration: 7_200)
        _ = try await LRCLIBClient(http: makeClient(), cacheDirectory: directory).lyrics(for: long)
        let exact = try #require(LyricsStubProtocol.requests.first?.url)
        #expect(exact.lastPathComponent == "get")
        #expect(URLComponents(url: exact, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "duration" } == false)
    }

    @Test func laterFailureKeepsExactLyricsWithoutCachingPartialResult() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let body = try JSONEncoder().encode(LyricsCandidate(id: 1, trackName: track.title, artistName: track.artist,
            albumName: "", duration: 180, instrumental: false, plainLyrics: "첫 줄", syncedLyrics: "[00:01]첫 줄"))
        LyricsStubProtocol.configure { request in .init(data: request.url?.lastPathComponent == "get" ? body : Data("broken".utf8)) }
        let client = LRCLIBClient(http: makeClient(), cacheDirectory: directory)
        guard case let .synced(candidates) = try await client.lyrics(for: track) else { Issue.record("정상 후보는 남아 있어야 한다"); return }
        #expect(candidates.count == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func providerFailureDoesNotBecomeCachedAbsence() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { _ in .init(data: Data("{}".utf8)) }
        let client = ExtraLyricsSources(http: makeClient(), cacheDirectory: directory)
        for _ in 0..<2 { await #expect(throws: LyricsAccessError.invalidBody) { _ = try await client.candidates(for: track, sources: [.netease]) } }
        #expect(LyricsStubProtocol.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func successfulProviderRemainsUsableWhileAnotherFailureStaysVisible() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { request in
            if request.url?.host == "raw.githubusercontent.com" { return .init(data: Data("broken index".utf8)) }
            let body = request.url?.path.contains("cloudsearch") == true
                ? #"{"code":200,"result":{"songs":[{"id":1,"name":"직접 만든 곡","ar":[{"name":"CoNo"}],"dt":180000}]}}"#
                : #"{"code":200,"lrc":{"lyric":"[00:01]첫 줄\n[00:05]둘째 줄\n[00:10]셋째 줄"}}"#
            return .init(data: Data(body.utf8))
        }
        let client = ExtraLyricsSources(http: makeClient(), cacheDirectory: directory)
        for _ in 0..<2 {
            let candidates = try await client.candidates(for: track, sources: [.netease, .amll])
            #expect(candidates.count == 1 && candidates.first?.origin == .netease)
            #expect(await LyricsServiceMonitor.shared.snapshots[.amll]?.state == .failed(.invalidBody))
        }
        #expect(await LyricsServiceMonitor.shared.snapshots[.netease]?.state == .cached)
        #expect(LyricsStubProtocol.requests.filter { $0.url?.host == "raw.githubusercontent.com" }.count == 2,
                "AMLL의 실패는 빈 결과로 캐시하지 않는다")
    }

    @Test func malformedLyricInsideValidJSONDoesNotBecomePermanentSyncedCache() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let body = try JSONEncoder().encode(LyricsCandidate(id: 1, trackName: track.title, artistName: track.artist,
            albumName: "", duration: 180, instrumental: false, plainLyrics: nil, syncedLyrics: "this is no longer LRC"))
        LyricsStubProtocol.configure { _ in .init(data: body) }
        let client = LRCLIBClient(http: makeClient(), cacheDirectory: directory)
        for _ in 0..<2 { await #expect(throws: LyricsAccessError.invalidBody) { _ = try await client.lyrics(for: track) } }
        #expect(LyricsStubProtocol.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func neteaseMissingLyricFieldIsNotAValidEmptyResult() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        LyricsStubProtocol.configure { request in
            let body = request.url?.path.contains("cloudsearch") == true
                ? #"{"code":200,"result":{"songs":[{"id":1,"name":"직접 만든 곡","ar":[{"name":"CoNo"}],"dt":180000}]}}"#
                : #"{"code":200,"lrc":{}}"#
            return .init(data: Data(body.utf8))
        }
        let client = ExtraLyricsSources(http: makeClient(), cacheDirectory: directory)
        for _ in 0..<2 { await #expect(throws: LyricsAccessError.invalidBody) { _ = try await client.candidates(for: track, sources: [.netease]) } }
        #expect(LyricsStubProtocol.requests.count == 4)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func failedAMLLRefreshPreservesLastValidIndex() async throws {
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("amll-index.jsonl")
        let body = Data(#"{"metadata":[["musicName",["다른 곡"]],["artists",["다른 가수"]]],"rawLyricFile":"fixture.ttml"}"#.utf8)
        try body.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        LyricsStubProtocol.configure { _ in .init(data: Data("<html>unavailable</html>".utf8)) }
        let client = ExtraLyricsSources(http: makeClient(), cacheDirectory: directory)
        await #expect(throws: LyricsAccessError.invalidBody) { _ = try await client.candidates(for: track, sources: [.amll]) }
        #expect(try Data(contentsOf: file) == body)
    }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cono-access-\(UUID())") }
    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if LyricsStubProtocol.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    private func request() -> URLRequest { URLRequest(url: URL(string: "https://lrclib.net/api/search?q=fixture")!) }
    private func makeClient() -> LyricsHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsStubProtocol.self]
        return LyricsHTTPClient(configuration: configuration)
    }
}

/// Synthetic transport only: no account credentials or published lyrics leave the test process.
private final class LyricsStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var failure: URLError.Code?
        var deferred = false
    }
    private struct State {
        var reply: @Sendable (URLRequest) -> Reply = { _ in Reply() }
        var requests: [URLRequest] = []
        var pending: [LyricsStubProtocol] = []
    }
    private static let state = Mutex(State())
    private let pendingReply = Mutex<Reply?>(nil)
    private let stopped = Mutex(false)
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func configure(_ reply: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(reply: reply) }
    }
    static func resume(pathComponent: String) {
        let pending = state.withLock { value -> LyricsStubProtocol? in
            guard let index = value.pending.firstIndex(where: { $0.request.url?.lastPathComponent == pathComponent }) else { return nil }
            return value.pending.remove(at: index)
        }
        guard let pending, let reply = pending.pendingReply.withLock({ $0 }) else { return }
        pending.deliver(reply)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { value in
            let reply = value.reply(request)
            if reply.deferred {
                pendingReply.withLock { $0 = reply }
                value.pending.append(self)
            }
            value.requests.append(request)
            return reply
        }
        if reply.deferred { return }
        deliver(reply)
    }
    private func deliver(_ reply: Reply) {
        guard !stopped.withLock({ $0 }) else { return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
