// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Apple Music 계정 연결 (음절 가사용, #4). 앱 안 웹 창에 Apple 의 로그인 페이지를 그대로 띄우고,
// 로그인은 전부 Apple 페이지가 처리한다 — CoNo 는 비밀번호를 보지 않는다. 로그인 뒤 쿠키에 생기는
// media-user-token(구독자 토큰, 6개월)과 itua(구독 지역)만 꺼내 키체인에 둔다.
// (쿠키가 생기는 시점이 페이지 흐름마다 달라 페이지 이벤트 대신 1초마다 쿠키를 본다)

import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class AppleMusicConnection {
    static let shared = AppleMusicConnection()

    enum State: Equatable {
        case disconnected
        case connected(savedAt: Date, storefront: String)
    }

    private(set) var state: State = .disconnected
    private(set) var isConnecting = false
    /// 토큰이 거부됨 (만료·취소) — 다시 연결해야 한다
    private(set) var rejected = false
    @ObservationIgnored private var loginWindow: AppleMusicLoginWindow?

    private init() { refresh() }

    func refresh() {
        rejected = AppleMusicCredentials.rejected
        if AppleMusicCredentials.userToken != nil {
            state = .connected(savedAt: AppleMusicCredentials.savedAt ?? Date(), storefront: AppleMusicCredentials.storefront)
        } else {
            state = .disconnected
        }
    }

    /// 만료 예상일 (Apple 의 6개월 상한으로 계산)
    var expiresAt: Date? {
        guard case let .connected(savedAt, _) = state else { return nil }
        return savedAt.addingTimeInterval(AppleMusicCredentials.lifetime)
    }

    func connect() {
        if let loginWindow {
            loginWindow.showWindow(nil)
            return
        }
        isConnecting = true
        let window = AppleMusicLoginWindow { [weak self] in
            guard let self else { return }
            self.loginWindow = nil
            self.isConnecting = false
            self.refresh()
        }
        loginWindow = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 연결 끊기: 토큰과 웹 로그인 상태를 함께 지운다 (안 지우면 다음 연결이 로그인 없이 같은 계정으로 되돌아온다)
    func disconnect() {
        AppleMusicCredentials.clear()
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let apple = records.filter { $0.displayName.contains("apple.com") }
            if !apple.isEmpty { store.removeData(ofTypes: types, for: apple) {} }
        }
        refresh()
    }
}

@MainActor
private final class AppleMusicLoginWindow: NSWindowController, NSWindowDelegate {
    private let completion: () -> Void
    private let webView: WKWebView
    private var pollTimer: Timer?
    private var tokenFirstSeenAt: Date?
    private var finished = false
    /// 토큰이 보인 뒤 지역 쿠키(itua)를 기다리는 시간. 못 받으면 비워 두고 가사 요청 때 계정에 묻는다.
    private static let storefrontGrace: TimeInterval = 8

    init(completion: @escaping () -> Void) {
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // 쿠키가 창을 닫아도 남아야 한다
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Apple Music 연결"
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.load(URLRequest(url: URL(string: "https://music.apple.com/login")!))
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCookies() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func checkCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self, !self.finished,
                      let token = cookies.first(where: { $0.name == "media-user-token" })?.value, !token.isEmpty
                else { return }
                let storefront = cookies.first(where: { $0.name == "itua" })?.value.lowercased() ?? ""
                if storefront.isEmpty {
                    if self.tokenFirstSeenAt == nil { self.tokenFirstSeenAt = Date() }
                    guard let seen = self.tokenFirstSeenAt, Date().timeIntervalSince(seen) >= Self.storefrontGrace else { return }
                }
                self.finish(token: token, storefront: storefront)
            }
        }
    }

    private func finish(token: String, storefront: String) {
        finished = true
        AppleMusicCredentials.save(userToken: token, storefront: storefront)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        completion()
    }
}
