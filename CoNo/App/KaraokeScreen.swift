// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 메인 화면 = 노래방 무대. 노래 부를 때 필요한 것만: 곡 제목·가수, 음정 바, 가사, 재생·키 도크.
// 나머지(소스·처리 방식·지연·AI 설정·싱크·진단)는 설정 창(⌘,)에 있다.
//
// 단축키 (메인 창에서): Space 재생·일시정지 · ↑↓ 키 · 0 원키 · K 내 키 · 1/2/3 반주·보컬·원곡 · [ ] 가사 싱크 · Return 시작

import AppKit
import SwiftUI

struct KaraokeScreen: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog
    let settings: AppSettings

    @State private var toast: Toast?
    @State private var artworks = ArtworkStore()
    @FocusState private var focused: Bool
    /// 전체화면 무대 모드: 마우스가 3초 멈추면 컨트롤을 숨기고 가사를 키운다
    @State private var isFullScreen = false
    @State private var controlsHidden = false
    @State private var lastActivity = Date()
    /// 자동 시작 한 번만: 시작(자동·수동)하면 잠그고, 음악이 멈춘 걸 본 뒤에야 다시 연다
    /// → 직접 끝낸 뒤 같은 곡이 흐르는 동안 다시 켜지지 않는다
    @State private var autoStartArmed = true

    var body: some View {
        ZStack {
            StageBackdrop(engine: engine, artworks: artworks)
            if engine.isRunning {
                runningStage
            } else {
                IdleStage(engine: engine, catalog: catalog, settings: settings, start: start)
            }
            if let toast {
                ToastView(toast: toast)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(toast.id)
            }
        }
        .foregroundStyle(StageTheme.ink)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(action: handleKey)
        .onContinuousHover { _ in noteActivity() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
            noteActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            noteActivity()
        }
        .onChange(of: engine.lyrics.currentTrack?.id, initial: true) { _, id in
            artworks.load(trackID: id, from: engine.lyrics)
        }
        .onChange(of: settings.displayLatencyMilliseconds, initial: true) { _, value in
            engine.displayLatencyMilliseconds = value
        }
        .onAppear { engine.guideVocalLevel = settings.guideVocalLevel }
        .onChange(of: settings.myVoice) { _, voice in
            // 내 키를 쓰는 중에 목소리를 바꾸면 바로 다시 맞춘다
            if case .voice = engine.keyMode { engine.applyVoiceKey(voice) }
        }
        .task {
            // 실행 중이 아닐 때 2초마다 소스 목록 갱신 (새로 재생을 시작한 앱 반영)
            var tick = 0
            while !Task.isCancelled {
                if tick % 4 == 0, !engine.isBusy {
                    catalog.refresh()
                    autoStartIfNeeded()
                }
                hideControlsIfIdle()
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - 무대 모드 (전체화면에서 컨트롤 자동 숨김)

    private func noteActivity() {
        lastActivity = Date()
        if controlsHidden { withAnimation(.easeOut(duration: 0.25)) { controlsHidden = false } }
    }

    private func hideControlsIfIdle() {
        guard isFullScreen, engine.isRunning, !engine.showsPaused, !controlsHidden,
              Date().timeIntervalSince(lastActivity) > 3 else { return }
        withAnimation(.easeInOut(duration: 0.6)) { controlsHidden = true }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: - 자동 시작

    private func autoStartIfNeeded() {
        guard settings.autoStart else { return }
        let source = settings.resolveSource(in: catalog.sources)
        // 음악 앱이거나 사용자가 직접 고른 앱이 재생 중일 때만 (브라우저 영상에 끼어들지 않게)
        let eligible = source.map { $0.isPlaying && ($0.bundleID == AppleMusicNowPlaying.bundleID || $0.bundleID == settings.sourcePreference) } ?? false
        guard eligible else {
            autoStartArmed = true
            return
        }
        guard autoStartArmed, !engine.isModelLoading else { return }
        start()
    }

    // MARK: - 무대

    private var runningStage: some View {
        VStack(spacing: 0) {
            StageHeader(engine: engine, artworks: artworks, controlsHidden: controlsHidden)
                .padding(.horizontal, 24) // 음정 바 가장자리와 맞춘다
                .padding(.top, 10)

            Group {
                if let timeline = engine.pitchTimeline {
                    PitchBarView(
                        timeline: timeline,
                        position: { engine.displayPosition() },
                        keyShift: engine.keyShift,
                        showDiagnostics: settings.showPitchDiagnostics,
                        autoZoom: settings.pitchAutoZoom,
                        showContour: settings.showPitchContour
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(StageTheme.faintInk)
                        Text("음정 바는 AI 반주 모드에서 나타납니다")
                            .font(StageTheme.rounded(14, .medium))
                            .foregroundStyle(StageTheme.faintInk)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            LyricsView(controller: engine.lyrics, heardCaptureTime: { engine.heardCaptureTime() }, lineFontSize: isFullScreen ? 60 : 42)
                .padding(.horizontal, 32)
                .padding(.vertical, 18)

            if let message = engine.playbackMessage {
                Text(message).font(.callout).foregroundStyle(.orange).padding(.bottom, 6)
            }

            ControlDock(engine: engine, settings: settings)
                .padding(.bottom, 20)
                .opacity(controlsHidden ? 0 : 1)
                .allowsHitTesting(!controlsHidden)
        }
    }

    // MARK: - 시작

    private func start() {
        guard let source = settings.resolveSource(in: catalog.sources), !engine.isBusy else { return }
        autoStartArmed = false
        Task {
            await engine.start(
                source: source,
                delaySeconds: settings.delaySeconds,
                muteOriginal: settings.muteOriginal,
                mode: settings.mode,
                separation: settings.separation
            )
        }
    }

    // MARK: - 단축키

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        noteActivity()
        if !engine.isRunning {
            guard press.key == .return else { return .ignored }
            start()
            return .handled
        }
        switch press.key {
        case .space:
            engine.togglePlayback()
        case .upArrow:
            engine.changeKey(by: 1)
            show("키 \(StageTheme.keyLabel(engine.keyShift))")
        case .downArrow:
            engine.changeKey(by: -1)
            show("키 \(StageTheme.keyLabel(engine.keyShift))")
        default:
            switch press.characters.lowercased() {
            case "0":
                engine.resetKey()
                show("원키")
            case "k":
                applyMyKey()
            case "1", "2", "3":
                guard engine.runningMode == .aiSeparation else { return .ignored }
                let output: SeparationOutput = press.characters == "1" ? .accompaniment : press.characters == "2" ? .vocals : .original
                engine.separationOutput = output
                show(output.label)
            case "[":
                nudgeLyrics(by: -0.05)
            case "]":
                nudgeLyrics(by: 0.05)
            default:
                return .ignored
            }
        }
        return .handled
    }

    private func applyMyKey() {
        guard engine.runningMode == .aiSeparation else { return }
        let voice = settings.myVoice
        engine.applyVoiceKey(voice)
        show(engine.suggestedKey(for: voice).map { "내 키 \(StageTheme.keyLabel($0))" } ?? "내 키 — 음역 분석 중")
    }

    private func nudgeLyrics(by seconds: Double) {
        let lyrics = engine.lyrics
        lyrics.offsetSeconds = min(max(lyrics.offsetSeconds + seconds, -1), 1)
        show(String(format: "가사 %+.2f초", lyrics.offsetSeconds))
    }

    private func show(_ message: String) {
        let next = Toast(message: message)
        withAnimation(.snappy) { toast = next }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if toast?.id == next.id { withAnimation(.easeOut) { toast = nil } }
        }
    }
}

// MARK: - 헤더

private struct StageHeader: View {
    let engine: KaraokeEngine
    let artworks: ArtworkStore
    var controlsHidden = false

    var body: some View {
        // 양옆 요소는 제목 아랫줄 높이에 둔다 — 제목 표시줄을 숨겨 왼쪽 위에 창 단추(빨강·노랑·초록)가 있어서
        ZStack(alignment: .bottom) {
            HStack(spacing: 10) {
                sourceChip
                Spacer()
                StatusPill(engine: engine)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("설정 (⌘,)")
            }
            .opacity(controlsHidden ? 0 : 1)
            // 가운데: 지금 들리는 곡 (0.5초마다 — 곡이 바뀌어도 소리가 바뀔 때 함께 바뀐다)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let track = engine.heardTrack
                HStack(spacing: 12) {
                    if let artwork = artworks.artwork(for: track?.id) {
                        Image(nsImage: artwork.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: artwork.primary.opacity(0.5), radius: 10)
                            .transition(.opacity)
                    }
                    VStack(alignment: artworks.artwork(for: track?.id) == nil ? .center : .leading, spacing: 2) {
                        Text(track?.title ?? engine.runningSource?.name ?? "")
                            .font(StageTheme.rounded(24))
                            .lineLimit(1)
                        Text(track?.artist ?? subtitle)
                            .font(StageTheme.rounded(14, .medium))
                            .foregroundStyle(StageTheme.secondaryInk)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 520)
                .animation(.easeInOut, value: track?.id)
            }
        }
    }

    private var subtitle: String {
        LyricsController.supports(bundleID: engine.runningSource?.bundleID) ? "음악 앱에서 노래를 틀어 주세요" : "가사는 음악 앱에서만 나옵니다"
    }

    /// 연결된 앱 (소리를 가져오는 앱)
    private var sourceChip: some View {
        HStack(spacing: 6) {
            Text("연결된 앱").foregroundStyle(StageTheme.faintInk)
            if let url = engine.runningSource?.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
            Text(engine.runningSource?.name ?? "").foregroundStyle(StageTheme.secondaryInk)
        }
        .font(StageTheme.rounded(12, .medium))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

}

// MARK: - 자주 바뀌는 값 (50 ms 통계) 을 읽는 작은 뷰들 — 화면 전체가 초당 20번 다시 그려지지 않게

/// 반주 세기에 맞춰 숨쉬는 무대 배경
private struct StageBackdrop: View {
    let engine: KaraokeEngine
    let artworks: ArtworkStore

    var body: some View {
        let artwork = engine.isRunning ? artworks.artwork(for: engine.heardTrack?.id) : nil
        StageBackground(
            accent: artwork?.primary ?? StageTheme.sky,
            secondAccent: artwork?.secondary ?? StageTheme.pink,
            energy: energy,
            artwork: artwork?.image
        )
        .animation(.easeInOut(duration: 1.2), value: engine.heardTrack?.id)
    }

    /// 반주 세기 → 조명 밝기 (0…1, −40 dBFS ~ 0 dBFS)
    private var energy: Double {
        guard engine.isRunning, !engine.isPaused else { return 0 }
        let peak = Double(engine.stats.outputPeak)
        guard peak > 0 else { return 0 }
        return min(max((20 * log10(peak) + 40) / 40, 0), 1)
    }
}

private struct StatusPill: View {
    let engine: KaraokeEngine

    var body: some View {
        let stats = engine.stats
        let (label, color): (String, Color) = if engine.isPaused {
            ("일시정지", StageTheme.secondaryInk)
        } else if !stats.isPrimed {
            ("준비 중", .orange)
        } else {
            ("LIVE", StageTheme.mint)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(StageTheme.rounded(11, .bold))
        }
        .foregroundStyle(color)
        .help(String(format: "%@ · 원곡보다 %.1f초 늦게 들립니다 (AI 분리·음정 미리보기 여유)", modeLabel, stats.bufferedSeconds))
    }

    private var modeLabel: String {
        switch engine.runningMode {
        case .aiSeparation: "AI 반주"
        case .centerCancel: "간이 반주"
        case .passthrough: "원곡 그대로"
        case nil: ""
        }
    }
}

// MARK: - 시작 전 화면

private struct IdleStage: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog
    let settings: AppSettings
    let start: () -> Void

    private var source: AudioSource? { settings.resolveSource(in: catalog.sources) }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 8) {
                Text("CoNo")
                    .font(StageTheme.rounded(72, .heavy))
                    .foregroundStyle(LinearGradient(colors: [StageTheme.sky, StageTheme.mint, StageTheme.pink], startPoint: .leading, endPoint: .trailing))
                Text("듣던 노래가 그대로 노래방이 됩니다")
                    .font(StageTheme.rounded(17, .medium))
                    .foregroundStyle(StageTheme.secondaryInk)
            }

            sourcePicker

            Button(action: start) {
                HStack(spacing: 8) {
                    if engine.status == .starting {
                        ProgressView().controlSize(.small).tint(StageTheme.night)
                    } else {
                        Image(systemName: "music.mic")
                    }
                    Text(engine.status == .starting ? "준비 중…" : "노래 시작")
                }
                .font(StageTheme.rounded(18))
                .foregroundStyle(StageTheme.night)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(Capsule().fill(StageTheme.mint))
            }
            .buttonStyle(.plain)
            .disabled(source == nil || engine.isBusy || engine.isModelLoading)
            .opacity(source == nil ? 0.5 : 1)
            .help("Return")

            statusLine
            Spacer()
            Text("Space 재생·일시정지 · ↑↓ 키 · K 내 키 · 0 원키 · 1 2 3 반주·보컬·원곡 · [ ] 가사 싱크 · ⌘, 설정")
                .font(StageTheme.rounded(11, .medium))
                .foregroundStyle(StageTheme.faintInk)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 40)
    }

    private var sourcePicker: some View {
        Menu {
            Picker("캡처할 앱", selection: Binding(get: { settings.sourcePreference }, set: { settings.sourcePreference = $0 })) {
                Text("자동 (음악 앱 우선)").tag(AppSettings.autoSource)
                ForEach(catalog.sources.filter { $0.kind != .systemWide && $0.bundleID != nil }) { app in
                    Text(app.isPlaying ? "\(app.name) · 재생 중" : app.name).tag(app.bundleID ?? "")
                }
                Text("시스템 전체").tag(AppSettings.systemSource)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                if let url = source?.bundleURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "hifispeaker.2")
                }
                Text(source.map { "\($0.name)\($0.isPlaying ? " · 재생 중" : "")" } ?? "음악 앱에서 노래를 틀어 주세요")
                    .font(StageTheme.rounded(14, .medium))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(StageTheme.ink)
            .glassCapsule()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(engine.isBusy)
        .help("노래방으로 바꿀 앱")
    }

    @ViewBuilder
    private var statusLine: some View {
        if case let .failed(message) = engine.status {
            Text(message).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).textSelection(.enabled)
        } else if engine.status == .starting {
            Text(engine.isModelLoading ? "AI 반주 모델을 준비하고 있습니다 (처음엔 수십 초 걸립니다)" : "오디오 권한 창이 뜨면 허용해 주세요")
                .font(.callout)
                .foregroundStyle(StageTheme.secondaryInk)
        } else if let error = catalog.lastError {
            Text("앱 목록을 읽지 못했습니다: \(error)").font(.callout).foregroundStyle(.orange)
        } else {
            Text(" ").font(.callout)
        }
    }
}

// MARK: - 토스트

private struct Toast: Equatable {
    let id = UUID()
    let message: String
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(StageTheme.rounded(22))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .glassCapsule()
            .allowsHitTesting(false)
    }
}

extension KaraokeEngine {
    /// 지금 들리는 곡 (지연 때문에 음악 앱이 알려주는 "지금 곡" 보다 몇 초 늦다)
    var heardTrack: TrackInfo? {
        heardCaptureTime().flatMap { lyrics.track(atCaptureTime: $0) } ?? lyrics.currentTrack
    }
}
