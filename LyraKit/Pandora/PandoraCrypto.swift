import CommonCrypto
import Foundation

/// Blowfish-ECB as used by the Pandora tuner API: request bodies are encrypted
/// and hex-encoded, and the `syncTime` returned by `auth.partnerLogin` is
/// hex-encoded ciphertext. Input is zero-padded to the 8-byte block size.
///
/// Replaces Hermes's bundled C implementation (`ImportedSources/blowfish`).
public enum PandoraCrypto {
    public enum Error: Swift.Error, Equatable {
        case invalidHex
        case cryptorFailure(CCCryptorStatus)
    }

    /// Encrypts `data` and returns lowercase hex ciphertext.
    public static func encrypt(_ data: Data, key: String) throws -> String {
        let cipher = try blowfish(CCOperation(kCCEncrypt), data: zeroPadded(data), key: key)
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    /// Decrypts lowercase or uppercase hex ciphertext, stripping trailing zero padding.
    public static func decrypt(hex: String, key: String) throws -> Data {
        guard let cipher = Data(hexString: hex), cipher.count % kCCBlockSizeBlowfish == 0 else {
            throw Error.invalidHex
        }
        var plain = try blowfish(CCOperation(kCCDecrypt), data: cipher, key: key)
        while plain.last == 0 { plain.removeLast() }
        return plain
    }

    private static func zeroPadded(_ data: Data) -> Data {
        let remainder = data.count % kCCBlockSizeBlowfish
        guard remainder != 0 else { return data }
        return data + Data(count: kCCBlockSizeBlowfish - remainder)
    }

    private static func blowfish(_ op: CCOperation, data: Data, key: String) throws -> Data {
        let keyBytes = Array(key.utf8)
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCrypt(op, CCAlgorithm(kCCAlgorithmBlowfish), CCOptions(kCCOptionECBMode),
                        keyBytes, keyBytes.count, nil,
                        input.baseAddress, data.count,
                        out.baseAddress, data.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw Error.cryptorFailure(status) }
        return output.prefix(moved)
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
