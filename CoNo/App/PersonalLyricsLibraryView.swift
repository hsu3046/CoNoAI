// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct PersonalLyricsEditorRequest: Identifiable {
    let id = UUID()
    var document: PersonalLyricsDocument?
    var input = PersonalLyricsInput()
}

struct PersonalLyricsLibraryView: View {
    let engine: KaraokeEngine
    private let store = PersonalLyricsStore.shared
    @State private var documents: [PersonalLyricsDocument] = []
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var issues: [String] = []
    @State private var message: String?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var editor: PersonalLyricsEditorRequest?
    @State private var deletion: PersonalLyricsDocument?
    @State private var publication: PersonalLyricsDocument?
    @State private var targetTrackID: String?
    @State private var application: Application?
    @State private var tapRequest: LyricsEditorRequest?
    @State private var aiRequest: LyricsAIDraftRequest?
    @State private var loadGeneration = UUID()
    @State private var importGeneration = UUID()
    private struct Application { let document: PersonalLyricsDocument; let track: TrackInfo }

    private var filtered: [PersonalLyricsDocument] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? documents : documents.filter {
            [$0.lyrics.title, $0.lyrics.artist, $0.lyrics.album].contains { $0.localizedStandardContains(term) }
        }
    }
    private var selected: PersonalLyricsDocument? { documents.first { $0.id == selectedID } }
    private var targetTrack: TrackInfo? { engine.lyrics.availableTracksForLyrics.first { $0.id == targetTrackID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("내 가사 보관함").font(.title.bold())
                    Text("곡을 틀지 않아도 가사를 등록할 수 있어요. 이 Mac에만 저장하며 공개는 별도로 선택합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("새 가사") { editor = PersonalLyricsEditorRequest() }.buttonStyle(.borderedProminent).disabled(isWorking)
                Button("파일 가져오기…") { importFile() }.disabled(isWorking)
            }
            HSplitView {
                VStack(spacing: 10) {
                    TextField("제목·가수·앨범 검색", text: $query).textFieldStyle(.roundedBorder)
                    List(selection: $selectedID) {
                        ForEach(filtered) { document in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.lyrics.title).font(.headline).lineLimit(2)
                                Text(document.lyrics.artist.isEmpty ? "가수 미지정" : document.lyrics.artist).font(.caption).foregroundStyle(.secondary)
                                Text(document.lyrics.format.label).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4).tag(document.id)
                        }
                    }
                    if filtered.isEmpty {
                        Text(isLoading ? "불러오는 중…" : query.isEmpty ? "새 가사를 등록하거나 TXT·LRC 파일을 가져오세요." : "검색 결과가 없습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(minWidth: 230, idealWidth: 250, maxWidth: 330)
                Group {
                    if let selected { detail(selected) }
                    else { ContentUnavailableView("가사를 선택해 주세요", systemImage: "text.book.closed", description: Text("일반 가사와 시간 있는 가사를 함께 보관합니다.")) }
                }
                .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity).padding(.leading, 16)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if !issues.isEmpty {
                Text("읽지 못한 파일 \(issues.count)개를 그대로 보존했습니다. 폴더에서 확인해 주세요.")
                    .font(.caption).foregroundStyle(.orange).help(issues.joined(separator: "\n"))
            }
            HStack {
                Text("\(documents.count)개 · 이 Mac에 보관").font(.caption).foregroundStyle(.secondary)
                if isLoading || isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("새로 고침") { Task { await reload() } }.disabled(isLoading)
                Button("보관함 폴더 열기") { openFolder() }
            }
        }
        .padding(24).frame(minWidth: 840, minHeight: 660)
        .task { await reload(); targetTrackID = engine.lyrics.currentTrack?.id ?? engine.lyrics.availableTracksForLyrics.first?.id }
        .onDisappear { loadGeneration = UUID(); importGeneration = UUID(); isWorking = false }
        .sheet(item: $editor, onDismiss: { Task { await reload() } }) { request in
            PersonalLyricsEditorView(document: request.document, input: request.input) { saved in
                loadGeneration = UUID(); isLoading = false
                if let index = documents.firstIndex(where: { $0.id == saved.id }) { documents[index] = saved }
                else { documents.insert(saved, at: 0) }
                selectedID = saved.id
            }
        }
        .sheet(item: $publication) { document in
            LyricsPublishView(track: document.track, plainLyrics: document.lyrics.plainLyrics,
                              syncedLyrics: document.lyrics.format == .synced ? document.lyrics.contents : "")
        }
        .sheet(item: $tapRequest) { request in LyricsTapSyncView(engine: engine, track: request.track, initialText: request.initialText) }
        .sheet(item: $aiRequest) { request in LyricsAIDraftView(engine: engine, track: request.track, initialText: request.initialText) }
        .alert("보관함에서 삭제할까요?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("취소", role: .cancel) { deletion = nil }
            Button("삭제", role: .destructive) {
                guard let document = deletion else { return }
                deletion = nil; isWorking = true
                Task {
                    defer { isWorking = false }
                    do { try await store.remove(document); await reload(); message = "보관함에서 삭제했어요. 곡에 적용한 사본과 원본 파일은 그대로입니다." }
                    catch { message = error.localizedDescription }
                }
            }
        } message: { Text("‘\(deletion?.lyrics.title ?? "")’의 보관함 사본을 삭제합니다. 이 작업은 되돌릴 수 없습니다.") }
        .alert("선택한 곡에 적용할까요?", isPresented: Binding(get: { application != nil }, set: { if !$0 { application = nil } })) {
            Button("취소", role: .cancel) { application = nil }
            Button("적용") {
                guard let request = application else { return }
                application = nil; isWorking = true
                Task {
                    let applied = await engine.lyrics.applyPersonalLyrics(request.document, to: request.track)
                    message = applied ? "‘\(request.track.title)’에 가사를 적용했어요." : engine.lyrics.localLyricsError ?? "적용하지 못했어요. 다시 시도해 주세요."
                    isWorking = false
                }
            }
        } message: { Text("‘\(application?.document.lyrics.title ?? "")’ 가사를 ‘\(application?.track.title ?? "")’의 사용자 가사로 사용합니다. 해당 곡의 기존 사용자 사본을 바꾸며 보관함 원본은 유지합니다.") }
    }

    private func detail(_ document: PersonalLyricsDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.lyrics.title).font(.title2.bold()).textSelection(.enabled)
            Text([document.lyrics.artist, document.lyrics.album].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            HStack {
                Text(document.lyrics.format.label).font(.caption)
                if let duration = document.lyrics.duration { Text("\(duration.formatted())초").font(.caption.monospacedDigit()) }
                Spacer()
                Button("편집") { editor = PersonalLyricsEditorRequest(document: document) }.disabled(isWorking)
                Button("내보내기…") { export(document) }
                Button("삭제…", role: .destructive) { deletion = document }.disabled(isWorking)
            }
            ScrollView {
                Text(document.lyrics.plainLyrics).font(.body).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("보관한 가사 내용")
            if !engine.lyrics.availableTracksForLyrics.isEmpty {
                Picker("적용할 곡", selection: $targetTrackID) {
                    Text("곡 선택").tag(String?.none)
                    ForEach(engine.lyrics.availableTracksForLyrics, id: \.id) { track in
                        Text("\(track.title) · \(track.artist)").tag(Optional(track.id))
                    }
                }
                HStack {
                    Button("선택한 곡에 적용…") { if let targetTrack { application = Application(document: document, track: targetTrack) } }
                        .disabled(targetTrack == nil || isWorking || engine.lyrics.isChangingLocalLyrics)
                    Button("탭으로 시간 맞추기…") {
                        if let targetTrack { tapRequest = LyricsEditorRequest(track: targetTrack, initialText: document.lyrics.plainLyrics) }
                    }.disabled(targetTrack == nil)
                    Button("AI 초안으로…") {
                        if let targetTrack { aiRequest = LyricsAIDraftRequest(track: targetTrack, initialText: document.lyrics.plainLyrics) }
                    }.disabled(targetTrack == nil || !engine.lyrics.localAlignment.isEnabled || !engine.isRunning)
                }
            } else {
                Text("곡을 연결하면 해당 곡에 적용하거나 탭으로 줄 시간을 맞출 수 있어요.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("LRCLIB에 공개…") { publication = document }
                Text("공개할 곡 정보·가사를 다시 확인한 뒤 전송합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        let generation = UUID(); loadGeneration = generation; isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let listing = try await store.list()
            guard loadGeneration == generation, !Task.isCancelled else { return }
            documents = listing.documents; issues = listing.issues
            if !documents.contains(where: { $0.id == selectedID }) { selectedID = documents.first?.id }
        } catch { if loadGeneration == generation { message = error.localizedDescription } }
    }

    private func importFile() {
        guard !isWorking, editor == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "보관할 TXT·LRC 가사 가져오기"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let generation = UUID(); importGeneration = generation
        isWorking = true
        Task {
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                if importGeneration == generation { isWorking = false }
            }
            do {
                let input = try await store.importedInput(at: url)
                guard importGeneration == generation, editor == nil, !Task.isCancelled else { return }
                editor = PersonalLyricsEditorRequest(input: input); message = nil
            } catch { if importGeneration == generation { message = error.localizedDescription } }
        }
    }

    private func export(_ document: PersonalLyricsDocument) {
        let panel = NSSavePanel()
        panel.title = "가사 내보내기"
        panel.allowedContentTypes = [UTType(filenameExtension: document.lyrics.format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = "CoNo-lyrics.\(document.lyrics.format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(document.lyrics.contents.utf8).write(to: url, options: .atomic); message = "가사 원문을 내보냈어요." }
        catch { message = "파일을 내보내지 못했어요: \(error.localizedDescription)" }
    }

    private func openFolder() {
        do { try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true); NSWorkspace.shared.open(store.directoryURL) }
        catch { message = error.localizedDescription }
    }
}

private struct PersonalLyricsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PersonalLyricsEditingState
    @State private var durationText: String
    @State private var isSaving = false
    @State private var message: String?
    @State private var closeConfirmation = false
    let onSave: (PersonalLyricsDocument) -> Void
    private let store = PersonalLyricsStore.shared

    init(document: PersonalLyricsDocument?, input: PersonalLyricsInput, onSave: @escaping (PersonalLyricsDocument) -> Void) {
        let state = PersonalLyricsEditingState(document: document, input: input)
        _editing = State(initialValue: state)
        _durationText = State(initialValue: state.input.duration.map { String($0) } ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editing.saved == nil ? "새 가사 등록" : "가사 편집").font(.title2.bold())
                Spacer()
                Button("닫기") { if isDirty { closeConfirmation = true } else { dismiss() } }.keyboardShortcut(.cancelAction).disabled(isSaving)
            }
            Text("이 Mac의 개인 보관함에 저장합니다. 노래를 재생하거나 공개할 필요가 없습니다.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("곡 제목 (필수)", text: $editing.input.title)
                TextField("가수 (필수)", text: $editing.input.artist)
                TextField("앨범 (선택)", text: $editing.input.album)
                TextField("전체 곡 길이 · 초 (선택)", text: $durationText)
                Picker("가사 형식", selection: $editing.input.format) {
                    ForEach(PersonalLyricsFormat.allCases, id: \.self) { format in Text(format.label).tag(format) }
                }
            }
            Text(editing.input.format == .plain ? "일반 가사를 입력하거나 붙여넣으세요. 시각은 임의로 만들지 않습니다." : "[00:12.500]가사 형태의 LRC 원문을 입력하세요. 단어 시각도 그대로 보존합니다.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $editing.input.contents).font(editing.input.format == .synced ? .body.monospaced() : .body)
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("보관할 가사 원문")
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Text("1 MB · 4,000줄 · 줄당 500글자까지").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                if editing.saved != nil { Button("새 사본으로 저장") { save(asCopy: true) }.disabled(isSaving) }
                Button("보관함에 저장") { save(asCopy: false) }.buttonStyle(.borderedProminent).disabled(isSaving)
            }
        }
        .padding(24).frame(width: 720, height: 720)
        .interactiveDismissDisabled(isDirty || isSaving)
        .alert("저장하지 않은 변경을 버릴까요?", isPresented: $closeConfirmation) {
            Button("계속 편집", role: .cancel) {}
            Button("버리고 닫기", role: .destructive) { dismiss() }
        } message: { Text("보관함에 저장된 내용은 유지됩니다. 이 화면의 미저장 입력만 사라집니다.") }
    }

    private var isDirty: Bool {
        let baseline = (editing.saved?.lyrics.duration ?? editing.input.duration).map { String($0) } ?? ""
        return editing.isDirty || durationText != baseline
    }

    private func save(asCopy: Bool) {
        let rawDuration = durationText.trimmingCharacters(in: .whitespacesAndNewlines)
        var input = editing.input
        if rawDuration.isEmpty { input.duration = nil }
        else if let value = Double(rawDuration), value.isFinite, value > 0, value <= 86_400 { input.duration = value }
        else { message = PersonalLyricsError.invalidMetadata.localizedDescription; return }
        editing.input.duration = input.duration
        let snapshot = input
        let expected = asCopy ? nil : editing.saved
        let durationSnapshot = durationText
        isSaving = true; message = nil
        Task {
            defer { isSaving = false }
            do {
                let saved = try await store.save(snapshot, id: expected?.id, expectedRevision: expected?.revision)
                editing.didSave(saved, snapshot: snapshot)
                if durationText == durationSnapshot { durationText = saved.lyrics.duration.map { String($0) } ?? "" }
                onSave(saved)
                message = isDirty ? "저장했어요. 저장 중 새로 입력한 변경은 아직 저장되지 않았습니다." : "개인 보관함에 저장했어요. 공개되지 않습니다."
            } catch { message = error.localizedDescription }
        }
    }
}
