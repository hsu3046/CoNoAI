// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 마이크 채점 화면 요소: 음정 바 구석의 실시간 점수 · 곡이 끝나면 뜨는 결과 카드.

import SwiftUI

/// 음정 바 오른쪽 아래: 지금까지 점수와 맞춘 음표 (0.25초마다)
struct LiveScoreChip: View {
    let singing: SingingTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let score = singing.snapshot().score
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StageTheme.gold)
                if score.notesTotal == 0 {
                    Text("듣는 중")
                        .font(StageTheme.rounded(12, .semibold))
                        .foregroundStyle(StageTheme.secondaryInk)
                } else {
                    Text("\(score.score)")
                        .font(StageTheme.rounded(18))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(score.score)))
                    Text("음표 \(score.notesHit)/\(score.notesTotal)")
                        .font(StageTheme.rounded(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(StageTheme.secondaryInk)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.4)))
            .overlay(Capsule().strokeBorder(StageTheme.gold.opacity(0.25), lineWidth: 1))
            .animation(.snappy, value: score.score)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(score.notesTotal == 0 ? "채점: 듣는 중" : "채점 \(score.score)점, 음표 \(score.notesHit)개 맞춤, 전체 \(score.notesTotal)개")
        }
    }
}

/// 곡이 끝나면 뜨는 채점 연출 (CelebrationView.swift). 누르면 닫힘, 가만두면 14초 뒤 닫힘.
struct SingingResultCard: View {
    let result: SingingResult
    let artwork: NSImage?
    let dismiss: () -> Void

    private let show: CelebrationShow
    /// 소리를 예약할 여유 — 화면 시계도 같은 만큼 늦게 시작해 드럼롤·팡과 맞춘다
    private static let audioLead = 0.08
    @State private var startedAt: Date?
    @State private var audio = CelebrationAudio()

    init(result: SingingResult, artwork: NSImage?, dismiss: @escaping () -> Void) {
        self.result = result
        self.artwork = artwork
        self.dismiss = dismiss
        show = CelebrationShow(score: result.score.score, seed: UInt64(truncatingIfNeeded: result.id.hashValue))
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = startedAt.map { context.date.timeIntervalSince($0) - Self.audioLead } ?? 0
            CelebrationFrame(result: result, artwork: artwork, show: show, elapsed: max(0, elapsed))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .onAppear {
            startedAt = Date()
            audio.play(show: show, lead: Self.audioLead)
        }
        .onDisappear { audio.stop() }
        .task {
            try? await Task.sleep(for: .seconds(14))
            close()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("채점 결과 \(result.score.score)점, \(Self.comment(for: result.score.score))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close() }
    }

    private func close() {
        audio.stop()
        dismiss()
    }

    static func comment(for score: Int) -> String {
        switch score {
        case 95...: "완벽해요!"
        case 85..<95: "훌륭해요!"
        case 70..<85: "좋아요!"
        case 50..<70: "조금만 더!"
        default: "연습하면 늘어요"
        }
    }
}
