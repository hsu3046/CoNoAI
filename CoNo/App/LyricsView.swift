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

    var body: some View {
        TimelineView(.animation) { timeline in
            content(frameDate: timeline.date)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(Color(red: 0.05, green: 0.05, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func content(frameDate: Date) -> some View {
        // frameDate: 매 틱 다시 계산하게 하는 의존성 (값은 쓰지 않는다)
        let _ = frameDate
        let state = heardCaptureTime().map { controller.display(atCaptureTime: $0) }

        VStack(alignment: .leading, spacing: 10) {
            if let lyrics = state?.lyrics {
                if let current = lyrics.current {
                    KaraokeLine(text: current, progress: lyrics.progress, highlightedCharacters: lyrics.highlightedCharacters)
                } else if let countdown = lyrics.countdown {
                    CountdownDots(remaining: countdown)
                } else {
                    Text("♪").font(.system(size: 30, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                }
                Text(lyrics.next ?? " ")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            footer(track: state?.track)
        }
    }

    private func footer(track: TrackInfo?) -> some View {
        HStack(spacing: 6) {
            if let track {
                Image(systemName: "music.note")
                Text("\(track.title) — \(track.artist)").lineLimit(1)
            }
            Spacer()
            // 자동 싱크: 적용 중인 가사 지연 · 최근 추정 신뢰도 · 선택한 가사 후보
            let auto = controller.autoSync
            if auto.candidateCount > 0 {
                let confidence = auto.lastEstimate.map { String(format: "신뢰도 %.0f%% · %d줄", $0.confidence * 100, $0.lineCount) } ?? "측정 중"
                Text(String(format: "자동 싱크 %+.2fs (%@) · 가사 %d/%d", -auto.appliedDelay, confidence, auto.candidateIndex + 1, auto.candidateCount))
                    .monospacedDigit()
            }
            // 진단: 음악 앱 재생 위치 보고의 흔들림 (범위가 크면 앵커가 들쭉날쭉)
            let d = controller.anchorDiagnostics
            if d.count > 1, d.range > 0.15 {
                Text(String(format: "위치 흔들림 %.2fs", d.range))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange.opacity(0.8))
            }
            if case .ready(_, synced: false) = controller.status {
                Text("싱크 가사 없음")
            } else if case .ready = controller.status {
                Text("가사: LRCLIB")
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.4))
    }

    private var statusMessage: String {
        switch controller.status {
        case .inactive: "가사 꺼짐"
        case .unsupportedSource: "이 앱은 아직 가사 연동을 지원하지 않습니다 (지금은 음악 앱만)"
        case .waitingForPlayer: "음악 앱에서 곡을 재생하면 가사가 표시됩니다"
        case let .loading(track): "가사를 찾는 중… \(track.title)"
        case let .ready(track, synced): synced ? "곧 가사가 시작됩니다" : "\(track.title): 시간 정보가 있는 가사를 찾지 못했습니다"
        case let .notFound(track): "가사를 찾지 못했습니다: \(track.title) — \(track.artist)"
        case let .failed(message): message
        }
    }
}

/// 왼쪽부터 색이 차오르는 한 줄
private struct KaraokeLine: View {
    static let fontSize: CGFloat = 30
    let text: String
    let progress: Double
    /// 음절 정렬 결과 (칠해진 글자 수). 있으면 글자 폭 기준으로 칠한다.
    let highlightedCharacters: Double?

    /// 칠할 폭 비율 — 글자 수를 실제 글자 폭으로 환산 (한글·영문 폭 차이 반영, 축소 표시에도 비율은 그대로)
    private var widthFraction: Double {
        guard let highlightedCharacters else { return progress }
        return TextWidthCache.shared.fraction(of: text, characters: highlightedCharacters, fontSize: Self.fontSize)
    }

    var body: some View {
        let progress = widthFraction
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(.white.opacity(0.9))
            Text(text)
                .foregroundStyle(Color(red: 0.25, green: 0.8, blue: 1.0))
                .mask(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * progress)
                    }
                }
                .accessibilityHidden(true) // 색칠용 겹친 글자 — VoiceOver 가 같은 줄을 두 번 읽지 않게
        }
        .font(.system(size: Self.fontSize, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
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
        let dots = min(3, max(1, Int(remaining.rounded(.up))))
        Text(String(repeating: "● ", count: dots))
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Color(red: 0.25, green: 0.8, blue: 1.0))
    }
}
