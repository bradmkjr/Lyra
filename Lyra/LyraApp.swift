import LyraKit
import SwiftUI

@main
struct LyraApp: App {
    var body: some Scene {
        Window("Lyra", id: "main") {
            ContentView()
        }
        .defaultSize(width: 720, height: 480)

        MenuBarExtra("Lyra", systemImage: "music.note") {
            Button("Play/Pause") {}
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Song") {}
            Divider()
            Button("Quit Lyra") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }

        Settings {
            SettingsView()
        }
    }
}
