// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
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
            if let result = engine.singingResult {
                SingingResultCard(result: result) {
                    withAnimation(.easeOut) { engine.singingResult = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .id(result.id)
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
        .onChange(of: settings.extraLyricsSources, initial: true) { _, sources in
            engine.lyrics.enabledExtraSources = sources
        }
        .onChange(of: settings.singingDifficulty, initial: true) { _, difficulty in
            engine.singingDifficulty = difficulty
        }
        .onAppear {
            if settings.singingEnabled, !engine.wantsSinging { engine.setSinging(true) }
        }
        .animation(.snappy, value: engine.singingResult?.id)
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
                .padding(.top, 16)

            Group {
                if let timeline = engine.pitchTimeline {
                    PitchBarStage(engine: engine, settings: settings, timeline: timeline)
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
            .overlay { SeekingBadge(engine: engine) }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            LyricsView(
                controller: engine.lyrics,
                heardCaptureTime: { engine.heardCaptureTime() },
                lineFontSize: isFullScreen ? 60 : 42,
                onSkipInterlude: engine.canControlPlayback ? { engine.seek(toSongPosition: $0) } : nil
            )
                .padding(.horizontal, 32)
                .padding(.vertical, 18)

            // 안내 한 줄 자리는 늘 비워 둔다 (떴다 사라질 때 위의 음정 바 높이가 바뀌지 않게)
            Text(engine.playbackMessage ?? engine.singingNotice ?? " ")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(height: 20)
                .padding(.bottom, 6)

            SongProgressBar(engine: engine)
                .frame(maxWidth: 760)
                .padding(.horizontal, 40)
                .padding(.bottom, 12)
                .opacity(controlsHidden ? 0 : 1)
                .allowsHitTesting(!controlsHidden)

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
        case .rightArrow:
            guard let heard = engine.heardCaptureTime(), let target = engine.lyrics.interludeSkipTarget(atCaptureTime: heard) else {
                return .ignored
            }
            engine.seek(toSongPosition: target)
            show("간주 점프")
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
        lyrics.offsetSeconds = min(max(lyrics.offsetSeconds + seconds, -LyricsController.offsetLimit), LyricsController.offsetLimit)
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
                    .padding(.trailing, 10)
                ShortcutsButton()
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
                let onAd = engine.heardCaptureTime().flatMap { engine.lyrics.advertisement(atCaptureTime: $0) } != nil
                HStack(spacing: 12) {
                    if let artwork = artworks.artwork(for: track?.id) {
                        Image(nsImage: artwork.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: artwork.primary.opacity(0.5), radius: 10)
                            .transition(.opacity)
                    }
                    VStack(alignment: artworks.artwork(for: track?.id) == nil ? .center : .leading, spacing: 2) {
                        // 광고 안내는 가사 자리에서만 — 여기선 연결된 앱 이름만
                        Text(onAd ? engine.runningSource?.name ?? "" : track?.title ?? engine.runningSource?.name ?? "")
                            .font(StageTheme.rounded(30))
                            .lineLimit(1)
                        Text(onAd ? " " : track?.artist ?? subtitle)
                            .font(StageTheme.rounded(17, .medium))
                            .foregroundStyle(StageTheme.secondaryInk)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 620)
                .animation(.easeInOut, value: track?.id)
            }
        }
    }

    private var subtitle: String {
        engine.lyrics.status == .unsupportedSource ? "곡 정보를 받을 수 없는 연결입니다" : "연결된 앱에서 노래를 틀어 주세요"
    }

    /// 연결된 앱 (소리를 가져오는 앱) — 누르면 연결을 끊고 노래방을 끝낸다 (원곡도 멈춘다)
    private var sourceChip: some View {
        SourceChip(engine: engine)
    }

}

/// 음정 바 + 위에 마우스를 올리면 나오는 표시 스위치 (자동 줌 · 원곡 곡선)
private struct PitchBarStage: View {
    let engine: KaraokeEngine
    let settings: AppSettings
    let timeline: PitchTimeline
    @State private var hovering = false

    var body: some View {
        PitchBarView(
            timeline: timeline,
            position: { engine.displayPosition() },
            keyShift: engine.keyShift,
            showDiagnostics: settings.showPitchDiagnostics,
            autoZoom: settings.pitchAutoZoom,
            showContour: settings.showPitchContour,
            singing: engine.singing
        )
        .overlay {
            // 광고가 들리는 동안: 광고 목소리의 음정이 흐르지 않게 덮는다
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                if engine.heardCaptureTime().flatMap({ engine.lyrics.advertisement(atCaptureTime: $0) }) != nil {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(StageTheme.night.opacity(0.78))
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 6) {
                    toggle(
                        "자동 줌", symbol: "arrow.up.and.down", isOn: settings.pitchAutoZoom,
                        help: "음역에 맞춰 세로 범위를 자동으로 넓히고 좁힙니다. 끄면 A2–A5 고정 (높이 감을 잡기 쉬움)"
                    ) { settings.pitchAutoZoom.toggle() }
                    toggle(
                        "원곡 곡선", symbol: "scribble.variable", isOn: settings.showPitchContour,
                        help: "원곡 가수가 실제로 부른 음정을 분홍 선으로 겹쳐 그립니다"
                    ) { settings.showPitchContour.toggle() }
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let singing = engine.singing {
                LiveScoreChip(singing: singing)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.2)) { hovering = inside }
        }
    }

    private func toggle(_ title: String, symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(StageTheme.rounded(12, .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? StageTheme.night : StageTheme.secondaryInk)
            .background(Capsule().fill(isOn ? StageTheme.ink : Color.black.opacity(0.35)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 연결된 앱 칩. 끝의 ⏏ 를 포함해 칩 전체가 "연결 끊기" 버튼이고, 마우스를 올리면 붉게 바뀐다.
private struct SourceChip: View {
    let engine: KaraokeEngine
    @State private var hovering = false

    var body: some View {
        Button {
            Task { await engine.finish() }
        } label: {
            HStack(spacing: 6) {
                Text(hovering ? "연결 끊기" : "연결된 앱")
                    .foregroundStyle(hovering ? StageTheme.stopRed : StageTheme.secondaryInk)
                if let url = engine.runningSource?.bundleURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                }
                Text(engine.runningSource?.name ?? "").foregroundStyle(StageTheme.ink)
                Image(systemName: "eject.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? StageTheme.stopRed : StageTheme.secondaryInk)
                    .padding(.leading, 2)
            }
            .font(StageTheme.rounded(12, .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering ? StageTheme.stopRed.opacity(0.14) : Color.black.opacity(0.22)))
            .overlay(Capsule().strokeBorder(hovering ? StageTheme.stopRed.opacity(0.35) : Color.white.opacity(0.1), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("연결 끊기 — 노래방을 끝내고 원곡도 멈춥니다")
        .accessibilityLabel("연결 끊기: \(engine.runningSource?.name ?? "")")
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
            ("일시정지", StageTheme.ink)
        } else if !stats.isPrimed {
            ("준비 중", .orange)
        } else {
            ("LIVE", StageTheme.mint)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(label).font(StageTheme.rounded(13, .bold))
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

/// 이동 중: 새 위치의 소리가 닿을 때까지 (통계를 읽으므로 작은 뷰로)
private struct SeekingBadge: View {
    let engine: KaraokeEngine

    var body: some View {
        if engine.seekTarget != nil || engine.stats.isOutputMuted {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("이동 중…").font(StageTheme.rounded(15, .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassCapsule()
            .transition(.opacity)
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
                // 앱 아이콘의 마이크·링 (배경 투명)
                if let logo = NSImage(named: "StageLogo") {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .shadow(color: StageTheme.mint.opacity(0.35), radius: 18)
                        .accessibilityHidden(true)
                }
                Text("CoNo")
                    .font(StageTheme.rounded(72, .heavy))
                    .foregroundStyle(LinearGradient(colors: [StageTheme.sky, StageTheme.mint, StageTheme.pink], startPoint: .leading, endPoint: .trailing))
                Text("코인 노래방 No! 집에서 나만의 노래방 즐기기")
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
                .frame(width: Self.controlWidth)
                .padding(.vertical, 14)
                .background(Capsule().fill(StageTheme.mint))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(source == nil || engine.isBusy || engine.isModelLoading)
            .opacity(source == nil ? 0.5 : 1)
            .help("Return")

            statusLine
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            ShortcutsButton().padding(.top, 16).padding(.trailing, 24)
        }
    }

    /// 앱 선택 칸과 시작 버튼의 폭 (같은 폭으로 세워 둔다)
    static let controlWidth: CGFloat = 300

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
                    .font(StageTheme.rounded(15, .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 18)
            .frame(width: Self.controlWidth)
            .padding(.vertical, 11)
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

// MARK: - 단축키 안내

/// ⌨ 버튼: 누르면 단축키 목록 (메인 창에서만 동작하는 키)
private struct ShortcutsButton: View {
    @State private var showing = false

    private static let shortcuts: [(keys: String, action: String)] = [
        ("Space", "재생 · 일시정지"),
        ("↑  ↓", "키 반음 올리기 · 내리기"),
        ("K", "내 키 (내 목소리에 맞추기)"),
        ("0", "원키"),
        ("1  2  3", "반주 · 보컬 · 원곡"),
        ("→", "간주 점프"),
        ("[  ]", "가사 싱크 늦추기 · 앞당기기"),
        ("Return", "노래 시작 (시작 화면)"),
        ("⌘ ,", "설정"),
        ("⌃ ⌘ F", "전체 화면"),
    ]

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("단축키")
        .accessibilityLabel("단축키")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("단축키").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(Self.shortcuts, id: \.keys) { item in
                        GridRow {
                            Text(item.keys)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .monospaced()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                            Text(item.action).font(.callout)
                        }
                    }
                }
            }
            .padding(16)
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
