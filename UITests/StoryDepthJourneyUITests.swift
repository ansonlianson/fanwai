import XCTest

@MainActor final class StoryDepthJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func state(_ app: XCUIApplication) -> [String: Any] {
        let raw = app.otherElements["record-crate"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }
    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: @escaping @MainActor () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    func testJaneFilmAndLargePortraitReturnAndOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "switch", "-freezeNowState", "--ui-isolate-data", "--ui-reset", "--ui-state=P24-portrait", "--ui-network=offline"]
        app.launch()
        XCTAssertTrue(app.buttons["accept-track-switch"].waitForExistence(timeout: 10))
        app.buttons["accept-track-switch"].tap()
        waitUntil { app.staticTexts["now-title"].label == "JANE DOE" }
        XCTAssertTrue(app.buttons["crate-item-film"].exists)
        XCTAssertFalse(app.buttons["story-read"].exists, "Short fallback must not promise a duplicate full story")
        capture(app, "01-jane-film-and-short-story")
        let person = app.buttons["crate-item-utada"]
        person.tap()
        waitUntil { self.state(app)["held"] as? String == "utada" }
        waitUntil { app.buttons["crate-item-utada"].frame.height > 180 }
        capture(app, "02-large-held-portrait")
        let held = app.buttons["crate-item-utada"]
        XCTAssertGreaterThan(held.frame.width, 170)
        XCTAssertGreaterThan(held.frame.height, 180)
        let from = held.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(.init(dx: 0, dy: 90)), withVelocity: .slow, thenHoldForDuration: 0)
        waitUntil { self.state(app)["held"] as? String == "" }
        person.tap()
        waitUntil { self.state(app)["held"] as? String == "utada" }
        app.buttons["crate-item-utada"].tap()
        waitUntil { app.staticTexts["now-title"].label == "宇多田光" }
        waitUntil { !app.otherElements["crate-page-transition"].exists }
        capture(app, "03-portrait-opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitUntil { app.staticTexts["now-title"].label == "JANE DOE" }
        XCTAssertTrue(app.buttons["crate-item-film"].exists)
        capture(app, "04-returned-jane")
        app.terminate()
    }

    func testLiveJaneFullStoryAndCachedReopen() throws {
        guard ProcessInfo.processInfo.environment["PIANWAI_P24_UI_LIVE"] == "1" else { throw XCTSkip("Explicit live journey only") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-reset", "--ui-state=P24-jane-live",
                               "--ui-playback=jane", "--ui-storefront=JPN", "--ui-internal-story-live"]
        if ProcessInfo.processInfo.environment["PIANWAI_P24_REUSE"] == "1" {
            app.launchArguments.removeAll { $0 == "--ui-reset" }
        }
        app.launch()
        XCTAssertTrue(app.buttons["story-read"].waitForExistence(timeout: 150))
        XCTAssertEqual(app.staticTexts["now-title"].label, "JANE DOE")
        XCTAssertTrue(app.buttons["crate-item-film"].exists)
        let preview = app.staticTexts["story-preview"].label
        capture(app, "05-live-jane-preview")
        app.buttons["story-read"].tap()
        XCTAssertTrue(app.staticTexts["story-full-body"].waitForExistence(timeout: 5))
        let full = app.staticTexts["story-full-body"]
        let fullText = full.label
        XCTAssertGreaterThan(full.label.count, preview.count + 60)
        XCTAssertLessThan(full.frame.maxY, app.buttons["story-full-source"].frame.minY)
        XCTAssertTrue(app.buttons["story-full-source"].isHittable)
        capture(app, "06-live-jane-full-story")
        let copy = XCTAttachment(string: full.label); copy.name = "P24-live-jane-copy"; copy.lifetime = .keepAlways; add(copy)
        app.buttons["story-close"].tap()
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-reset" || $0 == "--ui-internal-story-live" }
        app.launchArguments += ["--ui-network=offline"]
        app.launch()
        XCTAssertTrue(app.buttons["story-read"].waitForExistence(timeout: 8))
        app.buttons["story-read"].tap()
        XCTAssertEqual(app.staticTexts["story-full-body"].label, fullText)
        capture(app, "07-cached-full-story-offline")
        app.terminate()
    }

    func testLiveLoadingToStory() throws {
        guard ProcessInfo.processInfo.environment["PIANWAI_P24_UI_LIVE"] == "1" else { throw XCTSkip("Explicit live journey only") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-reset", "--ui-state=P24-pool-live",
                               "--ui-playback=poolJP", "--ui-storefront=JPN", "--ui-internal-story-live"]
        app.launch()
        XCTAssertTrue(app.otherElements["story-loading"].waitForExistence(timeout: 15))
        capture(app, "08-real-story-loading")
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 180))
        XCTAssertFalse(app.otherElements["story-loading"].exists)
        capture(app, "09-real-story-ready")
        app.terminate()
    }
}
