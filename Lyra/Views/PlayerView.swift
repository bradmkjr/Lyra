import LyraKit
import SwiftUI

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var player: Player { model.player }

    var body: some View {
        if let song = player.currentSong {
            nowPlaying(song)
        } else if let station = player.station {
            ProgressView("Loading \(station.displayName)…")
        } else {
            ContentUnavailableView("Nothing Playing", systemImage: "music.note",
                                   description: Text("Double-click a station to start listening."))
        }
    }

    private func nowPlaying(_ song: Song) -> some View {
        VStack(spacing: 16) {
            AlbumArtView(url: song.albumArtUrl)
                .contextMenu { links(for: song) }

            VStack(spacing: 4) {
                Text(song.songName)
                    .font(.title2.weight(.semibold))
                Text(song.artistName)
                    .foregroundStyle(.secondary)
                Text(song.albumName)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .textSelection(.enabled)

            VStack(spacing: 4) {
                ProgressView(value: player.elapsed, total: max(player.duration, 1))
                HStack {
                    Text(formatTime(player.elapsed))
                    Spacer()
                    if player.isBuffering { ProgressView().controlSize(.mini) }
                    Spacer()
                    Text(player.duration > 0 ? "-" + formatTime(player.duration - player.elapsed) : "--:--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)

            HStack(spacing: 28) {
                Button("Dislike", systemImage: song.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                    Task { await player.dislike() }
                }
                .help("Dislike (⌘D)")
                Button(player.isPlaying ? "Pause" : "Play",
                       systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.playPause()
                }
                .font(.largeTitle)
                .help("Play/Pause (Space)")
                Button("Next", systemImage: "forward.fill") { player.next() }
                    .help("Next Song (⌘E)")
                Button("Like", systemImage: song.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    Task { await player.toggleLike() }
                }
                .foregroundStyle(song.isLiked ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .help("Like (⌘L)")
                Menu {
                    Button("Tired of Song") { Task { await player.tired() } }
                    Divider()
                    links(for: song)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                Slider(value: Binding(get: { Double(player.volume) },
                                      set: { model.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 140)
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
            .controlSize(.small)
        }
        .padding()
    }

    @ViewBuilder
    private func links(for song: Song) -> some View {
        if let url = song.songDetailUrl { Button("Song on Pandora") { openURL(url) } }
        if let url = song.artistDetailUrl { Button("Artist on Pandora") { openURL(url) } }
        if let url = song.albumDetailUrl { Button("Album on Pandora") { openURL(url) } }
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
}
