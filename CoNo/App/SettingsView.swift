// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// 설정 창 (⌘,): 일반 · 소리 · 가사 · AI 엔진 · 진단 · 정보.
// 노래 부르는 중에 쓰는 조절(키·반주/보컬·가사 싱크·음정 바 표시)은 메인 화면에, 나머지는 여기.
// 실행 중에 못 바꾸는 항목은 잠그고 이유를 적는다.

import AppKit
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
            LyricsSettings(engine: engine, settings: settings)
                .tabItem { Label("가사", systemImage: "text.quote") }
            SeparationSettingsTab(engine: engine, settings: settings)
                .tabItem { Label("AI 엔진", systemImage: "cpu") }
            DiagnosticsSettings(engine: engine, settings: settings)
                .tabItem { Label("진단", systemImage: "stethoscope") }
            AboutSettings()
                .tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 580)
        .frame(minHeight: 460)
    }
}

/// 실행 중에는 못 바꾸는 항목 안내
private struct LockedWhileRunning: View {
    let engine: KaraokeEngine

    var body: some View {
        if engine.isBusy {
            Label("노래방이 켜져 있는 동안은 바꿀 수 없어요. 끝낸 뒤 다시 시작하면 반영됩니다.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 설명 한 줄 (회색 작은 글씨)
private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 일반

private struct GeneralSettings: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog
    let settings: AppSettings

    var body: some View {
        Form {
            Section("연결") {
                Picker("연결할 앱", selection: Binding(get: { settings.sourcePreference }, set: { settings.sourcePreference = $0 })) {
                    Text("자동 — 음악 앱 우선, 없으면 지금 재생 중인 앱").tag(AppSettings.autoSource)
                    ForEach(catalog.sources.filter { $0.kind != .systemWide && $0.bundleID != nil }) { app in
                        Text(app.isPlaying ? "\(app.name) · 재생 중" : app.name).tag(app.bundleID ?? "")
                    }
                    if ![AppSettings.autoSource, AppSettings.systemSource].contains(settings.sourcePreference),
                       !catalog.sources.contains(where: { $0.bundleID == settings.sourcePreference }) {
                        Text("\(settings.sourcePreference) (지금 실행 중 아님)").tag(settings.sourcePreference)
                    }
                    Text("시스템 전체 — 곡 정보·가사·재생 제어 없음").tag(AppSettings.systemSource)
                }
                Toggle("원곡 소리 끄기", isOn: Binding(get: { settings.muteOriginal }, set: { settings.muteOriginal = $0 }))
                Caption("끄면 원곡과 CoNo 소리가 겹쳐 들려요. 보통은 켜 두세요.")
                LockedWhileRunning(engine: engine)
            }
            .disabled(engine.isBusy)

            Section {
                Toggle("노래가 나오면 자동으로 시작", isOn: Binding(get: { settings.autoStart }, set: { settings.autoStart = $0 }))
                Caption("CoNo 를 열어 둔 채 음악 앱(또는 위에서 고른 앱)에서 재생하면 바로 노래방이 켜집니다. 직접 끝낸 뒤에는 그 곡이 멈출 때까지 다시 켜지지 않아요.")
            }

            Section("내 목소리") {
                Picker("내 목소리", selection: Binding(get: { settings.myVoice }, set: { settings.myVoice = $0 })) {
                    Text("남성").tag(VoiceType.male)
                    Text("여성").tag(VoiceType.female)
                }
                .pickerStyle(.segmented)
                Caption("'내 키' 를 누르면 원곡 보컬의 음역을 재서 이 목소리가 편한 높이로 키를 옮깁니다. 원곡 가수와 성별이 달라도 옥타브까지 고려해요.")
            }

            Section("권한") {
                PermissionRow(
                    title: "화면 및 시스템 오디오 녹음",
                    detail: "연결된 앱의 소리를 가져옵니다. 없으면 무음만 들어와요. (필수)",
                    pane: "Privacy_ScreenCapture"
                )
                PermissionRow(
                    title: "자동화 › 음악",
                    detail: "Apple Music 앱을 직접 연결해 곡 정보·재생 위치를 더 정확히 읽고 재생·일시정지·이동을 합니다. 다른 앱(브라우저·Spotify 등)은 이 권한이 필요 없어요.",
                    pane: "Privacy_Automation"
                )
                PermissionRow(
                    title: "손쉬운 사용",
                    detail: "다른 앱을 멈출 때 예비 수단(⏯ 미디어 키)으로만 씁니다. 보통은 필요 없어요.",
                    pane: "Privacy_Accessibility"
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// 권한 한 줄: 이름 · 쓰임 · 시스템 설정 열기
private struct PermissionRow: View {
    let title: String
    let detail: String
    /// 시스템 설정 › 개인정보 보호 및 보안 의 패널 이름
    let pane: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Caption(detail)
            }
            Spacer()
            Button("열기") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .help("시스템 설정에서 \(title) 열기")
        }
    }
}

// MARK: - 소리

private struct SoundSettings: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("반주 만들기", selection: Binding(get: { settings.mode }, set: { settings.mode = $0 })) {
                    Text("AI 반주").tag(ProcessingMode.aiSeparation)
                    Text("간이 반주").tag(ProcessingMode.centerCancel)
                    Text("원곡 그대로").tag(ProcessingMode.passthrough)
                }
                .pickerStyle(.segmented)
                Caption("AI 반주: 목소리를 AI 로 지우고 음정 바·내 키·가사 자동 싱크가 동작합니다. 간이 반주: 가운데 소리를 빼는 옛 방식(AI 없음). 원곡 그대로: 비교·점검용.")

                LabeledContent("지연") {
                    HStack {
                        Slider(value: Binding(get: { settings.delaySeconds }, set: { settings.delaySeconds = $0 }), in: 0.5...8, step: 0.5)
                        Text(String(format: "%.1f초", settings.delaySeconds)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Caption("CoNo 는 원곡보다 이만큼 늦게 들려줍니다. 그 사이 AI 가 목소리를 지우고 다음 음정을 미리 보여 줘요. 짧을수록 이동·재개가 빠르지만 너무 짧으면 소리가 끊깁니다.")
                if settings.mode == .aiSeparation {
                    let recommended = engine.recommendedDelay(for: settings.separation)
                    if settings.delaySeconds < recommended {
                        HStack {
                            Text(String(format: "이 Mac 의 권장값 %.1f초보다 짧아 소리가 끊길 수 있어요", recommended))
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

            Section("가이드 보컬") {
                LabeledContent("시작할 때 양") {
                    HStack {
                        Slider(value: Binding(get: { settings.guideVocalLevel }, set: { value in
                            settings.guideVocalLevel = value
                            engine.guideVocalLevel = value
                        }), in: 0...0.5)
                        Text(String(format: "%.0f%%", settings.guideVocalLevel * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Caption("반주에 원곡 목소리를 살짝 섞어 부를 줄을 들려줍니다. 노래하는 중에는 도크의 마이크 슬라이더로 바꿔요.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI 엔진

private struct SeparationSettingsTab: View {
    let engine: KaraokeEngine
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("계산 장치", selection: Binding(get: { settings.backend }, set: { settings.backend = $0 })) {
                    ForEach(InferenceBackend.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("갱신 간격") {
                    HStack {
                        Slider(value: Binding(get: { settings.stepSeconds }, set: { settings.stepSeconds = $0 }), in: 0.5...3, step: 0.25)
                        Text(String(format: "%.2f초", settings.stepSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .help("몇 초마다 새로 분리할지. 한 번 계산하는 시간보다 길어야 끊기지 않습니다.")
                LabeledContent("미리 듣는 길이") {
                    HStack {
                        Slider(value: Binding(get: { settings.rightContextSeconds }, set: { settings.rightContextSeconds = $0 }), in: 0.25...2.5, step: 0.25)
                        Text(String(format: "%.2f초", settings.rightContextSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                .help("AI 에게 보여 줄 '앞으로 나올 소리' 길이. 길수록 목소리가 깨끗이 지워지지만 지연이 늘어납니다.")
                Caption("대부분은 기본값(자동 · 1초 · 1초)이 가장 좋습니다. 소리가 끊기면 갱신 간격을 늘리거나 소리 탭의 지연을 권장값으로 맞춰 보세요.")
                LockedWhileRunning(engine: engine)
            }
            .disabled(engine.isBusy)

            Section("AI 모델") {
                HStack(alignment: .firstTextBaseline) {
                    Button("불러오고 속도 재기") {
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
            Text("노래방을 시작하면 자동으로 불러옵니다. 미리 불러 두면 첫 시작이 빨라져요.").font(.caption).foregroundStyle(.secondary)
        case let .loading(backend):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(backend.label) 불러오는 중… (처음 한 번은 준비에 수십 초 걸릴 수 있어요)").font(.caption)
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

// MARK: - 가사

private struct LyricsSettings: View {
    let engine: KaraokeEngine
    let settings: AppSettings
    @State private var cleared = false

    var body: some View {
        Form {
            Section("싱크") {
                LabeledContent("가사 미세조정") {
                    HStack {
                        Slider(value: Binding(get: { engine.lyrics.offsetSeconds }, set: { engine.lyrics.offsetSeconds = $0 }),
                               in: -LyricsController.offsetLimit...LyricsController.offsetLimit, step: 0.05)
                            .accessibilityLabel("가사 미세조정")
                        Text(String(format: "%+.2f초", engine.lyrics.offsetSeconds)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Caption("자동 싱크 위에 더하는 값이에요. 가사가 노래보다 늦으면 +, 빠르면 −. 노래하는 중에는 가사 위에 마우스를 올리거나 [ ] 키로 바꿉니다.")
                AutoSyncInfoView(controller: engine.lyrics)

                LabeledContent("화면 싱크") {
                    HStack {
                        Slider(value: Binding(get: { settings.displayLatencyMilliseconds }, set: { settings.displayLatencyMilliseconds = $0 }), in: -300...500, step: 10)
                            .accessibilityLabel("화면 싱크")
                        Text(String(format: "%+.0f ms", settings.displayLatencyMilliseconds)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Caption("음정 바와 가사가 소리보다 앞서 보이면 + 로 늦춥니다. 블루투스 이어폰·스피커는 보통 +150~250 ms.")
            }

            Section("가사 출처") {
                Caption("시간이 맞춰진 가사는 LRCLIB(커뮤니티 가사 DB)에서 찾습니다. 곡 정보는 음악 앱은 직접, 그 밖의 앱(브라우저의 YouTube 등)은 macOS '지금 재생 중' 으로 받아요. 영상 제목은 '가수 - 곡' 형태로 다듬어 찾습니다.")
                HStack {
                    Button("가사 캐시·기억한 싱크 지우기") {
                        LRCLIBClient.clearCache()
                        LearnedLyricsDelays().removeAll()
                        cleared = true
                    }
                    if cleared {
                        Text("지웠습니다. 다음 곡부터 새로 찾아요.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Caption("가사가 엉뚱하거나 계속 어긋날 때 써 보세요. 곡마다 맞춰 둔 가사 싱크도 함께 지워집니다.")
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
                Caption("재생 위치·분석 여유·프레임 수를 음정 바 왼쪽 위에 보여 줍니다.")
                HStack {
                    Button("최근 30초 녹음 저장") { engine.saveDiagnosticRecording() }
                        .disabled(!engine.isRunning)
                    if let message = engine.diagnosticSaveMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                    }
                }
                Caption("'틱' 하는 잡음이 들린 직후 누르세요. CoNo 가 받은 소리와 내보낸 소리를 다운로드 폴더에 각각 저장합니다. 문제를 알려 주실 때 함께 보내 주시면 원인을 찾는 데 도움이 돼요.")
            }

            if engine.isRunning {
                Section("모니터") {
                    MonitorView(engine: engine, delaySeconds: settings.delaySeconds)
                }
            } else {
                Section("모니터") {
                    Caption("노래방이 켜져 있을 때 버퍼·끊김·오디오 장치·AI 계산 시간을 보여 줍니다.")
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
                        Text("AI 계산").foregroundStyle(.secondary)
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

// MARK: - 정보

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 빌드 번호 — 같은 버전을 여러 번 배포할 때 구별하는 내부 번호 (도움말로만)
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CoNo").font(.title2.bold())
                        Text("코인 노래방 No! 집에서 나만의 노래방 즐기기").foregroundStyle(.secondary)
                        Text("버전 \(version)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .help("빌드 \(build)")
                    }
                }
                .padding(.vertical, 4)
            }

            Section("만든 곳") {
                LabeledContent("AIB Inc.") { Link("aib.vote", destination: URL(string: "https://www.aib.vote")!) }
                LabeledContent("소스 코드") { Link("github.com/hsu3046/CoNoAI", destination: URL(string: "https://github.com/hsu3046/CoNoAI")!) }
                LabeledContent("라이선스") { Text("GNU GPL v3") }
            }

            Section("함께 쓰는 것") {
                Caption("목소리 분리: UVR MDX-Net Karaoke 2 · 음정 검출: SwiftF0 · 추론: ONNX Runtime · 가사: LRCLIB · 지금 재생 중: mediaremote-adapter")
                Link("오픈소스 고지 보기", destination: URL(string: "https://github.com/hsu3046/CoNoAI/blob/main/THIRD_PARTY_NOTICES.md")!)
                Caption("소리는 이 Mac 안에서만 처리되고 밖으로 보내지 않아요 (진단 녹음은 직접 저장할 때만 다운로드 폴더에). 인터넷으로는 가사만 찾습니다.")
            }
        }
        .formStyle(.grouped)
    }
}

