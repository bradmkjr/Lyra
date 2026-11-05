import Foundation
import Testing
@testable import LyraKit

/// Exercises `PandoraClient` against a fake tuner server.
@Suite(.serialized)
struct PandoraClientTransportTests {
    let device = PandoraDevice.android
    let server = FakeTuner()

    private func makeClient() -> PandoraClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.handler = server.handle
        return PandoraClient(device: device, session: URLSession(configuration: config))
    }

    @Test func decodesSyncTime() throws {
        let hex = try PandoraCrypto.encrypt(Data("\u{1}\u{2}\u{3}\u{4}1700000000".utf8), key: device.decryptKey)
        #expect(try PandoraClient.decodeSyncTime(hex, key: device.decryptKey) == 1_700_000_000)
    }

    @Test func loginSendsPartnerThenEncryptedUserLogin() async throws {
        let client = makeClient()
        try await client.login(username: "me@example.com", password: "pw")
        #expect(await client.isAuthenticated)

        let requests = server.requests
        #expect(requests.map(\.method) == ["auth.partnerLogin", "auth.userLogin"])

        let partner = requests[0]
        #expect(partner.query["partner_id"] == nil)
        #expect(partner.body["deviceModel"] as? String == device.deviceID)
        #expect(partner.wasEncrypted == false)

        let user = requests[1]
        #expect(user.wasEncrypted)
        #expect(user.query["partner_id"] == "42")
        // `+`, `/` and `=` in tokens survive the round trip through the query string.
        #expect(user.query["auth_token"] == FakeTuner.partnerToken)
        #expect(user.body["partnerAuthToken"] as? String == FakeTuner.partnerToken)
        #expect(user.body["username"] as? String == "me@example.com")
        let syncTime = try #require(user.body["syncTime"] as? Int64)
        #expect((1_700_000_000...1_700_000_010).contains(syncTime))
    }

    @Test func authenticatedCallsSendUserTokenAndParseStations() async throws {
        let client = makeClient()
        try await client.login(username: "me", password: "pw")
        let stations = try await client.stations()

        #expect(stations.map(\.displayName) == ["Shuffle", "Radiohead Radio"])
        #expect(stations[1].dateCreated?.time == 1_600_000_000_000)
        let request = try #require(server.requests.last)
        #expect(request.query["user_id"] == "u1")
        #expect(request.query["auth_token"] == FakeTuner.userToken)
        #expect(request.body["userAuthToken"] as? String == FakeTuner.userToken)
    }

    @Test func playlistDropsAdsAndTagsStation() async throws {
        let client = makeClient()
        try await client.login(username: "me", password: "pw")
        let station = Station(stationId: "s2", stationToken: "tok2", stationName: "Radiohead Radio")
        let songs = try await client.playlist(for: station)

        #expect(songs.map(\.songName) == ["Reckoner"])
        #expect(songs[0].stationToken == "tok2")
        #expect(songs[0].audioURL(for: .medium)?.lastPathComponent == "64")
        #expect(server.requests.last?.body["stationToken"] as? String == "tok2")
    }

    @Test func apiFailuresMapToPandoraError() async throws {
        server.failLogin = true
        let client = makeClient()
        await #expect(throws: PandoraError.api(code: 1012, message: "INVALID_PASSWORD")) {
            try await client.login(username: "me", password: "wrong")
        }
        #expect(PandoraError.api(code: 1012, message: "x").errorDescription == "Invalid email or password.")
        #expect(await client.isAuthenticated == false)
    }

    @Test func expiredAuthTokenSignsInAgainAndRetries() async throws {
        let client = makeClient()
        try await client.login(username: "me", password: "pw")
        server.expireTokenOnce = true
        let stations = try await client.stations()

        #expect(stations.count == 2)
        #expect(server.requests.map(\.method).suffix(4) ==
                ["user.getStationList", "auth.partnerLogin", "auth.userLogin", "user.getStationList"])
    }

    @Test func callsBeforeLoginFail() async {
        let client = makeClient()
        await #expect(throws: PandoraError.notAuthenticated) { try await client.stations() }
    }
}

// MARK: - Fake server

final class FakeTuner: @unchecked Sendable {
    struct Request {
        let method: String
        let query: [String: String]
        let body: [String: Any]
        let wasEncrypted: Bool
    }

    static let partnerToken = "VAa+b/c=="
    static let userToken = "XYu+1/2=="

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _failLogin = false
    private var _expireTokenOnce = false
    let device = PandoraDevice.android

    var requests: [Request] { lock.withLock { _requests } }
    var failLogin: Bool {
        get { lock.withLock { _failLogin } }
        set { lock.withLock { _failLogin = newValue } }
    }
    var expireTokenOnce: Bool {
        get { lock.withLock { _expireTokenOnce } }
        set { lock.withLock { _expireTokenOnce = newValue } }
    }

    func handle(_ request: URLRequest) -> Data {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let method = query["method"] ?? ""
        let raw = request.bodyData
        var wasEncrypted = false
        var bodyData = raw
        if (try? JSONSerialization.jsonObject(with: raw)) == nil {
            bodyData = (try? PandoraCrypto.decrypt(hex: String(decoding: raw, as: UTF8.self), key: device.encryptKey)) ?? raw
            wasEncrypted = true
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        lock.withLock { _requests.append(Request(method: method, query: query, body: body, wasEncrypted: wasEncrypted)) }
        return response(for: method)
    }

    private func response(for method: String) -> Data {
        switch method {
        case "auth.partnerLogin":
            let sync = try! PandoraCrypto.encrypt(Data("abcd1700000000".utf8), key: device.decryptKey)
            return ok(#"{"partnerId":"42","partnerAuthToken":"\#(Self.partnerToken)","syncTime":"\#(sync)"}"#)
        case "auth.userLogin":
            if failLogin { return fail(1012, "INVALID_PASSWORD") }
            return ok(#"{"userId":"u1","userAuthToken":"\#(Self.userToken)","isSubscriber":false}"#)
        case "user.getStationList":
            let expire = lock.withLock {
                defer { _expireTokenOnce = false }
                return _expireTokenOnce
            }
            if expire { return fail(1001, "INVALID_AUTH_TOKEN") }
            return ok(#"""
            {"stations":[
              {"stationId":"s1","stationToken":"tok1","stationName":"QuickMix","isQuickMix":true},
              {"stationId":"s2","stationToken":"tok2","stationName":"Radiohead Radio",
               "dateCreated":{"time":1600000000000}}
            ]}
            """#)
        case "station.getPlaylist":
            return ok(#"""
            {"items":[
              {"adToken":"ad1"},
              {"trackToken":"tr1","songName":"Reckoner","artistName":"Radiohead","albumName":"In Rainbows",
               "stationId":"s2","songRating":0,
               "additionalAudioUrl":["https://a.com/32","https://a.com/64","https://a.com/128"]}
            ]}
            """#)
        default:
            return ok("{}")
        }
    }

    private func ok(_ result: String) -> Data { Data(#"{"stat":"ok","result":\#(result)}"#.utf8) }
    private func fail(_ code: Int, _ message: String) -> Data {
        Data(#"{"stat":"fail","code":\#(code),"message":"\#(message)"}"#.utf8)
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.handler?(request) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession moves `httpBody` into a stream before a URLProtocol sees it.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
