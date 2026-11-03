import XCTest

final class LyraUITests: XCTestCase {
    @MainActor
    func testLaunchShowsMainWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["Lyra"].waitForExistence(timeout: 5))
    }
}
