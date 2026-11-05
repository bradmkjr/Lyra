import Foundation

/// `station.getStation` with `includeExtendedAttributes`: seeds and feedback.
public struct StationDetail: Sendable, Hashable, Decodable {
    public let stationToken: String
    public let stationName: String
    public var music: Music?
    public var feedback: FeedbackLists?
    public var stationDetailUrl: URL?

    public struct Music: Sendable, Hashable, Decodable {
        public var songs: [Seed]?
        public var artists: [Seed]?
        public var genres: [Seed]?
    }

    public struct FeedbackLists: Sendable, Hashable, Decodable {
        public var thumbsUp: [Feedback]?
        public var thumbsDown: [Feedback]?
    }

    public var seeds: [Seed] { (music?.artists ?? []) + (music?.songs ?? []) + (music?.genres ?? []) }
    public var likes: [Feedback] { feedback?.thumbsUp ?? [] }
    public var dislikes: [Feedback] { feedback?.thumbsDown ?? [] }

    private enum CodingKeys: String, CodingKey { case stationToken, stationName, music, feedback, stationDetailUrl }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stationToken = try c.decode(String.self, forKey: .stationToken)
        stationName = try c.decode(String.self, forKey: .stationName)
        music = try c.decodeIfPresent(Music.self, forKey: .music)
        feedback = try c.decodeIfPresent(FeedbackLists.self, forKey: .feedback)
        stationDetailUrl = c.lenientURL(.stationDetailUrl)
    }
}

public struct Seed: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { seedId }
    public let seedId: String
    public var artistName: String?
    public var songName: String?
    public var genreName: String?

    public var displayName: String {
        if let songName, let artistName { return "\(songName) — \(artistName)" }
        return songName ?? artistName ?? genreName ?? "Unknown"
    }
}

public struct Feedback: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { feedbackId }
    public let feedbackId: String
    public let songName: String
    public let artistName: String
    public let isPositive: Bool
}

/// `music.search` results. Any `musicToken` can seed a new station or be added to one.
public struct SearchResults: Sendable, Hashable, Decodable {
    public var songs: [SongMatch]
    public var artists: [ArtistMatch]

    public init(songs: [SongMatch] = [], artists: [ArtistMatch] = []) {
        self.songs = songs
        self.artists = artists
    }

    public struct SongMatch: Sendable, Hashable, Identifiable, Decodable {
        public var id: String { musicToken }
        public let musicToken: String
        public let songName: String
        public let artistName: String
    }

    public struct ArtistMatch: Sendable, Hashable, Identifiable, Decodable {
        public var id: String { musicToken }
        public let musicToken: String
        public let artistName: String
    }

    private enum CodingKeys: String, CodingKey { case songs, artists }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decodeIfPresent([SongMatch].self, forKey: .songs) ?? []
        artists = try c.decodeIfPresent([ArtistMatch].self, forKey: .artists) ?? []
    }
}

public struct GenreCategory: Sendable, Hashable, Identifiable, Decodable {
    public var id: String { categoryName }
    public let categoryName: String
    public let stations: [GenreStation]

    /// A genre station's token is accepted as a `musicToken` by `station.createStation`.
    public struct GenreStation: Sendable, Hashable, Identifiable, Decodable {
        public var id: String { stationToken }
        public let stationName: String
        public let stationToken: String
    }
}
