// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 진행 막대: 지금 들리는 곡 위치 / 곡 길이. 끌어서 놓으면 그 위치로 이동한다 (KaraokeEngine.seek).
// 이동 중에는 목표 위치를 보여 준다 (새 위치의 소리가 닿기 전까지 들리는 위치는 옛 위치라서).

import SwiftUI

struct SongProgressBar: View {
    let engine: KaraokeEngine
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let playback = engine.heardCaptureTime().flatMap { engine.lyrics.playback(atCaptureTime: $0) }
            HStack(spacing: 10) {
                if let playback {
                    let shown = dragFraction.map { $0 * playback.duration } ?? engine.seekTarget ?? playback.position
                    timeLabel(shown, alignment: .trailing)
                    track(fraction: min(max(shown / playback.duration, 0), 1), duration: playback.duration)
                    timeLabel(playback.duration, alignment: .leading)
                }
            }
        }
        // 곡 정보가 없을 때도 같은 높이 (위의 음정 바가 들썩이지 않게)
        .frame(height: 18)
        .onHover { hovering = $0 }
    }

    private func track(fraction: Double, duration: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let active = hovering || dragFraction != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [StageTheme.sky, StageTheme.mint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, width * fraction))
                Circle()
                    .fill(StageTheme.ink)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
                    .opacity(active && engine.canControlPlayback ? 1 : 0)
            }
            .frame(height: active ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard engine.canControlPlayback, width > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        guard engine.canControlPlayback, width > 0 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        dragFraction = nil
                        engine.seek(toSongPosition: fraction * duration)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .accessibilityElement()
        .accessibilityLabel("재생 위치")
        .accessibilityValue(Self.format(fraction * duration))
    }

    private func timeLabel(_ seconds: Double, alignment: Alignment) -> some View {
        Text(Self.format(seconds))
            .font(StageTheme.rounded(11, .medium))
            .monospacedDigit()
            .foregroundStyle(StageTheme.secondaryInk)
            .frame(width: 40, alignment: alignment)
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
