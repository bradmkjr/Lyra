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
        // Missing medium quality falls back to the best available.
        #expect(song.audioURL(for: .medium)?.lastPathComponent == "high.mp4")
    }
}
