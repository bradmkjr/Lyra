import Foundation
import Testing
@testable import LyraKit

struct PandoraCryptoTests {
    // Ciphertext produced by Hermes's ImportedSources/blowfish C implementation.
    private let hermesVector = (
        plain: #"{"syncTime":1700000000}"#,
        key: PandoraDevice.iPhone.encryptKey,
        cipher: "8ed4232b70bd606d79844bbc1d27457fafb1589852be2000"
    )

    @Test func encryptMatchesHermes() throws {
        let hex = try PandoraCrypto.encrypt(Data(hermesVector.plain.utf8), key: hermesVector.key)
        #expect(hex == hermesVector.cipher)
    }

    @Test func decryptMatchesHermes() throws {
        let plain = try PandoraCrypto.decrypt(hex: hermesVector.cipher, key: hermesVector.key)
        #expect(String(decoding: plain, as: UTF8.self) == hermesVector.plain)
    }

    @Test(arguments: [PandoraDevice.iPhone, .android, .desktop])
    func roundTrip(device: PandoraDevice) throws {
        let message = Data(#"{"username":"lyra","password":"hunter2"}"#.utf8)
        // Same key for both directions so the round trip is meaningful.
        let hex = try PandoraCrypto.encrypt(message, key: device.encryptKey)
        #expect(try PandoraCrypto.decrypt(hex: hex, key: device.encryptKey) == message)
    }

    @Test func rejectsMalformedHex() {
        #expect(throws: PandoraCrypto.Error.invalidHex) {
            try PandoraCrypto.decrypt(hex: "abc", key: "k")
        }
    }
}
