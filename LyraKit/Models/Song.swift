import Foundation

public struct Song: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { trackToken }
    public let trackToken: String
    public let songName: String
    public let artistName: String
    public let albumName: String
    public var albumArtUrl: URL?
    public var songDetailUrl: URL?
    public var artistDetailUrl: URL?
    public var albumDetailUrl: URL?
    public var stationId: String?
    /// Filled in by `PandoraClient.playlist(for:)`; feedback calls need it.
    public var stationToken: String?
    /// 1 = liked, -1 = disliked (local only), 0 = unrated.
    public var songRating: Int
    public var trackGain: String?
    public var audioStreams: [Quality: AudioStream]

    /// Keys of `audioUrlMap`, matching Hermes's audio-quality preference.
    public enum Quality: String, Sendable, CaseIterable, Hashable {
        case low = "lowQuality"
        case medium = "mediumQuality"
        case high = "highQuality"

        public var title: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    /// One way to stream the song. Pandora's URLs have no file extension, so the
    /// format is kept alongside to tell AVFoundation what it's getting.
    public struct AudioStream: Sendable, Hashable {
        public let url: URL
        public let format: AudioFormat

        public init(url: URL, format: AudioFormat) {
            self.url = url
            self.format = format
        }
    }

    public enum AudioFormat: String, Sendable, Hashable {
        /// Raw AAC+ in ADTS frames (Pandora's `aacplus`), served as `audio/aacp`.
        case aacADTS
        case mp3

        public var mimeType: String {
            switch self {
            case .aacADTS: "audio/aac"
            case .mp3: "audio/mpeg"
            }
        }
    }

    public init(trackToken: String, songName: String, artistName: String, albumName: String,
                albumArtUrl: URL? = nil, stationId: String? = nil, stationToken: String? = nil,
                songRating: Int = 0, audioStreams: [Quality: AudioStream] = [:]) {
        self.trackToken = trackToken
        self.songName = songName
        self.artistName = artistName
        self.albumName = albumName
        self.albumArtUrl = albumArtUrl
        self.stationId = stationId
        self.stationToken = stationToken
        self.songRating = songRating
        self.audioStreams = audioStreams
    }

    /// Falls back the way Hermes does: missing medium uses low, missing high uses medium,
    /// and anything still missing uses whatever exists.
    public func audioStream(for quality: Quality) -> AudioStream? {
        let low = audioStreams[.low]
        let medium = audioStreams[.medium] ?? low
        let high = audioStreams[.high] ?? medium
        let chosen = switch quality {
        case .low: low
        case .medium: medium
        case .high: high
        }
        return chosen ?? high ?? medium ?? low
    }

    public func audioURL(for quality: Quality) -> URL? {
        audioStream(for: quality)?.url
    }

    /// Streams to try in order when one fails to load: the preferred quality, then any MP3
    /// (the most widely decodable), then everything else from best to worst, without repeats.
    public func audioCandidates(preferring quality: Quality) -> [AudioStream] {
        let byQuality = [Quality.high, .medium, .low].compactMap { audioStreams[$0] }
        let ordered = [audioStream(for: quality)].compactMap { $0 }
            + byQuality.filter { $0.format == .mp3 }
            + byQuality
        var seen = Set<URL>()
        return ordered.filter { seen.insert($0.url).inserted }
    }

    public var isLiked: Bool { songRating > 0 }
    public var isDisliked: Bool { songRating < 0 }

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey {
        case trackToken, songName, artistName, albumName, albumArtUrl, songDetailUrl
        case artistDetailUrl, albumDetailUrl, stationId, songRating, trackGain
        case audioUrlMap, additionalAudioUrl
    }

    private struct AudioURLInfo: Decodable {
        let audioUrl: String
        let bitrate: String?
        let encoding: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackToken = try c.decode(String.self, forKey: .trackToken)
        songName = try c.decode(String.self, forKey: .songName)
        artistName = try c.decode(String.self, forKey: .artistName)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName) ?? ""
        albumArtUrl = c.lenientURL(.albumArtUrl)
        songDetailUrl = c.lenientURL(.songDetailUrl)
        artistDetailUrl = c.lenientURL(.artistDetailUrl)
        albumDetailUrl = c.lenientURL(.albumDetailUrl)
        stationId = try c.decodeIfPresent(String.self, forKey: .stationId)
        songRating = (try? c.decodeIfPresent(Int.self, forKey: .songRating)) ?? 0
        trackGain = try? c.decodeIfPresent(String.self, forKey: .trackGain)

        // `additionalAudioUrl` is requested as 32k AAC+, 64k AAC+, 128k MP3 (see
        // PandoraClient.playlist); `audioUrlMap` overrides it when it offers a better bitrate.
        // Audio URLs keep their scheme: the audio-*.pandora.com hosts don't serve HTTPS, so
        // they load over HTTP via NSAllowsArbitraryLoadsForMedia in Lyra-Info.plist.
        var streams: [Quality: AudioStream] = [:]
        let additional = (try? c.decodeIfPresent([String].self, forKey: .additionalAudioUrl))
            ?? (try? c.decodeIfPresent(String.self, forKey: .additionalAudioUrl)).flatMap { $0.map { [$0] } }
            ?? []
        let requestedFormats: [(Quality, AudioFormat)] = [(.low, .aacADTS), (.medium, .aacADTS), (.high, .mp3)]
        for ((quality, format), string) in zip(requestedFormats, additional) {
            if let url = URL(string: string) { streams[quality] = AudioStream(url: url, format: format) }
        }
        let map = (try? c.decodeIfPresent([String: AudioURLInfo].self, forKey: .audioUrlMap)) ?? [:]
        let thresholds: [Quality: Int] = [.high: 128, .medium: 64, .low: 32]
        for quality in Quality.allCases {
            guard let info = map[quality.rawValue], let url = URL(string: info.audioUrl) else { continue }
            if streams[quality] == nil || Int(info.bitrate ?? "") ?? 0 > thresholds[quality]! {
                let format: AudioFormat = info.encoding?.lowercased().contains("mp3") == true ? .mp3 : .aacADTS
                streams[quality] = AudioStream(url: url, format: format)
            }
        }
        audioStreams = streams
    }
}

extension KeyedDecodingContainer {
    /// Pandora sends `""` for missing URLs, which `URL`'s own decoder rejects.
    func lenientURL(_ key: Key) -> URL? {
        guard let string = try? decodeIfPresent(String.self, forKey: key), !string.isEmpty else { return nil }
        return URL(secureString: string)
    }
}

extension URL {
    /// Pandora still returns `http://` URLs for album art and detail pages. Those hosts
    /// serve the same paths over HTTPS, so upgrade them rather than weakening App Transport
    /// Security (Hermes set `NSAllowsArbitraryLoads`). Not for audio: see `Song.init(from:)`.
    init?(secureString string: String) {
        guard var components = URLComponents(string: string) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        guard let url = components.url else { return nil }
        self = url
    }
}
