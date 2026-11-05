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
    public var audioURLs: [Quality: URL]

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

    public init(trackToken: String, songName: String, artistName: String, albumName: String,
                albumArtUrl: URL? = nil, stationId: String? = nil, stationToken: String? = nil,
                songRating: Int = 0, audioURLs: [Quality: URL] = [:]) {
        self.trackToken = trackToken
        self.songName = songName
        self.artistName = artistName
        self.albumName = albumName
        self.albumArtUrl = albumArtUrl
        self.stationId = stationId
        self.stationToken = stationToken
        self.songRating = songRating
        self.audioURLs = audioURLs
    }

    /// Falls back the way Hermes does: missing medium uses low, missing high uses medium,
    /// and anything still missing uses whatever exists.
    public func audioURL(for quality: Quality) -> URL? {
        let low = audioURLs[.low]
        let medium = audioURLs[.medium] ?? low
        let high = audioURLs[.high] ?? medium
        let chosen = switch quality {
        case .low: low
        case .medium: medium
        case .high: high
        }
        return chosen ?? high ?? medium ?? low
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
        var urls: [Quality: URL] = [:]
        let additional = (try? c.decodeIfPresent([String].self, forKey: .additionalAudioUrl))
            ?? (try? c.decodeIfPresent(String.self, forKey: .additionalAudioUrl)).flatMap { $0.map { [$0] } }
            ?? []
        for (quality, string) in zip([Quality.low, .medium, .high], additional) {
            urls[quality] = URL(string: string)
        }
        let map = (try? c.decodeIfPresent([String: AudioURLInfo].self, forKey: .audioUrlMap)) ?? [:]
        let thresholds: [Quality: Int] = [.high: 128, .medium: 64, .low: 32]
        for quality in Quality.allCases {
            guard let info = map[quality.rawValue], let url = URL(string: info.audioUrl) else { continue }
            if urls[quality] == nil || Int(info.bitrate ?? "") ?? 0 > thresholds[quality]! {
                urls[quality] = url
            }
        }
        audioURLs = urls
    }
}

extension KeyedDecodingContainer {
    /// Pandora sends `""` for missing URLs, which `URL`'s own decoder rejects.
    func lenientURL(_ key: Key) -> URL? {
        guard let string = try? decodeIfPresent(String.self, forKey: key), !string.isEmpty else { return nil }
        return URL(string: string)
    }
}
