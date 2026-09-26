// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 마이크 채점 화면 요소: 음정 바 구석의 실시간 점수 · 곡이 끝나면 뜨는 결과 카드.

import AVFoundation
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

/// 곡이 끝나면: 드럼롤과 함께 점수가 0 부터 올라가고, 심벌이 울리는 순간 불꽃이 터진다.
/// 누르면 닫힘, 가만두면 14초 뒤 닫힘.
struct SingingResultCard: View {
    let result: SingingResult
    let dismiss: () -> Void

    /// 효과음에서 심벌이 울리는 시각 (Drumroll.m4a 를 자를 때 맞춘 값) — 숫자가 이때 멈춘다
    static let crashTime: Double = 2.8
    @State private var startedAt = Date()
    @State private var sound = CelebrationSound()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                // 무대를 어둡게 + 불꽃
                Color.black.opacity(0.45)
                Fireworks(elapsed: elapsed - Self.crashTime, bursts: Self.burstCount(for: result.score.score), seed: result.id.hashValue)
                card(elapsed: elapsed)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .onAppear {
            startedAt = Date()
            sound.play()
        }
        .onDisappear { sound.stop() }
        .task {
            try? await Task.sleep(for: .seconds(14))
            close()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("채점 결과 \(result.score.score)점")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close() }
    }

    private func close() {
        sound.stop()
        dismiss()
    }

    private func card(elapsed: Double) -> some View {
        let score = result.score
        let progress = min(1, max(0, elapsed / Self.crashTime))
        // 끝으로 갈수록 느려지게 (드럼롤이 커지는 동안 숫자가 조여 온다)
        let eased = 1 - pow(1 - progress, 3)
        let shown = Int((Double(score.score) * eased).rounded(.down))
        let landed = elapsed >= Self.crashTime
        // 심벌 순간 살짝 튀어 오르는 크기
        let pop = landed ? 1 + 0.18 * max(0, 1 - (elapsed - Self.crashTime) / 0.35) : 1

        return VStack(spacing: 10) {
            Text(result.title ?? "이번 곡")
                .font(StageTheme.rounded(16, .semibold))
                .foregroundStyle(StageTheme.secondaryInk)
                .lineLimit(1)
            Text("\(landed ? score.score : shown)")
                .font(StageTheme.rounded(96))
                .monospacedDigit()
                .foregroundStyle(StageTheme.gold)
                .shadow(color: StageTheme.gold.opacity(landed ? 0.7 : 0.35), radius: landed ? 26 : 12)
                .scaleEffect(pop)
            Group {
                Text(Self.comment(for: score.score))
                    .font(StageTheme.rounded(22))
                HStack(spacing: 22) {
                    stat("맞춘 음표", "\(score.notesHit) / \(score.notesTotal)")
                    stat("최고 연속", "\(score.bestStreak)")
                }
                .padding(.top, 4)
            }
            .opacity(landed ? min(1, (elapsed - Self.crashTime) / 0.4) : 0)
            .offset(y: landed ? 0 : 8)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 30)
        .frame(minWidth: 340)
        .background(RoundedRectangle(cornerRadius: 30).fill(StageTheme.night.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(StageTheme.gold.opacity(landed ? 0.5 : 0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30)
        .foregroundStyle(StageTheme.ink)
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

    /// 점수가 높을수록 불꽃이 많이
    static func burstCount(for score: Int) -> Int {
        switch score {
        case 90...: 10
        case 70..<90: 7
        case 50..<70: 4
        default: 2
        }
    }
}

/// 불꽃놀이: 심벌 순간(elapsed = 0)부터 0.3초 간격으로 터진다. 입자 = 초속·중력·공기 저항·잔상.
private struct Fireworks: View {
    /// 첫 불꽃부터 지난 초 (음수면 아직)
    let elapsed: Double
    let bursts: Int
    let seed: Int

    private static let palette: [Color] = [StageTheme.gold, StageTheme.pink, StageTheme.mint, StageTheme.sky, .white]
    private static let particleCount = 46
    private static let life = 1.8

    var body: some View {
        Canvas { context, size in
            guard elapsed > 0 else { return }
            var random = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
            for burst in 0..<bursts {
                // 터질 위치·색·크기는 불꽃마다 고정 (매 프레임 같은 난수열)
                let origin = CGPoint(x: size.width * random.next(in: 0.15...0.85), y: size.height * random.next(in: 0.12...0.55))
                let color = Self.palette[Int(random.next(in: 0...Double(Self.palette.count - 1)).rounded())]
                let power = random.next(in: 160...300)
                let delay = Double(burst) * 0.3 + random.next(in: 0...0.12)
                let t = elapsed - delay
                // 난수열을 불꽃마다 같은 만큼 소비해야 다음 불꽃이 흔들리지 않는다
                var angles: [(Double, Double)] = []
                for _ in 0..<Self.particleCount {
                    angles.append((random.next(in: 0...(2 * .pi)), random.next(in: 0.55...1)))
                }
                guard t > 0, t < Self.life else { continue }
                let fade = 1 - t / Self.life
                // 터지는 순간의 빛
                if t < 0.15 {
                    let flash = CGFloat(40 * (1 - t / 0.15))
                    context.fill(Path(ellipseIn: CGRect(x: origin.x - flash, y: origin.y - flash, width: flash * 2, height: flash * 2)),
                                 with: .color(color.opacity(0.35 * (1 - t / 0.15))))
                }
                for (angle, speed) in angles {
                    let point = Self.position(origin: origin, angle: angle, speed: speed * power, t: t)
                    let tail = Self.position(origin: origin, angle: angle, speed: speed * power, t: max(0, t - 0.09))
                    var streak = Path()
                    streak.move(to: tail)
                    streak.addLine(to: point)
                    context.stroke(streak, with: .color(color.opacity(fade * 0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    // 끝무렵 반짝임
                    if fade < 0.5, Int(t * 20 + angle * 10) % 3 == 0 {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(.white.opacity(fade)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 공기 저항(지수 감속) + 중력
    private static func position(origin: CGPoint, angle: Double, speed: Double, t: Double) -> CGPoint {
        let drag = 2.2
        let travel = speed * (1 - exp(-drag * t)) / drag
        let gravity = 90 * t * t
        return CGPoint(x: origin.x + cos(angle) * travel, y: origin.y + sin(angle) * travel + gravity)
    }
}

/// 매 프레임 같은 불꽃을 그리기 위한 결정적 난수 (SplitMix64)
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Double(z >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

/// 드럼롤 + 심벌 (Freesound 569113, CC0 — THIRD_PARTY_NOTICES.md)
@MainActor
final class CelebrationSound {
    private var player: AVAudioPlayer?

    func play() {
        guard let url = Bundle.main.url(forResource: "Drumroll", withExtension: "m4a") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.8
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
