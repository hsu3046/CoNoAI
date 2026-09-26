// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 연결된 브라우저의 탭 제목 읽기 (광고 알아채기용, AdDetector). 탭 제목만 읽고 페이지 내용은 보지 않는다.
// 처음 한 번 "자동화 › 브라우저" 권한을 묻는다. 거부되면 1분 동안 다시 묻지 않고 nil (추정으로 대신).

import Foundation

final class BrowserTabs: @unchecked Sendable {
    private let bundleID: String
    /// NSAppleScript 는 스레드 안전하지 않아 이 큐에서만 만들고 쓴다
    private let queue = DispatchQueue(label: "space.knowai.cono.browsertabs", qos: .userInitiated)
    private var script: NSAppleScript?
    private var deniedUntil: Date?

    init?(bundleID: String?) {
        guard let bundleID, BrowserTabScript.supports(bundleID: bundleID) else { return nil }
        self.bundleID = bundleID
    }

    /// 모든 탭 제목. 읽지 못하면 nil.
    func titles() async -> [String]? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readSync())
            }
        }
    }

    private func readSync() -> [String]? {
        if let deniedUntil, Date() < deniedUntil { return nil }
        if script == nil, let source = BrowserTabScript.source(bundleID: bundleID) {
            script = NSAppleScript(source: source)
        }
        var errorInfo: NSDictionary?
        guard let result = script?.executeAndReturnError(&errorInfo), errorInfo == nil else {
            let code = errorInfo?[NSAppleScript.errorNumber] as? Int
            // -1743 = 자동화 권한 거부, -1744 = 동의 필요
            if code == -1743 || code == -1744 { deniedUntil = Date().addingTimeInterval(60) }
            return nil
        }
        var titles: [String] = []
        Self.collect(result, into: &titles)
        return titles
    }

    /// {{창1 탭들}, {창2 탭들}} 을 펼친다
    private static func collect(_ descriptor: NSAppleEventDescriptor, into titles: inout [String]) {
        if descriptor.numberOfItems > 0 {
            for index in 1...descriptor.numberOfItems {
                if let item = descriptor.atIndex(index) { collect(item, into: &titles) }
            }
        } else if let text = descriptor.stringValue, !text.isEmpty {
            titles.append(text)
        }
    }
}
