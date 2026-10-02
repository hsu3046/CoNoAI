// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import CryptoKit
import Foundation

struct LRCLIBPublishPayload: Codable, Equatable, Sendable {
    let trackName: String
    let artistName: String
    let albumName: String
    /// LRCLIB의 duration 단위는 초다.
    let duration: Double
    let plainLyrics: String
    let syncedLyrics: String

    func validatedData() throws -> Data {
        guard !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [trackName, artistName, albumName].allSatisfy({ $0.count <= 500 }),
              duration.isFinite, duration > 0, duration <= 86_400,
              plainLyrics.utf8.count <= 1_048_576, syncedLyrics.utf8.count <= 1_048_576 else { throw LRCLIBPublishError.invalidPayload }
        if syncedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 공식 PublishRequest는 plain/synced를 각각 optional로 받고 빈 synced는 None으로 처리한다.
            // https://github.com/tranxuanthang/lrclib/blob/main/server/src/lyricsfile.rs
            do { try LocalLyricsStore.validatePlain(plainLyrics) }
            catch { throw LRCLIBPublishError.invalidPayload }
        } else {
            let lines = LRCParser.parse(syncedLyrics).lines.filter { !$0.isInterlude }
            guard !lines.isEmpty, lines.count <= 4_000, lines.allSatisfy({
                $0.start >= 0 && $0.start < duration && $0.text.count <= 500
                    && ($0.explicitEnd.map { $0 <= duration } ?? true)
                    && $0.segments.allSatisfy { $0.start < duration && ($0.end.map { $0 <= duration } ?? true) }
            }), lines.map(\.text).joined(separator: "\n") == plainLyrics else { throw LRCLIBPublishError.invalidPayload }
        }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 1_048_576 else { throw LRCLIBPublishError.invalidPayload }
        return data
    }
}

enum LRCLIBPublishError: LocalizedError {
    case invalidPayload, invalidChallenge, challengeTimeout, http(Int), uncertainOutcome

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "곡 제목·가수·곡 길이·가사 내용을 확인해 주세요. 시간 있는 가사는 모든 시각이 곡 길이 안에 있어야 합니다."
        case .invalidChallenge: "LRCLIB 게시 인증 응답을 읽지 못했어요. 나중에 다시 시도해 주세요."
        case .challengeTimeout: "LRCLIB 게시 인증 계산이 오래 걸려 멈췄어요. 잠시 뒤 다시 시도하거나 LRC로 내보내 주세요."
        case let .http(status): "LRCLIB 게시 요청이 거절됐어요 (HTTP \(status)). 로컬 가사는 그대로 있습니다."
        case .uncertainOutcome: "전송 후 응답을 확인하지 못했어요. 이미 게시되었을 수 있으니 LRCLIB에서 곡을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

struct LRCLIBChallenge: Codable, Sendable {
    let prefix: String
    let target: String

    private func targetBytes() throws -> [UInt8] {
        guard !prefix.isEmpty, prefix.utf8.count <= 256, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              target.count == 64, target.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw LRCLIBPublishError.invalidChallenge }
        let chars = Array(target)
        let bytes = stride(from: 0, to: 64, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
        guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else { throw LRCLIBPublishError.invalidChallenge }
        return bytes
    }

    /// 공식 검증식: SHA256(prefix + nonce) <= target. 콜론은 전송 토큰에만 넣는다.
    /// https://github.com/tranxuanthang/lrclib/blob/main/server/src/utils.rs
    func accepts(nonce: UInt64) throws -> Bool {
        let target = try targetBytes()
        let digest = Array(SHA256.hash(data: Data((prefix + String(nonce)).utf8)))
        return digest == target || digest.lexicographicallyPrecedes(target)
    }

    func solve(maximumAttempts: UInt64 = 100_000_000, timeout: Duration = .seconds(120)) async throws -> String {
        let target = try targetBytes()
        let deadline = ContinuousClock.now + timeout
        // 단일 백그라운드 작업으로 계산하며 정기적으로 취소/기한을 확인한다.
        var prefixHasher = SHA256()
        prefixHasher.update(data: Data(prefix.utf8))
        for nonce in 0..<maximumAttempts {
            if nonce % 1_024 == 0 {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw LRCLIBPublishError.challengeTimeout }
                await Task.yield()
            }
            var hasher = prefixHasher
            hasher.update(data: Data(String(nonce).utf8))
            let digest = Array(hasher.finalize())
            if digest == target || digest.lexicographicallyPrecedes(target) { return "\(prefix):\(nonce)" }
        }
        throw LRCLIBPublishError.challengeTimeout
    }
}

enum LRCLIBPublishPhase: Equatable, Sendable { case preparing, solving, sending }

/// 사용자가 게시 확인 버튼을 눌렀을 때만 호출한다. 자동 재시도는 중복 게시를 만들 수 있어 하지 않는다.
actor LRCLIBPublisher {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private static let baseURL = URL(string: "https://lrclib.net/api")!

    init(transport: Transport? = nil) {
        if let transport { self.transport = transport }
        else {
            let client = LyricsHTTPClient.shared
            self.transport = { request in
                try await client.data(for: request, service: .lrclib,
                                      maximumBytes: request.url?.lastPathComponent == "request-challenge" ? 4_096 : 65_536,
                                      acceptedStatus: Set(200...599))
            }
        }
    }

    func publish(_ payload: LRCLIBPublishPayload,
                 phase: @Sendable (LRCLIBPublishPhase) async -> Void = { _ in }) async throws {
        let body = try payload.validatedData()
        try Task.checkCancellation()
        await phase(.preparing)
        let (data, response) = try await transport(Self.request(path: "request-challenge"))
        guard response.statusCode == 200 else { throw LRCLIBPublishError.http(response.statusCode) }
        guard data.count <= 4_096, let challenge = try? JSONDecoder().decode(LRCLIBChallenge.self, from: data) else {
            throw LRCLIBPublishError.invalidChallenge
        }
        await phase(.solving)
        let token = try await challenge.solve()
        try Task.checkCancellation()
        var request = Self.request(path: "publish")
        request.setValue(token, forHTTPHeaderField: "X-Publish-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        await phase(.sending)
        // 상태 안내 await 중 취소한 요청도 실제 전송 전에 멈춘다.
        try Task.checkCancellation()
        // 공식 publish_lyrics.rs는 성공 시 201을 반환한다. 전송 뒤 타임아웃은 결과 미확정이다.
        let result: (Data, HTTPURLResponse)
        do { result = try await transport(request) }
        catch let error as LyricsAccessError {
            // acceptedStatus가 모든 HTTP 상태를 허용하므로 이 셋은 공용 전송 계층의 요청 전 거부다.
            // 이미 전송했을 수 있는 연결/취소 오류와 구분해 재시도 대기 안내를 유지한다.
            switch error {
            case .rateLimited, .unavailable, .unsafeAddress: throw error
            default: throw LRCLIBPublishError.uncertainOutcome
            }
        }
        catch { throw LRCLIBPublishError.uncertainOutcome }
        guard result.1.statusCode == 201 else { throw LRCLIBPublishError.http(result.1.statusCode) }
    }

    private static func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("CoNo/0.2 (https://www.aib.vote)", forHTTPHeaderField: "Lrclib-Client")
        request.setValue("CoNo/0.2 (https://www.aib.vote)", forHTTPHeaderField: "User-Agent")
        return request
    }
}
