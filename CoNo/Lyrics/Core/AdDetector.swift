// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 브라우저 영상(YouTube 등) 광고 알아채기. YouTube 는 "지금 재생 중" 에 광고라고 표시하지 않고
// (isAdvertisement 비어 있음 — 2026-09-26 실측), 광고 제목·광고주·광고 길이를 새 곡처럼 보고한다:
//   "여기어때, 해외여행 플랫폼으로 확장! …" · monday.com · 59.9초  →  본 영상 "가수 - 곡 / THE FIRST TAKE" · 244초
// 광고 중에도 브라우저 탭 제목은 본 영상 제목 그대로다 → "지금 재생 중" 제목이 어느 탭 제목에도 없으면 광고.
// 탭 제목을 못 읽으면(권한 거부·지원 안 하는 브라우저) 짧고 광고주가 도메인인 항목을 광고로 추정한다.

import Foundation

enum AdDetector {
    /// - Parameter tabTitles: 연결된 브라우저의 탭 제목들. nil = 읽지 못함 (추정으로 대신한다)
    static func isAdvertisement(title: String, artist: String, duration: Double, tabTitles: [String]?) -> Bool {
        let playing = normalized(title)
        guard !playing.isEmpty else { return false }
        if let tabTitles {
            let tabs = tabTitles.map(normalizedTabTitle).filter { $0.count >= 4 && !genericTabTitles.contains($0) }
            if !tabs.isEmpty {
                // 탭 제목이 잘려 있을 수도 있어 양쪽 포함을 모두 본다
                return !tabs.contains { $0.contains(playing) || playing.contains($0) }
            }
        }
        return looksLikeAd(artist: artist, duration: duration)
    }

    /// 탭 제목 없이 추정: 짧은 항목(65초 이하)이고 광고주 칸이 도메인("monday.com", "Hostinger.com/kr/…")
    static func looksLikeAd(artist: String, duration: Double) -> Bool {
        guard duration > 0, duration <= 65 else { return false }
        return artist.range(of: #"[A-Za-z0-9-]+\.(com|net|co|io|ai|kr|jp|app|shop|store|me)\b"#, options: .regularExpression) != nil
    }

    /// 사이트 이름만 남은 탭 ("YouTube" 등) 은 비교에서 뺀다 — 모든 제목이 그 안에 들어 있다고 오판하지 않게
    private static let genericTabTitles: Set<String> = ["youtube", "youtube music", "new tab", "새 탭"]

    static func normalizedTabTitle(_ title: String) -> String {
        var text = normalized(title)
        // 알림 개수 "(3) " 와 사이트 꼬리 " - youtube" 를 뗀다
        text = text.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        for suffix in [" - youtube music", " - youtube", " – youtube", " | youtube"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text
    }

    /// 소문자 + 공백 하나로
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 브라우저 탭 제목을 읽는 AppleScript (탭 제목만 — 페이지 내용은 읽지 않는다)
enum BrowserTabScript {
    /// Chrome 계열은 `title`, Safari 는 `name`
    private static let titleProperty: [String: String] = [
        "com.google.Chrome": "title",
        "com.google.Chrome.beta": "title",
        "com.microsoft.edgemac": "title",
        "com.brave.Browser": "title",
        "com.vivaldi.Vivaldi": "title",
        "company.thebrowser.Browser": "title", // Arc
        "com.apple.Safari": "name",
    ]

    static func supports(bundleID: String?) -> Bool {
        bundleID.map { titleProperty[$0] != nil } ?? false
    }

    /// 모든 창의 모든 탭 제목 (브라우저가 꺼져 있으면 켜지 않고 빈 목록)
    static func source(bundleID: String) -> String? {
        guard let property = titleProperty[bundleID] else { return nil }
        return """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)" to return \(property) of every tab of every window
        end if
        return {}
        """
    }
}
