import AVFoundation
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
    static let notifyNewSong = "notifyOnNewSong"
    static let notifyResume = "notifyOnResume"
    static let outputDeviceUIDs = "outputDeviceUIDs"
    static let airPlayRooms = "airPlayRooms"
    static let selectedAirPlayRooms = "selectedAirPlayRooms"
}

/// A receiver's saved settings and live state.
struct AirPlayRoomSettings: Codable, Equatable {
    var volume: Double = 0.7
    /// Seconds later (+) or earlier (−) than the other rooms.
    var delay: Double = 0
}

enum AirPlayRoomStatus: Equatable {
    case idle, connecting, playing
    case failed(String)
}

/// App-wide state: the Pandora session, the station list and the player.
@MainActor
@Observable
final class AppModel {
    /// Shared by SwiftUI and the AppleScript commands (AppleScriptSupport.swift).
    static let shared = AppModel()

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
    @ObservationIgnored private var volumeBeforeMute: Float?

    /// Local outputs (Core Audio devices) and which of them Lyra plays through together.
    /// Empty selection means the system default output.
    private(set) var outputs: [AudioOutputDevice] = []
    private(set) var selectedOutputIDs: Set<String> = []
    @ObservationIgnored private let router = OutputRouter()
    @ObservationIgnored private var outputMonitor: OutputDeviceMonitor?
    /// What the router last built, so device-list changes (including the aggregate Lyra
    /// itself creates) don't trigger a rebuild loop.
    @ObservationIgnored private var routedOutputIDs: [String]?

    /// AirPlay receivers on the network (Lyra's own sender, not macOS's single route).
    private(set) var airPlayReceivers: [AirPlayReceiver] = []
    private(set) var airPlayRooms: [String: AirPlayRoomSettings] = [:]
    private(set) var airPlayStatus: [String: AirPlayRoomStatus] = [:]
    /// The last calibration outcome per room, shown under its sliders.
    private(set) var calibrationMessage: [String: String] = [:]
    private(set) var calibratingID: String?

    /// Calibration needs a microphone: the MacBook Air has one, the Mac mini doesn't.
    var canCalibrate: Bool { AVCaptureDevice.default(for: .audio) != nil }

    /// Rooms Lyra plays to. Kept across launches; a room reconnects when it's found again.
    private(set) var selectedAirPlayIDs: Set<String> = []
    @ObservationIgnored let streamer = AirPlayStreamer()
    @ObservationIgnored private var airPlayBrowser: AirPlayBrowser?

    private init() {
        defaults.register(defaults: [
            DefaultsKey.audioQuality: Song.Quality.medium.rawValue,
            DefaultsKey.volume: 1.0,
            DefaultsKey.showInDock: true,
            DefaultsKey.autoPlay: true,
            DefaultsKey.notifyNewSong: true,
            DefaultsKey.notifyResume: false,
        ])
        client = PandoraClient()
        player = Player(client: client)
        player.volume = defaults.float(forKey: DefaultsKey.volume)
        player.quality = Song.Quality(rawValue: defaults.string(forKey: DefaultsKey.audioQuality) ?? "") ?? .medium
        stationSort = StationSort(rawValue: defaults.string(forKey: DefaultsKey.stationSort) ?? "") ?? .nameAscending

        selectedOutputIDs = Set(defaults.stringArray(forKey: DefaultsKey.outputDeviceUIDs) ?? [])
        refreshOutputs()
        outputMonitor = OutputDeviceMonitor { [weak self] in self?.refreshOutputs() }
        if let data = defaults.data(forKey: DefaultsKey.airPlayRooms),
           let rooms = try? JSONDecoder().decode([String: AirPlayRoomSettings].self, from: data) {
            airPlayRooms = rooms
        }
        selectedAirPlayIDs = Set(defaults.stringArray(forKey: DefaultsKey.selectedAirPlayRooms) ?? [])
        airPlayBrowser = AirPlayBrowser { [weak self] receivers in self?.airPlayReceiversChanged(receivers) }
        airPlayBrowser?.start()

        player.onSongStart = { [weak self] song in self?.songStarted(song) }
        player.onResume = { [weak self] song in
            guard let self, defaults.bool(forKey: DefaultsKey.notifyResume) else { return }
            Task { await NotificationService.shared.notify(song, resumed: true) }
        }
    }

    private func songStarted(_ song: Song) {
        NotificationService.shared.broadcast(song)
        if defaults.bool(forKey: DefaultsKey.notifyNewSong) {
            Task { await NotificationService.shared.notify(song) }
        }
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
        if volume > 0 { volumeBeforeMute = nil }
    }

    func mute() {
        guard player.volume > 0 else { return }
        let previous = player.volume
        setVolume(0)
        volumeBeforeMute = previous
    }

    func unmute() {
        setVolume(volumeBeforeMute ?? 1)
    }

    func setQuality(_ quality: Song.Quality) {
        player.quality = quality
        defaults.set(quality.rawValue, forKey: DefaultsKey.audioQuality)
    }

    // MARK: - Outputs

    var isUsingSystemOutput: Bool { activeOutputs.isEmpty }

    /// Selected outputs that are currently connected.
    var activeOutputs: [AudioOutputDevice] {
        outputs.filter { selectedOutputIDs.contains($0.id) }
    }

    /// Adds or removes an output. Aggregates play alone, since they can't be nested.
    func toggleOutput(_ device: AudioOutputDevice) {
        var selection = selectedOutputIDs
        if selection.contains(device.id) {
            selection.remove(device.id)
        } else if device.canJoinGroup {
            let aggregates = Set(outputs.filter { !$0.canJoinGroup }.map(\.id))
            selection.subtract(aggregates)
            selection.insert(device.id)
        } else {
            selection = [device.id]
        }
        setOutputs(selection)
    }

    func useSystemOutput() {
        setOutputs([])
    }

    private func setOutputs(_ selection: Set<String>) {
        selectedOutputIDs = selection
        defaults.set(Array(selection).sorted(), forKey: DefaultsKey.outputDeviceUIDs)
        applyOutputs()
    }

    private func refreshOutputs() {
        outputs = AudioOutputDevice.outputDevices()
        applyOutputs()
    }

    /// Points the player at the selected outputs. Disconnected outputs stay selected and
    /// rejoin when plugged back in.
    private func applyOutputs() {
        let chosen = activeOutputs
        let ids = chosen.map(\.id)
        guard ids != routedOutputIDs else { return }
        routedOutputIDs = ids
        player.outputDeviceUID = nil
        do {
            player.outputDeviceUID = try router.route(to: chosen)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - AirPlay rooms

    /// Ticks or unticks a room; ticking connects it, unticking disconnects it.
    func toggleAirPlayRoom(_ receiver: AirPlayReceiver) {
        if selectedAirPlayIDs.contains(receiver.id) {
            selectedAirPlayIDs.remove(receiver.id)
            airPlayStatus[receiver.id] = .idle
            updateAirPlayRouting()
            Task { await streamer.disconnect(receiver.id) }
        } else {
            selectedAirPlayIDs.insert(receiver.id)
            Task { await connectRoom(receiver) }
        }
        defaults.set(Array(selectedAirPlayIDs).sorted(), forKey: DefaultsKey.selectedAirPlayRooms)
    }

    private func airPlayReceiversChanged(_ receivers: [AirPlayReceiver]) {
        airPlayReceivers = receivers
        // Reconnect selected rooms as they appear on the network.
        for receiver in receivers where selectedAirPlayIDs.contains(receiver.id)
            && (airPlayStatus[receiver.id] ?? .idle) == .idle {
            Task { await connectRoom(receiver) }
        }
    }

    /// Sends Lyra's music to the AirPlay rooms while any is connected, and holds this Mac's
    /// speakers back by the AirPlay buffer so every room plays the same moment.
    private func updateAirPlayRouting() {
        let active = airPlayStatus.values.contains(.playing)
        if active {
            let input = streamer.input
            let sink: @Sendable ([Int16], UInt64) -> Void = { samples, capturedAt in
                input.push(samples, capturedAt: capturedAt)
            }
            player.setAirPlaySink(sink)
            player.setLocalDelay(AirPlayStreamer.baseLatency)
        } else {
            player.setAirPlaySink(nil)
            player.setLocalDelay(0)
        }
    }

    private func connectRoom(_ receiver: AirPlayReceiver) async {
        let settings = roomSettings(receiver.id)
        airPlayStatus[receiver.id] = .connecting
        do {
            try await streamer.connect(receiver, volume: Float(settings.volume), delay: settings.delay)
            airPlayStatus[receiver.id] = selectedAirPlayIDs.contains(receiver.id) ? .playing : .idle
            if !selectedAirPlayIDs.contains(receiver.id) { await streamer.disconnect(receiver.id) }
        } catch {
            airPlayStatus[receiver.id] = .failed(error.localizedDescription)
        }
        updateAirPlayRouting()
    }

    /// Plays chirps in one ticked room, hears them with this Mac's microphone, and sets that
    /// room's delay so it sounds exactly when Lyra's clock says. Stand in the room to run it.
    func calibrate(_ receiver: AirPlayReceiver) async {
        guard airPlayStatus[receiver.id] == .playing else {
            calibrationMessage[receiver.id] = "Tick the room and wait for it to connect first."
            return
        }
        let wasPlaying = player.isPlaying
        if wasPlaying { player.pause() }
        defer { if wasPlaying { player.resume() } }
        calibratingID = receiver.id
        defer { calibratingID = nil }
        calibrationMessage[receiver.id] = "Listening…"

        let delay = roomSettings(receiver.id).delay
        do {
            let result = try await RoomCalibration.measure(streamer: streamer, receiverID: receiver.id, delay: delay)
            let range = AirPlayStreamer.delayRange
            let corrected = min(range.upperBound, max(range.lowerBound, ((delay - result.error) * 100).rounded() / 100))
            setRoomDelay(corrected, for: receiver.id)
            calibrationMessage[receiver.id] = String(format: "Heard %+.0f ms off; delay set to %+.2f s.",
                                                     result.error * 1000, corrected)
        } catch {
            calibrationMessage[receiver.id] = error.localizedDescription
        }
    }

    func roomSettings(_ id: String) -> AirPlayRoomSettings {
        airPlayRooms[id] ?? AirPlayRoomSettings()
    }

    func setRoomVolume(_ volume: Double, for id: String) {
        updateRoom(id) { $0.volume = volume }
        Task { await streamer.setVolume(Float(volume), for: id) }
    }

    func setRoomDelay(_ delay: Double, for id: String) {
        updateRoom(id) { $0.delay = delay }
        Task { await streamer.setDelay(delay, for: id) }
    }

    private func updateRoom(_ id: String, _ change: (inout AirPlayRoomSettings) -> Void) {
        var settings = roomSettings(id)
        change(&settings)
        airPlayRooms[id] = settings
        if let data = try? JSONEncoder().encode(airPlayRooms) {
            defaults.set(data, forKey: DefaultsKey.airPlayRooms)
        }
    }

    /// Connects to one receiver, plays a 3-second tone, and disconnects. Lyra's own music
    /// pauses for the test so the tone is easy to hear, and resumes afterwards.
    func playTestTone(on receiver: AirPlayReceiver) async {
        let settings = roomSettings(receiver.id)
        let wasPlaying = player.isPlaying
        if wasPlaying { player.pause() }
        defer { if wasPlaying { player.resume() } }
        airPlayStatus[receiver.id] = .connecting
        do {
            try await streamer.connect(receiver, volume: Float(settings.volume), delay: settings.delay)
            airPlayStatus[receiver.id] = .playing
            await streamer.playTestTone(seconds: 3)
            // The receiver plays ~2 s behind; let the tone finish before hanging up.
            try? await Task.sleep(for: .seconds(3 + AirPlayStreamer.baseLatency + max(0, settings.delay) + 0.5))
            // A ticked room stays connected after its test.
            if selectedAirPlayIDs.contains(receiver.id) {
                airPlayStatus[receiver.id] = .playing
            } else {
                await streamer.disconnect(receiver.id)
                airPlayStatus[receiver.id] = .idle
            }
        } catch {
            if !selectedAirPlayIDs.contains(receiver.id) { await streamer.disconnect(receiver.id) }
            airPlayStatus[receiver.id] = .failed(error.localizedDescription)
        }
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
