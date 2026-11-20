import XCTest

/// Drives an already running app (launched and profiled from outside) through ten crate
/// opens and back, without relaunching it, so Instruments can stay attached.
@MainActor final class AhaProfileUITests: XCTestCase {
    func testCrateOpensOnRunningApp() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        for _ in 0..<10 {
            let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shop-work-")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 12))
            item.tap()
            let open = app.buttons["shop-note-打开"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 2.5)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
