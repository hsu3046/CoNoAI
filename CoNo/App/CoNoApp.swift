// CoNo — Copyright (C) 2026 KnowAI (https://knowai.space) — GPL-3.0-or-later

import SwiftUI

@main
struct CoNoApp: App {
    @State private var engine = KaraokeEngine()
    @State private var catalog = AudioSourceCatalog()

    var body: some Scene {
        Window("CoNo", id: "main") {
            ContentView(engine: engine, catalog: catalog)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
