// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 노래방식 2줄 가사: 지금 부르는 줄(크게, 왼쪽부터 색이 차오름) + 다음 줄(작게).
// 색칠: AI 분리 모드에서는 분리된 보컬로 정렬한 음절 타이밍(SyllableAligner) + 글자 폭 환산,
//       보컬 데이터가 없으면 줄 길이 비례 근사.

import AppKit
import SwiftUI

struct LyricsView: View {
    let controller: LyricsController
    /// 지금 귀에 들리는 소리의 캡처 스트림 시각
    let heardCaptureTime: () -> Double?
    /// 지금 줄 글자 크기 (전체화면에서 키운다)
    var lineFontSize: CGFloat = 42

    var body: some View {
        TimelineView(.animation) { timeline in
            content(frameDate: timeline.date)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }

    @ViewBuilder
    private func content(frameDate: Date) -> some View {
        // frameDate: 매 틱 다시 계산하게 하는 의존성 (값은 쓰지 않는다)
        let _ = frameDate
        let state = heardCaptureTime().map { controller.display(atCaptureTime: $0) }

        VStack(spacing: 14) {
            if let lyrics = state?.lyrics {
                Group {
                    if let current = lyrics.current {
                        KaraokeLine(text: current, progress: lyrics.progress, highlightedCharacters: lyrics.highlightedCharacters, fontSize: lineFontSize)
                    } else if let countdown = lyrics.countdown {
                        CountdownDots(remaining: countdown)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(StageTheme.faintInk)
                    }
                }
                .frame(height: lineFontSize * 1.4)
                Text(lyrics.next ?? " ")
                    .font(StageTheme.rounded(lineFontSize * 0.52, .semibold))
                    .foregroundStyle(StageTheme.secondaryInk.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(statusMessage)
                    .font(StageTheme.rounded(17, .medium))
                    .foregroundStyle(StageTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusMessage: String {
        switch controller.status {
        case .inactive: " "
        case .unsupportedSource: "이 연결에서는 가사를 받을 수 없습니다 (시스템 전체 캡처)"
        case .waitingForPlayer: "연결된 앱에서 노래를 틀면 가사가 나옵니다"
        case let .loading(track): "가사를 찾는 중… \(track.title)"
        case let .ready(_, synced): synced ? "곧 가사가 시작됩니다" : "이 곡은 시간이 맞춰진 가사가 없습니다"
        case .notFound: "이 곡의 가사를 찾지 못했습니다"
        case let .failed(message): message
        }
    }
}

/// 왼쪽부터 색이 차오르는 한 줄
private struct KaraokeLine: View {
    let text: String
    let progress: Double
    /// 음절 정렬 결과 (칠해진 글자 수). 있으면 글자 폭 기준으로 칠한다.
    let highlightedCharacters: Double?
    var fontSize: CGFloat = 42

    /// 칠할 폭 비율 — 글자 수를 실제 글자 폭으로 환산 (한글·영문 폭 차이 반영, 축소 표시에도 비율은 그대로)
    private var widthFraction: Double {
        guard let highlightedCharacters else { return progress }
        return TextWidthCache.shared.fraction(of: text, characters: highlightedCharacters, fontSize: fontSize)
    }

    var body: some View {
        let progress = widthFraction
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(StageTheme.ink)
            Text(text)
                // 글자 안쪽만 칠한다 (빛 번짐 그림자를 주면 사각 마스크에 갇혀 글자 뒤에 색 상자가 생긴다)
                .foregroundStyle(LinearGradient(colors: [StageTheme.sky, StageTheme.mint], startPoint: .leading, endPoint: .trailing))
                .mask(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * progress)
                    }
                }
                .accessibilityHidden(true) // 색칠용 겹친 글자 — VoiceOver 가 같은 줄을 두 번 읽지 않게
        }
        .font(StageTheme.rounded(fontSize, .heavy))
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

/// 글자 앞부분까지의 폭 누적 (줄마다 한 번 측정해 캐시)
@MainActor
private final class TextWidthCache {
    static let shared = TextWidthCache()
    private var cache: [String: [CGFloat]] = [:]

    /// characters 개(소수 허용)까지 칠했을 때 전체 폭 대비 비율
    func fraction(of text: String, characters: Double, fontSize: CGFloat) -> Double {
        let prefix = prefixWidths(text, fontSize: fontSize)
        guard let total = prefix.last, total > 0 else { return 0 }
        let whole = min(max(Int(characters.rounded(.down)), 0), prefix.count - 1)
        let partial = characters - Double(whole)
        var width = prefix[whole]
        if whole + 1 < prefix.count {
            width += (prefix[whole + 1] - prefix[whole]) * partial
        }
        return Double(width / total)
    }

    /// prefix[k] = 앞 k 글자의 폭
    private func prefixWidths(_ text: String, fontSize: CGFloat) -> [CGFloat] {
        if let cached = cache[text] { return cached }
        // 화면 글꼴과 같은 둥근 굵은 글꼴로 잰다 (폭이 다르면 색칠 위치가 글자와 어긋난다)
        let base = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        let characters = Array(text)
        var widths: [CGFloat] = [0]
        for k in 1...max(characters.count, 1) where k <= characters.count {
            let prefix = String(characters[0..<k]) as NSString
            widths.append(prefix.size(withAttributes: [.font: font]).width)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[text] = widths
        return widths
    }
}

/// 간주 끝 무렵 다음 줄 시작 전 카운트다운 (●●● → ●● → ●)
private struct CountdownDots: View {
    let remaining: Double

    var body: some View {
        let lit = min(3, max(1, Int(remaining.rounded(.up))))
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < lit ? StageTheme.pink : Color.white.opacity(0.12))
                    .frame(width: 16, height: 16)
                    .shadow(color: index < lit ? StageTheme.pink.opacity(0.6) : .clear, radius: 8)
            }
        }
        .animation(.snappy, value: lit)
        .accessibilityLabel("\(lit)초 뒤 가사 시작")
    }
}
