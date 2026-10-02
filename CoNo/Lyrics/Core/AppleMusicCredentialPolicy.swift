// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Synchronization

enum AppleMusicCredentialError: LocalizedError, Equatable {
    case invalidToken, invalidStorefront, changed
    case keychain(operation: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidToken: "Apple Music 이용 토큰을 확인하지 못했어요. 다시 연결해 주세요."
        case .invalidStorefront: "Apple Music 구독 지역을 확인하지 못했어요. 다시 연결해 주세요."
        case .changed: "Apple Music 연결 상태가 바뀌어 이전 작업을 중단했어요."
        case let .keychain(operation, status): "Apple Music 연결 \(operation)에 실패했어요 (키체인 오류 \(status)). 접근 권한을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

enum AppleMusicCredentialPolicy {
    static func validStorefront(_ value: String) -> Bool {
        value.utf8.count == 2 && value.utf8.allSatisfy { (97...122).contains($0) }
    }

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func isAppleHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host == "apple.com" || host.hasSuffix(".apple.com"), host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func allowsLoginNavigation(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443) && isAppleHost(url.host ?? "")
    }

    /// music.apple.com에 실제로 전송될 수 있는 Secure 쿠키만 읽는다.
    /// 다른 Apple 서비스 쿠키도 이름이 같다는 이유로 음악 계정에 연결하지 않는다.
    static func acceptsCookie(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        return cookie.isSecure && isAppleHost(domain) &&
            (domain == "music.apple.com" || "music.apple.com".hasSuffix("." + domain)) &&
            (cookie.expiresDate == nil || cookie.expiresDate! > now)
    }
}

struct AppleMusicCredentialMetadata: Sendable, Equatable {
    var storefront = ""
    var savedAt: Date?
    var rejected = false
}

struct AppleMusicCredentialSnapshot: Sendable, Equatable {
    let userToken: String?
    let storefront: String
    let savedAt: Date?
    let rejected: Bool
    let revision: UUID
}

/// 구현은 키체인/메타데이터, 테스트는 메모리 저장소를 사용한다. 토큰은 로그로 전달하지 않는다.
protocol AppleMusicCredentialPersistence: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String) throws
    func deleteToken() throws
    func readMetadata() -> AppleMusicCredentialMetadata
    func writeMetadata(_ metadata: AppleMusicCredentialMetadata)
}

/// 키체인 연산과 메타/UUID 갱신을 하나의 lock 안에서 끝내 일관된 스냅샷을 만든다.
/// async/네트워크 작업이나 사용자 콜백은 lock 안에서 실행하지 않는다.
final class AppleMusicCredentialStore: Sendable {
    static let didChange = Notification.Name("CoNoAppleMusicCredentialsChanged")
    /// 저장/해제에만 발행한다. 지역 최초 발견/거부 상태 갱신은 정상 lookup을 취소하면 안 된다.
    static let connectionDidChange = Notification.Name("CoNoAppleMusicConnectionChanged")
    private let persistence: any AppleMusicCredentialPersistence
    private let generation = Mutex(UUID())

    init(persistence: any AppleMusicCredentialPersistence) { self.persistence = persistence }

    var revision: UUID { generation.withLock { $0 } }

    func snapshot() throws -> AppleMusicCredentialSnapshot {
        try generation.withLock { try read(revision: $0) }
    }

    @discardableResult
    func save(userToken: String, storefront: String, matching revision: UUID? = nil,
              now: Date = Date()) throws -> AppleMusicCredentialSnapshot {
        guard AppleMusicCredentialPolicy.validToken(userToken) else { throw AppleMusicCredentialError.invalidToken }
        guard storefront.isEmpty || AppleMusicCredentialPolicy.validStorefront(storefront) else { throw AppleMusicCredentialError.invalidStorefront }
        let result = try generation.withLock { current in
            if let revision, current != revision { throw AppleMusicCredentialError.changed }
            // 키체인 실패 시 메타데이터와 세대는 그대로 둔다.
            try persistence.writeToken(userToken)
            let metadata = AppleMusicCredentialMetadata(storefront: storefront, savedAt: now, rejected: false)
            persistence.writeMetadata(metadata)
            current = UUID()
            return snapshot(token: userToken, metadata: metadata, revision: current)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        NotificationCenter.default.post(name: Self.connectionDidChange, object: self)
        return result
    }

    func clear() throws {
        try generation.withLock { current in
            try persistence.deleteToken()
            persistence.writeMetadata(AppleMusicCredentialMetadata())
            current = UUID()
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        NotificationCenter.default.post(name: Self.connectionDidChange, object: self)
    }

    func isCurrent(_ snapshot: AppleMusicCredentialSnapshot) throws -> Bool {
        try generation.withLock { current in try matches(snapshot, revision: current) }
    }

    @discardableResult
    func reject(_ snapshot: AppleMusicCredentialSnapshot) throws -> Bool {
        let changed = try generation.withLock { current in
            guard try matches(snapshot, revision: current) else { return false }
            var metadata = persistence.readMetadata()
            metadata.rejected = true
            persistence.writeMetadata(metadata)
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changed
    }

    /// 지역도 세대를 바꾼다. 호출자는 반환한 새 스냅샷으로 남은 요청을 이어 간다.
    func setStorefront(_ value: String, matching snapshot: AppleMusicCredentialSnapshot) throws -> AppleMusicCredentialSnapshot? {
        guard AppleMusicCredentialPolicy.validStorefront(value) else { throw AppleMusicCredentialError.invalidStorefront }
        let updated: AppleMusicCredentialSnapshot? = try generation.withLock { current in
            guard try matches(snapshot, revision: current) else { return nil }
            var metadata = persistence.readMetadata()
            metadata.storefront = value
            persistence.writeMetadata(metadata)
            current = UUID()
            return self.snapshot(token: snapshot.userToken, metadata: metadata, revision: current)
        }
        if updated != nil { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return updated
    }

    private func matches(_ snapshot: AppleMusicCredentialSnapshot, revision: UUID) throws -> Bool {
        guard snapshot.revision == revision, snapshot.userToken != nil else { return false }
        return try persistence.readToken() == snapshot.userToken
    }

    private func read(revision: UUID) throws -> AppleMusicCredentialSnapshot {
        let token = try persistence.readToken()
        if let token, !AppleMusicCredentialPolicy.validToken(token) { throw AppleMusicCredentialError.invalidToken }
        return snapshot(token: token, metadata: persistence.readMetadata(), revision: revision)
    }

    private func snapshot(token: String?, metadata: AppleMusicCredentialMetadata, revision: UUID) -> AppleMusicCredentialSnapshot {
        AppleMusicCredentialSnapshot(userToken: token,
            storefront: AppleMusicCredentialPolicy.validStorefront(metadata.storefront) ? metadata.storefront : "",
            savedAt: metadata.savedAt, rejected: metadata.rejected, revision: revision)
    }
}
