import Foundation
import Testing
@testable import LyraKit

struct SongTests {
    @Test func decodesPlaylistItemAndPicksQuality() throws {
        let json = """
        {
          "trackToken": "t1", "songName": "Song", "artistName": "Artist", "albumName": "Album",
          "songRating": 1,
          "audioUrlMap": {
            "highQuality": {"audioUrl": "https://example.com/high.mp4", "bitrate": "192", "encoding": "aacplus"},
            "lowQuality":  {"audioUrl": "https://example.com/low.mp4",  "bitrate": "32",  "encoding": "aacplus"}
          }
        }
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.audioURL(for: .low)?.lastPathComponent == "low.mp4")
        // Missing medium quality falls back to low, as in Hermes.
        #expect(song.audioURL(for: .medium)?.lastPathComponent == "low.mp4")
        #expect(song.audioURL(for: .high)?.lastPathComponent == "high.mp4")
        #expect(song.isLiked)
    }

    @Test func additionalAudioUrlFillsQualitiesAndEmptyURLsAreIgnored() throws {
        let json = """
        {
          "trackToken": "t2", "songName": "S", "artistName": "A", "albumName": "B",
          "albumArtUrl": "",
          "additionalAudioUrl": ["https://e.com/32", "https://e.com/64", "https://e.com/128"],
          "audioUrlMap": {"highQuality": {"audioUrl": "https://e.com/192", "bitrate": "192"}}
        }
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.albumArtUrl == nil)
        #expect(song.audioURL(for: .low)?.lastPathComponent == "32")
        #expect(song.audioURL(for: .medium)?.lastPathComponent == "64")
        // A higher bitrate from audioUrlMap wins.
        #expect(song.audioURL(for: .high)?.lastPathComponent == "192")
    }

    @Test func httpURLsAreUpgradedToHTTPS() throws {
        let json = """
        {
          "trackToken": "t3", "songName": "S", "artistName": "A", "albumName": "B",
          "albumArtUrl": "http://mediaserver-cont-sv7-2-v4v6.pandora.com/images/x/1080W_1080H.jpg",
          "songDetailUrl": "http://www.pandora.com/song/x",
          "additionalAudioUrl": ["http://audio.example.com/32"]
        }
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.albumArtUrl?.absoluteString ==
                "https://mediaserver-cont-sv7-2-v4v6.pandora.com/images/x/1080W_1080H.jpg")
        #expect(song.songDetailUrl?.scheme == "https")
        #expect(song.audioURL(for: .low)?.scheme == "https")
    }
}
