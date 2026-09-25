// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// PoC 화면: 소스 선택 → 처리 방식(그대로 / L−R / AI 분리)·지연 설정 → 시작, 레벨·버퍼·추론 모니터.

import AppKit
import SwiftUI

struct ContentView: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog

    @State private var selectedSourceID: AudioSource.ID?
    @State private var delaySeconds = 3.0
    @State private var muteOriginal = true
    @State private var mode: ProcessingMode = .aiSeparation
    @State private var separation = SeparationSettings()

    private var selectedSource: AudioSource? {
        catalog.sources.first { $0.id == selectedSourceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let timeline = engine.pitchTimeline {
                PitchBarView(timeline: timeline, position: { engine.displayPosition() }, keyShift: engine.keyShift)
                    .frame(minHeight: 240)
            } else {
                sourceList
            }
            settings
            controls
            if engine.isRunning { monitor }
            Spacer(minLength: 0)
        }
        .padding(20)
        .task {
            // 실행 중이 아닐 때 2초마다 목록 갱신 (새로 재생을 시작한 앱 반영)
            while !Task.isCancelled {
                if !engine.isBusy { catalog.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CoNo").font(.largeTitle.bold())
            Text("PoC ③ — AI 보컬 분리 + 음정 바 (SwiftF0)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("캡처할 소스").font(.headline)
            List(catalog.sources, selection: $selectedSourceID) { source in
                HStack(spacing: 8) {
                    sourceIcon(source)
                    Text(source.name)
                    Spacer()
                    if source.isPlaying {
                        Label("재생 중", systemImage: "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .help("지금 소리를 내고 있습니다")
                    }
                }
                .tag(source.id)
            }
            .frame(minHeight: 180)
            .disabled(engine.isBusy)
            .overlay {
                if catalog.sources.count <= 1 {
                    Text("소리를 내는 앱이 없습니다. 스트리밍 앱에서 노래를 재생해 보세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            if let error = catalog.lastError {
                Text("목록을 읽지 못했습니다: \(error)").font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func sourceIcon(_ source: AudioSource) -> some View {
        if let url = source.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "hifispeaker.2")
                .frame(width: 20, height: 20)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("처리 방식", selection: $mode) {
                Text("그대로").tag(ProcessingMode.passthrough)
                Text("간이 제거 (L−R)").tag(ProcessingMode.centerCancel)
                Text("AI 분리").tag(ProcessingMode.aiSeparation)
            }
            .pickerStyle(.segmented)
            .disabled(engine.isBusy)
            .help("방식마다 지연이 달라서 실행 중에는 바꿀 수 없습니다")

            if mode == .aiSeparation {
                separationSettings
            }

            HStack {
                Text("지연")
                Slider(value: $delaySeconds, in: 0.5...8, step: 0.5)
                Text(String(format: "%.1f초", delaySeconds))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(engine.isBusy)
            .help("보컬 분리·음정 미리보기에 쓸 여유 시간. 실행 중에는 바꿀 수 없습니다.")

            if mode == .aiSeparation {
                let recommended = engine.recommendedDelay(for: separation)
                if delaySeconds < recommended {
                    HStack {
                        Text(String(format: "권장 지연 %.1f초보다 짧아 소리가 끊길 수 있습니다", recommended))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("권장값으로") { delaySeconds = min(8, (recommended * 2).rounded(.up) / 2) }
                            .controlSize(.small)
                            .disabled(engine.isBusy)
                    }
                }
            }

            Toggle("원본 소리 끄기 (CoNo 가 지연 재생)", isOn: $muteOriginal)
                .disabled(engine.isBusy)
                .help("끄면 원본과 CoNo 재생이 겹쳐 들립니다 (에코 확인용)")
        }
    }

    private var separationSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("추론", selection: $separation.backend) {
                    ForEach(InferenceBackend.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("갱신 간격").frame(width: 70, alignment: .leading)
                    Slider(value: $separation.stepSeconds, in: 0.5...3, step: 0.25)
                    Text(String(format: "%.2f초", separation.stepSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .help("몇 초마다 새로 분리할지. 추론 1회 시간보다 길어야 끊기지 않습니다.")

                HStack {
                    Text("뒤 문맥").frame(width: 70, alignment: .leading)
                    Slider(value: $separation.rightContextSeconds, in: 0.25...2.5, step: 0.25)
                    Text(String(format: "%.2f초", separation.rightContextSeconds)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .help("모델에게 보여줄 '앞으로 나올 소리' 길이. 길수록 품질이 좋아지고 지연이 늘어납니다.")

                HStack(alignment: .firstTextBaseline) {
                    Button("모델 준비 · 속도 측정") {
                        Task { await engine.prepareModel(backend: separation.backend) }
                    }
                    .disabled(engine.isModelLoading)
                    modelStateLabel
                }
            }
            .disabled(engine.isBusy)
            .padding(4)
        }
    }

    @ViewBuilder
    private var modelStateLabel: some View {
        switch engine.modelState {
        case .notLoaded:
            Text("시작하면 자동으로 로드합니다").font(.caption).foregroundStyle(.secondary)
        case let .loading(backend):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(backend.label) 로드 중… (CoreML 첫 로드는 컴파일로 오래 걸릴 수 있음)").font(.caption)
            }
        case let .ready(benchmark):
            let ratio = benchmark.steadyInferenceMilliseconds / (separation.stepSeconds * 1000)
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if engine.isBusy {
                    Button("정지", systemImage: "stop.fill") { engine.stop() }
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("시작", systemImage: "play.fill") {
                        guard let selectedSource else { return }
                        Task {
                            await engine.start(
                                source: selectedSource,
                                delaySeconds: delaySeconds,
                                muteOriginal: muteOriginal,
                                mode: mode,
                                separation: separation
                            )
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selectedSource == nil || engine.isModelLoading)
                }
                if case let .running(name) = engine.status {
                    Text("캡처 중: \(name)").foregroundStyle(.secondary)
                } else if engine.status == .starting {
                    ProgressView().controlSize(.small)
                    Text("시작 중… 오디오 권한 창이 떠 있으면 허용해 주세요").foregroundStyle(.secondary)
                }
            }
            .controlSize(.large)

            keyControl

            if case let .failed(message) = engine.status {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            if engine.runningMode == .aiSeparation {
                Picker("들려줄 소리", selection: Binding(
                    get: { engine.separationOutput },
                    set: { engine.separationOutput = $0 }
                )) {
                    Text("반주 (노래방)").tag(SeparationOutput.accompaniment)
                    Text("보컬만").tag(SeparationOutput.vocals)
                    Text("원곡").tag(SeparationOutput.original)
                }
                .pickerStyle(.segmented)
                .help("세 소리는 같은 시점으로 맞춰져 있어 실행 중에 바꿔 비교할 수 있습니다")
            }
        }
    }

    private var monitor: some View {
        let stats = engine.stats
        return GroupBox("모니터") {
            VStack(alignment: .leading, spacing: 8) {
                LevelBar(label: "입력 (원본)", level: stats.inputPeak)
                LevelBar(label: "출력 (CoNo)", level: stats.outputPeak)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("버퍼").foregroundStyle(.secondary)
                        Text(String(format: "%.2f초 / 목표 %.1f초", stats.bufferedSeconds, delaySeconds)).monospacedDigit()
                        Text(stats.isPrimed ? "재생 중" : "채우는 중…")
                            .foregroundStyle(stats.isPrimed ? .green : .orange)
                    }
                    GridRow {
                        Text("끊김").foregroundStyle(.secondary)
                        Text("언더런 \(stats.underruns) · 오버플로 \(stats.captureOverflows)").monospacedDigit()
                        Text("")
                    }
                    diagnosticsRow("캡처 IO", stats.capture)
                    diagnosticsRow("재생 IO", stats.playback)
                    GridRow {
                        Text("장치").foregroundStyle(.secondary)
                        Text(engine.inputSampleRate == engine.outputSampleRate
                            ? "\(engine.outputDeviceName) · \(Int(engine.outputSampleRate)) Hz"
                            : "\(engine.outputDeviceName) · 탭 \(Int(engine.inputSampleRate)) → 출력 \(Int(engine.outputSampleRate)) Hz (CoNo 변환)")
                        Text("")
                    }
                }
                .font(.callout)

                if engine.runningMode == .aiSeparation {
                    let inference = engine.inferenceStats
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("추론").foregroundStyle(.secondary)
                            Text(String(format: "최근 %.0f · 평균 %.0f · 최대 %.0f ms (%d회)",
                                        inference.lastMilliseconds, inference.averageMilliseconds,
                                        inference.maxMilliseconds, inference.count))
                        }
                        if let timing = engine.separationTiming {
                            GridRow {
                                Text("분리 지연").foregroundStyle(.secondary)
                                Text(String(format: "출력 오프셋 %.2f초 · 최대 대기 %.2f초 + 추론",
                                            timing.streamOffset, timing.maxWait))
                            }
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }

                if engine.pitchTimeline != nil {
                    HStack {
                        Text("화면 싱크").foregroundStyle(.secondary)
                        Slider(
                            value: Binding(get: { engine.displayLatencyMilliseconds }, set: { engine.displayLatencyMilliseconds = $0 }),
                            in: -300...500,
                            step: 10
                        )
                        Text(String(format: "%+.0f ms", engine.displayLatencyMilliseconds))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                    .font(.callout)
                    .help("음정 바가 소리보다 빠르면 +로 늦춥니다. 블루투스 이어폰은 보통 +150~250 ms.")
                }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private extension ContentView {
    /// 노래방 기계식 키 조절: ♭ / 원키 / ♯ (반음 단위, 실행 중에도 즉시 반영)
    var keyControl: some View {
        HStack(spacing: 8) {
            Text("키").foregroundStyle(.secondary)
            Button {
                engine.changeKey(by: -1)
            } label: {
                Label("내리기", systemImage: "minus").labelStyle(.iconOnly)
            }
            .disabled(engine.keyShift <= PlaybackOutput.keyShiftRange.lowerBound)
            .keyboardShortcut(.downArrow, modifiers: .command)
            .help("반음 내리기 (⌘↓)")

            Text(engine.keyShift == 0 ? "원키" : String(format: "%@%d", engine.keyShift > 0 ? "♯ +" : "♭ ", engine.keyShift))
                .monospacedDigit()
                .frame(width: 56)

            Button {
                engine.changeKey(by: 1)
            } label: {
                Label("올리기", systemImage: "plus").labelStyle(.iconOnly)
            }
            .disabled(engine.keyShift >= PlaybackOutput.keyShiftRange.upperBound)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("반음 올리기 (⌘↑)")

            Button("원키로") { engine.resetKey() }
                .disabled(engine.keyShift == 0)
                .keyboardShortcut("0", modifiers: .command)
        }
        .controlSize(.regular)
    }

    /// 오디오 콜백 진단: 건너뜀이 늘면 시스템이 제때 IO 를 못 돌린 것 (틱 소리)
    func diagnosticsRow(_ label: String, _ diagnostics: CallbackDiagnostics) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(String(
                format: "사이클 건너뜀 %d회 · 콜백 최대 %.2f ms / 주기 %.1f ms",
                diagnostics.skippedCycles, diagnostics.maxCallbackMilliseconds, diagnostics.cycleMilliseconds
            ))
            .monospacedDigit()
            .foregroundStyle(diagnostics.skippedCycles > 0 ? .orange : .primary)
            Text("")
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
