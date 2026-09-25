// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 귀렌찬 스타일 음정 바: 원곡 보컬의 음표가 오른쪽에서 흘러와 재생선(왼쪽 1/4)을 지나간다.
// 시간축은 출력 스트림 초 — KaraokeEngine.displayPosition() 과 PitchTimeline 이 같은 축이다.

import SwiftUI

struct PitchBarView: View {
    let timeline: PitchTimeline
    let position: () -> Double?

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
        .background(Color(red: 0.05, green: 0.05, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("음정 바")
    }

    /// - Parameter frameDate: TimelineView 틱 시각. 값 자체는 쓰지 않지만 매 틱 다시 그리게 하는 의존성이다
    ///   (재생 위치는 오디오 출력 시각 기반의 `position()` 이 더 정확하다).
    private func draw(in context: inout GraphicsContext, size: CGSize, frameDate: Date) {
        _ = frameDate
        drawCounter.count += 1
        guard let now = position() else {
            context.draw(
                Text("재생이 시작되면 음정이 흐릅니다").font(.callout).foregroundStyle(.white.opacity(0.6)),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let t0 = now - pastSeconds
        let t1 = now + futureSeconds
        let period = timeline.framePeriod
        // 음표 경계가 창 가장자리에서 흔들리지 않도록 1초 앞부터 잘라 묶는다
        let snapshot = timeline.snapshot(from: t0 - 1, to: t1)
        let notes = segmenter.segment(snapshot.frames)
        range.update(with: notes.filter { Double($0.endFrame) * period > t0 })

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
            context.stroke(line, with: .color(.white.opacity(isC ? 0.18 : 0.05)), lineWidth: 1)
            if isC {
                context.draw(
                    Text("C\(midi / 12 - 1)").font(.caption2).foregroundStyle(.white.opacity(0.45)),
                    at: CGPoint(x: 6, y: y(Double(midi))),
                    anchor: .leading
                )
            }
        }

        // 아직 분석되지 않은 미래 구간
        let knownX = x(snapshot.knownUntil)
        if knownX < size.width {
            let unknown = CGRect(x: max(0, knownX), y: 0, width: size.width - max(0, knownX), height: size.height)
            context.fill(Path(unknown), with: .color(.white.opacity(0.04)))
            if unknown.width > 60 {
                context.draw(
                    Text("분석 중").font(.caption2).foregroundStyle(.white.opacity(0.4)),
                    at: CGPoint(x: size.width - 8, y: 10),
                    anchor: .trailing
                )
            }
        }

        // 음표 막대
        for note in notes {
            let start = Double(note.startFrame) * period
            let end = Double(note.endFrame) * period
            guard end > t0, start < t1 else { continue }
            let rect = CGRect(
                x: x(start),
                y: y(Double(note.midi)) - rowHeight / 2 + 1,
                width: max(2, x(end) - x(start)),
                height: max(3, rowHeight - 2)
            )
            let color: Color = end < now ? .white.opacity(0.3) : (start <= now ? .yellow : .white.opacity(0.9))
            context.fill(Path(roundedRect: rect, cornerRadius: min(4, rect.height / 2)), with: .color(color))
        }

        // 원곡 보컬 음정 곡선 (무성·끊김에서 선을 끊는다)
        var contour = Path()
        var previousIndex: Int?
        for frame in snapshot.frames where frame.confidence >= segmenter.voicedThreshold && frame.pitchHz > 0 {
            let t = Double(frame.index) * period
            guard t >= t0 else { continue }
            let point = CGPoint(x: x(t), y: y(NoteSegmenter.midi(fromHz: frame.pitchHz)))
            if let previousIndex, frame.index - previousIndex <= 2 {
                contour.addLine(to: point)
            } else {
                contour.move(to: point)
            }
            previousIndex = frame.index
        }
        context.stroke(contour, with: .color(.cyan.opacity(0.55)), lineWidth: 1.5)

        // 진단 표시 (좌상단)
        context.draw(
            Text(String(
                format: "pos %.2fs · 분석 +%.2fs · 프레임 %d · 음표 %d · 그리기 #%d",
                now, snapshot.knownUntil - now, snapshot.frames.count, notes.count, drawCounter.count
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.5)),
            at: CGPoint(x: 40, y: 10),
            anchor: .leading
        )

        // 재생선
        var playhead = Path()
        playhead.move(to: CGPoint(x: x(now), y: 0))
        playhead.addLine(to: CGPoint(x: x(now), y: size.height))
        context.stroke(playhead, with: .color(.red), lineWidth: 2)
    }
}

/// 세로 음역을 곡에 맞춰 천천히 따라가게 한다 (그리기마다 갱신, 상태 알림 없음)
final class MidiRangeTracker {
    private(set) var low: Double = 55 // G3
    private(set) var high: Double = 79 // G5
    private let minimumSpan: Double = 14
    private let margin: Double = 3
    private let smoothing: Double = 0.03

    func update(with notes: [SungNote]) {
        guard let minMidi = notes.map(\.midi).min(), let maxMidi = notes.map(\.midi).max() else { return }
        var targetLow = Double(minMidi) - margin
        var targetHigh = Double(maxMidi) + margin
        if targetHigh - targetLow < minimumSpan {
            let center = (targetLow + targetHigh) / 2
            targetLow = center - minimumSpan / 2
            targetHigh = center + minimumSpan / 2
        }
        low += (targetLow - low) * smoothing
        high += (targetHigh - high) * smoothing
    }
}

final class DrawCounter {
    var count = 0
}
