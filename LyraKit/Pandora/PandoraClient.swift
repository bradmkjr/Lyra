import Foundation

/// Pandora tuner API (v5) client, ported from Hermes's `Pandora.m`.
///
/// Sign-in is two steps: `auth.partnerLogin` (unencrypted, yields the partner token
/// and an encrypted server time), then `auth.userLogin`. Every later call sends
/// `userAuthToken` + `syncTime` in a Blowfish-encrypted body and the ids in the URL.
public actor PandoraClient {
    private let defaultDevice: PandoraDevice
    private var device: PandoraDevice
    private let session: URLSession

    private var partnerId: String?
    private var partnerAuthToken: String?
    private var userId: String?
    private var userAuthToken: String?
    private var syncTime: Int64 = 0
    private var syncStart = Date()
    /// Kept so an expired auth token can be renewed transparently.
    private var credentials: (username: String, password: String)?

    public private(set) var isSubscriber = false

    public init(device: PandoraDevice = .android, session: URLSession = .shared) {
        self.defaultDevice = device
        self.device = device
        self.session = session
    }

    public var isAuthenticated: Bool { userAuthToken != nil }

    // MARK: - Authentication

    public func login(username: String, password: String) async throws {
        logout()
        try await performLogin(username: username, password: password)
        credentials = (username, password)
    }

    public func logout() {
        resetSession()
        credentials = nil
        isSubscriber = false
        device = defaultDevice
    }

    private func resetSession() {
        partnerId = nil
        partnerAuthToken = nil
        userId = nil
        userAuthToken = nil
        syncTime = 0
    }

    private func performLogin(username: String, password: String) async throws {
        try await partnerLogin()

        struct UserLogin: Decodable, Sendable {
            let userId: String
            let userAuthToken: String
            let isSubscriber: Bool?
        }
        let result: UserLogin = try await send(.userLogin, body: [
            "loginType": "user",
            "username": username,
            "password": password,
            "partnerAuthToken": partnerAuthToken ?? "",
            "syncTime": currentSyncTime,
            "returnIsSubscriber": true,
        ])
        userId = result.userId
        userAuthToken = result.userAuthToken
        isSubscriber = result.isSubscriber ?? false

        // Subscribers get higher-quality streams through the desktop partner (as in Hermes).
        if isSubscriber && device != .desktop {
            device = .desktop
            resetSession()
            try await performLogin(username: username, password: password)
        }
    }

    private func partnerLogin() async throws {
        struct PartnerLogin: Decodable, Sendable {
            let partnerId: String
            let partnerAuthToken: String
            let syncTime: String
        }
        let result: PartnerLogin = try await send(.partnerLogin, body: [
            "username": device.username,
            "password": device.password,
            "deviceModel": device.deviceID,
            "version": PandoraMethod.apiVersion,
            "includeUrls": true,
        ])
        partnerId = result.partnerId
        partnerAuthToken = result.partnerAuthToken
        syncTime = try Self.decodeSyncTime(result.syncTime, key: device.decryptKey)
        syncStart = Date()
    }

    /// The partner login's `syncTime` is encrypted; after 4 junk bytes come ASCII digits.
    static func decodeSyncTime(_ hex: String, key: String) throws -> Int64 {
        let plain = try PandoraCrypto.decrypt(hex: hex, key: key)
        let digits = plain.dropFirst(4).prefix { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        guard let value = Int64(String(decoding: digits, as: UTF8.self)) else {
            throw PandoraError.invalidResponse("Undecodable syncTime")
        }
        return value
    }

    private var currentSyncTime: Int64 {
        syncTime + Int64(Date().timeIntervalSince(syncStart))
    }

    // MARK: - Stations

    public func stations() async throws -> [Station] {
        struct Result: Decodable, Sendable { let stations: [Station] }
        let result: Result = try await authenticated(.getStationList)
        return result.stations
    }

    public func playlist(for station: Station) async throws -> [Song] {
        struct Result: Decodable, Sendable { let items: [Lossy<Song>] }
        let result: Result = try await authenticated(.getPlaylist, [
            "stationToken": station.stationToken,
            "additionalAudioUrl": "HTTP_32_AACPLUS_ADTS,HTTP_64_AACPLUS_ADTS,HTTP_128_MP3",
        ])
        // Ads have no trackToken and fail to decode as songs; drop them like Hermes does.
        return result.items.compactMap(\.value).map { song in
            var song = song
            song.stationToken = station.stationToken
            return song
        }
    }

    public func createStation(musicToken: String) async throws -> Station {
        try await authenticated(.createStation, ["musicToken": musicToken])
    }

    public func renameStation(_ station: Station, to name: String) async throws {
        let _: Empty = try await authenticated(.renameStation, [
            "stationToken": station.stationToken,
            "stationName": name,
        ])
    }

    public func deleteStation(_ station: Station) async throws {
        let _: Empty = try await authenticated(.deleteStation, ["stationToken": station.stationToken])
    }

    public func stationDetail(_ station: Station) async throws -> StationDetail {
        try await stationDetail(token: station.stationToken)
    }

    private func stationDetail(token: String) async throws -> StationDetail {
        try await authenticated(.getStation, [
            "stationToken": token,
            "includeExtendedAttributes": true,
        ])
    }

    public func genreStations() async throws -> [GenreCategory] {
        struct Result: Decodable, Sendable { let categories: [GenreCategory] }
        let result: Result = try await authenticated(.getGenreStations)
        return result.categories
    }

    public func search(_ text: String) async throws -> SearchResults {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return SearchResults() }
        return try await authenticated(.search, ["searchText": text])
    }

    // MARK: - Seeds & feedback

    @discardableResult
    public func addSeed(musicToken: String, to station: Station) async throws -> Seed {
        try await authenticated(.addMusic, [
            "musicToken": musicToken,
            "stationToken": station.stationToken,
        ])
    }

    public func deleteSeed(_ seed: Seed) async throws {
        let _: Empty = try await authenticated(.deleteMusic, ["seedId": seed.seedId])
    }

    public func deleteFeedback(_ feedback: Feedback) async throws {
        let _: Empty = try await authenticated(.deleteFeedback, ["feedbackId": feedback.feedbackId])
    }

    // MARK: - Songs

    public func rate(_ song: Song, liked: Bool) async throws {
        guard let stationToken = song.stationToken else {
            throw PandoraError.invalidResponse("Song has no station")
        }
        let _: Empty = try await authenticated(.addFeedback, [
            "trackToken": song.trackToken,
            "isPositive": liked,
            "stationToken": stationToken,
        ])
    }

    /// The API has no "unrate"; find the song's feedback on its station and delete it.
    public func removeRating(_ song: Song) async throws {
        guard let stationToken = song.stationToken else { return }
        let detail = try await stationDetail(token: stationToken)
        for feedback in detail.likes + detail.dislikes
        where feedback.songName == song.songName && feedback.artistName == song.artistName {
            try await deleteFeedback(feedback)
        }
    }

    /// "Tired of this song": Pandora won't play it for a month.
    public func sleep(_ song: Song) async throws {
        let _: Empty = try await authenticated(.sleepSong, ["trackToken": song.trackToken])
    }

    // MARK: - Transport

    private func authenticated<T: Decodable & Sendable>(
        _ method: PandoraMethod, _ parameters: [String: Any] = [:]
    ) async throws -> T {
        guard userAuthToken != nil else { throw PandoraError.notAuthenticated }
        do {
            return try await send(method, body: authenticatedBody(parameters))
        } catch PandoraError.api(code: PandoraError.Code.invalidAuthToken, _) {
            // Tokens expire after a few hours; sign in again once and retry.
            guard let credentials else { throw PandoraError.notAuthenticated }
            resetSession()
            try await performLogin(username: credentials.username, password: credentials.password)
            return try await send(method, body: authenticatedBody(parameters))
        }
    }

    private func authenticatedBody(_ parameters: [String: Any]) -> [String: Any] {
        var body = parameters
        body["userAuthToken"] = userAuthToken
        body["syncTime"] = currentSyncTime
        return body
    }

    private func send<T: Decodable & Sendable>(_ method: PandoraMethod, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: url(for: method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = try JSONSerialization.data(withJSONObject: body)
        if method.isEncrypted {
            payload = Data(try PandoraCrypto.encrypt(payload, key: device.encryptKey).utf8)
        }
        request.httpBody = payload

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PandoraError.http(statusCode: http.statusCode)
        }
        return try Self.decodeResult(data)
    }

    func url(for method: PandoraMethod) -> URL {
        var query = "method=\(method.rawValue)"
        if let partnerId { query += "&partner_id=\(Self.escape(partnerId))" }
        if let token = userAuthToken ?? partnerAuthToken { query += "&auth_token=\(Self.escape(token))" }
        if let userId { query += "&user_id=\(Self.escape(userId))" }
        return URL(string: "https://\(device.apiHost)\(PandoraMethod.apiPath)?\(query)")!
    }

    /// Auth tokens contain `+`, `/` and `=`, which must be escaped in the query.
    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    static func decodeResult<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        let status: ResponseStatus
        do {
            status = try decoder.decode(ResponseStatus.self, from: data)
        } catch {
            throw PandoraError.invalidResponse(String(describing: error))
        }
        guard status.stat == "ok" else {
            throw PandoraError.api(code: status.code ?? -1, message: status.message ?? "Unknown Pandora error")
        }
        do {
            if let result = try decoder.decode(ResponseEnvelope<T>.self, from: data).result { return result }
            if let empty = Empty() as? T { return empty }
            throw PandoraError.invalidResponse("Missing result")
        } catch let error as PandoraError {
            throw error
        } catch {
            throw PandoraError.invalidResponse(String(describing: error))
        }
    }
}

private struct ResponseStatus: Decodable {
    let stat: String
    let code: Int?
    let message: String?
}

private struct ResponseEnvelope<T: Decodable>: Decodable {
    let result: T?
}

/// For calls whose result we don't use.
struct Empty: Decodable, Sendable {}

/// Decodes an element if it can, so one odd item (e.g. an ad) doesn't fail the array.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
