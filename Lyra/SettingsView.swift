import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                Text("Pandora account settings will go here.")
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }

            Form {
                Text("Audio quality, notifications, and Last.fm settings will go here.")
            }
            .tabItem { Label("Playback", systemImage: "play.circle") }
        }
        .frame(width: 420, height: 240)
        .padding()
    }
}
