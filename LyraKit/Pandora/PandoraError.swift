import Foundation

public enum PandoraError: Error, Sendable, Hashable {
    /// The tuner API returned `"stat": "fail"`.
    case api(code: Int, message: String)
    /// An authenticated call was made before `login`.
    case notAuthenticated
    /// The response wasn't the JSON shape we expected.
    case invalidResponse(String)
    /// The server answered with a non-2xx HTTP status.
    case http(statusCode: Int)

    /// Error codes returned in the `code` field of a failed tuner API response.
    /// See https://6xq.net/pandora-apidoc/json/errorcodes/
    public enum Code {
        public static let invalidSyncTime = 13
        public static let invalidAuthToken = 1001
        public static let invalidPartnerLogin = 1002
        public static let invalidUsername = 1011
        public static let invalidPassword = 1012
        public static let listenerNotAuthorized = 1003
        public static let playlistExceeded = 1039
        public static let noSeedsLeft = 1032
    }

    public var code: Int? {
        if case .api(let code, _) = self { code } else { nil }
    }
}

extension PandoraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(Code.invalidUsername, _), .api(Code.invalidPassword, _):
            "Invalid email or password."
        case .api(Code.invalidPartnerLogin, _):
            "Pandora rejected this client. Try again later."
        case .api(Code.playlistExceeded, _):
            "You've requested too many playlists. Try again later."
        case .api(Code.noSeedsLeft, _):
            "A station must have at least one seed."
        case .api(_, let message):
            message
        case .notAuthenticated:
            "You're not signed in to Pandora."
        case .invalidResponse:
            "Pandora sent an unexpected response."
        case .http(let status):
            "Pandora returned HTTP \(status)."
        }
    }
}
