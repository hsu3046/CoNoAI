// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
//
// 하단 도크: 재생·일시정지 | 키 ♭/♯ | 원키·내 키 | 반주·보컬·원곡 (+ 가이드 보컬) | 채점. 끝내기는 헤더의 연결된 앱 칩.
// 노래방 리모컨처럼 큰 버튼 몇 개로 끝나게 한다. 단축키는 KaraokeScreen 이 받는다.

import SwiftUI

struct ControlDock: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    private var isAIMode: Bool { engine.runningMode == .aiSeparation }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                playButton
                endSongButton
            }
            divider
            keyStepper
            voiceChips
            if isAIMode {
                divider
                outputSwitch
                // 가이드 보컬은 반주에 섞는 것이라 반주를 들을 때만
                if engine.separationOutput == .accompaniment {
                    guideVocal
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                divider
                singButton
            }

        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .glassCapsule()
        .buttonStyle(.plain)
        .foregroundStyle(StageTheme.ink)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 28).padding(.horizontal, 2)
    }

    // MARK: 재생

    private var playButton: some View {
        let paused = engine.showsPaused
        // 곡을 끝내 둔 뒤엔 재생 = 다음 곡
        let symbol = engine.endedSong ? "forward.end.fill" : paused ? "play.fill" : "pause.fill"
        return Button {
            engine.togglePlayback()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(StageTheme.night)
                .frame(width: 46, height: 46)
                .background(Circle().fill(StageTheme.ink))
                .contentTransition(.symbolEffect(.replace))
        }
        .help(engine.endedSong ? "다음 곡 부르기 (Space)" : paused ? "이어서 재생 (Space)" : "일시정지 (Space)")
        .accessibilityLabel(engine.endedSong ? "다음 곡" : paused ? "재생" : "일시정지")
    }

    /// 곡 끝내기: 연결은 두고 여기까지 채점하고 멈춘다 (노래방 리모컨의 종료)
    private var endSongButton: some View {
        Button {
            engine.endSong()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .disabled(engine.endedSong)
        .opacity(engine.endedSong ? 0.4 : 1)
        .help(engine.wantsSinging ? "곡 끝내기 — 여기까지 채점하고 멈춰요. 재생을 누르면 다음 곡 (Esc)" : "곡 끝내기 — 멈추고, 재생을 누르면 다음 곡 (Esc)")
        .accessibilityLabel("곡 끝내기")
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
            myKeyChip
        }
    }

    /// 내 키: 이 곡을 설정의 "내 목소리" 에 맞춘다 (곡이 바뀌어도 새 곡에 다시 맞춘다)
    private var myKeyChip: some View {
        let voice = settings.myVoice
        let selected = engine.keyMode == .voice(voice)
        let detail: String? = if !isAIMode {
            nil
        } else if let key = engine.suggestedKey(for: voice) {
            StageTheme.keyLabel(key)
        } else {
            "분석 중"
        }
        let voiceName = voice == .male ? "남성" : "여성"
        let help: String = if !isAIMode {
            "AI 반주 모드에서 원곡 음역을 재서 맞출 수 있습니다"
        } else if let range = engine.vocalRange, let key = engine.suggestedKey(for: voice) {
            "원곡 음역 중심 \(StageTheme.noteName(range.medianMidi)) → \(voiceName)인 내게 맞춘 키 \(StageTheme.keyLabel(key)) (옥타브까지 고려해 가장 편한 높이) · K"
        } else {
            "원곡을 조금 더 들으면 \(voiceName)인 내게 맞는 키를 찾습니다 (내 목소리는 설정 › 일반) · K"
        }
        return chip(title: "내 키", detail: detail, selected: selected, help: help) {
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
            .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.08), lineWidth: 1))
            .animation(.snappy, value: selected)
        }
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: 반주·보컬·원곡

    private var outputSwitch: some View {
        HStack(spacing: 2) {
            ForEach(SeparationOutput.allCases, id: \.self) { output in
                let selected = engine.separationOutput == output
                Button {
                    withAnimation(.snappy) { engine.separationOutput = output }
                } label: {
                    Text(output.label)
                        .font(StageTheme.rounded(12, .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(selected ? StageTheme.night : StageTheme.secondaryInk)
                        .background(Capsule().fill(selected ? StageTheme.ink : .clear))
                }
                .help("\(output.label) 듣기 (\(output.rawValue + 1))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    // MARK: 채점

    private var singButton: some View {
        let on = engine.wantsSinging
        let failed = if case .failed = engine.singingState { true } else { false }
        return Button {
            // 실패 상태에서 누르면 끄지 않고 다시 시도 (권한을 켜고 돌아온 경우)
            let next = failed || !engine.wantsSinging
            engine.setSinging(next)
            settings.singingEnabled = next
        } label: {
            HStack(spacing: 6) {
                if on, let singing = engine.singing {
                    MicLevelIcon(singing: singing)
                } else {
                    Image(systemName: failed ? "mic.slash.fill" : on ? "mic.fill" : "mic")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 18)
                }
                Text("채점").font(StageTheme.rounded(13, .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(on && !failed ? StageTheme.night : failed ? .orange : StageTheme.ink)
            .background(Capsule().fill(on && !failed ? StageTheme.gold : Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0 : 0.08), lineWidth: 1))
            .animation(.snappy, value: on)
        }
        .help(singHelp)
        .accessibilityLabel("마이크 채점")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var singHelp: String {
        switch engine.singingState {
        case .off: "마이크로 불러 원곡 음정과 맞는지 보여주고 채점합니다. 스피커로 틀어도 됩니다"
        case .starting: "마이크를 여는 중…"
        case let .listening(device, isBluetooth):
            isBluetooth
                ? "마이크: \(device) — 블루투스 마이크는 이어폰 소리를 통화 음질로 떨어뜨려요. 누르면 끕니다"
                : "마이크: \(device) — 누르면 끕니다"
        case let .failed(message): message
        }
    }

    // MARK: 가이드 보컬

    private var guideVocal: some View {
        HStack(spacing: 8) {
            // 마이크 모양은 채점 버튼이 쓰므로 원곡 가수 목소리는 사람 아이콘
            Image(systemName: engine.guideVocalLevel > 0 ? "person.wave.2.fill" : "person.wave.2")
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
}

/// 채점 중 마이크 아이콘: 들어오는 소리 크기만큼 뒤 원이 커진다 (0.1초마다)
private struct MicLevelIcon: View {
    let singing: SingingTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let level = CGFloat(min(1, singing.snapshot().micPeak * 4))
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 18)
                .background(
                    Circle()
                        .fill(StageTheme.night.opacity(0.18))
                        .frame(width: 10 + 16 * level, height: 10 + 16 * level)
                        .animation(.easeOut(duration: 0.1), value: level)
                )
        }
    }
}
