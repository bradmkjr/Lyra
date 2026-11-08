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

    @Test func artUpgradesToHTTPSButAudioKeepsItsScheme() throws {
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
        // audio-*.pandora.com hosts are HTTP-only; Lyra-Info.plist allows HTTP for media.
        #expect(song.audioURL(for: .low)?.scheme == "http")
    }

    @Test func formatsComeFromRequestOrderAndEncoding() throws {
        let json = """
        {
          "trackToken": "t4", "songName": "S", "artistName": "A", "albumName": "B",
          "additionalAudioUrl": ["http://e.com/32", "http://e.com/64", "http://e.com/128"],
          "audioUrlMap": {
            "highQuality": {"audioUrl": "http://e.com/192", "bitrate": "192", "encoding": "mp3"},
            "mediumQuality": {"audioUrl": "http://e.com/map64", "bitrate": "64", "encoding": "aacplus"}
          }
        }
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        #expect(song.audioStream(for: .low)?.format == .aacADTS)
        // 64 kbps isn't better than the requested 64 kbps AAC+, so additionalAudioUrl wins.
        #expect(song.audioStream(for: .medium) == Song.AudioStream(url: URL(string: "http://e.com/64")!, format: .aacADTS))
        #expect(song.audioStream(for: .high) == Song.AudioStream(url: URL(string: "http://e.com/192")!, format: .mp3))
        #expect(Song.AudioFormat.aacADTS.mimeType == "audio/aac")
    }

    @Test func candidatesPreferChoiceThenMP3ThenRest() throws {
        let low = Song.AudioStream(url: URL(string: "http://e.com/32")!, format: .aacADTS)
        let medium = Song.AudioStream(url: URL(string: "http://e.com/64")!, format: .aacADTS)
        let high = Song.AudioStream(url: URL(string: "http://e.com/128")!, format: .mp3)
        let song = Song(trackToken: "t", songName: "S", artistName: "A", albumName: "B",
                        audioStreams: [.low: low, .medium: medium, .high: high])
        #expect(song.audioCandidates(preferring: .medium) == [medium, high, low])
        #expect(song.audioCandidates(preferring: .high) == [high, medium, low])

        // Medium missing falls back to low; low isn't repeated later in the list.
        let sparse = Song(trackToken: "t", songName: "S", artistName: "A", albumName: "B",
                          audioStreams: [.low: low])
        #expect(sparse.audioCandidates(preferring: .medium) == [low])
    }
}
