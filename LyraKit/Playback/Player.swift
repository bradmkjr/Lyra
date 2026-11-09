import AVFoundation
import Foundation
import Observation
import os

/// Plays a Pandora station: fetches playlist fragments, prefetches the next one
/// when the queue runs low, and keeps a short history (replaces Hermes's
/// `AudioStreamer` + `ASPlaylist`).
@MainActor
@Observable
public final class Player {
    public private(set) var station: Station?
    public private(set) var currentSong: Song?
    /// Most recent first, including the current song.
    public private(set) var history: [Song] = []
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// Last error worth showing to the user; the UI clears it.
    public var lastError: String?

    /// 0...1
    public var volume: Float = 1 {
        didSet { avPlayer.volume = volume }
    }
    /// Applies from the next song on.
    public var quality: Song.Quality = .medium

    /// Core Audio device to play through (see `OutputRouter`); nil is the system default.
    /// Takes effect immediately, mid-song.
    public var outputDeviceUID: String? {
        didSet { avPlayer.audioOutputDeviceUniqueID = outputDeviceUID }
    }

    public static let historyLimit = 20

    /// Where captured audio goes (the AirPlay rooms); nil stops capturing.
    public func setAirPlaySink(_ sink: (@Sendable ([Int16], UInt64) -> Void)?) {
        tap.setSink(sink)
    }

    /// Holds this Mac's own output back by `seconds`, so it plays with the AirPlay rooms.
    public func setLocalDelay(_ seconds: TimeInterval) {
        tap.setLocalDelay(seconds)
    }

    /// Called once a song's audio is ready to play (for notifications and broadcasts).
    @ObservationIgnored public var onSongStart: (@MainActor (Song) -> Void)?
    /// Called when paused playback resumes.
    @ObservationIgnored public var onResume: (@MainActor (Song) -> Void)?

    static let log = Logger(subsystem: "com.velpeo.Lyra", category: "playback")

    @ObservationIgnored private let client: PandoraClient
    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private var queue: [Song] = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var nowPlaying = NowPlayingBridge(player: self)
    @ObservationIgnored private let tap = PCMTap()
    /// Consecutive songs that failed to start; stops a skip loop when the network is down.
    @ObservationIgnored private var consecutiveFailures = 0
    /// The song being loaded; failures for any other song are stale and ignored.
    @ObservationIgnored private var pendingTrackToken: String?
    /// Streams of the pending song not tried yet.
    @ObservationIgnored private var remainingStreams: [Song.AudioStream] = []
    @ObservationIgnored private var announcedTrackToken: String?

    public init(client: PandoraClient) {
        self.client = client
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        // Never hand Pandora's stream URL to an AirPlay receiver: an Apple TV fetching it
        // itself can't decode the extension-less raw AAC and fails within a second. AirPlay
        // rooms are reached as Core Audio outputs instead (see OutputRouter), so this Mac
        // decodes and the receiver gets plain audio.
        avPlayer.allowsExternalPlayback = false

        // KVO can fire on any thread; @Sendable keeps these handlers from being main-actor
        // isolated (Swift 6 traps if an isolated closure runs elsewhere). They hop back via Task.
        statusObservation = avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.syncPlaybackState() }
        }
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTime() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let finished = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let current = self.avPlayer.currentItem,
                      finished == ObjectIdentifier(current) else { return }
                self.next()
            }
        }
        nowPlaying.registerCommands()
    }

    // MARK: - Transport

    /// Starts `station`, or resumes it if it is already loaded.
    public func play(station: Station) {
        if station.id == self.station?.id, currentSong != nil {
            resume()
            return
        }
        stopPlayback()
        self.station = station
        queue = []
        fetchTask?.cancel()
        fetchTask = nil
        Task { await advance() }
    }

    public func resume() {
        guard let song = currentSong else {
            if station != nil { Task { await advance() } }
            return
        }
        let wasPaused = avPlayer.timeControlStatus == .paused
        avPlayer.play()
        if wasPaused { onResume?(song) }
    }

    public func pause() {
        avPlayer.pause()
    }

    public func playPause() {
        isPlaying ? pause() : resume()
    }

    public func next() {
        Task { await advance() }
    }

    /// Stops playback and forgets the station (sign-out).
    public func stop() {
        stopPlayback()
        station = nil
        queue = []
        history = []
        fetchTask?.cancel()
        fetchTask = nil
    }

    public func increaseVolume() { volume = min(1, volume + 0.1) }
    public func decreaseVolume() { volume = max(0, volume - 0.1) }

    // MARK: - Feedback

    /// Likes `song` (the current song by default), or removes the like if already liked.
    public func toggleLike(_ song: Song? = nil) async {
        guard let song = song ?? currentSong else { return }
        if song.isLiked {
            await perform { try await self.client.removeRating(song) }
            setRating(0, for: song)
        } else {
            await perform { try await self.client.rate(song, liked: true) }
            setRating(1, for: song)
        }
    }

    /// Dislikes `song`; if it's playing, skips it.
    public func dislike(_ song: Song? = nil) async {
        guard let song = song ?? currentSong else { return }
        if song.trackToken == currentSong?.trackToken { next() }
        await perform { try await self.client.rate(song, liked: false) }
        setRating(-1, for: song)
    }

    /// Tells Pandora not to play this song for a month, and skips it.
    public func tired() async {
        guard let song = currentSong else { return }
        next()
        await perform { try await self.client.sleep(song) }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func setRating(_ rating: Int, for song: Song) {
        if currentSong?.trackToken == song.trackToken {
            currentSong?.songRating = rating
            nowPlaying.update()
        }
        for index in history.indices where history[index].trackToken == song.trackToken {
            history[index].songRating = rating
        }
    }

    // MARK: - Queue

    private func advance() async {
        if queue.isEmpty { await refill() }
        guard let song = queue.first else {
            stopPlayback()
            return
        }
        queue.removeFirst()
        start(song)
        if queue.count < 2 {
            Task { await refill() }
        }
    }

    /// Fetches the next playlist fragment; concurrent callers share one request.
    private func refill() async {
        if let fetchTask {
            await fetchTask.value
            return
        }
        guard let station else { return }
        let task = Task {
            do {
                let songs = try await client.playlist(for: station)
                guard self.station?.id == station.id else { return }
                queue += songs
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
            }
        }
        fetchTask = task
        await task.value
        if fetchTask == task { fetchTask = nil }
    }

    private func start(_ song: Song) {
        currentSong = song
        elapsed = 0
        duration = 0
        history.removeAll { $0.trackToken == song.trackToken }
        history.insert(song, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        pendingTrackToken = song.trackToken
        remainingStreams = song.audioCandidates(preferring: quality)
        nowPlaying.update()
        loadNextStream(for: song, lastError: "No audio URL")
    }

    /// Tries the song's next stream; once all have failed, gives up on the song.
    private func loadNextStream(for song: Song, lastError: String) {
        guard pendingTrackToken == song.trackToken else { return }
        guard !remainingStreams.isEmpty else {
            failed(song, reason: lastError)
            return
        }
        let stream = remainingStreams.removeFirst()
        Self.log.info("Loading \(song.songName, privacy: .public) as \(stream.format.rawValue, privacy: .public) from \(stream.url.host() ?? "?", privacy: .public)")

        // Pandora's URLs have no extension; tell AVFoundation what format to expect.
        let asset = AVURLAsset(url: stream.url, options: [AVURLAssetOverrideMIMETypeKey: stream.format.mimeType])
        let item = AVPlayerItem(asset: asset)
        tap.attach(to: item)
        itemObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            let status = item.status
            let reason = item.errorLog()?.events.last?.errorComment
                ?? item.error?.localizedDescription
                ?? "Unknown error"
            Task { @MainActor in
                self?.itemStatusChanged(status, reason: reason, stream: stream, song: song)
            }
        }
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.volume = volume
        avPlayer.play()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, reason: String,
                                   stream: Song.AudioStream, song: Song) {
        guard pendingTrackToken == song.trackToken else { return }
        switch status {
        case .readyToPlay:
            consecutiveFailures = 0
            if announcedTrackToken != song.trackToken {
                announcedTrackToken = song.trackToken
                onSongStart?(song)
            }
        case .failed:
            Self.log.error("Stream failed (\(stream.format.rawValue, privacy: .public), \(stream.url.host() ?? "?", privacy: .public)): \(reason, privacy: .public)")
            loadNextStream(for: song, lastError: reason)
        default:
            break
        }
    }

    /// No stream of `song` would play. Pandora stream URLs expire after a while, so
    /// drop the queued fragment and fetch a fresh one.
    private func failed(_ song: Song, reason: String) {
        guard pendingTrackToken == song.trackToken else { return }
        pendingTrackToken = nil
        history.removeAll { $0.trackToken == song.trackToken }
        consecutiveFailures += 1
        Self.log.error("Skipping \(song.songName, privacy: .public): \(reason, privacy: .public)")
        queue = []
        if consecutiveFailures >= 3 {
            consecutiveFailures = 0
            lastError = "Couldn't play audio from Pandora: \(reason)"
            stopPlayback()
            return
        }
        next()
    }

    private func stopPlayback() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        itemObservation = nil
        pendingTrackToken = nil
        remainingStreams = []
        currentSong = nil
        elapsed = 0
        duration = 0
        nowPlaying.update()
    }

    // MARK: - AVPlayer sync

    private func syncPlaybackState() {
        isPlaying = avPlayer.timeControlStatus == .playing
        isBuffering = avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
        nowPlaying.update()
    }

    private func syncTime() {
        let seconds = avPlayer.currentTime().seconds
        elapsed = seconds.isFinite ? seconds : 0
        if let itemDuration = avPlayer.currentItem?.duration.seconds, itemDuration.isFinite {
            if duration != itemDuration {
                duration = itemDuration
                nowPlaying.update()
            }
        }
    }
}
