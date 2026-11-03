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
}
