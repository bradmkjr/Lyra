import AppKit
import MediaPlayer

/// Publishes the current song to Control Center / the Now Playing widget and routes
/// media keys and headphone controls back to the player. Replaces Hermes's
/// `SPMediaKeyTap`, which needed an event tap and Accessibility access.
@MainActor
final class NowPlayingBridge {
    private weak var player: Player?
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(player: Player) {
        self.player = player
    }

    func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            command.isEnabled = true
            // @Sendable: MediaPlayer may call this off the main thread (see makeArtwork).
            command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in
                    if let player = self?.player { action(player) }
                }
                return .success
            }
        }
        handle(center.playCommand) { $0.resume() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.togglePlayPauseCommand) { $0.playPause() }
        handle(center.nextTrackCommand) { $0.next() }
        handle(center.likeCommand) { player in Task { await player.toggleLike() } }
        handle(center.dislikeCommand) { player in Task { await player.dislike() } }

        // Pandora allows neither going back nor seeking.
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let player, let song = player.currentSong else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.songName,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if player.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = player.duration }
        if song.albumArtUrl == artworkURL, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused

        MPRemoteCommandCenter.shared().likeCommand.isActive = song.isLiked
        loadArtwork(for: song)
    }

    private func loadArtwork(for song: Song) {
        guard let url = song.albumArtUrl, url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), !Task.isCancelled else { return }
            artwork = Self.makeArtwork(image)
            update()
        }
    }

    /// MediaPlayer calls the request handler on its own queue. A closure written inside this
    /// main-actor class would be main-actor isolated, and Swift 6 traps when it runs elsewhere,
    /// so build it in a nonisolated context.
    private nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
