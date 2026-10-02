// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import SwiftUI

@main
struct CoNoApp: App {
    @State private var engine = KaraokeEngine()
    @State private var catalog = AudioSourceCatalog()
    @State private var settings = AppSettings()
    @State private var privacyMigrationStarted = false
    @State private var privacyMigrationWarning: String?

    init() {
        #if DEBUG
        // 개발용: 채점 연출 프레임을 PNG 로 뽑고 끝낸다 (CONO_RENDER_CELEBRATION=<폴더>)
        CelebrationPreviewRenderer.renderIfRequested()
        #endif
    }

    var body: some Scene {
        Window("CoNo", id: "main") {
            KaraokeScreen(engine: engine, catalog: catalog, settings: settings)
                .frame(minWidth: 1040, minHeight: 600)
                .preferredColorScheme(.dark)
                .task { await migrateLyricsPrivacy() }
                .alert("이전 가사 캐시 확인", isPresented: Binding(
                    get: { privacyMigrationWarning != nil },
                    set: { if !$0 { privacyMigrationWarning = nil } }
                )) {
                    Button("확인") { privacyMigrationWarning = nil }
                } message: {
                    Text(privacyMigrationWarning ?? "")
                }
                // 종료할 때 캡처·"지금 재생 중" 백그라운드 프로세스를 정리한다
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    engine.stop()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                ScoreHistoryCommand()
                PersonalLyricsCommand()
            }
        }

        Window("나의 노래 기록", id: "score-history") {
            ScoreHistoryView(history: engine.scoreHistory).preferredColorScheme(.dark)
        }
        .defaultSize(width: 860, height: 650)

        Window("내 가사 보관함", id: "personal-lyrics") {
            PersonalLyricsLibraryView(engine: engine).preferredColorScheme(.dark)
        }
        .defaultSize(width: 920, height: 720)

        Settings {
            SettingsView(engine: engine, catalog: catalog, settings: settings)
        }
    }

    private func migrateLyricsPrivacy() async {
        guard !privacyMigrationStarted else { return }
        privacyMigrationStarted = true
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            privacyMigrationWarning = "이전 자동 가사 캐시 위치를 확인하지 못했습니다. 앱을 다시 열어 확인해 주세요."
            return
        }
        // Only derived caches are migrated. Registered personal lyrics and applied user files are excluded.
        let report = await Task.detached(priority: .utility) {
            LyricsPrivacyMigration.run(cachesRoot: caches.appendingPathComponent("space.knowai.cono", isDirectory: true),
                learnedDirectory: support.appendingPathComponent("space.knowai.cono/learned-word-timings", isDirectory: true))
        }.value
        if report.needsAttention {
            privacyMigrationWarning = "이전 자동 가사 파일 중 읽지 못한 항목 \(report.unreadablePaths)개, 정리하지 못한 항목 \(report.failedRemovals)개, 바로가기 \(report.preservedSymbolicLinks)개를 보존했습니다. 개인 보관함과 직접 적용한 가사는 정리 대상이 아닙니다."
        }
    }
}

private struct PersonalLyricsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("내 가사 보관함") { openWindow(id: "personal-lyrics") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

private struct ScoreHistoryCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("나의 노래 기록") { openWindow(id: "score-history") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}
