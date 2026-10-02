// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// Apple 웹 플레이어 호환 연결. 비밀번호 입력은 Apple 페이지에서 처리한다.
// 일시적인 로그인 창의 Secure 음악 쿠키에서 이용 토큰/구독 지역만 읽어 키체인에 저장한다.
// Music User Token에는 고정 180일 만료를 가정하지 않는다.

import AppKit
import Observation
import WebKit

@MainActor @Observable
final class AppleMusicConnection {
    static let shared = AppleMusicConnection()
    enum State: Equatable {
        case disconnected
        case connected(savedAt: Date, storefront: String)
    }
    private(set) var state: State = .disconnected
    private(set) var isConnecting = false
    private(set) var isDisconnecting = false
    private(set) var rejected = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var loginWindow: AppleMusicLoginWindow?
    @ObservationIgnored private var credentialObserver: NSObjectProtocol?

    private init() {
        refresh()
        credentialObserver = NotificationCenter.default.addObserver(forName: AppleMusicCredentialStore.didChange,
                                                                    object: nil, queue: .main) { [weak self] notification in
            guard let store = notification.object as? AppleMusicCredentialStore, store === AppleMusicCredentials.store else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        do {
            let snapshot = try AppleMusicCredentials.store.snapshot()
            rejected = snapshot.userToken != nil && snapshot.rejected
            if snapshot.userToken != nil {
                state = .connected(savedAt: snapshot.savedAt ?? Date(), storefront: snapshot.storefront)
            } else { state = .disconnected }
        } catch {
            // 키체인 읽기 실패를 '연결 해제됨'으로 바꾸지 않는다.
            errorMessage = error.localizedDescription
        }
    }

    func connect() {
        guard !isDisconnecting else { return }
        if let loginWindow { loginWindow.showWindow(nil); return }
        errorMessage = nil
        isConnecting = true
        let window = AppleMusicLoginWindow(revision: AppleMusicCredentials.store.revision,
                                          onError: { [weak self] in self?.errorMessage = $0 }) { [weak self] error in
            guard let self else { return }
            self.loginWindow = nil
            self.isConnecting = false
            self.errorMessage = error
            self.refresh()
        }
        loginWindow = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        // 이미 시작한 쿠키 콜백도 창을 닫은 뒤 토큰을 다시 저장하지 못하게 한다.
        loginWindow?.close()
        errorMessage = nil
        isDisconnecting = true
        do {
            try AppleMusicCredentials.store.clear()
            LyricsServiceMonitor.shared.record(.appleMusic, .idle)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            isDisconnecting = false
            refresh()
            return
        }
        // 이전 버전의 영구 WebKit 로그인 흔적도 Apple 도메인 경계 안에서만 삭제한다.
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            let apple = records.filter { AppleMusicCredentialPolicy.isAppleHost($0.displayName) }
            store.removeData(ofTypes: types, for: apple) { [weak self] in
                MainActor.assumeIsolated { self?.isDisconnecting = false }
            }
        }
    }
}

@MainActor
private final class AppleMusicLoginWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let completion: (String?) -> Void
    private let onError: (String) -> Void
    private let revision: UUID
    private let webView: WKWebView
    private var pollTimer: Timer?
    private var tokenFirstSeenAt: Date?
    private var finished = false
    private var didComplete = false
    private var failureMessage: String?
    private static let storefrontGrace: TimeInterval = 8

    init(revision: UUID, onError: @escaping (String) -> Void, completion: @escaping (String?) -> Void) {
        self.revision = revision
        self.onError = onError
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        // 재연결 창이 이전 로그인 쿠키를 즉시 재저장하지 않게 매번 새 세션을 사용한다.
        // 창이 닫힌 뒤 필요한 이용 토큰은 키체인에만 남는다.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple Music 연결"
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "https://music.apple.com/login")!))
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCookies() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func checkCookies() {
        guard !finished, let url = webView.url, AppleMusicCredentialPolicy.allowsLoginNavigation(url) else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                let trusted = cookies.filter { AppleMusicCredentialPolicy.acceptsCookie($0) }
                    .sorted { $0.domain.count > $1.domain.count }
                guard let token = trusted.first(where: { $0.name == "media-user-token" && AppleMusicCredentialPolicy.validToken($0.value) })?.value else { return }
                let storefront = trusted.first(where: {
                    $0.name == "itua" && AppleMusicCredentialPolicy.validStorefront($0.value.lowercased())
                })?.value.lowercased() ?? ""
                if storefront.isEmpty {
                    if self.tokenFirstSeenAt == nil { self.tokenFirstSeenAt = Date() }
                    guard let seen = self.tokenFirstSeenAt, Date().timeIntervalSince(seen) >= Self.storefrontGrace else { return }
                }
                self.finish(token: token, storefront: storefront)
            }
        }
    }

    private func finish(token: String, storefront: String) {
        guard !finished else { return }
        finished = true
        do {
            try AppleMusicCredentials.store.save(userToken: token, storefront: storefront, matching: revision)
            failureMessage = nil
            LyricsServiceMonitor.shared.record(.appleMusic, .idle)
        } catch { report(error.localizedDescription) }
        close()
    }

    private func report(_ message: String) {
        failureMessage = message
        onError(message)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !finished, let url = navigationAction.request.url else { return .cancel }
        if AppleMusicCredentialPolicy.allowsLoginNavigation(url) { return .allow }
        // 빈 하위 프레임은 로그인 페이지가 만들 수 있으나 외부 사이트로의 이동은 허용하지 않는다.
        if navigationAction.targetFrame?.isMainFrame == false, url.absoluteString == "about:blank" { return .allow }
        report("Apple의 안전한 로그인 주소가 아닌 이동을 중단했어요. 연결 창을 닫고 다시 시도해 주세요.")
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !finished, let url = navigationAction.request.url,
              AppleMusicCredentialPolicy.allowsLoginNavigation(url) else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished, (error as? URLError)?.code != .cancelled else { return }
        report("Apple 로그인 페이지에 연결하지 못했어요. 네트워크와 HTTPS 연결을 확인한 뒤 다시 시도해 주세요.")
    }

    func windowWillClose(_ notification: Notification) {
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        webView.stopLoading()
        guard !didComplete else { return }
        didComplete = true
        completion(failureMessage)
    }
}
