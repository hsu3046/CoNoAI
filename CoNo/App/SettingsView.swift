// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 설정 창 (⌘,): 일반 · 소리 · AI 분리 · 싱크 · 진단.
// 메인 화면에서 뺀 조절·진단은 모두 여기에 있다. 실행 중에 못 바꾸는 항목은 잠그고 이유를 적는다.

import SwiftUI

struct SettingsView: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog
    let settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettings(engine: engine, catalog: catalog, settings: settings)
                .tabItem { Label("일반", systemImage: "gearshape") }
            SoundSettings(engine: engine, settings: settings)
                .tabItem { Label("소리", systemImage: "speaker.wave.2") }
            SeparationSettingsTab(engine: engine, settings: settings)
                .tabItem { Label("AI 분리", systemImage: "cpu") }
            SyncSettings(engine: engine, settings: settings)
                .tabItem { Label("싱크", systemImage: "metronome") }
            DiagnosticsSettings(engine: engine, settings: settings)
                .tabItem { Label("진단", systemImage: "stethoscope") }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

/// 실행 중에는 못 바꾸는 항목 안내
private struct LockedWhileRunning: View {
    let engine: KaraokeEngine

    var body: some View {
        if engine.isBusy {
            Label("노래방이 켜져 있는 동안은 바꿀 수 없습니다. 끝낸 뒤 다시 시작하면 반영됩니다.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 일반

private struct GeneralSettings: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("캡처할 앱", selection: Binding(get: { settings.sourcePreference }, set: { settings.sourcePreference = $0 })) {
                    Text("자동 (음악 앱 우선, 없으면 재생 중인 앱)").tag(AppSettings.autoSource)
                    ForEach(catalog.sources.filter { $0.kind != .systemWide && $0.bundleID != nil }) { app in
                        Text(app.isPlaying ? "\(app.name) · 재생 중" : app.name).tag(app.bundleID ?? "")
                    }
                    if ![AppSettings.autoSource, AppSettings.systemSource].contains(settings.sourcePreference),
                       !catalog.sources.contains(where: { $0.bundleID == settings.sourcePreference }) {
                        Text("\(settings.sourcePreference) (실행 중 아님)").tag(settings.sourcePreference)
                    }
                    Text("시스템 전체 (CoNo 제외)").tag(AppSettings.systemSource)
                }
                Toggle("원본 소리 끄기", isOn: Binding(get: { settings.muteOriginal }, set: { settings.muteOriginal = $0 }))
                Text("끄지 않으면 원곡과 CoNo 반주가 겹쳐 들립니다 (에코 확인용).").font(.caption).foregroundStyle(.secondary)
                LockedWhileRunning(engine: engine)
            }
            .disabled(engine.isBusy)

            Section {
                Toggle("음악 앱에서 노래가 나오면 바로 시작", isOn: Binding(get: { settings.autoStart }, set: { settings.autoStart = $0 }))
                Text("CoNo 를 열어 둔 채 음악 앱에서 재생하면 자동으로 노래방이 켜집니다. 직접 끝낸 뒤에는 다시 켜지지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("가사와 재생 제어") {
                Text("가사·곡 정보·재생/일시정지는 지금 음악 앱(Apple Music)에서만 됩니다. 처음 쓸 때 '자동화' 권한을 허용해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 소리

private struct SoundSettings: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("처리 방식", selection: Binding(get: { settings.mode }, set: { settings.mode = $0 })) {
                    Text("AI 반주").tag(ProcessingMode.aiSeparation)
                    Text("간이 반주 (L−R)").tag(ProcessingMode.centerCancel)
                    Text("원곡 그대로").tag(ProcessingMode.passthrough)
                }
                .pickerStyle(.segmented)

                LabeledContent("지연") {
                    HStack {
                        Slider(value: Binding(get: { settings.delaySeconds }, set: { settings.delaySeconds = $0 }), in: 0.5...8, step: 0.5)
                        Text(String(format: "%.1f초", settings.delaySeconds)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("AI 가 목소리를 지우고 다음 음정을 미리 보여 줄 여유입니다. 원곡보다 이만큼 늦게 들립니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.mode == .aiSeparation {
                    let recommended = engine.recommendedDelay(for: settings.separation)
                    if settings.delaySeconds < recommended {
                        HStack {
                            Text(String(format: "권장 %.1f초보다 짧아 소리가 끊길 수 있습니다", recommended))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("권장값으로") { settings.delaySeconds = min(8, (recommended * 2).rounded(.up) / 2) }
                                .controlSize(.small)
                        }
                    }
                }
                LockedWhileRunning(engine: engine)
            }
            .disabled(engine.isBusy)

            Section("AI 반주") {
                LabeledContent("가이드 보컬 기본값") {
                    HStack {
                        Slider(value: Binding(get: { settings.guideVocalLevel }, set: { value in
                            settings.guideVocalLevel = value
                            engine.guideVocalLevel = value
                        }), in: 0...0.5)
                        Text(String(format: "%.0f%%", settings.guideVocalLevel * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if engine.runningMode == .aiSeparation {
                    Picker("들려줄 소리 (비교용)", selection: Binding(get: { engine.separationOutput }, set: { engine.separationOutput = $0 })) {
                        Text("반주").tag(SeparationOutput.accompaniment)
                        Text("보컬만").tag(SeparationOutput.vocals)
                        Text("원곡").tag(SeparationOutput.original)
                    }
                    .pickerStyle(.segmented)
                    Text("세 소리는 같은 시점으로 맞춰져 있어 실행 중에 바꿔 비교할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI 분리

private struct SeparationSettingsTab: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("추론", selection: Binding(get: { settings.backend }, set: { settings.backend = $0 })) {
                    ForEach(InferenceBackend.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("갱신 간격") {
                    HStack {
                        Slider(value: Binding(get: { settings.stepSeconds }, set: { settings.stepSeconds = $0 }), in: 0.5...3, step: 0.25)
                        Text(String(format: "%.2f초", settings.stepSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .help("몇 초마다 새로 분리할지. 추론 1회 시간보다 길어야 끊기지 않습니다.")
                LabeledContent("뒤 문맥") {
                    HStack {
                        Slider(value: Binding(get: { settings.rightContextSeconds }, set: { settings.rightContextSeconds = $0 }), in: 0.25...2.5, step: 0.25)
                        Text(String(format: "%.2f초", settings.rightContextSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .help("모델에게 보여줄 '앞으로 나올 소리' 길이. 길수록 품질이 좋아지고 지연이 늘어납니다.")
                LockedWhileRunning(engine: engine)
            }
            .disabled(engine.isBusy)

            Section("모델") {
                HStack(alignment: .firstTextBaseline) {
                    Button("모델 준비 · 속도 측정") {
                        Task { await engine.prepareModel(backend: settings.backend) }
                    }
                    .disabled(engine.isModelLoading || engine.isBusy)
                    Spacer()
                }
                ModelStateLabel(engine: engine, stepSeconds: settings.stepSeconds)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelStateLabel: View {
    let engine: KaraokeEngine
    let stepSeconds: Double

    var body: some View {
        switch engine.modelState {
        case .notLoaded:
            Text("노래방을 시작하면 자동으로 불러옵니다.").font(.caption).foregroundStyle(.secondary)
        case let .loading(backend):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(backend.label) 불러오는 중… (CoreML 첫 로드는 컴파일로 오래 걸릴 수 있음)").font(.caption)
            }
        case let .ready(benchmark):
            let ratio = benchmark.steadyInferenceMilliseconds / (stepSeconds * 1000)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: "%@ · 로드 %.1f초 · 첫 추론 %.0fms · 평균 %.0fms (모델 %.0f + 전후처리 %.0f)",
                    benchmark.backend.label, benchmark.loadSeconds,
                    benchmark.firstInferenceMilliseconds, benchmark.steadyInferenceMilliseconds,
                    benchmark.steadyModelMilliseconds,
                    benchmark.steadyInferenceMilliseconds - benchmark.steadyModelMilliseconds
                ))
                Text(String(format: "갱신 간격 대비 %.0f%% %@", ratio * 100, ratio < 0.7 ? "— 여유 있음" : ratio < 1 ? "— 빠듯함" : "— 실시간 불가, 간격을 늘리세요"))
                    .foregroundStyle(ratio < 0.7 ? .green : ratio < 1 ? .orange : .red)
                if let hz = benchmark.pitchSelfTestHz {
                    let ok = abs(hz - 220) < 3
                    Text(String(format: "음정 검출 자가진단: 220 Hz → %.1f Hz %@", hz, ok ? "✓" : "✗ 이상"))
                        .foregroundStyle(ok ? .green : .red)
                } else {
                    Text("음정 검출기(SwiftF0) 실패 — 음정 바 없이 분리만 동작: \(benchmark.pitchSelfTestError ?? "")")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .monospacedDigit()
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

// MARK: - 싱크

private struct SyncSettings: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section("화면") {
                LabeledContent("화면 싱크") {
                    HStack {
                        Slider(value: Binding(get: { settings.displayLatencyMilliseconds }, set: { settings.displayLatencyMilliseconds = $0 }), in: -300...500, step: 10)
                            .accessibilityLabel("화면 싱크")
                        Text(String(format: "%+.0f ms", settings.displayLatencyMilliseconds)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Text("음정 바·가사가 소리보다 빠르면 +로 늦춥니다. 블루투스 이어폰은 보통 +150~250 ms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("가사") {
                LabeledContent("가사 미세조정") {
                    HStack {
                        Slider(value: Binding(get: { engine.lyrics.offsetSeconds }, set: { engine.lyrics.offsetSeconds = $0 }), in: -1...1, step: 0.05)
                            .accessibilityLabel("가사 미세조정")
                        Text(String(format: "%+.2f초", engine.lyrics.offsetSeconds)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Text("자동 싱크 위에 더합니다. 가사가 노래보다 늦으면 +, 빠르면 −. 메인 화면에서 [ ] 키로도 조절합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AutoSyncInfoView(controller: engine.lyrics)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AutoSyncInfoView: View {
    let controller: LyricsController

    var body: some View {
        let auto = controller.autoSync
        let diagnostics = controller.anchorDiagnostics
        VStack(alignment: .leading, spacing: 4) {
            if auto.candidateCount > 0 {
                let confidence = auto.lastEstimate.map { String(format: "신뢰도 %.0f%% · %d줄", $0.confidence * 100, $0.lineCount) } ?? "측정 중"
                Text(String(format: "자동 싱크 %+.2f초 (%@) · 가사 후보 %d/%d", -auto.appliedDelay, confidence, auto.candidateIndex + 1, auto.candidateCount))
            } else {
                Text("자동 싱크: 싱크 가사가 있는 곡을 AI 반주로 부르면 동작합니다")
            }
            if diagnostics.count > 1 {
                Text(String(format: "음악 앱 위치 보고 흔들림 %.2f초 · 끊김 %d회", diagnostics.range, diagnostics.discontinuities))
                    .foregroundStyle(diagnostics.range > 0.15 ? .orange : .secondary)
            }
            if case .ready(_, synced: true) = controller.status {
                Text("가사 출처: LRCLIB (커뮤니티 가사 DB)")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

// MARK: - 진단

private struct DiagnosticsSettings: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("음정 바에 진단 숫자 표시", isOn: Binding(get: { settings.showPitchDiagnostics }, set: { settings.showPitchDiagnostics = $0 }))
                HStack {
                    Button("최근 30초 녹음 저장") { engine.saveDiagnosticRecording() }
                        .disabled(!engine.isRunning)
                    if let message = engine.diagnosticSaveMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                    }
                }
                Text("틱 소리가 들린 직후 누르세요. CoNo 가 받은 소리와 내보낸 소리를 ~/Downloads 에 각각 저장합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.isRunning {
                Section("모니터") {
                    MonitorView(engine: engine, delaySeconds: settings.delaySeconds)
                }
            } else {
                Section("모니터") {
                    Text("노래방이 켜져 있을 때 버퍼·끊김·오디오 장치·추론 시간을 보여 줍니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct MonitorView: View {
    let engine: KaraokeEngine
    let delaySeconds: Double

    var body: some View {
        let stats = engine.stats
        VStack(alignment: .leading, spacing: 8) {
            LevelBar(label: "입력 (원본)", level: stats.inputPeak)
            LevelBar(label: "출력 (CoNo)", level: stats.outputPeak)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("버퍼").foregroundStyle(.secondary)
                    Text(String(format: "%.2f초 / 목표 %.1f초 · %@", stats.bufferedSeconds, delaySeconds, stats.isPrimed ? "재생 중" : "채우는 중…"))
                }
                GridRow {
                    Text("끊김").foregroundStyle(.secondary)
                    Text("언더런 \(stats.underruns) · 오버플로 \(stats.captureOverflows)")
                }
                diagnosticsRow("캡처 IO", stats.capture)
                diagnosticsRow("재생 IO", stats.playback)
                GridRow {
                    Text("장치").foregroundStyle(.secondary)
                    Text(engine.inputSampleRate == engine.outputSampleRate
                        ? "\(engine.outputDeviceName) · \(Int(engine.outputSampleRate)) Hz"
                        : "\(engine.outputDeviceName) · 탭 \(Int(engine.inputSampleRate)) → 출력 \(Int(engine.outputSampleRate)) Hz (CoNo 변환)")
                }
                if engine.runningMode == .aiSeparation {
                    let inference = engine.inferenceStats
                    GridRow {
                        Text("추론").foregroundStyle(.secondary)
                        Text(String(format: "최근 %.0f · 평균 %.0f · 최대 %.0f ms (%d회)",
                                    inference.lastMilliseconds, inference.averageMilliseconds,
                                    inference.maxMilliseconds, inference.count))
                    }
                    if let timing = engine.separationTiming {
                        GridRow {
                            Text("분리 지연").foregroundStyle(.secondary)
                            Text(String(format: "출력 오프셋 %.2f초 · 최대 대기 %.2f초 + 추론", timing.streamOffset, timing.maxWait))
                        }
                    }
                    if let range = engine.vocalRange {
                        GridRow {
                            Text("원곡 음역").foregroundStyle(.secondary)
                            Text(String(format: "중앙값 MIDI %.1f · 유성 %.0f초", range.medianMidi, range.voicedSeconds))
                        }
                    }
                }
            }
            .font(.callout)
            .monospacedDigit()

            if let error = engine.pitchError ?? engine.pitchTimeline?.error {
                Text("음정 추적 오류: \(error)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = stats.processingError {
                Text("처리 중단: \(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if stats.capturedSeconds > 3, !stats.hasReceivedSignal {
                Text("입력이 계속 무음입니다. 선택한 앱에서 재생 중인지, 그리고 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 CoNo 가 허용됐는지 확인하세요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 오디오 콜백 진단: 건너뜀이 늘면 시스템이 제때 IO 를 못 돌린 것 (틱 소리)
    private func diagnosticsRow(_ label: String, _ diagnostics: CallbackDiagnostics) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(String(
                format: "사이클 건너뜀 %d회 · 콜백 최대 %.2f ms / 주기 %.1f ms",
                diagnostics.skippedCycles, diagnostics.maxCallbackMilliseconds, diagnostics.cycleMilliseconds
            ))
            .foregroundStyle(diagnostics.skippedCycles > 0 ? .orange : .primary)
        }
    }
}

/// dBFS 기반 가로 레벨 바 (-60 dB ~ 0 dB).
private struct LevelBar: View {
    let label: String
    let level: Float

    private var normalized: Double {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return min(max((db + 60) / 60, 0), 1)
    }

    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 90, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(normalized > 0.95 ? Color.red : Color.accentColor)
                        .frame(width: proxy.size.width * normalized)
                }
            }
            .frame(height: 8)
        }
    }
}
