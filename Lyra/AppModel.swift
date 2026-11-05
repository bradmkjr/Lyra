import Foundation
import LyraKit
import Observation

enum StationSort: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending, dateAscending, dateDescending
    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .dateAscending: "Date Created (Oldest First)"
        case .dateDescending: "Date Created (Newest First)"
        }
    }
}

enum DefaultsKey {
    static let audioQuality = "audioQuality"
    static let volume = "volume"
    static let lastStationId = "lastStationId"
    static let stationSort = "stationSort"
    static let showInDock = "showInDock"
    static let autoPlay = "autoPlayLastStation"
}

/// App-wide state: the Pandora session, the station list and the player.
@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case signedOut
        case signingIn
        case signedIn(username: String)
    }

    private(set) var session: SessionState = .signedOut
    private(set) var stations: [Station] = []
    private(set) var isLoadingStations = false
    var selectedStationID: Station.ID?
    var errorMessage: String?

    var stationSort: StationSort {
        didSet { defaults.set(stationSort.rawValue, forKey: DefaultsKey.stationSort) }
    }

    let client: PandoraClient
    let player: Player
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            DefaultsKey.audioQuality: Song.Quality.medium.rawValue,
            DefaultsKey.volume: 1.0,
            DefaultsKey.showInDock: true,
            DefaultsKey.autoPlay: true,
        ])
        client = PandoraClient()
        player = Player(client: client)
        player.volume = defaults.float(forKey: DefaultsKey.volume)
        player.quality = Song.Quality(rawValue: defaults.string(forKey: DefaultsKey.audioQuality) ?? "") ?? .medium
        stationSort = StationSort(rawValue: defaults.string(forKey: DefaultsKey.stationSort) ?? "") ?? .nameAscending
    }

    var isSignedIn: Bool {
        if case .signedIn = session { true } else { false }
    }

    var username: String? {
        if case .signedIn(let username) = session { username } else { nil }
    }

    var selectedStation: Station? {
        stations.first { $0.id == selectedStationID }
    }

    // MARK: - Session

    /// Signs in with saved Keychain credentials, if any.
    func restoreSession() async {
        guard session == .signedOut,
              let saved = try? KeychainService.getCredentials() else { return }
        await signIn(username: saved.username, password: saved.password, remember: false)
    }

    func signIn(username: String, password: String, remember: Bool) async {
        session = .signingIn
        do {
            try await client.login(username: username, password: password)
            if remember {
                do {
                    try KeychainService.saveCredentials(username, password: password)
                } catch {
                    errorMessage = "Signed in, but couldn't save your password: \(error.localizedDescription)"
                }
            }
            session = .signedIn(username: username)
            await refreshStations()
            if defaults.bool(forKey: DefaultsKey.autoPlay),
               let last = stations.first(where: { $0.id == defaults.string(forKey: DefaultsKey.lastStationId) }) {
                play(last)
            }
        } catch {
            session = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        player.stop()
        Task { await client.logout() }
        try? KeychainService.deleteCredentials()
        stations = []
        selectedStationID = nil
        session = .signedOut
    }

    // MARK: - Stations

    func refreshStations() async {
        isLoadingStations = true
        defer { isLoadingStations = false }
        do {
            stations = try await client.stations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shuffle stays on top, as in Hermes.
    func sortedStations(matching filter: String) -> [Station] {
        let filtered = filter.isEmpty ? stations
            : stations.filter { $0.displayName.localizedCaseInsensitiveContains(filter) }
        return filtered.sorted { a, b in
            if a.isQuickMix == true { return b.isQuickMix != true }
            if b.isQuickMix == true { return false }
            let created = { (s: Station) in s.dateCreated?.time ?? 0 }
            switch stationSort {
            case .nameAscending: return a.stationName.localizedCaseInsensitiveCompare(b.stationName) == .orderedAscending
            case .nameDescending: return a.stationName.localizedCaseInsensitiveCompare(b.stationName) == .orderedDescending
            case .dateAscending: return created(a) < created(b)
            case .dateDescending: return created(a) > created(b)
            }
        }
    }

    func play(_ station: Station) {
        selectedStationID = station.id
        defaults.set(station.id, forKey: DefaultsKey.lastStationId)
        player.play(station: station)
    }

    @discardableResult
    func createStation(musicToken: String) async -> Station? {
        do {
            let station = try await client.createStation(musicToken: musicToken)
            stations.removeAll { $0.id == station.id }
            stations.append(station)
            play(station)
            return station
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ station: Station, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != station.stationName else { return }
        do {
            try await client.renameStation(station, to: name)
            if let index = stations.firstIndex(where: { $0.id == station.id }) {
                stations[index].stationName = name
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ station: Station) async {
        do {
            try await client.deleteStation(station)
            stations.removeAll { $0.id == station.id }
            if player.station?.id == station.id { player.stop() }
            if selectedStationID == station.id { selectedStationID = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Preferences

    func setVolume(_ volume: Float) {
        player.volume = volume
        defaults.set(volume, forKey: DefaultsKey.volume)
    }

    func setQuality(_ quality: Song.Quality) {
        player.quality = quality
        defaults.set(quality.rawValue, forKey: DefaultsKey.audioQuality)
    }

    /// Runs a throwing call, reporting failure through `errorMessage`.
    @discardableResult
    func attempt<T>(_ operation: () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
