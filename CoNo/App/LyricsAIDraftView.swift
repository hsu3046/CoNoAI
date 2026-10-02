// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsAIDraftRequest: Identifiable {
    let id = UUID()
    let track: TrackInfo
    var initialText: String? = nil
}

/// 원본 가사와 분리된 검토 화면. 오디오는 메모리에서만 처리하고 저장 버튼은 명시적으로 확인한다.
struct LyricsAIDraftView: View {
    let engine: KaraokeEngine
    let track: TrackInfo
    private let initialText: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var draft: AlignedLyricsDraft?
    @State private var analyzedRange: ClosedRange<Double>?
    @State private var message: String?
    @State private var isAnalyzing = false
    @State private var isCancelling = false
    @State private var isSaving = false
    @State private var hasSaved = false
    @State private var requestID = UUID()
    @State private var requestTask: Task<Void, Never>?
    @State private var manualSession: UUID?
    @State private var confirmation: Confirmation?
    @State private var editorRequest: LyricsEditorRequest?
    private enum Confirmation { case close, save, replace }
    private var coordinator: AlignmentCoordinator { engine.lyrics.localAlignment }

    init(engine: KaraokeEngine, track: TrackInfo, initialText: String? = nil) {
        self.engine = engine
        self.track = track
        self.initialText = initialText ?? ""
        _text = State(initialValue: self.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("최근 구간 AI 가사 초안").font(.title2.bold())
                    Text("\(track.title) · \(track.artist)").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("닫기") {
                    if hasUnsavedChanges { confirmation = .close } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(isSaving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("AI 반주로 들은 최근 최대 20초를 이 기기에서 분석합니다. 곡을 처음부터 끝까지 들을 필요 없이 한 구간씩 확인할 수 있어요.")
                        .font(.callout)
                    Text("방금 들은 구간의 가사가 있으면 해당 줄만 입력하세요. 비워 두면 받아쓰기 초안을 만듭니다.")
                        .font(.callout)
                    TextEditor(text: $text)
                        .font(.body).padding(8).frame(height: 130)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("최근 구간의 일반 가사, 비워 두면 받아쓰기")
                        .disabled(isAnalyzing || isSaving)
                    HStack {
                        Button("현재 가사 불러오기") { text = engine.lyrics.availablePlainLyrics(for: track); message = "방금 들은 구간의 줄만 남겨 주세요. 한 번에 512글자까지 분석합니다." }
                            .disabled(isAnalyzing || isSaving || engine.lyrics.availablePlainLyrics(for: track).isEmpty)
                        Spacer()
                        Text("\(text.count)/512글자").font(.caption.monospacedDigit()).foregroundStyle(text.count > 512 ? .red : .secondary)
                    }
                    HStack {
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                            Text(isCancelling ? "현재 분석을 마친 뒤 취소합니다…" : "이 기기에서 분석 중…").font(.callout)
                            Spacer()
                            Button("분석 취소") { isCancelling = true; requestTask?.cancel() }.disabled(isCancelling)
                        } else {
                            Button(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "최근 구간 받아쓰기" : "최근 구간 줄 시각 맞추기") {
                                if draft != nil, !hasSaved { confirmation = .replace } else { analyze() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAnalyze)
                            if coordinator.isBusy { Text("앞선 분석이 끝나기를 기다리는 중").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if engine.lyrics.currentTrack?.id != track.id {
                        Text("다른 곡이 재생 중입니다. 이 곡으로 돌아온 뒤 새 구간을 분석해 주세요.").font(.callout).foregroundStyle(.orange)
                    }
                    if let draft { preview(draft) }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("노래·발음·반주에 따라 오인식할 수 있어요. 원문과 시각을 확인한 뒤 저장하세요. 음성은 외부로 보내거나 파일로 저장하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let draft {
                HStack {
                    Button("탭으로 다시 맞추기…") { editorRequest = LyricsEditorRequest(track: track, initialText: draft.plainLyrics) }
                    Button("LRC 내보내기…") { export(draft) }
                    Spacer()
                    Button(isSaving ? "저장 중…" : "이 구간을 내 가사로 저장…") { confirmation = .save }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(isAnalyzing || isSaving || engine.lyrics.isChangingLocalLyrics)
            }
        }
        .padding(24)
        .frame(width: 730, height: 730)
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .onAppear { if manualSession == nil { manualSession = coordinator.beginManualSession() } }
        .onDisappear {
            requestID = UUID()
            requestTask?.cancel()
            if let manualSession { coordinator.endManualSession(manualSession) }
        }
        .onChange(of: text) { _, _ in draft = nil; hasSaved = false; analyzedRange = nil }
        .sheet(item: $editorRequest) { request in
            LyricsTapSyncView(engine: engine, track: request.track, initialText: request.initialText)
        }
        .alert(alertTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("취소", role: .cancel) { confirmation = nil }
            if confirmation == .save {
                Button("이 구간으로 저장") { confirmation = nil; save() }
            } else {
                Button(confirmation == .close ? "버리고 닫기" : "새로 분석", role: .destructive) {
                    let action = confirmation
                    confirmation = nil
                    if action == .close { dismiss() } else { analyze() }
                }
            }
        } message: { Text(alertMessage) }
    }

    private var canAnalyze: Bool {
        coordinator.isEnabled && coordinator.modelAvailable && !coordinator.isBusy && !coordinator.isDeleting
            && !isSaving && engine.isRunning && !engine.showsPaused && engine.seekTarget == nil
            && engine.lyrics.currentTrack?.id == track.id
    }
    private var hasUnsavedChanges: Bool { !hasSaved && (draft != nil || text != initialText) }
    private var alertTitle: String {
        confirmation == .save ? "‘\(track.title)’의 내 가사로 저장할까요?" : "아직 저장하지 않은 초안을 버릴까요?"
    }
    private var alertMessage: String {
        if confirmation == .save {
            return "이 초안에는 최근 구간만 있습니다. 저장하면 현재 가사 대신 이 구간의 초안을 사용합니다. 전체 곡을 만들려면 탭 편집에서 다른 줄을 추가해 주세요. 선택했던 원본 파일과 온라인 가사는 삭제하지 않습니다."
        }
        return "기존에 저장한 가사는 그대로 남습니다. 이 화면의 초안만 사라집니다."
    }

    @ViewBuilder private func preview(_ draft: AlignedLyricsDraft) -> some View {
        Divider()
        HStack {
            Text(draft.isTranscription ? "받아쓰기 AI 초안" : "줄 시각 AI 초안").font(.headline)
            Spacer()
            if let analyzedRange {
                Text("\(LyricsTapSync.timestamp(analyzedRange.lowerBound))–\(LyricsTapSync.timestamp(analyzedRange.upperBound))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        ForEach(draft.lyrics.lines.indices, id: \.self) { index in
            let line = draft.lyrics.lines[index]
            HStack(alignment: .top, spacing: 12) {
                Button(LyricsTapSync.timestamp(line.start)) { engine.seek(toSongPosition: max(0, line.start - 1)) }
                    .font(.caption.monospacedDigit())
                    .help("이 줄 1초 전부터 듣기")
                    .disabled(engine.lyrics.currentTrack?.id != track.id || !engine.canControlPlayback)
                Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func analyze() {
        guard canAnalyze else { return }
        let input = text
        let requestText: String?
        do { requestText = try AlignedLyricsDraft.requestText(input) }
        catch { message = error.localizedDescription; return }
        guard let heard = engine.heardCaptureTime(), let window = engine.lyrics.recentAlignmentWindow(for: track, atCaptureTime: heard) else {
            message = LocalAlignmentError.missingAudio.localizedDescription
            return
        }
        let id = UUID()
        requestID = id
        isAnalyzing = true; isCancelling = false; message = nil
        requestTask = Task {
            defer { if requestID == id { isAnalyzing = false; isCancelling = false; requestTask = nil } }
            do {
                let result = try await coordinator.draft(window: window, text: requestText)
                try Task.checkCancellation()
                let parsed = try AlignedLyricsDraft(result: result, expectedText: requestText)
                _ = try parsed.lrc()
                guard requestID == id, text == input else { return }
                draft = parsed
                analyzedRange = window.songStart...(window.songStart + window.streamEnd - window.streamStart)
                hasSaved = false
                message = "내용과 시각을 확인해 주세요. 이 초안은 아직 현재 가사에 적용되지 않았습니다."
            } catch is CancellationError {
                if requestID == id { message = "분석을 취소했어요. 곡·재생 위치가 바뀐 경우에는 새 구간을 분석해 주세요." }
            } catch { if requestID == id { message = error.localizedDescription } }
        }
    }

    private func save() {
        guard let draft else { return }
        let contents: String
        do { contents = try draft.lrc() }
        catch { message = error.localizedDescription; return }
        isSaving = true
        Task {
            let saved = await engine.lyrics.saveTappedLyrics(contents, for: track, fileName: "ai-draft.lrc", label: "검토한 AI 가사 초안")
            hasSaved = saved
            message = saved ? "‘\(track.title)’에 검토한 구간을 저장했어요." : engine.lyrics.localLyricsError ?? "저장하지 못했어요. 다시 시도해 주세요."
            isSaving = false
        }
    }

    private func export(_ draft: AlignedLyricsDraft) {
        let contents: String
        do { contents = try draft.lrc() }
        catch { message = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.title = "검토한 AI 가사 초안 내보내기"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.nameFieldStringValue = "CoNo-AI-draft.lrc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            hasSaved = true
            message = "LRC 파일을 내보냈어요. 앱의 현재 가사는 그대로입니다."
        } catch { message = "파일을 내보내지 못했어요: \(error.localizedDescription)" }
    }
}
