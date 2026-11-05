import AppKit
import LyraKit
import SwiftUI

@main
struct LyraApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Lyra", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.restoreSession() }
        }
        .defaultSize(width: 820, height: 520)
        .commands { LyraCommands(model: model) }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.player.isPlaying ? "music.note" : "pause.circle")
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [DefaultsKey.showInDock: true])
        Self.applyDockPreference()
    }

    /// Keep playing from the menu bar after the window closes, like Hermes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func applyDockPreference() {
        let showInDock = UserDefaults.standard.bool(forKey: DefaultsKey.showInDock)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

/// Menu bar commands and keyboard shortcuts from Hermes's KeyboardShortcuts.md.
struct LyraCommands: Commands {
    let model: AppModel
    @FocusedValue(\.stationSheet) private var stationSheet

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Station…") { stationSheet?.wrappedValue = .new }
                .keyboardShortcut("n")
                .disabled(!model.isSignedIn || stationSheet == nil)
            Button("Edit Station…") {
                if let station = model.selectedStation { stationSheet?.wrappedValue = .edit(station) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selectedStation?.canEdit != true || stationSheet == nil)
            Button("Reload Stations") { Task { await model.refreshStations() } }
                .keyboardShortcut("r")
                .disabled(!model.isSignedIn)
            Divider()
            Button("Sign Out") { model.signOut() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.isSignedIn)
        }

        CommandMenu("Controls") {
            PlaybackMenuItems(player: model.player, showsShortcuts: true)
        }
    }
}

/// Shared by the Controls menu and the menu bar extra.
struct PlaybackMenuItems: View {
    let player: Player
    var showsShortcuts = false

    var body: some View {
        let hasSong = player.currentSong != nil
        Button(player.isPlaying ? "Pause" : "Play") { player.playPause() }
            .disabled(player.station == nil)
        Button("Next Song") { player.next() }
            .shortcut("e", enabled: showsShortcuts)
            .disabled(player.station == nil)
        Divider()
        Button(player.currentSong?.isLiked == true ? "Remove Like" : "Like") {
            Task { await player.toggleLike() }
        }
        .shortcut("l", enabled: showsShortcuts)
        .disabled(!hasSong)
        Button("Dislike") { Task { await player.dislike() } }
            .shortcut("d", enabled: showsShortcuts)
            .disabled(!hasSong)
        Button("Tired of Song") { Task { await player.tired() } }
            .shortcut("t", enabled: showsShortcuts)
            .disabled(!hasSong)
        Divider()
        Button("Increase Volume") { player.increaseVolume() }
            .shortcut(.upArrow, enabled: showsShortcuts)
        Button("Decrease Volume") { player.decreaseVolume() }
            .shortcut(.downArrow, enabled: showsShortcuts)
    }
}

private extension View {
    @ViewBuilder
    func shortcut(_ key: KeyEquivalent, enabled: Bool) -> some View {
        if enabled { keyboardShortcut(key, modifiers: .command) } else { self }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let song = model.player.currentSong {
            Text(song.songName)
            Text("\(song.artistName) — \(song.albumName)")
            Divider()
        } else if let station = model.player.station {
            Text(station.displayName)
            Divider()
        }
        PlaybackMenuItems(player: model.player)
        if model.isSignedIn, !model.stations.isEmpty {
            Divider()
            Menu("Stations") {
                ForEach(model.sortedStations(matching: "")) { station in
                    Toggle(station.displayName, isOn: Binding(
                        get: { model.player.station?.id == station.id },
                        set: { _ in model.play(station) }
                    ))
                }
            }
        }
        Divider()
        Button("Show Lyra") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Button("Quit Lyra") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
