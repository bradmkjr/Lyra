import LyraKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let player = model.player
        List(player.history) { song in
            HStack(spacing: 10) {
                AlbumArtView(url: song.albumArtUrl, size: 40)
                VStack(alignment: .leading) {
                    Text(song.songName).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if song.isLiked { Image(systemName: "hand.thumbsup.fill").foregroundStyle(.tint) }
                if song.isDisliked { Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.secondary) }
            }
            .contextMenu {
                Button(song.isLiked ? "Remove Like" : "Like") { Task { await player.toggleLike(song) } }
                Button("Dislike") { Task { await player.dislike(song) } }
                Divider()
                if let url = song.songDetailUrl { Button("Song on Pandora") { openURL(url) } }
                if let url = song.artistDetailUrl { Button("Artist on Pandora") { openURL(url) } }
                if let url = song.albumDetailUrl { Button("Album on Pandora") { openURL(url) } }
            }
        }
        .overlay {
            if player.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock")
            }
        }
    }
}
