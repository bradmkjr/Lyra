import Foundation
import Security

/// Main client for interacting with the Pandora API.
public actor PandoraClient {
    /// Authentication state for the client.
    public struct AuthState: Sendable, Hashable {
        public var partnerId: String
        public var userId: String
        public var authToken: String
        
        public init(partnerId: String, userId: String, authToken: String) {
            self.partnerId = partnerId
            self.userId = userId
            self.authToken = authToken
        }
    }
    
    /// Current authentication state.
    private var authState: AuthState?
    
    /// Timestamp synchronization data for the client.
    private var syncTime: Int64?
    
    /// The device used to communicate with Pandora.
    private let device: PandoraDevice
    
    /// URL session for network requests.
    private let urlSession: URLSession
    
    /// Creates a new PandoraClient.
    public init(device: PandoraDevice = .iPhone) {
        self.device = device
        self.urlSession = URLSession.shared
    }
    
    /// Performs partner login with the given device credentials.
    public func partnerLogin() async throws -> AuthState {
        let params = [
            "method": "auth.partnerLogin",
            "partner_id": device.username,
            "password": device.password,
            "device_id": device.deviceID,
            "version": "5"
        ]
        
        let response = try await makeRequest(params: params)
        guard let partnerInfo = response["partnerInfo"] as? [String: Any],
              let partnerId = partnerInfo["partnerId"] as? String,
              let authToken = response["authToken"] as? String else {
            throw PandoraError.invalidResponse
        }
        
        // Parse syncTime if available
        if let time = response["syncTime"] as? Int {
            self.syncTime = Int64(time)
        }
        
        let authState = AuthState(partnerId: partnerId, userId: "", authToken: authToken)
        self.authState = authState
        
        return authState
    }
    
    /// Performs user login with username and password.
    public func userLogin(username: String, password: String) async throws -> AuthState {
        let params = [
            "method": "auth.userLogin",
            "username": username,
            "password": password,
            "auth_token": authState?.authToken ?? "",
            "partner_id": device.username
        ]
        
        let response = try await makeRequest(params: params)
        guard let userInfo = response["userInfo"] as? [String: Any],
              let userId = userInfo["userId"] as? String,
              let authToken = response["authToken"] as? String else {
            throw PandoraError.invalidResponse
        }
        
        // Parse syncTime if available
        if let time = response["syncTime"] as? Int {
            self.syncTime = Int64(time)
        }
        
        let authState = AuthState(partnerId: device.username, userId: userId, authToken: authToken)
        self.authState = authState
        
        return authState
    }
    
    /// Gets the list of stations for the current user.
    public func getStationList() async throws -> [Station] {
        guard let authState else {
            throw PandoraError.notAuthenticated
        }
        
        let params = [
            "method": "user.getStationList",
            "auth_token": authState.authToken,
            "user_id": authState.userId
        ]
        
        let response = try await makeRequest(params: params)
        guard let stations = response["stations"] as? [[String: Any]] else {
            throw PandoraError.invalidResponse
        }
        
        return try stations.map { stationData in
            guard let stationId = stationData["stationId"] as? String,
                  let stationToken = stationData["stationToken"] as? String,
                  let stationName = stationData["stationName"] as? String else {
                throw PandoraError.invalidResponse
            }
            
            var isQuickMix: Bool?
            if let quickMix = stationData["isQuickMix"] as? Bool {
                isQuickMix = quickMix
            }
            
            var dateCreated: PandoraDate?
            if let created = stationData["dateCreated"] as? Int {
                dateCreated = PandoraDate(time: Int64(created))
            }
            
            return Station(
                stationId: stationId,
                stationToken: stationToken,
                stationName: stationName
            )
        }
    }
    
    /// Gets a playlist for the given station.
    public func getPlaylist(stationId: String) async throws -> [Song] {
        guard let authState else {
            throw PandoraError.notAuthenticated
        }
        
        let params = [
            "method": "station.getPlaylist",
            "auth_token": authState.authToken,
            "user_id": authState.userId,
            "station_id": stationId
        ]
        
        let response = try await makeRequest(params: params)
        guard let songs = response["items"] as? [[String: Any]] else {
            throw PandoraError.invalidResponse
        }
        
        return try songs.map { songData in
            guard let trackToken = songData["trackToken"] as? String,
                  let songName = songData["songName"] as? String,
                  let artistName = songData["artistName"] as? String else {
                throw PandoraError.invalidResponse
            }
            
            var albumName: String?
            if let name = songData["albumName"] as? String {
                albumName = name
            }
            
            var albumArtUrl: URL?
            if let url = songData["albumArtUrl"] as? String, let urlObject = URL(string: url) {
                albumArtUrl = urlObject
            }
            
            var songDetailUrl: URL?
            if let url = songData["songDetailUrl"] as? String, let urlObject = URL(string: url) {
                songDetailUrl = urlObject
            }
            
            var artistDetailUrl: URL?
            if let url = songData["artistDetailUrl"] as? String, let urlObject = URL(string: url) {
                artistDetailUrl = urlObject
            }
            
            var albumDetailUrl: URL?
            if let url = songData["albumDetailUrl"] as? String, let urlObject = URL(string: url) {
                albumDetailUrl = urlObject
            }
            
            var songRating: Int?
            if let rating = songData["songRating"] as? Int {
                songRating = rating
            }
            
            var trackGain: String?
            if let gain = songData["trackGain"] as? String {
                trackGain = gain
            }
            
            // Handle audio URL map
            var audioUrlMap: [String: Song.AudioURL]?
            if let audioUrls = songData["audioUrlMap"] as? [[String: Any]] {
                audioUrlMap = [:]
                for urlData in audioUrls {
                    if let quality = urlData["quality"] as? String,
                       let audioUrl = urlData["audioUrl"] as? String,
                       let urlObject = URL(string: audioUrl) {
                        audioUrlMap?[quality] = Song.AudioURL(
                            audioUrl: urlObject,
                            bitrate: urlData["bitrate"] as? String,
                            encoding: urlData["encoding"] as? String
                        )
                    }
                }
            }
            
            return Song(
                trackToken: trackToken,
                songName: songName,
                artistName: artistName,
                albumName: albumName ?? "",
                albumArtUrl: albumArtUrl,
                songDetailUrl: songDetailUrl,
                artistDetailUrl: artistDetailUrl,
                albumDetailUrl: albumDetailUrl,
                stationId: songData["stationId"] as? String,
                songRating: songRating,
                trackGain: trackGain,
                audioUrlMap: audioUrlMap
            )
        }
    }
    
    /// Adds feedback for a song.
    public func addFeedback(songToken: String, rating: Int) async throws {
        guard let authState else {
            throw PandoraError.notAuthenticated
        }
        
        let params = [
            "method": "station.addFeedback",
            "auth_token": authState.authToken,
            "user_id": authState.userId,
            "song_token": songToken,
            "feedback": rating
        ]
        
        _ = try await makeRequest(params: params)
    }
    
    /// Deletes feedback for a song.
    public func deleteFeedback(songToken: String) async throws {
        guard let authState else {
            throw PandoraError.notAuthenticated
        }
        
        let params = [
            "method": "station.deleteFeedback",
            "auth_token": authState.authToken,
            "user_id": authState.userId,
            "song_token": songToken
        ]
        
        _ = try await makeRequest(params: params)
    }
    
    /// Marks a song as slept.
    public func sleepSong(songToken: String) async throws {
        guard let authState else {
            throw PandoraError.notAuthenticated
        }
        
        let params = [
            "method": "user.sleepSong",
            "auth_token": authState.authToken,
            "user_id": authState.userId,
            "song_token": songToken
        ]
        
        _ = try await makeRequest(params: params)
    }
    
    /// Makes a request to the Pandora API.
    private func makeRequest(params: [String: String]) async throws -> [String: Any] {
        // Prepare the parameters including time synchronization
        var finalParams = params
        
        if let syncTime {
            finalParams["sync_time"] = "\(syncTime)"
        }
        
        // Encrypt request body for methods that require it
        var requestBody = ""
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(finalParams)
            requestBody = String(data: jsonData, encoding: .utf8) ?? ""
            
            // Only encrypt the request-body for specific methods
            if finalParams["method"]?.hasPrefix("auth.") == true || 
               finalParams["method"]?.hasPrefix("user.") == true ||
               finalParams["method"]?.hasPrefix("station.") == true {
                let encrypted = try PandoraCrypto.encrypt(
                    Data(requestBody.utf8),
                    key: device.encryptKey
                )
                requestBody = encrypted
            }
        } catch {
            throw PandoraError.serializationFailure(error)
        }
        
        // Construct URL with device host
        guard var urlComponents = URLComponents(string: "https://\(device.apiHost)/services/json/") else {
            throw PandoraError.invalidURL
        }
        
        urlComponents.queryItems = [
            .init(name: "method", value: params["method"]),
            .init(name: "partner_id", value: params["partner_id"]),
            .init(name: "auth_token", value: params["auth_token"]),
            .init(name: "user_id", value: params["user_id"]),
            .init(name: "device_id", value: params["device_id"]),
            .init(name: "version", value: params["version"]),
        ]
        
        // Create request
        guard let url = urlComponents.url else {
            throw PandoraError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = requestBody.data(using: .utf8)
        
        // Perform the request and parse response
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PandoraError.networkFailure(
                "HTTP \(httpResponse.statusCode)"
            )
        }
        
        // Parse JSON response
        do {
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Handle error responses
                if let status = jsonObject["stat"] as? String, status == "fail" {
                    if let code = jsonObject["code"] as? Int, let message = jsonObject["message"] as? String {
                        throw PandoraError.apiFailure(code: code, message: message)
                    } else {
                        throw PandoraError.apiFailure(code: 0, message: "API error")
                    }
                }
                
                return jsonObject
            } else {
                throw PandoraError.invalidResponse
            }
        } catch {
            throw PandoraError.serializationFailure(error)
        }
    }
}
