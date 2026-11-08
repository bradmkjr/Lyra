import AppKit
import LyraKit

// AppleScript support, ported from Hermes's AppleScript.m. The dictionary is Lyra.sdef;
// its cocoa keys resolve to the `lyra*` properties below and the command classes by name.

/// The sdef's `player states` enumeration codes.
private enum ScriptPlaybackState {
    static let stopped = fourCharCode("stop")
    static let playing = fourCharCode("play")
    static let paused = fourCharCode("paus")

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

extension NSApplication {
    private var model: AppModel { AppModel.shared }

    /// 0–100, like Hermes.
    @objc var lyraVolume: Int {
        get { Int((model.player.volume * 100).rounded()) }
        set { model.setVolume(Float(min(max(newValue, 0), 100)) / 100) }
    }

    @objc var lyraPlaybackState: UInt32 {
        get {
            let player = model.player
            if player.currentSong == nil { return ScriptPlaybackState.stopped }
            return player.isPlaying ? ScriptPlaybackState.playing : ScriptPlaybackState.paused
        }
        set {
            if newValue == ScriptPlaybackState.playing { model.player.resume() } else { model.player.pause() }
        }
    }

    @objc var lyraPlaybackPosition: Double { model.player.elapsed }
    @objc var lyraCurrentSongDuration: Double { model.player.duration }

    @objc var lyraCurrentSong: ScriptSong? {
        model.player.currentSong.map(ScriptSong.init)
    }

    @objc var lyraStations: [ScriptStation] {
        model.sortedStations(matching: "").map(ScriptStation.init)
    }

    @objc var lyraCurrentStation: ScriptStation? {
        get { model.player.station.map(ScriptStation.init) }
        set {
            if let id = newValue?.stationID, let station = model.stations.first(where: { $0.id == id }) {
                model.play(station)
            }
        }
    }
}

@objc(ScriptSong)
final class ScriptSong: NSObject {
    private let song: Song

    init(_ song: Song) {
        self.song = song
    }

    @objc var title: String { song.songName }
    @objc var artist: String { song.artistName }
    @objc var album: String { song.albumName }
    @objc var art: String? { song.albumArtUrl?.absoluteString }
    @objc var nrating: Int { song.songRating }
    @objc var albumUrl: String? { song.albumDetailUrl?.absoluteString }
    @objc var artistUrl: String? { song.artistDetailUrl?.absoluteString }
    @objc var titleUrl: String? { song.songDetailUrl?.absoluteString }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: app, containerSpecifier: nil, key: "lyraCurrentSong")
    }
}

@objc(ScriptStation)
final class ScriptStation: NSObject {
    @objc let name: String
    @objc let stationID: String

    init(_ station: Station) {
        name = station.displayName
        stationID = station.stationId
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: app, containerSpecifier: nil,
                                   key: "lyraStations", uniqueID: stationID)
    }

    /// Lets `NSUniqueIDSpecifier` find stations by id.
    @objc var uniqueID: String { stationID }
}

// MARK: - Commands

/// Base class: runs the subclass's `run(_:)` on the shared model and returns nothing to the
/// script. Apple events arrive on the main thread. `run` is a class method so only the
/// (Sendable) metatype crosses into the main-actor closure, not the command itself.
class LyraScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let command = type(of: self)
        MainActor.assumeIsolated { command.run(AppModel.shared) }
        return nil
    }

    @MainActor class func run(_ model: AppModel) {}
}

@objc(PlayCommand) final class PlayCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.player.resume() }
}

@objc(PauseCommand) final class PauseCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.player.pause() }
}

@objc(PlayPauseCommand) final class PlayPauseCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.player.playPause() }
}

@objc(SkipCommand) final class SkipCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.player.next() }
}

@objc(ThumbsUpCommand) final class ThumbsUpCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { Task { await model.player.toggleLike() } }
}

@objc(ThumbsDownCommand) final class ThumbsDownCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { Task { await model.player.dislike() } }
}

@objc(TiredCommand) final class TiredCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { Task { await model.player.tired() } }
}

@objc(RaiseVolumeCommand) final class RaiseVolumeCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.setVolume(min(1, model.player.volume + 0.1)) }
}

@objc(LowerVolumeCommand) final class LowerVolumeCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.setVolume(max(0, model.player.volume - 0.1)) }
}

@objc(FullVolumeCommand) final class FullVolumeCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.setVolume(1) }
}

@objc(MuteCommand) final class MuteCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.mute() }
}

@objc(UnmuteCommand) final class UnmuteCommand: LyraScriptCommand {
    override class func run(_ model: AppModel) { model.unmute() }
}
