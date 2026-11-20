import XCTest

@MainActor final class StoryRecoveryJourneyUITests: XCTestCase {
    func testLiveDiscoveryThenOfflineReading() throws {
        guard let mode = ProcessInfo.processInfo.environment["PIANWAI_P27_UI_LIVE"],
              ["farAway", "goodWeather", "shaira"].contains(mode) else {
            throw XCTSkip("Explicit bounded P27 live content review only")
        }
        continueAfterFailure = false
        let title = mode == "farAway" ? "遠くを想像するように" : mode == "goodWeather" ? "いい天気" : "シャイラ"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-reset", "--ui-state=P27-" + mode,
                               "--ui-playback=" + mode, "--ui-storefront=JPN", "--ui-internal-story-live"]
        app.launch()
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 240),
                      "A loading or empty state does not pass content acceptance")
        XCTAssertEqual(app.staticTexts["now-title"].label, title)
        let preview = app.staticTexts["story-preview"].label
        XCTAssertFalse(preview.isEmpty)
        capture(app, "P27-" + mode + "-now")
        if app.buttons["story-read"].exists {
            app.buttons["story-read"].tap()
            XCTAssertTrue(app.staticTexts["story-full-body"].waitForExistence(timeout: 5))
            XCTAssertGreaterThan(app.staticTexts["story-full-body"].label.count, preview.count)
            XCTAssertTrue(app.buttons["story-full-source"].isHittable)
            XCTAssertLessThan(app.staticTexts["story-full-body"].frame.maxY,
                              app.buttons["story-full-source"].frame.minY)
            capture(app, "P27-" + mode + "-full")
            let copy = XCTAttachment(string: app.staticTexts["story-full-body"].label)
            copy.name = "P27-" + mode + "-copy"; copy.lifetime = .keepAlways; add(copy)
            app.buttons["story-close"].tap()
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "--ui-reset" || $0 == "--ui-internal-story-live" }
        app.launchArguments.append("--ui-network=offline")
        app.launch()
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["story-preview"].label, preview,
                       "The generated story must survive relaunch without another request")
        capture(app, "P27-" + mode + "-cached")
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
