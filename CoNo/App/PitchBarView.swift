// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 귀렌찬 스타일 음정 바: 원곡 보컬의 음표가 오른쪽에서 흘러와 재생선(왼쪽 1/4)을 지나간다.
// 시간축은 출력 스트림 초 — KaraokeEngine.displayPosition() 과 PitchTimeline 이 같은 축이다.

import SwiftUI

struct PitchBarView: View {
    let timeline: PitchTimeline
    let position: () -> Double?
    /// 키 조절 반음 — 원곡 음정에 더해 "지금 들리는 키" 로 그린다
    var keyShift: Int = 0
    /// 좌상단 진단 숫자 (설정 › 진단)
    var showDiagnostics = false

    /// 재생선 왼쪽(지나간 부분)과 오른쪽(앞으로 부를 부분)에 보여줄 초
    private let pastSeconds = 1.5
    private let futureSeconds = 4.5
    private let segmenter = NoteSegmenter()
    @State private var range = MidiRangeTracker()
    /// 진단용: 그리기 횟수 (멈춤이 "안 그림"인지 "위치 정지"인지 구별)
    @State private var drawCounter = DrawCounter()

    var body: some View {
        // Canvas 는 그리기 함수가 쓰는 입력이 바뀔 때만 다시 그린다. 타이머 시각을 넘기지 않으면
        // 매 틱이 "변화 없음"으로 판단돼 그리기를 건너뛴다 (창 크기를 바꿀 때만 갱신되던 버그).
        TimelineView(.animation) { timelineContext in
            Canvas { [date = timelineContext.date] context, size in
                draw(in: &context, size: size, frameDate: date)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("음정 바")
    }

    /// - Parameter frameDate: TimelineView 틱 시각. 값 자체는 쓰지 않지만 매 틱 다시 그리게 하는 의존성이다
    ///   (재생 위치는 오디오 출력 시각 기반의 `position()` 이 더 정확하다).
    private func draw(in context: inout GraphicsContext, size: CGSize, frameDate: Date) {
        _ = frameDate
        drawCounter.count += 1
        guard let now = position() else {
            context.draw(
                Text("곧 음정이 흐릅니다").font(StageTheme.rounded(14, .medium)).foregroundStyle(StageTheme.faintInk),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let t0 = now - pastSeconds
        let t1 = now + futureSeconds
        let period = timeline.framePeriod
        // 음표 경계가 창 가장자리에서 흔들리지 않도록 1초 앞부터 잘라 묶는다
        let snapshot = timeline.snapshot(from: t0 - 1, to: t1)
        let notes = segmenter.segment(snapshot.frames).map {
            SungNote(startFrame: $0.startFrame, endFrame: $0.endFrame, midi: $0.midi + keyShift)
        }
        range.update(with: notes, framePeriod: period, now: now)

        let low = range.low
        let high = range.high
        let rows = high - low + 1
        let rowHeight = size.height / rows
        func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / (t1 - t0)) * size.width }
        func y(_ midi: Double) -> CGFloat { size.height - CGFloat((midi - low + 0.5) / rows) * size.height }

        // 반음 격자 + C 라벨
        for midi in Int(low.rounded(.down))...Int(high.rounded(.up)) {
            let lineY = y(Double(midi)) + rowHeight / 2
            let isC = midi % 12 == 0
            var line = Path()
            line.move(to: CGPoint(x: 0, y: lineY))
            line.addLine(to: CGPoint(x: size.width, y: lineY))
            context.stroke(line, with: .color(.white.opacity(isC ? 0.12 : 0.035)), lineWidth: 1)
            if isC {
                context.draw(
                    Text("C\(midi / 12 - 1)").font(StageTheme.rounded(10, .semibold)).foregroundStyle(StageTheme.faintInk),
                    at: CGPoint(x: 10, y: y(Double(midi))),
                    anchor: .leading
                )
            }
        }

        // 분석 경계(미래 쪽) 근처에서 음표·곡선만 서서히 사라지게 하는 가로 그라데이션.
        // 덮개를 씌우면 격자선까지 지워져 선이 끊겨 보였다 → 음표·곡선의 채색 자체에만 적용한다.
        let knownX = x(snapshot.knownUntil)
        let fadeStart = CGPoint(x: knownX - 60, y: 0)
        let fadeEnd = CGPoint(x: knownX, y: 0)
        func fading(_ color: Color) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: [color, color.opacity(0)]), startPoint: fadeStart, endPoint: fadeEnd)
        }

        // 음표 막대: 지난 음 흐리게 · 지금 부를 음 민트로 빛나게 · 다가오는 음 흰색
        let playheadX = x(now)
        for note in notes {
            let start = Double(note.startFrame) * period
            let end = Double(note.endFrame) * period
            guard end > t0, start < t1 else { continue }
            let rect = CGRect(
                x: x(start),
                y: y(Double(note.midi)) - rowHeight / 2 + 1.5,
                width: max(3, x(end) - x(start)),
                height: max(4, rowHeight - 3)
            )
            let bar = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            if end < now {
                context.fill(bar, with: .color(.white.opacity(0.16)))
            } else if start <= now {
                // 빛 번짐 → 본체
                context.fill(Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: rect.height / 2 + 4),
                             with: .color(StageTheme.mint.opacity(0.22)))
                context.fill(bar, with: .color(StageTheme.mint))
            } else {
                context.fill(bar, with: fading(.white.opacity(0.82)))
            }
        }

        // 원곡 보컬 음정 곡선 (무성·끊김에서 선을 끊는다) — 재생선까지만 그려 "지금 부르는 음" 을 따라간다
        var contour = Path()
        var previousIndex: Int?
        var headPoint: CGPoint?
        for frame in snapshot.frames where frame.confidence >= segmenter.voicedThreshold && frame.pitchHz > 0 {
            let t = Double(frame.index) * period
            guard t >= t0 else { continue }
            guard t <= now else { break }
            let point = CGPoint(x: x(t), y: y(NoteSegmenter.midi(fromHz: frame.pitchHz) + Double(keyShift)))
            if let previousIndex, frame.index - previousIndex <= 2 {
                contour.addLine(to: point)
            } else {
                contour.move(to: point)
            }
            previousIndex = frame.index
            headPoint = now - t < 0.08 ? point : nil
        }
        context.stroke(contour, with: .color(StageTheme.pink.opacity(0.75)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

        // 재생선 (은은한 빛 + 선) 과 지금 원곡이 내는 음
        var playhead = Path()
        playhead.move(to: CGPoint(x: playheadX, y: 0))
        playhead.addLine(to: CGPoint(x: playheadX, y: size.height))
        context.stroke(playhead, with: .color(StageTheme.pink.opacity(0.18)), lineWidth: 8)
        context.stroke(playhead, with: .color(StageTheme.pink.opacity(0.9)), lineWidth: 1.5)
        if let headPoint {
            context.fill(Path(ellipseIn: CGRect(x: playheadX - 9, y: headPoint.y - 9, width: 18, height: 18)), with: .color(StageTheme.pink.opacity(0.25)))
            context.fill(Path(ellipseIn: CGRect(x: playheadX - 5, y: headPoint.y - 5, width: 10, height: 10)), with: .color(StageTheme.pink))
        }

        if showDiagnostics {
            context.draw(
                Text(String(
                    format: "pos %.2fs · 분석 +%.2fs · 프레임 %d · 음표 %d · 그리기 #%d",
                    now, snapshot.knownUntil - now, snapshot.frames.count, notes.count, drawCounter.count
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)),
                at: CGPoint(x: 40, y: 12),
                anchor: .leading
            )
        }
    }
}

/// 세로 음역을 곡에 맞춘다 — 기준선이 자주 움직이면 음 위치를 놓치므로 안정성을 우선한다.
///   - 기준: 화면에 보이는 6초가 아니라 최근 20초에 나온 음표 전체
///   - 넓히기: 음표가 범위 밖으로 나갈 때만, 빠르게 (음표가 잘리면 안 되므로)
///   - 좁히기: 필요한 범위보다 4반음 넘게 넓은 상태가 8초 이어질 때만, 천천히
final class MidiRangeTracker {
    private(set) var low: Double = 55 // G3
    private(set) var high: Double = 79 // G5
    private let minimumSpan: Double = 14
    private let margin: Double = 3
    private let historySeconds: Double = 20
    private var history: [Int: (time: Double, midi: Int)] = [:] // 음표 시작 프레임 → (시각, 음)
    private var tooWideSince: Double?

    func update(with notes: [SungNote], framePeriod: Double, now: Double) {
        for note in notes {
            history[note.startFrame] = (Double(note.startFrame) * framePeriod, note.midi)
        }
        history = history.filter { $0.value.time >= now - historySeconds }
        guard let minMidi = history.values.map(\.midi).min(), let maxMidi = history.values.map(\.midi).max() else { return }

        var targetLow = Double(minMidi) - margin
        var targetHigh = Double(maxMidi) + margin
        if targetHigh - targetLow < minimumSpan {
            let center = (targetLow + targetHigh) / 2
            targetLow = center - minimumSpan / 2
            targetHigh = center + minimumSpan / 2
        }

        if targetLow < low - 0.01 || targetHigh > high + 0.01 {
            // 범위 밖 음표 → 빠르게 넓힌다 (지금 범위와 목표의 합집합 쪽으로)
            low += (min(low, targetLow) - low) * 0.15
            high += (max(high, targetHigh) - high) * 0.15
            tooWideSince = nil
        } else if (high - low) - (targetHigh - targetLow) > 4 {
            // 필요보다 한참 넓음 → 8초 지켜본 뒤 천천히 좁힌다
            if tooWideSince == nil { tooWideSince = now }
            if let since = tooWideSince, now - since > 8 {
                low += (targetLow - low) * 0.02
                high += (targetHigh - high) * 0.02
            }
        } else {
            tooWideSince = nil
        }
    }
}

final class DrawCounter {
    var count = 0
}
