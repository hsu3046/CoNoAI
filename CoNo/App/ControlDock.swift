// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 하단 도크: 재생·일시정지 | 키 ♭/♯ | 원키·남자키·여자키 | 가이드 보컬 | 끝내기.
// 노래방 리모컨처럼 큰 버튼 몇 개로 끝나게 한다. 단축키는 KaraokeScreen 이 받는다.

import SwiftUI

struct ControlDock: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    private var isAIMode: Bool { engine.runningMode == .aiSeparation }

    var body: some View {
        HStack(spacing: 14) {
            playButton
            divider
            keyStepper
            voiceChips
            if isAIMode {
                divider
                guideVocal
            }
            divider
            stopButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCapsule()
        .buttonStyle(.plain)
        .foregroundStyle(StageTheme.ink)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 28)
    }

    // MARK: 재생

    private var playButton: some View {
        let paused = engine.showsPaused
        return Button {
            engine.togglePlayback()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(StageTheme.night)
                .frame(width: 46, height: 46)
                .background(Circle().fill(StageTheme.ink))
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(!engine.canControlPlayback)
        .opacity(engine.canControlPlayback ? 1 : 0.4)
        .help(engine.canControlPlayback
            ? (paused ? "이어서 재생 (Space)" : "일시정지 (Space)")
            : "재생·일시정지는 지금 음악 앱에서만 됩니다")
        .accessibilityLabel(paused ? "재생" : "일시정지")
    }

    // MARK: 키

    private var keyStepper: some View {
        HStack(spacing: 6) {
            roundIcon("minus", help: "반음 내리기 (↓)") { engine.changeKey(by: -1) }
                .disabled(engine.keyShift <= PlaybackOutput.keyShiftRange.lowerBound)
            VStack(spacing: 0) {
                Text("키").font(StageTheme.rounded(10, .medium)).foregroundStyle(StageTheme.secondaryInk)
                Text(StageTheme.keyLabel(engine.keyShift))
                    .font(StageTheme.rounded(19))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(engine.keyShift)))
                    .animation(.snappy, value: engine.keyShift)
            }
            .frame(minWidth: 50)
            .accessibilityElement(children: .combine)
            roundIcon("plus", help: "반음 올리기 (↑)") { engine.changeKey(by: 1) }
                .disabled(engine.keyShift >= PlaybackOutput.keyShiftRange.upperBound)
        }
    }

    private func roundIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var voiceChips: some View {
        HStack(spacing: 6) {
            chip(title: "원키", detail: nil, selected: engine.keyMode == .manual && engine.keyShift == 0, help: "원래 키로 (0)") {
                engine.resetKey()
            }
            voiceChip(.male, title: "남자키", shortcut: "M")
            voiceChip(.female, title: "여자키", shortcut: "F")
        }
    }

    private func voiceChip(_ voice: VoiceType, title: String, shortcut: String) -> some View {
        let selected = engine.keyMode == .voice(voice)
        let detail: String? = if !isAIMode {
            nil
        } else if let key = engine.suggestedKey(for: voice) {
            StageTheme.keyLabel(key)
        } else {
            "분석 중"
        }
        return chip(
            title: title,
            detail: detail,
            selected: selected,
            help: isAIMode
                ? "원곡 보컬 음역을 재서 \(title)로 맞춥니다. 곡이 바뀌어도 새 곡에 다시 맞춥니다 (\(shortcut))"
                : "AI 반주 모드에서 원곡 음역을 재서 맞출 수 있습니다"
        ) {
            engine.applyVoiceKey(voice)
        }
        .disabled(!isAIMode)
        .opacity(isAIMode ? 1 : 0.4)
    }

    private func chip(title: String, detail: String?, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(StageTheme.rounded(13, .semibold))
                if let detail {
                    Text(detail)
                        .font(StageTheme.rounded(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? StageTheme.night.opacity(0.7) : StageTheme.secondaryInk)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? StageTheme.night : StageTheme.ink)
            .background(Capsule().fill(selected ? StageTheme.mint : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.1), lineWidth: 0.5))
            .animation(.snappy, value: selected)
        }
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 가이드 보컬

    private var guideVocal: some View {
        HStack(spacing: 8) {
            Image(systemName: engine.guideVocalLevel > 0 ? "music.mic" : "mic.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(engine.guideVocalLevel > 0 ? StageTheme.pink : StageTheme.secondaryInk)
                .frame(width: 18)
            Slider(
                value: Binding(
                    get: { engine.guideVocalLevel },
                    set: { value in
                        engine.guideVocalLevel = value
                        settings.guideVocalLevel = value
                    }
                ),
                in: 0...0.5
            )
            .frame(width: 90)
            .controlSize(.small)
            .tint(StageTheme.pink)
            .accessibilityLabel("가이드 보컬")
        }
        .help("가이드 보컬: 원곡 목소리를 살짝 섞어 부를 줄을 들려줍니다")
    }

    // MARK: 끝내기

    private var stopButton: some View {
        Button {
            engine.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .help("노래방 끝내기")
        .accessibilityLabel("노래방 끝내기")
    }
}
