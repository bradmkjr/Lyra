import Foundation

/// Error codes returned in the `code` field of a failed tuner API response.
/// See https://6xq.net/pandora-apidoc/json/errorcodes/
public struct PandoraError: Error, Sendable, Hashable {
    public let code: Int
    public let message: String?

    public init(code: Int, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public static let invalidSyncTime = 13
    public static let invalidAuthToken = 1001
    public static let invalidPartnerLogin = 1002
    public static let invalidUsername = 1011
    public static let invalidPassword = 1012
    public static let noSeedsLeft = 1032
    
    // Additional error cases for the client implementation
    public static let notAuthenticated = PandoraError(code: -1, message: "Not authenticated")
    public static let invalidResponse = PandoraError(code: -2, message: "Invalid API response")
    public static let serializationFailure = PandoraError(code: -3, message: "Serialization failure")
    public static let invalidURL = PandoraError(code: -4, message: "Invalid URL")
    public static let networkFailure = PandoraError(code: -5, message: "Network failure")
    public static let apiFailure = PandoraError(code: -6, message: "API failure")
}
