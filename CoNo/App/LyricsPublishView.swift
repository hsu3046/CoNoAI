// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import SwiftUI

struct LyricsPublishView: View {
    let plainLyrics: String
    let syncedLyrics: String
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var duration: Double
    @State private var confirmed = false
    @State private var phase: LRCLIBPublishPhase = .preparing
    @State private var publishTask: Task<Void, Never>?
    @State private var message: String?
    @State private var succeeded = false

    init(track: TrackInfo, plainLyrics: String, syncedLyrics: String) {
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _duration = State(initialValue: track.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LRCLIB에 가사 공유").font(.title2.bold())
            Text("아래 곡 정보와 가사를 LRCLIB에 공개합니다. 다른 사람이 검색해 사용할 수 있습니다. 로컬 저장과는 별개입니다.")
                .font(.callout).foregroundStyle(.secondary)
            Text("공개할 권한이 있는 가사만 게시해 주세요. 개인 보관함에서 삭제해도 LRCLIB의 공개 사본은 삭제되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("곡 제목", text: $title)
                TextField("가수", text: $artist)
                TextField("앨범", text: $album)
                TextField("음원의 전체 길이 (초)", value: $duration, format: .number.precision(.fractionLength(0...3)))
            }.disabled(publishTask != nil || succeeded)
            ScrollView {
                Text(syncedLyrics.isEmpty ? plainLyrics : syncedLyrics).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(syncedLyrics.isEmpty ? "공개할 일반 가사" : "공개할 가사와 줄 시각")
            if syncedLyrics.isEmpty { Text("시간 정보 없는 일반 가사로 공개합니다.").font(.caption).foregroundStyle(.secondary) }
            Toggle("공개 권한과 곡 정보·가사를 확인했고 공개하겠습니다", isOn: $confirmed)
                .disabled(publishTask != nil || succeeded)
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Link("LRCLIB API 안내", destination: URL(string: "https://lrclib.net/docs")!)
                Spacer()
                if publishTask != nil {
                    ProgressView().controlSize(.small)
                    Text(phase == .sending ? "공개하는 중…" : "게시 인증 준비 중…").font(.callout)
                    Button("취소") { publishTask?.cancel() }.disabled(phase == .sending)
                } else {
                    Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                    if !succeeded {
                        Button("LRCLIB에 공개") { publish() }
                            .buttonStyle(.borderedProminent).disabled(!confirmed)
                    }
                }
            }
        }
        .padding(24).frame(width: 620, height: 640)
        .interactiveDismissDisabled(publishTask != nil)
        .onDisappear { publishTask?.cancel() }
        // A changed payload needs a new explicit confirmation of the displayed metadata.
        .onChange(of: title) { confirmed = false }
        .onChange(of: artist) { confirmed = false }
        .onChange(of: album) { confirmed = false }
        .onChange(of: duration) { confirmed = false }
    }

    private func publish() {
        let payload = LRCLIBPublishPayload(trackName: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                          artistName: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                                          albumName: album.trimmingCharacters(in: .whitespacesAndNewlines),
                                          duration: duration, plainLyrics: plainLyrics, syncedLyrics: syncedLyrics)
        do { _ = try payload.validatedData() }
        catch { message = error.localizedDescription; return }
        guard confirmed, publishTask == nil else { return }
        message = nil
        phase = .preparing
        let publisher = LRCLIBPublisher()
        publishTask = Task(priority: .utility) {
            do {
                try await publisher.publish(payload) { @MainActor next in phase = next }
                succeeded = true
                message = "LRCLIB에 공개했어요."
            } catch is CancellationError {
                message = "게시 인증 준비를 취소했어요."
            } catch { message = error.localizedDescription }
            publishTask = nil
        }
    }
}
