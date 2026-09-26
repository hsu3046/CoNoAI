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

/// 곡이 끝나면 가운데 뜨는 결과 (12초 뒤 또는 누르면 닫힘)
struct SingingResultCard: View {
    let result: SingingResult
    let dismiss: () -> Void

    var body: some View {
        let score = result.score
        Button(action: dismiss) {
            VStack(spacing: 10) {
                Text(result.title ?? "이번 곡")
                    .font(StageTheme.rounded(16, .semibold))
                    .foregroundStyle(StageTheme.secondaryInk)
                    .lineLimit(1)
                Text("\(score.score)")
                    .font(StageTheme.rounded(84))
                    .monospacedDigit()
                    .foregroundStyle(StageTheme.gold)
                    .shadow(color: StageTheme.gold.opacity(0.45), radius: 18)
                Text(Self.comment(for: score.score))
                    .font(StageTheme.rounded(20))
                HStack(spacing: 18) {
                    stat("맞춘 음표", "\(score.notesHit) / \(score.notesTotal)")
                    stat("음정 정확도", "\(Int((Double(score.notesHit) / Double(max(1, score.notesTotal)) * 100).rounded()))%")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 28)
            .frame(minWidth: 320)
            .background(RoundedRectangle(cornerRadius: 28).fill(StageTheme.night.opacity(0.88)))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(StageTheme.gold.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StageTheme.ink)
        .help("눌러서 닫기")
        .task {
            try? await Task.sleep(for: .seconds(12))
            dismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("채점 결과 \(score.score)점")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StageTheme.rounded(18)).monospacedDigit()
            Text(title).font(StageTheme.rounded(11, .medium)).foregroundStyle(StageTheme.secondaryInk)
        }
    }

    static func comment(for score: Int) -> String {
        switch score {
        case 95...: "완벽해요!"
        case 85..<95: "훌륭해요"
        case 70..<85: "좋아요"
        case 50..<70: "조금만 더!"
        default: "연습하면 늘어요"
        }
    }
}
