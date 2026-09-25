// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later
//
// PoC ① 화면: 소스 선택 → 지연·음소거 설정 → 시작, 레벨·버퍼 모니터.

import AppKit
import SwiftUI

struct ContentView: View {
    let engine: KaraokeEngine
    let catalog: AudioSourceCatalog

    @State private var selectedSourceID: AudioSource.ID?
    @State private var delaySeconds = 3.0
    @State private var muteOriginal = true

    private var selectedSource: AudioSource? {
        catalog.sources.first { $0.id == selectedSourceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            sourceList
            settings
            controls
            if engine.isRunning { monitor }
            Spacer(minLength: 0)
        }
        .padding(20)
        .task {
            // 실행 중이 아닐 때 2초마다 목록 갱신 (새로 재생을 시작한 앱 반영)
            while !Task.isCancelled {
                if !engine.isRunning { catalog.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CoNo").font(.largeTitle.bold())
            Text("PoC ① — 다른 앱 소리 캡처 · 원본 음소거 · 지연 재생")
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
            .disabled(engine.isRunning)
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
            HStack {
                Text("지연")
                Slider(value: $delaySeconds, in: 0.5...8, step: 0.5)
                Text(String(format: "%.1f초", delaySeconds))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(engine.isRunning)
            .help("보컬 분리·음정 미리보기에 쓸 여유 시간. 실행 중에는 바꿀 수 없습니다.")

            Toggle("원본 소리 끄기 (CoNo 가 지연 재생)", isOn: $muteOriginal)
                .disabled(engine.isRunning)
                .help("끄면 원본과 CoNo 재생이 겹쳐 들립니다 (에코 확인용)")

            Picker("처리", selection: Binding(
                get: { engine.processingMode },
                set: { engine.processingMode = $0 }
            )) {
                Text("그대로").tag(ProcessingMode.passthrough)
                Text("간이 보컬 제거 (L−R)").tag(ProcessingMode.centerCancel)
            }
            .pickerStyle(.segmented)
            .help("L−R 은 AI 분리 전 임시 방식이라 베이스·킥도 같이 줄어듭니다")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if engine.isRunning {
                    Button("정지", systemImage: "stop.fill") { engine.stop() }
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("시작", systemImage: "play.fill") {
                        guard let selectedSource else { return }
                        engine.start(source: selectedSource, delaySeconds: delaySeconds, muteOriginal: muteOriginal)
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selectedSource == nil)
                }
                if case let .running(name) = engine.status {
                    Text("캡처 중: \(name)").foregroundStyle(.secondary)
                }
            }
            .controlSize(.large)

            if case let .failed(message) = engine.status {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
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
                    GridRow {
                        Text("장치").foregroundStyle(.secondary)
                        Text("\(engine.outputDeviceName) · \(Int(engine.sampleRate)) Hz")
                        Text("")
                    }
                }
                .font(.callout)

                if let warning = engine.sampleRateWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
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
