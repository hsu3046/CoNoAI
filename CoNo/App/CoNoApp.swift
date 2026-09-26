// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import SwiftUI

@main
struct CoNoApp: App {
    @State private var engine = KaraokeEngine()
    @State private var catalog = AudioSourceCatalog()
    @State private var settings = AppSettings()

    var body: some Scene {
        Window("CoNo", id: "main") {
            KaraokeScreen(engine: engine, catalog: catalog, settings: settings)
                .frame(minWidth: 820, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView(engine: engine, catalog: catalog, settings: settings)
        }
    }
}
