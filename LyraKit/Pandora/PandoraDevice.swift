import Foundation

/// Partner credentials Pandora issues to its own clients. The tuner API needs
/// one of these for `auth.partnerLogin` before a user can sign in.
///
/// Values come from Hermes's `PandoraDevice.m`; see
/// https://6xq.net/pandora-apidoc/json/partners/ for the list.
public struct PandoraDevice: Sendable, Hashable {
    public let username: String
    public let password: String
    public let deviceID: String
    public let encryptKey: String
    public let decryptKey: String
    public let apiHost: String

    public static let iPhone = PandoraDevice(
        username: "iphone",
        password: "P2E4FC0EAD3*878N92B2CDp34I0B1@388137C",
        deviceID: "IP01",
        encryptKey: "721^26xE22776",
        decryptKey: "20zE1E47BE57$51",
        apiHost: "tuner.pandora.com"
    )

    public static let android = PandoraDevice(
        username: "android",
        password: "AC7IBG09A3DTSYM4R41UJWL07VLN8JI7",
        deviceID: "android-generic",
        encryptKey: "6#26FRL$ZWD",
        decryptKey: "R=U!LH$O2B#",
        apiHost: "tuner.pandora.com"
    )

    /// Used by Hermes as a fallback for Pandora One subscribers when the
    /// mobile partner login is rejected.
    public static let desktop = PandoraDevice(
        username: "pandora one",
        password: "TVCKIBGS9AO9TSYLNNFUML0743LH82D",
        deviceID: "D01",
        encryptKey: "2%3WCL*JU$MP]4",
        decryptKey: "U#IO$RZPAB%VX2",
        apiHost: "internal-tuner.pandora.com"
    )
}
