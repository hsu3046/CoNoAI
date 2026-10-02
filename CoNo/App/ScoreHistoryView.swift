// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScoreHistoryView: View {
    let history: ScoreHistory
    @State private var query = ""
    @State private var message: String?
    @State private var deleting: Deletion?
    private struct Deletion {
        let record: ScoreRecord
        let isPending: Bool
    }
    private var filtered: [ScoreRecord] {
        history.records.filter { query.isEmpty || "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) }
    }
    private var filteredPending: [ScoreRecord] {
        history.pending.filter { query.isEmpty || "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("나의 노래 기록").font(StageTheme.rounded(26))
                    Text("저장된 기록 \(history.records.count)곡 · 최고 \(history.records.map(\.score).max().map(String.init) ?? "—")점")
                        .foregroundStyle(StageTheme.secondaryInk)
                }
                Spacer()
                Button("JSON 가져오기", systemImage: "square.and.arrow.down", action: importFile)
                Button("저장된 기록 내보내기", systemImage: "square.and.arrow.up") {
                    perform { try ScoreExport.save(history.exportData(), type: .json, name: "cono-scores.json") }
                }
            }
            Text("기록은 이 Mac에 JSON으로 저장돼요. 웹의 ‘나의 기록’으로 가져와 챌린지에 공개할 수 있어요.")
                .font(.callout).foregroundStyle(StageTheme.secondaryInk)
            TextField("곡·가수 검색", text: $query).textFieldStyle(.roundedBorder)
            if let error = history.errorMessage {
                HStack {
                    Text(error).foregroundStyle(StageTheme.pink)
                    if history.pending.isEmpty {
                        Button("다시 읽기") { history.reload() }
                    } else {
                        Button("저장 다시 시도") { history.retryPending() }
                    }
                    Button("파일 위치") { NSWorkspace.shared.selectFile(history.fileURL.path, inFileViewerRootedAtPath: "") }
                }
            }
            if !history.pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("저장되지 않은 기록 \(history.pending.count)곡").font(StageTheme.rounded(18))
                        Spacer()
                        Button("미저장 기록 모두 내보내기", systemImage: "square.and.arrow.up") {
                            perform { try ScoreExport.savePendingBatches(history.exportPendingData()) }
                        }
                    }
                    Text("이 기록은 앱을 종료하면 사라질 수 있어요. 먼저 JSON으로 내보낸 뒤 저장된 기록을 정리하거나 다시 저장해 주세요.")
                        .font(.callout)
                }
                .foregroundStyle(StageTheme.pink)
            }
            if let message { Text(message).foregroundStyle(StageTheme.pink) }
            if filtered.isEmpty && filteredPending.isEmpty {
                ContentUnavailableView(query.isEmpty ? "첫 무대를 기다리고 있어요" : "검색한 곡이 없어요", systemImage: "music.mic", description: Text("마이크 채점을 켜고 한 곡을 마치면 기록이 남아요."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredPending) { record in
                            recordCard(record, isPending: true)
                        }
                        ForEach(filtered) { record in
                            recordCard(record, isPending: false)
                        }
                    }
                }
            }
        }
        .padding(24).frame(minWidth: 780, minHeight: 550)
        .background(StageTheme.night).foregroundStyle(StageTheme.ink)
        .onAppear { history.reload() }
        .alert("이 기록을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) {
                if let deletion = deleting {
                    if deletion.isPending { history.discardPending(id: deletion.record.id) }
                    else { perform { try history.delete(id: deletion.record.id) } }
                }
                deleting = nil
            }
        } message: {
            Text(deleting?.isPending == true ? "아직 저장되지 않은 기록입니다. JSON으로 내보내지 않았다면 복구할 수 없어요. 원본 저장 파일은 변경하지 않습니다." : "내보낸 JSON이나 이미지는 유지됩니다.")
        }
    }

    private func recordCard(_ record: ScoreRecord, isPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPending ? "미저장 · 앱 종료 전 백업 필요" : "저장 완료")
                        .font(.caption).foregroundStyle(isPending ? StageTheme.pink : StageTheme.mint)
                    Text(record.title).font(StageTheme.rounded(20))
                    Text("\(record.artist) · \(record.source == "macos" ? "Mac" : record.source == "demo" ? "데모" : "브라우저") · \(record.difficulty == "hard" ? "어려움" : "보통")")
                        .font(.caption).foregroundStyle(StageTheme.secondaryInk)
                    if let date = record.date { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(StageTheme.secondaryInk) }
                }
                Spacer()
                Text("\(record.score)점").font(StageTheme.rounded(32)).foregroundStyle(StageTheme.gold)
            }
            ScoreRecordActions(record: record)
            HStack {
                Spacer()
                Button(isPending ? "미저장 기록 삭제" : "기록 삭제", role: .destructive) {
                    deleting = Deletion(record: record, isPending: isPending)
                }.buttonStyle(.borderless)
            }
        }
        .padding(18).background(isPending ? StageTheme.pink.opacity(0.06) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); message = nil } catch { message = error.localizedDescription }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw ScoreArchiveError.tooLarge }
            try history.importData(Data(contentsOf: url))
        }
    }
}

struct ScoreRecordActions: View {
    let record: ScoreRecord
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ShareLink(item: record.shareText) { Label("점수 공유", systemImage: "square.and.arrow.up") }
                Button("이미지 저장", systemImage: "photo") { perform { try ScoreExport.image(record) } }
                Button("JSON 내보내기") { perform { try ScoreExport.save(ScoreArchive(records: [record]).encoded(), type: .json, name: "cono-\(record.id.prefix(8)).json") } }
            }
            .buttonStyle(.bordered)
            if let message { Text(message).font(.caption).foregroundStyle(StageTheme.pink) }
        }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); message = nil } catch { message = error.localizedDescription }
    }
}

@MainActor
enum ScoreExport {
    static func save(_ data: Data, type: UTType, name: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
    static func savePendingBatches(_ batches: [Data]) throws {
        guard !batches.isEmpty else { return }
        if batches.count == 1 {
            try save(batches[0], type: .json, name: "cono-unsaved-scores.json")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "내보내기"
        panel.message = "가져오기 한도에 맞춰 나눈 JSON \(batches.count)개를 새 폴더에 저장합니다."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // 기존 파일에 겹쳐 쓰지 않도록 새 폴더와 no-replace 쓰기를 함께 사용한다.
        let folder = destination.appendingPathComponent("CoNo-unsaved-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (index, data) in batches.enumerated() {
            try data.write(to: folder.appendingPathComponent("cono-unsaved-\(index + 1).json"), options: .withoutOverwriting)
        }
        NSWorkspace.shared.selectFile(folder.path, inFileViewerRootedAtPath: destination.path)
    }
    static func image(_ record: ScoreRecord) throws {
        let renderer = ImageRenderer(content: ScoreShareCard(record: record))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CoNo.ScoreExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "이미지를 만들지 못했어요."])
        }
        try save(data, type: .png, name: "cono-\(record.score)-\(record.id.prefix(8)).png")
    }
}

struct ScoreShareCard: View {
    let record: ScoreRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("CoNo · MY STAGE").font(StageTheme.rounded(30)).foregroundStyle(StageTheme.mint)
            Text("\(record.score)점").font(StageTheme.rounded(150, .heavy)).foregroundStyle(StageTheme.gold)
            Text(record.title).font(StageTheme.rounded(42)).lineLimit(1).minimumScaleFactor(0.5)
            Text("\(record.artist) · 음표 \(record.notesHit)/\(record.notesTotal) · 최고 연속 \(record.bestStreak)")
                .font(StageTheme.rounded(26, .medium)).lineLimit(1).minimumScaleFactor(0.5)
            Spacer()
            Text("\(record.source == "macos" ? "Mac" : "브라우저") · \(record.difficulty == "hard" ? "어려움" : "보통") · \(record.createdAt.prefix(10)) · AIB Inc. · www.aib.vote")
                .font(.system(size: 22)).foregroundStyle(StageTheme.secondaryInk)
        }
        .padding(64).frame(width: 1200, height: 630, alignment: .leading)
        .foregroundStyle(StageTheme.ink)
        .background(LinearGradient(colors: [StageTheme.night, StageTheme.dusk], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(Rectangle().strokeBorder(StageTheme.mint.opacity(0.5), lineWidth: 4).padding(28))
    }
}
