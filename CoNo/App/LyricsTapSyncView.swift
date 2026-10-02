// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorRequest: Identifiable {
    let id = UUID()
    let track: TrackInfo
    var initialText: String? = nil
}

struct LyricsTapSyncView: View {
    let engine: KaraokeEngine
    let track: TrackInfo
    private let initialText: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var draft: LyricsTapSync?
    @State private var playback: LyricsTimingSnapshot?
    @State private var message: String?
    @State private var isSaving = false
    @State private var savedTimestamps: [Double]?
    @State private var showPreview = false
    @State private var showPublish = false
    @State private var publishLRC = ""
    @State private var confirmation: Confirmation?
    @FocusState private var recordingFocused: Bool

    private enum Confirmation: String { case close, reset, edit }

    init(engine: KaraokeEngine, track: TrackInfo, initialText: String? = nil) {
        self.engine = engine
        self.track = track
        let initial = initialText ?? engine.lyrics.availablePlainLyrics(for: track)
        self.initialText = initial
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("가사 직접 맞추기").font(.title2.bold())
                    Text("\(track.title) · \(track.artist)").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("닫기") { requestClose() }.keyboardShortcut(.cancelAction).disabled(isSaving)
            }
            if let draft { recording(draft) } else { textEditor }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("저장 전까지 현재 가사는 그대로입니다. 저장하면 선택한 곡의 내 가사를 바꿉니다. 현재 재생 중인 곡에 저장할 때는 가사 미세조정도 0초로 맞춥니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 700, height: 680)
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .onDisappear { draft?.disarm() }
        .task {
            while !Task.isCancelled {
                refreshPlayback()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .alert("기록한 내용을 버릴까요?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("계속 편집", role: .cancel) { confirmation = nil }
            Button("버리기", role: .destructive) {
                let action = confirmation
                confirmation = nil
                switch action {
                case .close: dismiss()
                case .reset: draft?.reset(); savedTimestamps = nil; message = nil
                case .edit: draft = nil; savedTimestamps = nil; message = nil
                case nil: break
                }
            }
        } message: { Text("아직 저장하지 않은 줄 시각은 복구할 수 없습니다. 현재 적용 중인 가사는 그대로 남습니다.") }
        .sheet(isPresented: $showPublish) {
            if let draft {
                LyricsPublishView(track: track, plainLyrics: draft.plainLyrics, syncedLyrics: publishLRC)
            }
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("일반 가사를 한 줄씩 입력하거나 붙여넣으세요. 빈 줄은 건너뜁니다.").font(.callout)
            TextEditor(text: $text)
                .font(.body)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("시간을 맞출 일반 가사")
            HStack {
                Button("현재 가사 불러오기") { text = engine.lyrics.availablePlainLyrics(for: track); message = nil }
                    .disabled(engine.lyrics.availablePlainLyrics(for: track).isEmpty)
                Spacer()
                Button("줄 시간 맞추기") {
                    do {
                        draft = try LyricsTapSync(trackID: track.id, plainLyrics: text)
                        message = nil
                        recordingFocused = true
                    } catch { message = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func recording(_ session: LyricsTapSync) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(playback.map { LyricsTapSync.timestamp($0.position) } ?? "재생 대기")
                    .font(.title3.monospacedDigit()).accessibilityLabel("들리는 곡 위치")
                Spacer()
                Button(engine.showsPaused ? "재생" : "일시정지") {
                    draft?.disarm()
                    engine.togglePlayback()
                }.disabled(!engine.canControlPlayback)
                Button("처음으로 이동") { draft?.disarm(); engine.seek(toSongPosition: 0) }
                    .disabled(!engine.canControlPlayback || engine.seekTarget != nil || engine.lyrics.currentTrack?.id != track.id)
            }
            if showPreview {
                let active = playback.flatMap { session.previewText(at: $0.position) }
                Text(active ?? "가사가 시작되면 여기에 표시됩니다")
                    .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 55).multilineTextAlignment(.center)
                    .accessibilityLabel("가사 미리보기")
            } else {
                Text(session.isComplete ? "모든 줄을 기록했어요" : session.lines[session.timestamps.count])
                    .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 55).multilineTextAlignment(.center)
                    .accessibilityLabel("다음에 기록할 줄")
            }
            HStack {
                Button(session.isArmed ? "기록 끄기" : "기록 켜기") {
                    showPreview = false
                    if session.isArmed { draft?.disarm() }
                    else {
                        do { try draft?.arm(at: recordableSnapshot()); message = nil }
                        catch { message = error.localizedDescription }
                    }
                    recordingFocused = true
                }.disabled(session.isComplete)
                Button("줄 시각 기록 · Space") { recordLine() }
                    .buttonStyle(.borderedProminent).disabled(!session.isArmed)
                    .accessibilityHint("다음 가사 줄을 부르기 시작하는 순간 누르세요")
                Spacer()
                Text("\(session.timestamps.count) / \(session.lines.count)줄").monospacedDigit().foregroundStyle(.secondary)
            }
            if let interruption = session.interruption {
                Text(interruption).font(.caption).foregroundStyle(.orange)
            } else {
                Text("기록을 켠 뒤 각 줄이 시작될 때 Space를 한 번 누르세요. 곡 변경·일시정지·이동 후에는 다시 켜야 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.lines.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(index < session.timestamps.count ? LyricsTapSync.timestamp(session.timestamps[index]) : "--:--.---")
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                Text(session.lines[index]).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(index == session.timestamps.count ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .id(index).accessibilityElement(children: .combine)
                        }
                    }
                }
                .onChange(of: session.timestamps.count) { _, value in proxy.scrollTo(min(value, session.lines.count - 1), anchor: .center) }
            }
            HStack {
                Button("되돌리기") { draft?.undo(); message = nil }
                    .keyboardShortcut("z", modifiers: .command).disabled(session.timestamps.isEmpty)
                Button("시각 재설정") { draft?.disarm(); confirmation = .reset }.disabled(session.timestamps.isEmpty)
                Button("가사 수정") {
                    draft?.disarm()
                    if session.timestamps.isEmpty { draft = nil } else { confirmation = .edit }
                }
                Spacer()
                Toggle("미리보기", isOn: $showPreview).toggleStyle(.button)
                    .onChange(of: showPreview) { _, preview in if preview { draft?.disarm() } }
                    .disabled(session.timestamps.isEmpty)
            }
            Divider()
            HStack {
                Button("LRC 내보내기…") { exportLRC() }.disabled(!session.isComplete)
                Button("LRCLIB에 공유…") { preparePublish() }.disabled(!session.isComplete)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("이 곡에 저장") { save() }
                    .buttonStyle(.borderedProminent).disabled(!session.isComplete || engine.lyrics.isChangingLocalLyrics)
            }
        }
        .disabled(isSaving)
        .focusable().focused($recordingFocused).focusEffectDisabled()
        .onKeyPress(.space, phases: [.down, .repeat]) { press in
            if press.phase == .down { recordLine() }
            return .handled
        }
    }

    private func refreshPlayback() {
        playback = engine.heardCaptureTime().flatMap { engine.lyrics.timingSnapshot(atCaptureTime: $0) }
        if playback?.trackID != track.id { playback = nil }
        draft?.observe(recordableSnapshot())
    }

    private func recordableSnapshot() -> LyricsTimingSnapshot? {
        guard engine.isRunning, !engine.showsPaused, engine.seekTarget == nil, engine.stats.isPrimed,
              !engine.stats.isOutputMuted, !engine.stats.isPlaybackSuspended, engine.stats.processingError == nil else { return nil }
        return engine.heardCaptureTime().flatMap { engine.lyrics.timingSnapshot(atCaptureTime: $0) }
    }

    private func recordLine() {
        guard !showPreview, !isSaving else { return }
        do { try draft?.record(at: recordableSnapshot()); message = nil }
        catch { message = draft?.interruption ?? error.localizedDescription }
    }

    private func save() {
        guard let draft else { return }
        let contents: String
        do { contents = try draft.lrc() }
        catch { message = error.localizedDescription; return }
        let timestamps = draft.timestamps
        self.draft?.disarm()
        isSaving = true
        Task {
            if await engine.lyrics.saveTappedLyrics(contents, for: track) {
                savedTimestamps = timestamps
                message = "‘\(track.title)’에 저장했어요."
            } else { message = engine.lyrics.localLyricsError ?? "저장을 완료하지 못했어요. 다시 시도해 주세요." }
            isSaving = false
        }
    }

    private func exportLRC() {
        guard let draft else { return }
        let contents: String
        do { contents = try draft.lrc() }
        catch { message = error.localizedDescription; return }
        self.draft?.disarm()
        let panel = NSSavePanel()
        panel.title = "맞춘 가사 내보내기"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText]
        panel.nameFieldStringValue = "CoNo-lyrics.lrc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contents.utf8).write(to: url, options: .atomic); message = "LRC 파일을 내보냈어요." }
        catch { message = "가사 파일을 저장하지 못했어요: \(error.localizedDescription)" }
    }

    private func preparePublish() {
        guard let draft else { return }
        do {
            publishLRC = try draft.lrc()
            self.draft?.disarm()
            showPublish = true
        } catch { message = error.localizedDescription }
    }

    private var hasUnsavedChanges: Bool {
        if let draft, !draft.timestamps.isEmpty {
            return draft.timestamps != savedTimestamps
        }
        return text != initialText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestClose() {
        draft?.disarm()
        if hasUnsavedChanges { confirmation = .close } else { dismiss() }
    }
}
