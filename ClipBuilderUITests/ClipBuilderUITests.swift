import XCTest

final class ClipBuilderUITests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBuilderUISmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testSidebarSmoke() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ClipBuilderDataFolder", temporaryRoot.appendingPathComponent("data").path,
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] {
            app.typeKey(digit, modifierFlags: .command)
            XCTAssertEqual(app.state, .runningForeground, "App crashed after Command-\(digit)")
        }
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.exists)
    }
}
