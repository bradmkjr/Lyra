import Foundation

public struct Song: Sendable, Hashable, Identifiable, Codable {
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
    /// 1 = liked, 0 = unrated (Pandora never returns dislikes here).
    public var songRating: Int?
    public var trackGain: String?
    public var audioUrlMap: [String: AudioURL]?

    public struct AudioURL: Sendable, Hashable, Codable {
        public let audioUrl: URL
        public let bitrate: String?
        public let encoding: String?
    }

    /// Keys of `audioUrlMap`, matching Hermes's audio-quality preference.
    public enum Quality: String, Sendable, CaseIterable {
        case low = "lowQuality"
        case medium = "mediumQuality"
        case high = "highQuality"
    }

    public func audioURL(for quality: Quality) -> URL? {
        audioUrlMap?[quality.rawValue]?.audioUrl
            ?? Quality.allCases.reversed().lazy.compactMap { audioUrlMap?[$0.rawValue]?.audioUrl }.first
    }
}
