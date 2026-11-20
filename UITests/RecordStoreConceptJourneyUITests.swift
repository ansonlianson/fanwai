import XCTest

@MainActor final class RecordStoreConceptJourneyUITests: XCTestCase {
    func testThreeWholeStoreLayoutsWithNativeControls() throws {
        continueAfterFailure = false
        for concept in ["counter", "listening", "notes"] {
            let app = XCUIApplication()
            app.launchArguments = ["-nowState", "ready", "--ui-state=P30-"+concept,
                "--ui-isolate-data", "--ui-reset", "--ui-network=offline", "--ui-store-design="+concept]
            app.launch()
            XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.tabBars.buttons["此刻"].exists)
            XCTAssertTrue(app.otherElements["now-mini-player"].exists)
            let crate = app.otherElements["record-crate"]
            XCTAssertTrue(crate.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            capture(app, concept+"-now")
            let original = crate.frame
            app.buttons["now-graph"].tap()
            XCTAssertTrue(app.staticTexts["map-card-title"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons["此刻"].exists)
            XCTAssertTrue(app.otherElements["now-mini-player"].exists)
            capture(app, concept+"-map")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(crate.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(crate.frame.minY, original.minY, accuracy: 1)
            capture(app, concept+"-returned")
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "P30-"+name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["PIANWAI_P30_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name+".png"))
        }
    }
}
