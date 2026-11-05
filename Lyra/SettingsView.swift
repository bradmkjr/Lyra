import LyraKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 440)
        .padding()
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let username = model.username {
                LabeledContent("Signed in as", value: username)
                Button("Sign Out") { model.signOut() }
            } else {
                Text("Not signed in. Sign in from the main window.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DefaultsKey.autoPlay) private var autoPlay = true

    var body: some View {
        Form {
            Picker("Audio quality", selection: Binding(get: { model.player.quality },
                                                       set: { model.setQuality($0) })) {
                ForEach(Song.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("High quality needs a Pandora subscription. Changes apply from the next song.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Play last station on launch", isOn: $autoPlay)
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(DefaultsKey.showInDock) private var showInDock = true

    var body: some View {
        Form {
            Toggle("Show Lyra in the Dock", isOn: $showInDock)
                .onChange(of: showInDock) { AppDelegate.applyDockPreference() }
            Text("When hidden, Lyra is available from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
