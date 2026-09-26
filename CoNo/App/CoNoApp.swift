// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later

import SwiftUI

@main
struct CoNoApp: App {
    @State private var engine = KaraokeEngine()
    @State private var catalog = AudioSourceCatalog()
    @State private var settings = AppSettings()

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
                // 종료할 때 캡처·"지금 재생 중" 백그라운드 프로세스를 정리한다
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    engine.stop()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView(engine: engine, catalog: catalog, settings: settings)
        }
    }
}
