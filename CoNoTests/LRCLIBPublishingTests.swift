// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Testing

struct LRCLIBPublishingTests {
    private var payload: LRCLIBPublishPayload {
        LRCLIBPublishPayload(trackName: "합성 테스트", artistName: "CoNo", albumName: "", duration: 180.5,
                             plainLyrics: "첫 줄\n둘째 줄", syncedLyrics: "[00:01.000]첫 줄\n[00:03.000]둘째 줄\n")
    }

    @Test func proofOfWorkMatchesOfficialPrefixConcatenationAndInclusiveTarget() async throws {
        // hashlib.sha256(b"abc0").hexdigest(): 전송 토큰의 콜론을 해시에 넣지 않는다.
        let hash = "56abfbd7d2ea606e667945422de5a368b8b0272b8f29081cb058b594dd7e3249"
        let challenge = LRCLIBChallenge(prefix: "abc", target: hash)
        #expect(try challenge.accepts(nonce: 0))
        #expect(try await challenge.solve(maximumAttempts: 1) == "abc:0")
        #expect(try !LRCLIBChallenge(prefix: "abc", target: String(hash.dropLast()) + "8").accepts(nonce: 0))
    }

    @Test func invalidChallengesAndBoundedWorkFailLocally() async throws {
        for challenge in [LRCLIBChallenge(prefix: "bad:prefix", target: String(repeating: "f", count: 64)),
                          LRCLIBChallenge(prefix: "abc", target: String(repeating: "é", count: 32)),
                          LRCLIBChallenge(prefix: "abc", target: String(repeating: "0", count: 64))] {
            await #expect(throws: LRCLIBPublishError.self) { _ = try await challenge.solve(maximumAttempts: 1) }
        }
        let hard = LRCLIBChallenge(prefix: "abc", target: String(repeating: "0", count: 63) + "1")
        await #expect(throws: LRCLIBPublishError.self) { _ = try await hard.solve(maximumAttempts: 1) }
        let task = Task { try await hard.solve() }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func publishSendsReviewedPayloadOnlyAfterChallengeAndAccepts201() async throws {
        let stub = PublishingStub()
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        try await publisher.publish(payload)
        let requests = await stub.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.lastPathComponent == "request-challenge")
        #expect(requests[0].httpBody == nil)
        #expect(requests[1].url?.absoluteString == "https://lrclib.net/api/publish")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].value(forHTTPHeaderField: "X-Publish-Token") == "fixture:0")
        #expect(try JSONDecoder().decode(LRCLIBPublishPayload.self, from: #require(requests[1].httpBody)) == payload)
    }

    @Test func invalidMetadataNeverRequestsAChallenge() async throws {
        let stub = PublishingStub()
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        let invalid = LRCLIBPublishPayload(trackName: "", artistName: "가수", albumName: "", duration: .nan,
                                           plainLyrics: "가사", syncedLyrics: "[00:01]가사")
        await #expect(throws: LRCLIBPublishError.self) { try await publisher.publish(invalid) }
        #expect(await stub.requests.isEmpty)
    }

    @Test func explicitPlainPublicationUsesEmptySyncedTextAndRejectsEmptyLyrics() async throws {
        let stub = PublishingStub()
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        let plain = LRCLIBPublishPayload(trackName: "직접 쓴 곡", artistName: "CoNo", albumName: "", duration: 180,
                                        plainLyrics: "시간 없는 첫 줄\n둘째 줄", syncedLyrics: "")
        try await publisher.publish(plain)
        let requests = await stub.requests
        #expect(requests.count == 2)
        let sent = try JSONDecoder().decode(LRCLIBPublishPayload.self, from: #require(requests.last?.httpBody))
        #expect(sent == plain)
        #expect(throws: LRCLIBPublishError.self) {
            try LRCLIBPublishPayload(trackName: "곡", artistName: "가수", albumName: "", duration: 100,
                                     plainLyrics: "\n ", syncedLyrics: "").validatedData()
        }
    }

    @Test func publishDoesNotRetryAnAmbiguousNetworkFailure() async throws {
        let stub = PublishingStub(failPublish: true)
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        do {
            try await publisher.publish(payload)
            Issue.record("전송 오류를 성공으로 처리하면 안 된다")
        } catch LRCLIBPublishError.uncertainOutcome { }
        #expect(await stub.requests.count == 2)
    }

    @Test func sharedTransportPreflightRefusalRemainsAConfirmedNonPublication() async throws {
        let until = Date().addingTimeInterval(120)
        for issue in [LyricsAccessError.rateLimited(until), .unavailable(until), .unsafeAddress] {
            let stub = PublishingStub(preflightRefusal: issue)
            let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
            await #expect(throws: issue) { try await publisher.publish(payload) }
            #expect(await stub.requests.count == 1, "공개 transport 진입 전에 거부되어 인증 요청만 전송됐다")
        }
    }

    @Test func postDispatchCancellationAndNetworkFailureRemainUncertain() async throws {
        for issue in [LyricsAccessError.network, .secureConnection] {
            let stub = PublishingStub(publishFailure: issue)
            let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
            do {
                try await publisher.publish(payload)
                Issue.record("전송 도중 연결 오류는 미확정으로 처리해야 한다")
            } catch LRCLIBPublishError.uncertainOutcome { }
            #expect(await stub.requests.count == 2)
        }
        let stub = PublishingStub(cancelPublish: true)
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        do {
            try await publisher.publish(payload)
            Issue.record("전송 도중 취소는 미확정으로 처리해야 한다")
        } catch LRCLIBPublishError.uncertainOutcome { }
        #expect(await stub.requests.count == 2)
    }

    @Test func cancellationDuringSendingStatusNeverTransmitsLyrics() async throws {
        let stub = PublishingStub()
        let publisher = LRCLIBPublisher(transport: { try await stub.reply(to: $0) })
        let payload = payload
        let task = Task {
            try await publisher.publish(payload) { phase in
                if phase == .sending { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await stub.requests.count == 1, "인증 요청만 했고 공개 가사는 아직 전송하지 않는다")
    }
}

private actor PublishingStub {
    private(set) var requests: [URLRequest] = []
    let failPublish: Bool
    let preflightRefusal: LyricsAccessError?
    let publishFailure: LyricsAccessError?
    let cancelPublish: Bool

    init(failPublish: Bool = false, preflightRefusal: LyricsAccessError? = nil,
         publishFailure: LyricsAccessError? = nil, cancelPublish: Bool = false) {
        self.failPublish = failPublish
        self.preflightRefusal = preflightRefusal
        self.publishFailure = publishFailure
        self.cancelPublish = cancelPublish
    }

    func reply(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let isChallenge = request.url?.lastPathComponent == "request-challenge"
        if !isChallenge, let preflightRefusal { throw preflightRefusal }
        requests.append(request)
        if !isChallenge && failPublish { throw URLError(.timedOut) }
        if !isChallenge, let publishFailure { throw publishFailure }
        if !isChallenge && cancelPublish { throw CancellationError() }
        let data = isChallenge ? try JSONEncoder().encode(LRCLIBChallenge(prefix: "fixture", target: String(repeating: "f", count: 64))) : Data()
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: isChallenge ? 200 : 201,
                                                   httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
}
