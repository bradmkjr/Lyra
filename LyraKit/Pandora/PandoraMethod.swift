import Foundation

/// Tuner API (v5) methods Hermes uses, all of which Lyra needs for parity.
public enum PandoraMethod: String, Sendable, CaseIterable {
    case partnerLogin = "auth.partnerLogin"
    case userLogin = "auth.userLogin"
    case search = "music.search"
    case getStationList = "user.getStationList"
    case sleepSong = "user.sleepSong"
    case getPlaylist = "station.getPlaylist"
    case getStation = "station.getStation"
    case getGenreStations = "station.getGenreStations"
    case createStation = "station.createStation"
    case renameStation = "station.renameStation"
    case deleteStation = "station.deleteStation"
    case addFeedback = "station.addFeedback"
    case deleteFeedback = "station.deleteFeedback"
    case addMusic = "station.addMusic"
    case deleteMusic = "station.deleteMusic"

    public static let apiPath = "/services/json/"
    public static let apiVersion = "5"

    /// Every body except the partner login is Blowfish-encrypted.
    public var isEncrypted: Bool { self != .partnerLogin }
}
