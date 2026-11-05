import AVFoundation
import Foundation
import Observation

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

    public static let historyLimit = 20

    @ObservationIgnored private let client: PandoraClient
    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private var queue: [Song] = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private lazy var nowPlaying = NowPlayingBridge(player: self)
    /// Consecutive songs that failed to start; stops a skip loop when the network is down.
    @ObservationIgnored private var consecutiveFailures = 0

    public init(client: PandoraClient) {
        self.client = client
        avPlayer.automaticallyWaitsToMinimizeStalling = true

        statusObservation = avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
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
        guard currentSong != nil else {
            if station != nil { Task { await advance() } }
            return
        }
        avPlayer.play()
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
        guard let url = song.audioURL(for: quality) else {
            failed(song)
            return
        }
        currentSong = song
        elapsed = 0
        duration = 0
        history.removeAll { $0.trackToken == song.trackToken }
        history.insert(song, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }

        let item = AVPlayerItem(url: url)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else {
                if item.status == .readyToPlay { Task { @MainActor in self?.consecutiveFailures = 0 } }
                return
            }
            Task { @MainActor in self?.failed(song) }
        }
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.volume = volume
        avPlayer.play()
        nowPlaying.update()
    }

    /// Pandora stream URLs expire after a while; skip songs that won't load.
    private func failed(_ song: Song) {
        guard song.trackToken == currentSong?.trackToken || currentSong == nil else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            consecutiveFailures = 0
            lastError = "Couldn't load audio from Pandora. Check your connection."
            queue = []
            stopPlayback()
            return
        }
        // Expired URLs usually mean the whole queued fragment is stale.
        queue = []
        next()
    }

    private func stopPlayback() {
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        itemObservation = nil
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
