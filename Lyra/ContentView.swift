import LyraKit
import SwiftUI

struct ContentView: View {
    @State private var selection: Station.ID?
    private let stations: [Station] = []

    var body: some View {
        NavigationSplitView {
            List(stations, selection: $selection) { station in
                Text(station.stationName)
            }
            .overlay {
                if stations.isEmpty {
                    ContentUnavailableView("No Stations", systemImage: "radio",
                                           description: Text("Sign in to Pandora to load your stations."))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            NowPlayingView()
        }
    }
}

struct NowPlayingView: View {
    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 200, height: 200)
                .overlay { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
            Text("Nothing Playing").font(.title2)
            HStack(spacing: 24) {
                Button("Dislike", systemImage: "hand.thumbsdown") {}
                Button("Play", systemImage: "play.fill") {}
                Button("Next", systemImage: "forward.fill") {}
                Button("Like", systemImage: "hand.thumbsup") {}
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)
            .disabled(true)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
