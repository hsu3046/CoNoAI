// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Observation

enum LyricsServiceID: String, CaseIterable, Sendable {
    case lrclib, netease, amll, appleMusic

    var label: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .netease: "NetEase"
        case .amll: "AMLL"
        case .appleMusic: "Apple Music"
        }
    }

    var hosts: Set<String> {
        switch self {
        case .lrclib: ["lrclib.net"]
        case .netease: ["music.163.com"]
        case .amll: ["raw.githubusercontent.com"]
        case .appleMusic: ["music.apple.com", "amp-api.music.apple.com"]
        }
    }
}

enum LyricsAccessError: LocalizedError, Equatable, Sendable {
    case authorization(Int), rateLimited(Date), unavailable(Date), network, secureConnection
    case unsafeAddress, invalidResponse, responseTooLarge, invalidBody, http(Int), needsConnection

    var errorDescription: String? {
        switch self {
        case .authorization(401): "서비스 인증을 확인하지 못했어요. 연결 정보와 서비스 이용 조건을 확인해 주세요."
        case .authorization: "서비스가 접근을 허용하지 않았어요. 구독·지역·이용 권한을 확인해 주세요."
        case let .rateLimited(until): "요청 한도에 도달했어요. \(until.formatted(date: .omitted, time: .standard)) 이후 다시 요청합니다."
        case let .unavailable(until): "서비스가 일시적으로 응답하지 않아요. \(until.formatted(date: .omitted, time: .standard)) 이후 다시 시도할 수 있습니다."
        case .network: "네트워크 연결을 확인해 주세요. 등록한 내 가사는 계속 사용할 수 있습니다."
        case .secureConnection: "서버의 안전한 HTTPS 연결을 확인하지 못했어요. 인증서 검증을 유지한 채 요청을 중단했습니다."
        case .unsafeAddress: "허용된 가사 서비스의 HTTPS 주소가 아니어서 요청을 중단했습니다."
        case .invalidResponse, .invalidBody: "서비스 응답 형식이 달라 가사를 읽지 못했어요. 검색 결과 없음으로 저장하지 않습니다."
        case .responseTooLarge: "서비스 응답이 허용 크기를 넘어 읽기를 중단했습니다."
        case let .http(status): "가사 서비스 응답 오류 (HTTP \(status)). 내 가사를 등록해 사용할 수 있습니다."
        case .needsConnection: "Apple Music 계정 연결과 이용 가능한 구독·지역이 필요합니다."
        }
    }

    var retryAfterDate: Date? {
        switch self {
        case let .rateLimited(date), let .unavailable(date): date
        default: nil
        }
    }
}

/// HTTP 응답을 받은 뒤의 파싱·캐시 기록도 원래 조회와 같은 세대로 묶는다.
/// actor 이동·async let에도 전달되며, 다른 서비스의 중첩 호출에는 재사용하지 않는다.
enum LyricsServiceOperation {
    struct Context: Sendable {
        let service: LyricsServiceID
        let id: UUID
    }
    @TaskLocal static var current: Context?

    static func requestID(for service: LyricsServiceID) -> UUID? {
        current?.service == service ? current?.id : nil
    }
}

/// 연결 상태만 보관한다. 곡 정보·응답 본문·토큰·URL은 진단에 포함하지 않는다.
@MainActor @Observable
final class LyricsServiceMonitor {
    static let shared = LyricsServiceMonitor()
    enum State: Equatable { case idle, loading, reachable, cached, failed(LyricsAccessError) }
    struct Snapshot: Equatable { let state: State; let checkedAt: Date }
    private(set) var snapshots: [LyricsServiceID: Snapshot] = [:]
    @ObservationIgnored private var activeChecks: [LyricsServiceID: UUID] = [:]

    func begin(_ service: LyricsServiceID) -> UUID {
        let id = UUID()
        activeChecks[service] = id
        snapshots[service] = Snapshot(state: .loading, checkedAt: Date())
        return id
    }

    func record(_ service: LyricsServiceID, _ state: State, requestID: UUID? = nil) {
        let requestID = requestID ?? LyricsServiceOperation.requestID(for: service)
        if let requestID, activeChecks[service] != requestID { return }
        if requestID == nil { activeChecks[service] = UUID() }
        snapshots[service] = Snapshot(state: state, checkedAt: Date())
    }
}

enum LyricsHTTPPolicy {
    static func allows(_ url: URL, service: LyricsServiceID) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && url.fragment == nil && (url.port == nil || url.port == 443)
            && service.hosts.contains(url.host?.lowercased() ?? "")
    }

    static func allowsRedirect(from original: URL, to next: URL) -> Bool {
        next.scheme?.lowercased() == "https" && next.user == nil && next.password == nil
            && next.fragment == nil && (next.port == nil || next.port == 443)
            && original.host?.lowercased() == next.host?.lowercased()
    }

    static func retryDate(_ value: String?, now: Date, fallback: TimeInterval) -> Date {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return now.addingTimeInterval(fallback) }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            // Very large server delays remain blocked for this process instead of overflowing Date.
            return now.addingTimeInterval(max(1, min(seconds, 31_536_000)))
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = parser.date(from: value) { return max(now.addingTimeInterval(1), date) }
        return now.addingTimeInterval(fallback)
    }

    static func issue(for status: Int, retryAfter: String?, now: Date) -> LyricsAccessError? {
        switch status {
        case 200...299, 404: nil
        case 401, 403: .authorization(status)
        case 429: .rateLimited(retryDate(retryAfter, now: now, fallback: 30))
        case 500...599: .unavailable(retryDate(retryAfter, now: now, fallback: 15))
        default: .http(status)
        }
    }
}

private final class LyricsRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url,
              LyricsHTTPPolicy.allowsRedirect(from: original, to: next) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// Bounded transport shared by lyric lookups and explicit publishing. It never retries a POST.
/// Rate limits/temporary outages are kept separate from a valid empty search result.
actor LyricsHTTPClient {
    static let shared = LyricsHTTPClient()
    private let session: URLSession
    private var cooldowns: [LyricsServiceID: LyricsAccessError] = [:]

    init(configuration: URLSessionConfiguration? = nil) {
        let configuration = configuration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "CoNo/0.2 (https://www.aib.vote)"]
        session = URLSession(configuration: configuration, delegate: LyricsRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest, service: LyricsServiceID, maximumBytes: Int = 1_048_576,
              acceptedStatus: Set<Int> = [200]) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, LyricsHTTPPolicy.allows(url, service: service),
              (1...8_388_608).contains(maximumBytes) else { throw LyricsAccessError.unsafeAddress }
        let checkID: UUID
        if let operationID = LyricsServiceOperation.requestID(for: service) { checkID = operationID }
        else { checkID = await LyricsServiceMonitor.shared.begin(service) }
        do {
            try Task.checkCancellation()
            // begin()의 actor 이동 중 생긴 제한도 실제 요청 전에 확인한다.
            if let cooldown = cooldowns[service], let until = cooldown.retryAfterDate, until > Date() { throw cooldown }
            cooldowns[service] = nil
            let (bytes, response) = try await session.bytes(for: request)
            // Leaving AsyncBytes early does not itself guarantee the underlying request stops.
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, let finalURL = response.url,
                  LyricsHTTPPolicy.allows(finalURL, service: service),
                  LyricsHTTPPolicy.allowsRedirect(from: url, to: finalURL) else { throw LyricsAccessError.invalidResponse }
            var issue = LyricsHTTPPolicy.issue(for: response.statusCode,
                                              retryAfter: response.value(forHTTPHeaderField: "Retry-After"), now: Date())
            if let reported = issue, let until = reported.retryAfterDate {
                // 이미 실행 중이던 짧은 503 응답이 더 긴 429 제한을 줄이지 않게 한다.
                if let existing = cooldowns[service], let previous = existing.retryAfterDate, previous > until {
                    issue = existing
                } else { cooldowns[service] = reported }
            }
            if let issue {
                await LyricsServiceMonitor.shared.record(service, .failed(issue), requestID: checkID)
            }
            guard acceptedStatus.contains(response.statusCode) else { throw issue ?? LyricsAccessError.http(response.statusCode) }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw LyricsAccessError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
                guard data.count < maximumBytes else { throw LyricsAccessError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            if issue == nil { await LyricsServiceMonitor.shared.record(service, .reachable, requestID: checkID) }
            return (data, response)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                await LyricsServiceMonitor.shared.record(service, .idle, requestID: checkID)
                throw CancellationError()
            }
            let issue: LyricsAccessError
            if let known = error as? LyricsAccessError { issue = known }
            else if let error = error as? URLError,
                    [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                     .clientCertificateRequired].contains(error.code) { issue = .secureConnection }
            else { issue = .network }
            await LyricsServiceMonitor.shared.record(service, .failed(issue), requestID: checkID)
            throw issue
        }
    }
}
