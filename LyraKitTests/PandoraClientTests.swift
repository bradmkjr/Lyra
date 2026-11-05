import XCTest
@testable import LyraKit

final class PandoraClientTests: XCTestCase {
    func testPandoraDeviceCreation() {
        // Test that the device structures are properly initialized
        XCTAssertNotNil(PandoraDevice.iPhone)
        XCTAssertNotNil(PandoraDevice.android)
        XCTAssertNotNil(PandoraDevice.desktop)
    }
    
    func testPandoraCryptoEncryptionDecryption() throws {
        let testData = "Hello, World!"
        let key = "testKey123456"
        
        // Test encryption
        let encrypted = try PandoraCrypto.encrypt(testData.data(using: .utf8)!, key: key)
        XCTAssertFalse(encrypted.isEmpty)
        
        // Test decryption
        let decrypted = try PandoraCrypto.decrypt(hex: encrypted, key: key)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), testData)
    }
    
    func testSongQualityEnum() {
        XCTAssertEqual(Song.Quality.low.rawValue, "lowQuality")
        XCTAssertEqual(Song.Quality.medium.rawValue, "mediumQuality")
        XCTAssertEqual(Song.Quality.high.rawValue, "highQuality")
        
        XCTAssertEqual(Song.Quality.allCases.count, 3)
    }
}