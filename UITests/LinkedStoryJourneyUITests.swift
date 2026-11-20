import XCTest

@MainActor final class LinkedStoryJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ name: String, state: String = "ready", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", state, "-freezeNowState", "--ui-isolate-data", "--ui-reset",
            "--ui-network=offline", "--ui-story-model-fixture", "--ui-state=P20-" + name] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func name(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let link = app.links[text].firstMatch
        if !link.waitForExistence(timeout: 3) {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "link-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(link.exists, text)
        return link
    }
    func testPreviewToFilmBackAndFixedHeaderPreservePlayback() {
        let app = launch("explore")
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 5))
        capture(app, "01-now-story")
        let hero = app.buttons["now-hero-pool"]
        let before = hero.frame
        hero.swipeUp()
        XCTAssertEqual(hero.frame.minY, before.minY, accuracy: 2)
        name("蕾塞篇", in: app).tap()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "电锯人 蕾塞篇")
        XCTAssertFalse(app.staticTexts["story-preview"].exists, "Credits alone do not create a story")
        XCTAssertTrue(app.buttons.matching(identifier: "now-playback-open").matching(NSPredicate(format: "label == %@", "in the pool")).firstMatch.exists)
        capture(app, "02-film-from-story")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["now-title"].label, "in the pool")
        XCTAssertTrue(app.staticTexts["story-preview"].exists)
        capture(app, "03-returned")
        let sleeve = app.buttons["crate-item-jane"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.05))
        sleeve.press(forDuration: 0.12, thenDragTo: sleeve.withOffset(.init(dx: 4, dy: -330)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "JANE DOE")
        XCTAssertTrue(app.staticTexts["story-preview"].exists)
        capture(app, "07-crate-to-story")
    }
    func testShortReadingNameSourceAndReturn() {
        let app = launch("reading")
        XCTAssertFalse(app.buttons["story-read"].exists, "Short copy has no duplicate full-reading entry")
        XCTAssertTrue(app.staticTexts["story-preview"].exists)
        capture(app, "04-short-reading")
        name("牛尾宪辅", in: app).tap()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "牛尾宪辅")
        XCTAssertTrue(app.buttons.matching(identifier: "now-playback-open").matching(NSPredicate(format: "label == %@", "in the pool")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["story-source"].tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["关闭", "Done", "完成", "Close"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        capture(app, "05-original-source")
        done.tap()
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 5))
        app.terminate()
        let unbound = launch("unbound", extra: ["--ui-story-unbound"])
        name("蕾塞篇", in: unbound).tap()
        XCTAssertTrue(unbound.staticTexts["选择故事里提到的作品或创作者"].waitForExistence(timeout: 5))
        XCTAssertTrue(unbound.buttons["原文：Real Sound 访谈"].exists)
        capture(unbound, "08-name-lookup")
        unbound.buttons["关闭"].tap()
        XCTAssertTrue(unbound.staticTexts["story-preview"].waitForExistence(timeout: 5))
    }
    func testBodySelfLinkAndAccessibleCompactReading() {
        let app = launch("large-type", state: "sparse", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["story-title"].exists)
        capture(app, "06-large-type")
        XCTAssertFalse(app.buttons["story-read"].exists)
        XCTAssertTrue(app.buttons["story-source"].isHittable)
        name("Actor", in: app).tap()
        XCTAssertTrue(app.staticTexts["story-preview"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "Actor")
        XCTAssertFalse(app.buttons["accept-track-switch"].exists)
    }
}
