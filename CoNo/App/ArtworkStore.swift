// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 곡별 앨범 아트와 거기서 뽑은 무대 조명 색. 곡이 바뀌면 한 번 가져와 곡 ID 로 기억한다.
// (지금 캡처되는 곡 기준으로 미리 가져와 두고, 화면은 "들리는 곡" 의 것을 쓴다)

import AppKit
import SwiftUI

struct TrackArtwork {
    let image: NSImage
    /// 가장 선명한 색 · 그와 색상이 다른 두 번째 색
    let primary: Color
    let secondary: Color
}

@MainActor
@Observable
final class ArtworkStore {
    private(set) var artworks: [String: TrackArtwork] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func artwork(for trackID: String?) -> TrackArtwork? {
        trackID.flatMap { artworks[$0] }
    }

    /// 새 곡이면 앨범 아트를 가져온다 (실패해도 조용히 기본 조명)
    func load(trackID: String?, from lyrics: LyricsController) {
        guard let trackID, !requested.contains(trackID) else { return }
        requested.insert(trackID)
        Task {
            guard let data = await lyrics.currentArtworkData(), let image = NSImage(data: data) else { return }
            let (primary, secondary) = ArtworkPalette.colors(of: image)
            // 오래 쓰면 쌓이지 않게 최근 몇 곡만
            if artworks.count > 12 { artworks.removeAll() }
            artworks[trackID] = TrackArtwork(image: image, primary: primary, secondary: secondary)
        }
    }
}

enum ArtworkPalette {
    /// 16×16 로 줄여 채도·밝기가 높은 색 두 개를 고른다. 무채색 표지면 기본 조명색.
    static func colors(of image: NSImage) -> (Color, Color) {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return (StageTheme.sky, StageTheme.pink) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var candidates: [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, score: CGFloat)] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(
                srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1
            )
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // 어둡거나 너무 밝은(흰색) 픽셀은 조명감이 없다
            let score = s * min(b, 1.1 - b + 0.3)
            candidates.append((h, s, b, score))
        }
        let ranked = candidates.filter { $0.saturation > 0.25 && $0.brightness > 0.2 }.sorted { $0.score > $1.score }
        guard let first = ranked.first else { return (StageTheme.sky, StageTheme.pink) }
        let second = ranked.first { hueDistance($0.hue, first.hue) > 0.12 } ?? ranked.dropFirst().first ?? first

        /// 무대 조명처럼 보이게 밝기·채도를 끌어올린다
        func glow(_ c: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, score: CGFloat)) -> Color {
            Color(hue: Double(c.hue), saturation: Double(min(max(c.saturation, 0.55), 0.9)), brightness: Double(max(c.brightness, 0.85)))
        }
        return (glow(first), glow(second))
    }

    private static func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }
}
