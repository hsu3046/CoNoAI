// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 곡 끝 채점 연출. 모든 그림은 "경과 초"의 순수 함수다 → 실시간(TimelineView)과 미리보기 렌더(ImageRenderer)가 같은 코드.
//   0.0s   무대가 어두워지고 카드가 튀어 오른다. 드럼롤, 점수가 게이지와 함께 올라간다
//   2.25s  첫 로켓들이 쉿- 올라간다
//   2.8s   심벌 = 점수 착지: 번쩍 · 흔들림 · 가운데와 양옆 불꽃 · 양쪽 아래 폭죽 대포 · 별점이 하나씩
//   3.3s~  점수만큼 불꽃이 이어서 팡팡 (90점 이상은 마지막에 한꺼번에 피날레)

import AVFoundation
import SwiftUI

// MARK: - 일정 (불꽃 위치·종류·시각)

struct CelebrationShow {
    enum Kind: CaseIterable {
        /// 둥글게 퍼지는 기본형
        case peony
        /// 금빛 버드나무: 느리게 늘어지며 오래 남는 꼬리
        case willow
        /// 퍼진 뒤 지지직 반짝이
        case crackle
        /// 기울어진 고리
        case ring
        /// 안쪽과 바깥쪽 색이 다른 이중 구
        case doubleColor
    }

    struct Particle {
        let angle: Double
        /// 1 = 불꽃 기본 세기
        let speed: Double
        let phase: Double
        /// 이중 구의 안쪽 입자
        let inner: Bool
    }

    struct Burst {
        let time: Double
        /// 터지는 곳 (화면 비율 0…1)
        let origin: CGPoint
        /// 로켓이 출발하는 가로 위치 (비율)
        let launchX: Double
        let kind: Kind
        let color: Color
        let secondColor: Color
        /// 화면 짧은 변 대비 퍼지는 세기
        let power: Double
        let particles: [Particle]
        /// 크게 번쩍이는 불꽃 (착지 순간)
        let isHeadline: Bool
    }

    /// 드럼롤 끝 심벌이 울리는 시각 (Drumroll.m4a 를 자를 때 맞춘 값)
    static let crashTime = 2.8
    /// 로켓이 올라가는 시간
    static let launchLead = 0.55

    let bursts: [Burst]
    let score: Int

    static let palette: [Color] = [
        StageTheme.gold, StageTheme.pink, StageTheme.mint, StageTheme.sky,
        Color(red: 1.0, green: 0.45, blue: 0.3), Color(red: 0.72, green: 0.55, blue: 1.0),
    ]

    init(score: Int, seed: UInt64) {
        self.score = score
        var random = SeededRandom(seed: seed)
        var bursts: [Burst] = []

        func make(at time: Double, origin: CGPoint, kind: Kind, power: Double, headline: Bool = false) -> Burst {
            let color = Self.palette[random.index(Self.palette.count)]
            var second = Self.palette[random.index(Self.palette.count)]
            if kind == .willow { second = StageTheme.gold }
            let count = switch kind {
            case .peony: 130
            case .willow: 90
            case .crackle: 100
            case .ring: 60
            case .doubleColor: 160
            }
            let particles = (0..<count).map { index -> Particle in
                let inner = kind == .doubleColor && index % 2 == 0
                let angle = kind == .ring
                    ? Double(index) / Double(count) * 2 * .pi
                    : random.next(in: 0...(2 * .pi))
                let speed = kind == .ring ? 1 : random.next(in: 0.62...1) * (inner ? 0.55 : 1)
                return Particle(angle: angle, speed: speed, phase: random.next(in: 0...(2 * .pi)), inner: inner)
            }
            return Burst(
                time: time,
                origin: origin,
                launchX: origin.x + random.next(in: -0.08...0.08),
                kind: kind,
                color: kind == .willow ? StageTheme.gold : color,
                secondColor: second,
                power: power,
                particles: particles,
                isHeadline: headline
            )
        }

        // 착지 순간: 점수 뒤 큰 이중 불꽃 + 양옆 두 발
        bursts.append(make(at: Self.crashTime, origin: CGPoint(x: 0.5, y: 0.36), kind: .doubleColor, power: 0.52, headline: true))
        bursts.append(make(at: Self.crashTime + 0.06, origin: CGPoint(x: 0.16, y: 0.3), kind: .peony, power: 0.36))
        bursts.append(make(at: Self.crashTime + 0.12, origin: CGPoint(x: 0.84, y: 0.27), kind: .peony, power: 0.36))

        // 이어지는 불꽃 (점수만큼)
        let extra = switch score {
        case 90...: 9
        case 70..<90: 6
        case 50..<70: 3
        default: 1
        }
        var time = Self.crashTime + 0.55
        for index in 0..<extra {
            let left = index % 2 == 0
            let x = left ? random.next(in: 0.08...0.42) : random.next(in: 0.58...0.92)
            let kinds: [Kind] = [.peony, .willow, .crackle, .ring, .doubleColor]
            bursts.append(make(
                at: time,
                origin: CGPoint(x: x, y: random.next(in: 0.12...0.45)),
                kind: kinds[random.index(kinds.count)],
                power: random.next(in: 0.28...0.42)
            ))
            time += random.next(in: 0.26...0.42)
        }
        // 90점 이상: 피날레 (한꺼번에)
        if score >= 90 {
            time += 0.25
            for x in [0.2, 0.5, 0.8] {
                bursts.append(make(at: time + random.next(in: 0...0.1), origin: CGPoint(x: x, y: random.next(in: 0.14...0.3)), kind: .willow, power: 0.44))
            }
        }
        self.bursts = bursts
    }

    /// 팡 소리·번쩍·흔들림이 나는 시각 (착지 순간 가까이 붙은 것은 하나로)
    var bangTimes: [(time: Double, strength: Double)] {
        bursts.map { ($0.time, $0.isHeadline ? 1 : 0.55) }
    }
}

// MARK: - 한 장면 (경과 초 → 그림)

struct CelebrationFrame: View {
    let result: SingingResult
    let artwork: NSImage?
    let show: CelebrationShow
    let elapsed: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shake = Self.shake(at: elapsed, bangs: show.bangTimes)
            ZStack {
                // 무대 어둡게 (가장자리 더 어둡게)
                RadialGradient(
                    colors: [Color.black.opacity(0.5), Color.black.opacity(0.85)],
                    center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7
                )
                .opacity(min(1, elapsed / 0.35))

                FireworksLayer(show: show, elapsed: elapsed)
                // 점수 뒤만 살짝 어둡게 (불꽃이 뒤에서 터져도 숫자가 읽히게)
                RadialGradient(colors: [Color.black.opacity(0.55), .clear], center: .center, startRadius: 60, endRadius: 330)
                    .opacity(min(1, elapsed / 0.35))
                ConfettiLayer(elapsed: elapsed - CelebrationShow.crashTime, seed: 99)
                ScoreCard(result: result, artwork: artwork, elapsed: elapsed)
                    .scaleEffect(min(1.25, max(0.7, size.height / 780)))
                    .offset(x: shake.width, y: shake.height)

                // 번쩍
                Color(red: 1, green: 0.86, blue: 0.62)
                    .opacity(Self.flash(at: elapsed, bangs: show.bangTimes))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    static func flash(at t: Double, bangs: [(time: Double, strength: Double)]) -> Double {
        var amount = 0.0
        for bang in bangs {
            let dt = t - bang.time
            guard dt >= 0, dt < 0.22 else { continue }
            amount = max(amount, (bang.strength >= 1 ? 0.32 : 0.1) * pow(1 - dt / 0.22, 2))
        }
        return amount
    }

    static func shake(at t: Double, bangs: [(time: Double, strength: Double)]) -> CGSize {
        var x = 0.0
        var y = 0.0
        for (index, bang) in bangs.enumerated() {
            let dt = t - bang.time
            guard dt >= 0, dt < 0.5 else { continue }
            let amplitude = (bang.strength >= 1 ? 14 : 5) * exp(-dt * 9)
            x += amplitude * sin(dt * 95 + Double(index))
            y += amplitude * 0.7 * cos(dt * 83 + Double(index) * 1.7)
        }
        return CGSize(width: x, height: y)
    }
}

// MARK: - 점수 카드

private struct ScoreCard: View {
    let result: SingingResult
    let artwork: NSImage?
    let elapsed: Double

    private var crash: Double { CelebrationShow.crashTime }
    private var landed: Bool { elapsed >= crash }
    private var sinceLanding: Double { elapsed - crash }

    // 네모 창 없이 무대 위에 떠 있는 점수판: 곡 이름표 · 게이지와 점수 · 별 · 한마디 · 기록
    var body: some View {
        let score = result.score
        // 등장: 아래에서 튀어 오르며 커진다 (살짝 넘쳤다 돌아옴)
        let appear = min(1, elapsed / 0.45)
        let entrance = Self.backOut(appear)

        VStack(spacing: 16) {
            header
                .opacity(appear)
            ZStack {
                SunburstRays(elapsed: elapsed, landed: landed)
                    .frame(width: 640, height: 640)
                    .opacity(landed ? min(1, sinceLanding / 0.3) : 0)
                    .scaleEffect(landed ? 0.75 + 0.25 * Self.cubicOut(min(1, sinceLanding / 0.5)) : 0.75)
                gauge(score: score.score)
                scoreNumber(score.score)
            }
            .frame(height: 330)
            .scaleEffect(0.7 + 0.3 * entrance)
            stars(score.score)
            Text(SingingResultCard.comment(for: score.score))
                .font(StageTheme.rounded(40, .heavy))
                .foregroundStyle(
                    LinearGradient(colors: [StageTheme.gold, Color(red: 1, green: 0.62, blue: 0.4), StageTheme.pink], startPoint: .leading, endPoint: .trailing)
                )
                .shadow(color: StageTheme.pink.opacity(0.5), radius: 16)
                .scaleEffect(reveal(after: 0.55) > 0 ? 1 + 0.25 * exp(-(sinceLanding - 0.55) * 8) : 1)
                .opacity(reveal(after: 0.55))
            HStack(spacing: 12) {
                chip("scope", "맞춘 음표", "\(score.notesHit) / \(score.notesTotal)")
                chip("flame.fill", "최고 연속", "\(score.bestStreak)")
            }
            .opacity(reveal(after: 0.85))
            .offset(y: 14 * (1 - reveal(after: 0.85)))
            Text("눌러서 닫기 · Esc")
                .font(StageTheme.rounded(12, .medium))
                .foregroundStyle(StageTheme.faintInk)
                .opacity(reveal(after: 1.8) * 0.8)
                .padding(.top, 2)
        }
        .frame(width: 640)
        .offset(y: 50 * (1 - entrance))
        .foregroundStyle(StageTheme.ink)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.mic")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(StageTheme.gold)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title ?? "이번 곡")
                    .font(StageTheme.rounded(18))
                    .lineLimit(1)
                Text(result.artist ?? "채점 결과")
                    .font(StageTheme.rounded(13, .medium))
                    .foregroundStyle(StageTheme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    // 게이지: 점수만큼 금→분홍 고리가 차오르고, 착지하면 빛이 고리를 돈다
    private func gauge(score: Int) -> some View {
        let fill = Double(score) / 100 * Self.cubicOut(countProgress)
        let diameter: CGFloat = 300
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 18)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(
                    AngularGradient(colors: [StageTheme.gold, Color(red: 1, green: 0.6, blue: 0.3), StageTheme.pink, StageTheme.gold], center: .center),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: StageTheme.gold.opacity(landed ? 0.9 : 0.35), radius: landed ? 20 : 6)
            // 착지 뒤 고리 위를 도는 빛
            Circle()
                .trim(from: 0, to: 0.12)
                .stroke(Color.white.opacity(landed ? 0.7 * max(0, 1 - sinceLanding / 3) : 0), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90 + sinceLanding * 220))
                .blur(radius: 2)
            // 고리 끝 빛나는 점
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: StageTheme.gold, radius: 12)
                .offset(y: -diameter / 2)
                .rotationEffect(.degrees(360 * fill))
                .opacity(fill > 0.01 ? 1 : 0)
        }
        .frame(width: diameter, height: diameter)
    }

    private func scoreNumber(_ score: Int) -> some View {
        let shown = landed ? score : Int((Double(score) * Self.cubicOut(countProgress)).rounded(.down))
        // 드럼롤 동안 점점 세게 두근거리고, 착지하면 쾅 커졌다가 튕기며 돌아온다
        let pulse = landed ? 0 : 0.04 * countProgress * sin(elapsed * 2 * .pi * 7)
        let slam = landed ? 0.5 * exp(-sinceLanding * 7) * cos(sinceLanding * 20) : 0
        return VStack(spacing: -10) {
            Text("\(shown)")
                .font(StageTheme.rounded(150, .heavy))
                .monospacedDigit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.97, blue: 0.78), StageTheme.gold, Color(red: 1, green: 0.52, blue: 0.22)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: Color(red: 1, green: 0.6, blue: 0.2).opacity(landed ? 0.95 : 0.45), radius: landed ? 34 : 14)
                .blur(radius: landed ? 0 : 1.4 * (1 - countProgress))
            Text("점")
                .font(StageTheme.rounded(24))
                .foregroundStyle(StageTheme.secondaryInk)
        }
        .scaleEffect(1 + pulse + slam)
    }

    // 별점: 착지 뒤 하나씩 뿅
    private func stars(_ score: Int) -> some View {
        let value = (Double(score) / 10).rounded() / 2 // 0…5, 0.5 단위
        return HStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { index in
                let symbol = value >= Double(index) + 1 ? "star.fill" : value >= Double(index) + 0.5 ? "star.leadinghalf.filled" : "star"
                let t = sinceLanding - 0.12 - Double(index) * 0.11
                let pop = t <= 0 ? 0 : 1 + 0.55 * exp(-t * 8) * sin(t * 18)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(symbol == "star" ? Color.white.opacity(0.2) : StageTheme.gold)
                    .shadow(color: StageTheme.gold.opacity(symbol == "star" ? 0 : 0.8), radius: 10)
                    .scaleEffect(max(0, pop))
                    .rotationEffect(.degrees(t <= 0 ? -60 : -60 * exp(-t * 7)))
            }
        }
        .frame(height: 46)
    }

    private func chip(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(StageTheme.gold)
            Text(title)
                .font(StageTheme.rounded(13, .medium))
                .foregroundStyle(StageTheme.secondaryInk)
            Text(value)
                .font(StageTheme.rounded(18))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.4)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    /// 드럼롤 진행 0…1
    private var countProgress: Double { min(1, max(0, elapsed / crash)) }

    private func reveal(after delay: Double) -> Double {
        min(1, max(0, (sinceLanding - delay) / 0.35))
    }

    static func cubicOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// 끝에서 살짝 넘쳤다 돌아오는 곡선
    static func backOut(_ x: Double) -> Double {
        let c = 1.9
        return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
    }
}

/// 점수 뒤로 천천히 도는 빛줄기
private struct SunburstRays: View {
    let elapsed: Double
    let landed: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let rays = 18
            let turn = elapsed * 0.35
            var path = Path()
            for index in 0..<rays {
                let a = Double(index) / Double(rays) * 2 * .pi + turn
                let half = .pi / Double(rays) * 0.55
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + cos(a - half) * radius, y: center.y + sin(a - half) * radius))
                path.addLine(to: CGPoint(x: center.x + cos(a + half) * radius, y: center.y + sin(a + half) * radius))
                path.closeSubpath()
            }
            context.fill(path, with: .radialGradient(
                Gradient(colors: [StageTheme.gold.opacity(0.32), StageTheme.gold.opacity(0.08), .clear]),
                center: center, startRadius: 40, endRadius: radius
            ))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 불꽃

private struct FireworksLayer: View {
    let show: CelebrationShow
    let elapsed: Double

    var body: some View {
        Canvas { context, size in
            context.blendMode = .plusLighter
            let unit = min(size.width, size.height)
            for burst in show.bursts {
                drawRocket(burst, in: &context, size: size)
                drawExplosion(burst, in: &context, size: size, unit: unit)
            }
        }
        .allowsHitTesting(false)
    }

    private func origin(_ burst: CelebrationShow.Burst, _ size: CGSize) -> CGPoint {
        CGPoint(x: burst.origin.x * size.width, y: burst.origin.y * size.height)
    }

    /// 로켓: 아래에서 올라가며 느려지고, 불티 꼬리를 남긴다
    private func drawRocket(_ burst: CelebrationShow.Burst, in context: inout GraphicsContext, size: CGSize) {
        let lead = CelebrationShow.launchLead
        let t = elapsed - (burst.time - lead)
        guard t > 0, t < lead else { return }
        let start = CGPoint(x: burst.launchX * size.width, y: size.height * 1.02)
        let end = origin(burst, size)
        func point(_ u: Double) -> CGPoint {
            let e = 1 - pow(1 - max(0, min(1, u)), 2)
            return CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e)
        }
        let u = t / lead
        var trail = Path()
        trail.move(to: point(max(0, u - 0.28)))
        trail.addLine(to: point(u))
        context.stroke(trail, with: .linearGradient(
            Gradient(colors: [burst.color.opacity(0), Color.white.opacity(0.9)]),
            startPoint: point(max(0, u - 0.28)), endPoint: point(u)
        ), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let head = point(u)
        context.fill(Path(ellipseIn: CGRect(x: head.x - 9, y: head.y - 9, width: 18, height: 18)), with: .color(burst.color.opacity(0.35)))
        context.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)), with: .color(.white))
        // 불티
        for index in 0..<6 {
            let back = u - Double(index) * 0.04 - 0.02
            guard back > 0 else { continue }
            var p = point(back)
            p.x += CGFloat(sin(Double(index) * 7.3 + elapsed * 40) * 3)
            p.y += CGFloat(index) * 2
            context.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)),
                         with: .color(StageTheme.gold.opacity(0.8 - Double(index) * 0.12)))
        }
    }

    private func drawExplosion(_ burst: CelebrationShow.Burst, in context: inout GraphicsContext, size: CGSize, unit: Double) {
        let t = elapsed - burst.time
        let willow = burst.kind == .willow
        let life = willow ? 2.8 : 1.9
        guard t > 0, t < life else { return }
        let center = origin(burst, size)
        let power = burst.power * unit * 2.3
        let drag = willow ? 1.3 : 2.5
        let gravity = (willow ? 150 : 80) * unit / 760
        let fade = pow(1 - t / life, willow ? 0.9 : 1.4)

        // 팡: 하얀 빛 덩어리가 부풀었다 꺼진다
        if t < 0.3 {
            let k = 1 - t / 0.3
            let radius = CGFloat((burst.isHeadline ? 230 : 130) * (0.5 + 0.5 * (1 - k)) * unit / 760)
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [Color.white.opacity(0.95 * k), burst.color.opacity(0.55 * k), burst.color.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: radius))
        }
        // 팡!: 사방으로 번쩍 뻗는 빛줄기 (0.12초)
        if t < 0.12 {
            let k = t / 0.12
            var rays = Path()
            let count = burst.isHeadline ? 16 : 10
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * .pi + burst.particles[0].phase
                let long = index % 2 == 0 ? 1.0 : 0.6
                let inner = power * 0.05
                let outer = power * (0.12 + 0.3 * k) * long
                rays.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                rays.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            }
            context.stroke(rays, with: .color(Color.white.opacity(0.9 * (1 - k))), style: StrokeStyle(lineWidth: burst.isHeadline ? 4 : 2.5, lineCap: .round))
        }
        // 충격파: 가운데 큰 불꽃만, 흐릿한 굵은 고리가 빠르게 퍼지며 사라진다
        if burst.isHeadline, t < 0.3 {
            let k = t / 0.3
            let radius = CGFloat(power * 0.32 * (1 - pow(1 - k, 3)))
            let ringHeight = radius
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - ringHeight, width: radius * 2, height: ringHeight * 2)),
                           with: .color(burst.color.opacity(0.35 * (1 - k))), lineWidth: CGFloat(10 * (1 - k) + 1))
        }

        func position(_ particle: CelebrationShow.Particle, _ time: Double) -> CGPoint {
            let time = max(0, time)
            let travel = particle.speed * power * (1 - exp(-drag * time)) / drag
            var dx = cos(particle.angle) * travel
            var dy = sin(particle.angle) * travel
            if burst.kind == .ring { dy *= 0.42 }
            dy += gravity * time * time
            // 버드나무는 늘어지며 살짝 흔들린다
            if willow { dx += sin(time * 2 + particle.phase) * 4 }
            return CGPoint(x: center.x + dx, y: center.y + dy)
        }

        // 처음 0.1초는 하얗게 달궈진 색 → 제 색
        let hot = max(0, 1 - t / 0.12)
        let segments = willow ? 14 : burst.kind == .ring ? 3 : 9
        let step = willow ? 0.05 : 0.03
        for layer in [false, true] where layer == false || burst.kind == .doubleColor {
            let color = layer ? burst.secondColor : burst.color
            let particles = burst.particles.filter { $0.inner == layer }
            // 꼬리: 같은 투명도끼리 한 Path 로 (입자마다 그리면 너무 많다)
            for segment in 0..<segments {
                var path = Path()
                for particle in particles {
                    let a = t - Double(segment) * step
                    guard a > 0 else { continue }
                    path.move(to: position(particle, a))
                    path.addLine(to: position(particle, a - step))
                }
                let alpha = fade * (1 - Double(segment) / Double(segments)) * (willow ? 0.75 : 0.9)
                context.stroke(path, with: .color(color.opacity(alpha)),
                               style: StrokeStyle(lineWidth: CGFloat((willow ? 3 : 3.6) * (1 - Double(segment) / Double(segments + 2))), lineCap: .round))
            }
            // 머리: 번짐 + 밝은 심
            var glow = Path()
            var core = Path()
            for particle in particles {
                // 끝무렵 반짝반짝
                if t > life * 0.55, sin(t * 38 + particle.phase * 5) < -0.2 { continue }
                let p = position(particle, t)
                glow.addEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                core.addEllipse(in: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
            }
            context.fill(glow, with: .color(color.opacity(0.32 * fade)))
            context.fill(core, with: .color(Color.white.opacity(fade * 0.7 + hot * 0.3)))

            // 지지직: 퍼진 뒤 입자 주변에 흰 반짝이
            if burst.kind == .crackle, t > 0.7, t < 1.4 {
                var sparks = Path()
                let bucket = Int(t * 30)
                for (index, particle) in particles.enumerated() where (index + bucket) % 3 == 0 {
                    let p = position(particle, t)
                    for k in 0..<3 {
                        let jitter = Double((index * 31 + bucket * 17 + k * 7) % 21) - 10
                        let jitterY = Double((index * 13 + bucket * 29 + k * 11) % 21) - 10
                        sparks.addEllipse(in: CGRect(x: p.x + jitter - 1.2, y: p.y + jitterY - 1.2, width: 2.4, height: 2.4))
                    }
                }
                context.fill(sparks, with: .color(Color.white.opacity(0.9 * (1 - (t - 0.7) / 0.7))))
            }
        }
    }
}

// MARK: - 폭죽 (양쪽 아래 대포 + 위에서 내리는 종이)

private struct ConfettiLayer: View {
    /// 착지부터 지난 초
    let elapsed: Double
    let seed: UInt64

    private struct Piece {
        let start: CGPoint // 비율
        let velocity: CGVector // 화면 높이/초
        let spin: Double
        let phase: Double
        let color: Color
        let size: CGSize
        let delay: Double
    }

    private static let colors: [Color] = [StageTheme.gold, StageTheme.pink, StageTheme.mint, StageTheme.sky, .white, Color(red: 1, green: 0.45, blue: 0.3)]

    private var pieces: [Piece] {
        var random = SeededRandom(seed: seed)
        var pieces: [Piece] = []
        // 대포: 왼쪽 아래 → 오른쪽 위, 오른쪽 아래 → 왼쪽 위
        for side in [0.0, 1.0] {
            for _ in 0..<110 {
                let angle = random.next(in: 38...78) * .pi / 180
                let speed = random.next(in: 0.9...2.1)
                let direction = side == 0 ? 1.0 : -1.0
                pieces.append(Piece(
                    start: CGPoint(x: side == 0 ? 0.02 : 0.98, y: 1.02),
                    velocity: CGVector(dx: cos(angle) * speed * direction * 1.1, dy: -sin(angle) * speed),
                    spin: random.next(in: 6...16),
                    phase: random.next(in: 0...(2 * .pi)),
                    color: Self.colors[random.index(Self.colors.count)],
                    size: CGSize(width: random.next(in: 6...10), height: random.next(in: 10...16)),
                    delay: random.next(in: 0...0.12)
                ))
            }
        }
        // 위에서 내리는 종이
        for _ in 0..<70 {
            pieces.append(Piece(
                start: CGPoint(x: random.next(in: 0...1), y: random.next(in: -0.35 ... -0.05)),
                velocity: CGVector(dx: 0, dy: random.next(in: 0.1...0.2)),
                spin: random.next(in: 3...9),
                phase: random.next(in: 0...(2 * .pi)),
                color: Self.colors[random.index(Self.colors.count)],
                size: CGSize(width: random.next(in: 6...9), height: random.next(in: 9...14)),
                delay: random.next(in: 0.2...1.2)
            ))
        }
        return pieces
    }

    var body: some View {
        Canvas { context, size in
            guard elapsed > 0 else { return }
            for piece in pieces {
                let t = elapsed - piece.delay
                guard t > 0 else { continue }
                let h = size.height
                let cannon = piece.velocity.dy < 0
                var x: Double
                var y: Double
                if cannon {
                    // 공기 저항이 큰 종이: 빠르게 솟았다가 둥실 내려온다
                    let drag = 2.6
                    let rise = (1 - exp(-drag * t)) / drag
                    x = piece.start.x * size.width + piece.velocity.dx * h * rise
                    y = piece.start.y * h + piece.velocity.dy * h * rise + 0.09 * h * t * t
                } else {
                    x = piece.start.x * size.width
                    y = piece.start.y * h + piece.velocity.dy * h * t
                }
                // 팔랑팔랑
                x += sin(t * 3 + piece.phase) * 18 * min(1, t)
                guard y < h + 30 else { continue }
                let flip = cos(t * piece.spin + piece.phase)
                let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2, width: piece.size.width * max(0.15, abs(flip)), height: piece.size.height)
                var local = context
                local.translateBy(x: x, y: y)
                local.rotate(by: .radians(t * piece.spin * 0.4 + piece.phase))
                let shade = flip > 0 ? 1.0 : 0.7
                local.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color.opacity(shade * min(1, (6 - t) / 1.5))))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 소리

/// 드럼롤(Freesound 569113, CC0) + 불꽃 소리(CoNo 합성, scripts/make_fireworks_sfx.py)를 장면 시각에 맞춰 예약한다
@MainActor
final class CelebrationAudio {
    private var players: [AVAudioPlayer] = []

    /// - Parameter lead: 첫 소리까지 여유 (화면 시계와 같은 기준으로 맞춘다)
    func play(show: CelebrationShow, lead: Double) {
        stop()
        guard let drumroll = Self.player("Drumroll", volume: 0.8) else { return }
        let base = drumroll.deviceCurrentTime + lead
        drumroll.play(atTime: base)
        players.append(drumroll)

        // 로켓 쉿- : 한꺼번에 오르는 무리는 한 번만
        var lastLaunch = -10.0
        for burst in show.bursts {
            let at = burst.time - CelebrationShow.launchLead
            guard at - lastLaunch > 0.25, let launch = Self.player("FireworkLaunch", volume: 0.35) else { continue }
            launch.pan = Float(burst.origin.x * 2 - 1) * 0.6
            launch.play(atTime: base + at)
            players.append(launch)
            lastLaunch = at
        }
        // 팡: 불꽃마다 (세 가지 소리를 돌려 쓴다)
        for (index, burst) in show.bursts.enumerated() {
            guard let bang = Self.player("FireworkBang\(index % 3 + 1)", volume: burst.isHeadline ? 0.95 : Float(0.55 + 0.1 * Double(index % 3))) else { continue }
            bang.pan = Float(burst.origin.x * 2 - 1) * 0.7
            bang.play(atTime: base + burst.time)
            players.append(bang)
        }
    }

    func stop() {
        players.forEach { $0.stop() }
        players.removeAll()
    }

    private static func player(_ name: String, volume: Float) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.volume = volume
        player.prepareToPlay()
        return player
    }
}

// MARK: - 결정적 난수 (매 프레임 같은 장면)

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return range.lowerBound + Double(z >> 11) / Double(UInt64(1) << 53) * (range.upperBound - range.lowerBound)
    }

    mutating func index(_ count: Int) -> Int {
        min(count - 1, Int(next(in: 0...Double(count))))
    }
}

#if DEBUG
/// 개발용: CONO_RENDER_CELEBRATION=<폴더> 로 실행하면 연출의 여러 순간을 PNG 로 저장하고 끝낸다
@MainActor
enum CelebrationPreviewRenderer {
    static func renderIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["CONO_RENDER_CELEBRATION"] else { return }
        let score = Int(ProcessInfo.processInfo.environment["CONO_RENDER_SCORE"] ?? "") ?? 92
        let result = SingingResult(
            trackID: nil, title: "First Love (Remastered 2014)", artist: "宇多田ヒカル",
            score: SongScore(notesTotal: 474, notesHit: 400, creditSeconds: Double(score), totalSeconds: 100, streak: 0, bestStreak: 37)
        )
        let show = CelebrationShow(score: score, seed: 42)
        let times = [0.2, 0.5, 1.4, 2.4, 2.7, 2.85, 2.95, 3.1, 3.4, 3.8, 4.3, 5.0, 6.0]
        for time in times {
            let view = ZStack {
                LinearGradient(colors: [Color(red: 0.25, green: 0.12, blue: 0.2), Color(red: 0.08, green: 0.1, blue: 0.2)], startPoint: .top, endPoint: .bottom)
                CelebrationFrame(result: result, artwork: nil, show: show, elapsed: time)
            }
            .frame(width: 1100, height: 760)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            if let image = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "celebration-%05.2f.png", time))
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        exit(0)
    }
}
#endif
