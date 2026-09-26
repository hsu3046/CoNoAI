// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 노래방 무대 화면의 색·글꼴과 배경.

import AppKit
import SwiftUI

enum StageTheme {
    static let ink = Color(red: 0.93, green: 0.94, blue: 1.0)
    static let secondaryInk = Color(red: 0.60, green: 0.63, blue: 0.78)
    /// 보조 라벨 — 밝은 앨범 아트 배경 위에서도 읽히는 밝기
    static let faintInk = Color(red: 0.52, green: 0.55, blue: 0.70)
    /// 불러야 할 음·색칠된 가사
    static let mint = Color(red: 0.37, green: 0.88, blue: 0.72)
    static let sky = Color(red: 0.36, green: 0.78, blue: 1.0)
    /// 원곡 가수의 목소리·재생선
    static let pink = Color(red: 1.0, green: 0.56, blue: 0.69)
    /// 내 목소리 (마이크 채점) — 맞춘 음표도 이 색으로 남는다
    static let gold = Color(red: 1.0, green: 0.80, blue: 0.36)
    /// 노래방 끝내기 (연결 해제)
    static let stopRed = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let night = Color(red: 0.045, green: 0.05, blue: 0.10)
    static let dusk = Color(red: 0.09, green: 0.05, blue: 0.16)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// MIDI → 음이름 (60 = C4)
    static func noteName(_ midi: Double) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let n = Int(midi.rounded())
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
    }

    /// 키 표기: 0 = 원키, +2 = ♯2, −3 = ♭3
    static func keyLabel(_ key: Int) -> String {
        key == 0 ? "원키" : key > 0 ? "♯\(key)" : "♭\(-key)"
    }
}

/// 무대 배경: 밤하늘 그라데이션 위에 조명 두 개. `accent` 는 곡 분위기 색, `energy`(0…1)는 반주 세기.
struct StageBackground: View {
    var accent: Color = StageTheme.sky
    var secondAccent: Color = StageTheme.pink
    var energy: Double = 0
    /// 앨범 아트 — 크게 흐리게 깔아 곡마다 다른 무대 분위기를 낸다
    var artwork: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [StageTheme.night, StageTheme.dusk], startPoint: .top, endPoint: .bottom)
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 80)
                        .opacity(0.3)
                        .clipped()
                        .transition(.opacity)
                    // 밝은 표지에서도 글자가 읽히게 전체를 한 겹 어둡게 + 가사 쪽(아래)은 더
                    StageTheme.night.opacity(0.35)
                    LinearGradient(colors: [.clear, StageTheme.night.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                }
                RadialGradient(
                    colors: [accent.opacity(0.28 + 0.14 * energy), .clear],
                    center: UnitPoint(x: 0.18, y: 0.0),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.75
                )
                RadialGradient(
                    colors: [secondAccent.opacity(0.18 + 0.12 * energy), .clear],
                    center: UnitPoint(x: 0.9, y: 1.0),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.7
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.25), value: energy)
    }
}

/// 유리 느낌의 둥근 패널
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .background(Capsule().fill(Color.black.opacity(0.25)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func glassCapsule() -> some View { modifier(GlassCapsule()) }
}
