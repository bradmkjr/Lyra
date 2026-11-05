import LyraKit
import SwiftUI

/// Search field + results list for picking a song or artist `musicToken`.
struct MusicSearchView: View {
    @Environment(AppModel.self) private var model
    let actionTitle: String
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Artist or song", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            row(artist.artistName, token: artist.musicToken)
                        }
                    }
                }
                if !results.songs.isEmpty {
                    Section("Songs") {
                        ForEach(results.songs) { song in
                            row("\(song.songName) — \(song.artistName)", token: song.musicToken)
                        }
                    }
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if !query.isEmpty && results.artists.isEmpty && results.songs.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .task(id: query) {
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = !query.isEmpty
            let found = await model.attempt { try await model.client.search(query) } ?? SearchResults()
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }

    private func row(_ title: String, token: String) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            Button(actionTitle) { onPick(token) }
                .controlSize(.small)
        }
    }
}
