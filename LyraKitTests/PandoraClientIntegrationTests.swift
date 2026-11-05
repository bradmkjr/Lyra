import XCTest
@testable import LyraKit

final class PandoraClientIntegrationTests: XCTestCase {
    func testPandoraClientInitialization() {
        let client = PandoraClient()
        XCTAssertNotNil(client)
    }
    
    func testPandoraDeviceStructure() {
        // Test all predefined devices have valid values
        let iPhoneDevice = PandoraDevice.iPhone
        XCTAssertEqual(iPhoneDevice.username, "iphone")
        XCTAssertEqual(iPhoneDevice.deviceID, "IP01")
        XCTAssertFalse(iPhoneDevice.encryptKey.isEmpty)
        XCTAssertFalse(iPhoneDevice.decryptKey.isEmpty)
        
        let androidDevice = PandoraDevice.android
        XCTAssertEqual(androidDevice.username, "android")
        XCTAssertEqual(androidDevice.deviceID, "android-generic")
        XCTAssertFalse(androidDevice.encryptKey.isEmpty)
        XCTAssertFalse(androidDevice.decryptKey.isEmpty)
        
        let desktopDevice = PandoraDevice.desktop
        XCTAssertEqual(desktopDevice.username, "pandora one")
        XCTAssertEqual(desktopDevice.deviceID, "D01")
        XCTAssertFalse(desktopDevice.encryptKey.isEmpty)
        XCTAssertFalse(desktopDevice.decryptKey.isEmpty)
    }
}