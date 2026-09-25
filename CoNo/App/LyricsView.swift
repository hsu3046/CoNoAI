// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 노래방식 2줄 가사: 지금 부르는 줄(크게, 왼쪽부터 색이 차오름) + 다음 줄(작게).
// 색칠은 줄 길이에 비례한 근사 (L3 에서 음표 시작점 기반 음절 단위로 바꿀 예정).

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
                    KaraokeLine(text: current, progress: lyrics.progress)
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
    let text: String
    let progress: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).foregroundStyle(.white.opacity(0.9))
            Text(text)
                .foregroundStyle(Color(red: 0.25, green: 0.8, blue: 1.0))
                .mask(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * progress)
                    }
                }
        }
        .font(.system(size: 30, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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
