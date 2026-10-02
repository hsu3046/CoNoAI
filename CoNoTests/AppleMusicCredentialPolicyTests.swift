// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import Foundation
import Synchronization
import Testing

final class AppleCredentialTestPersistence: AppleMusicCredentialPersistence {
    enum Failure: Error { case denied }
    struct State {
        var token: String?
        var metadata = AppleMusicCredentialMetadata()
        var failRead = false
        var failWrite = false
        var failDelete = false
    }
    let state = Mutex(State())
    func readToken() throws -> String? {
        try state.withLock { if $0.failRead { throw Failure.denied }; return $0.token }
    }
    func writeToken(_ token: String) throws {
        try state.withLock { if $0.failWrite { throw Failure.denied }; $0.token = token }
    }
    func deleteToken() throws {
        try state.withLock { if $0.failDelete { throw Failure.denied }; $0.token = nil }
    }
    func readMetadata() -> AppleMusicCredentialMetadata { state.withLock { $0.metadata } }
    func writeMetadata(_ metadata: AppleMusicCredentialMetadata) { state.withLock { $0.metadata = metadata } }
}

private final class AppleCredentialNotificationRecorder: Sendable {
    let names = Mutex([Notification.Name]())
}

struct AppleMusicCredentialPolicyTests {
    @Test(arguments: ["apple.com", "music.apple.com", "idmsa.apple.com", "APPLE.COM"])
    func acceptsAppleHosts(_ host: String) { #expect(AppleMusicCredentialPolicy.isAppleHost(host)) }

    @Test(arguments: ["evilapple.com", "apple.com.evil.test", "apple.com@evil.test", ".apple.com", "a..apple.com", "-a.apple.com", "apple.com.", "äpple.com"])
    func rejectsConfusableHosts(_ host: String) { #expect(!AppleMusicCredentialPolicy.isAppleHost(host)) }

    @Test(arguments: ["http://music.apple.com/login", "https://evilapple.com/", "https://apple.com:444/", "https://user:pass@apple.com/", "file:///apple.com"])
    func rejectsUnsafeNavigation(_ text: String) throws {
        #expect(!AppleMusicCredentialPolicy.allowsLoginNavigation(try #require(URL(string: text))))
    }

    @Test func acceptsSecureAppleNavigationAndOnlyASCIIStorefronts() throws {
        #expect(AppleMusicCredentialPolicy.allowsLoginNavigation(try #require(URL(string: "https://idmsa.apple.com:443/auth?redirect=music"))))
        for value in ["us", "kr", "jp"] { #expect(AppleMusicCredentialPolicy.validStorefront(value)) }
        for value in ["US", "u", "usa", "../us", "éa", "ｕｓ", "\nus"] { #expect(!AppleMusicCredentialPolicy.validStorefront(value)) }
    }

    @Test func acceptsOnlySecureUnexpiredCookiesScopedToMusic() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cookie(_ domain: String, secure: Bool, expired: Bool = false) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "media-user-token", .value: "synthetic-token", .domain: domain, .path: "/"]
            if secure { properties[.secure] = "TRUE" }
            properties[.expires] = now.addingTimeInterval(expired ? -1 : 60)
            return try #require(HTTPCookie(properties: properties))
        }
        #expect(AppleMusicCredentialPolicy.acceptsCookie(try cookie(".apple.com", secure: true), now: now))
        #expect(AppleMusicCredentialPolicy.acceptsCookie(try cookie("music.apple.com", secure: true), now: now))
        for domain in [".evilapple.com", "apple.com.evil.test", "appleid.apple.com", "test.music.apple.com"] {
            #expect(!AppleMusicCredentialPolicy.acceptsCookie(try cookie(domain, secure: true), now: now))
        }
        #expect(!AppleMusicCredentialPolicy.acceptsCookie(try cookie(".apple.com", secure: false), now: now))
        #expect(!AppleMusicCredentialPolicy.acceptsCookie(try cookie(".apple.com", secure: true, expired: true), now: now))
    }

    @Test func failedSaveAndClearPreserveCredentialsAndGeneration() throws {
        let persistence = AppleCredentialTestPersistence()
        let store = AppleMusicCredentialStore(persistence: persistence)
        let before = try store.save(userToken: "original-token", storefront: "kr", now: Date(timeIntervalSince1970: 42))
        persistence.state.withLock { $0.failWrite = true }
        #expect(throws: AppleCredentialTestPersistence.Failure.self) { try store.save(userToken: "replacement-token", storefront: "us") }
        #expect(try store.snapshot() == before)
        persistence.state.withLock { $0.failWrite = false; $0.failDelete = true }
        #expect(throws: AppleCredentialTestPersistence.Failure.self) { try store.clear() }
        #expect(try store.snapshot() == before)
        persistence.state.withLock { $0.failRead = true }
        #expect(throws: AppleCredentialTestPersistence.Failure.self) { try store.snapshot() }
    }

    @Test func oldTokenResponsesCannotRejectOrChangeReconnectedAccount() throws {
        let store = AppleMusicCredentialStore(persistence: AppleCredentialTestPersistence())
        let old = try store.save(userToken: "same-token", storefront: "")
        let current = try store.save(userToken: "same-token", storefront: "kr")
        #expect(old.revision != current.revision)
        #expect(try !store.isCurrent(old))
        #expect(try !store.reject(old))
        #expect(try store.setStorefront("us", matching: old) == nil)
        #expect(try store.snapshot() == current)
        #expect(throws: AppleMusicCredentialError.changed) {
            try store.save(userToken: "pending-login-token", storefront: "jp", matching: old.revision)
        }
    }

    @Test func clearInvalidatesPendingLoginAndRequests() throws {
        let store = AppleMusicCredentialStore(persistence: AppleCredentialTestPersistence())
        let old = try store.save(userToken: "synthetic-token", storefront: "kr")
        try store.clear()
        let cleared = try store.snapshot()
        #expect(cleared.userToken == nil && cleared.savedAt == nil && !cleared.rejected && cleared.storefront.isEmpty)
        #expect(cleared.revision != old.revision)
        #expect(try !store.reject(old))
        #expect(throws: AppleMusicCredentialError.changed) { try store.save(userToken: "pending-token", storefront: "us", matching: old.revision) }
    }

    @Test func regionUpdateReturnsNewSnapshotAndRejectsInvalidRegions() throws {
        let persistence = AppleCredentialTestPersistence()
        let store = AppleMusicCredentialStore(persistence: persistence)
        let original = try store.save(userToken: "synthetic-token", storefront: "")
        let storedUpdate = try store.setStorefront("kr", matching: original)
        let updated = try #require(storedUpdate)
        #expect(updated.storefront == "kr" && updated.revision != original.revision)
        #expect(try store.isCurrent(updated))
        #expect(throws: AppleMusicCredentialError.invalidStorefront) { try store.setStorefront("../us", matching: updated) }
        #expect(throws: AppleMusicCredentialError.invalidToken) { try store.save(userToken: "bad\nheader", storefront: "us") }
        #expect(try store.snapshot() == updated)
        persistence.state.withLock { $0.metadata.storefront = "../us" }
        #expect(try store.snapshot().storefront.isEmpty)
    }

    @Test func externalTokenReplacementAlsoInvalidatesSnapshot() throws {
        let persistence = AppleCredentialTestPersistence()
        let store = AppleMusicCredentialStore(persistence: persistence)
        let old = try store.save(userToken: "synthetic-token", storefront: "kr")
        persistence.state.withLock { $0.token = "external-replacement" }
        #expect(try !store.isCurrent(old))
        #expect(try !store.reject(old))
    }

    @Test func onlySuccessfulConnectionChangesInvalidateAccountBoundLyrics() throws {
        let persistence = AppleCredentialTestPersistence()
        let store = AppleMusicCredentialStore(persistence: persistence)
        let recorder = AppleCredentialNotificationRecorder()
        let observers = [AppleMusicCredentialStore.didChange, AppleMusicCredentialStore.connectionDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                guard let changed = notification.object as? AppleMusicCredentialStore, changed === store else { return }
                recorder.names.withLock { $0.append(notification.name) }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let saved = try store.save(userToken: "synthetic-token", storefront: "")
        let discovered = try store.setStorefront("kr", matching: saved)
        let current = try #require(discovered)
        #expect(try store.reject(current))
        persistence.state.withLock { $0.failWrite = true; $0.failDelete = true }
        #expect(throws: AppleCredentialTestPersistence.Failure.self) { try store.save(userToken: "new-token", storefront: "us") }
        #expect(throws: AppleCredentialTestPersistence.Failure.self) { try store.clear() }
        #expect(recorder.names.withLock { $0.filter { $0 == AppleMusicCredentialStore.connectionDidChange }.count } == 1)
        persistence.state.withLock { $0.failDelete = false }
        try store.clear()
        #expect(recorder.names.withLock { $0.filter { $0 == AppleMusicCredentialStore.connectionDidChange }.count } == 2)
        #expect(recorder.names.withLock { $0.filter { $0 == AppleMusicCredentialStore.didChange }.count } == 4)
    }

    @Test func concurrentSnapshotsNeverMixTokenAndMetadata() async throws {
        let store = AppleMusicCredentialStore(persistence: AppleCredentialTestPersistence())
        try store.save(userToken: "token-0", storefront: "us", now: Date(timeIntervalSince1970: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 1...100 {
                    try store.save(userToken: "token-\(index)", storefront: index.isMultiple(of: 2) ? "us" : "kr", now: Date(timeIntervalSince1970: Double(index)))
                }
            }
            group.addTask {
                for _ in 0..<500 {
                    let value = try store.snapshot()
                    let index = try #require(Int(value.userToken!.dropFirst(6)))
                    #expect(value.savedAt?.timeIntervalSince1970 == Double(index))
                    #expect(value.storefront == (index.isMultiple(of: 2) ? "us" : "kr"))
                }
            }
            try await group.waitForAll()
        }
    }
}
