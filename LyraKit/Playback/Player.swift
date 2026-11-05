import AVFoundation
import Foundation
import Observation

/// A player for Pandora audio streaming using AVQueuePlayer.
@Observable
public final class Player: NSObject {
    /// The underlying AVQueuePlayer
    private var avQueuePlayer: AVQueuePlayer
    
    /// Current playback state (playing, paused, stopped)
    public var isPlaying: Bool = false
    
    /// Current playback position in seconds
    public var currentTime: CMTime = .zero
    
    /// Total duration of current track in seconds
    public var duration: CMTime = .zero
    
    /// Volume level (0.0 to 1.0)
    public var volume: Float = 1.0 {
        didSet {
            avQueuePlayer.volume = volume
        }
    }
    
    /// Audio quality preference (low/medium/high)
    public var audioQuality: AudioQuality = .high
    
    /// Current song being played
    public var currentSong: Song?
    
    /// The current playback position as a Double in seconds
    public var currentTimeSeconds: Double {
        get { CMTimeGetSeconds(currentTime) }
        set { seek(to: newValue) }
    }
    
    /// The current duration as a Double in seconds
    public var durationSeconds: Double {
        get { CMTimeGetSeconds(duration) }
        set { duration = CMTime(seconds: newValue, preferredTimescale: 1) }
    }
    
    /// Indicates if the player is currently buffering
    public var isBuffering: Bool = false
    
    /// Completion handler for when a track ends
    public var onTrackEnd: (() -> Void)?
    
    /// Completion handler for when playback starts/stops
    public var onPlaybackStateChange: ((Bool) -> Void)?
    
    // MARK: - Initialization
    
    /// Creates a new player instance.
    public override init() {
        avQueuePlayer = AVQueuePlayer()
        super.init()
        
        avQueuePlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus), options: [.new, .old], context: nil)
        avQueuePlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem), options: [.new, .old], context: nil)
        avQueuePlayer.addObserver(self, forKeyPath: #keyPath(AVPlayer.volume), options: [.new, .old], context: nil)
        
        // Handle AVPlayerItem status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    // MARK: - Public Methods
    
    /// Starts playback of a song
    public func play(song: Song) {
        // Create an AVPlayerItem with the song's audio URL
        guard let audioURL = getAudioURL(for: song) else {
            return
        }
        
        // Create new item and add it to queue if this is a new song
        if currentSong?.trackToken != song.trackToken {
            let playerItem = AVPlayerItem(url: audioURL)
            avQueuePlayer.replaceCurrentItem(with: playerItem)
            currentSong = song
        }
        
        // Ensure we start playing after replacing the item
        avQueuePlayer.play()
        isPlaying = true
        onPlaybackStateChange?(true)
    }
    
    /// Starts playback from a list of songs
    public func play(songs: [Song]) {
        let playerItems = songs.compactMap { song in
            guard let audioURL = getAudioURL(for: song) else { return nil }
            return AVPlayerItem(url: audioURL)
        }
        
        avQueuePlayer.removeAllItems()
        avQueuePlayer.insert(playerItems, after: nil)
        currentSong = songs.first
        
        if !playerItems.isEmpty {
            avQueuePlayer.play()
            isPlaying = true
            onPlaybackStateChange?(true)
        }
    }
    
    /// Pauses playback
    public func pause() {
        avQueuePlayer.pause()
        isPlaying = false
        onPlaybackStateChange?(false)
    }
    
    /// Resumes playback
    public func resume() {
        guard isPlaying == false else { return }
        
        avQueuePlayer.play()
        isPlaying = true
        onPlaybackStateChange?(true)
    }
    
    /// Stops playback
    public func stop() {
        avQueuePlayer.pause()
        avQueuePlayer.replaceCurrentItem(with: nil)
        currentSong = nil
        isPlaying = false
        onPlaybackStateChange?(false)
    }
    
    /// Skips to the next song in the queue
    public func skip() {
        avQueuePlayer.advanceToNextItem()
        
        // If there's a next item, start playing it
        if let nextItem = avQueuePlayer.items().first {
            // Update current time tracking
            updateTimeObserver()
        }
    }
    
    /// Seeks to a specific position in the current track
    public func seek(to seconds: Double) {
        let seekTime = CMTime(seconds: seconds, preferredTimescale: 1)
        avQueuePlayer.seek(to: seekTime)
    }
    
    /// Sets the audio quality preference and updates if currently playing
    public func setAudioQuality(_ quality: AudioQuality) {
        audioQuality = quality
        // If currently playing, we may need to refetch or re-initialize with new quality
    }
    
    /// Prefetches the next playlist when needed
    public func prefetchNextPlaylist(stationId: String, currentPlaylist: [Song], completion: @escaping (Result<[Song], Error>) -> Void) {
        // This would typically be implemented by fetching new songs from the Pandora API
        // and preparing them for playback before they're about to be played
        print("Prefetching next playlist (stub: not yet implemented)")
        completion(.success([]))
    }
    
    /// Gets the audio URL for a song based on quality preference
    private func getAudioURL(for song: Song) -> URL? {
        // Use our quality preference to select appropriate audio URL
        guard let audioUrlMap = song.audioUrlMap else { return nil }
        
        var selectedQuality: String?
        
        switch audioQuality {
        case .high:
            if audioUrlMap["highQuality"] != nil {
                selectedQuality = "highQuality"
            } else if audioUrlMap["mediumQuality"] != nil {
                selectedQuality = "mediumQuality"
            } else {
                selectedQuality = "lowQuality"
            }
        case .medium:
            if audioUrlMap["mediumQuality"] != nil {
                selectedQuality = "mediumQuality"
            } else {
                selectedQuality = "highQuality" // fallback
            }
        case .low:
            selectedQuality = "lowQuality"
        }
        
        return selectedQuality.flatMap { audioUrlMap[$0]?.audioUrl }
    }
    
    // MARK: - Private Methods
    
    /// Updates the time tracking and observer
    private func updateTimeObserver() {
        currentTime = avQueuePlayer.currentTime()
        duration = avQueuePlayer.currentItem?.duration ?? .zero
    }
    
    // MARK: - Observer Handling
    
    /// Handles AVPlayer value changes
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath else { return }
        
        switch keyPath {
        case #keyPath(AVPlayer.timeControlStatus):
            // Handle playback state changes
            if avQueuePlayer.timeControlStatus == .playing {
                isPlaying = true
            } else if avQueuePlayer.timeControlStatus == .paused || avQueuePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                isPlaying = false
            }
            
        case #keyPath(AVPlayer.currentItem):
            // Update current time and duration when item changes
            updateTimeObserver()
            
        case #keyPath(AVPlayer.volume):
            volume = avQueuePlayer.volume
            
        default:
            break
        }
    }
    
    /// Handles when a player item finishes playing
    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        if let playerItem = notification.object as? AVPlayerItem,
           playerItem == avQueuePlayer.currentItem {
            // Call the completion handler when track ends
            onTrackEnd?()
        }
    }
    
    /// Cleans up resources when the player is deallocated
    deinit {
        NotificationCenter.default.removeObserver(self)
        avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus))
        avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.currentItem))
        avQueuePlayer.removeObserver(self, forKeyPath: #keyPath(AVPlayer.volume))
    }
}

/// Audio quality levels
public enum AudioQuality {
    case low
    case medium
    case high
}