import XCTest

@MainActor final class StoryModelAndCrateWindowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ suite: String, reset: Bool = true, many: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "--ui-state=" + suite, "--ui-isolate-data", "--ui-network=offline", "-freezeNowState", "--ui-story-model-fixture"]
            + (reset ? ["--ui-reset"] : []) + (many ? ["--ui-crate-many"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testSettingsKeySaveConnectionAndRemoval() {
        let app = launch("P5c-settings")
        app.buttons["now-more"].tap(); app.buttons["故事模型"].tap()
        XCTAssertTrue(app.secureTextFields["story-model-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["按服务商的价格从你的账户计费。"].exists)
        capture(app, "01-unconfigured")
        app.secureTextFields["story-model-key"].tap()
        app.secureTextFields["story-model-key"].typeText("fixture-not-a-key-abcd\n")
        XCTAssertTrue(app.buttons["story-model-masked-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sk-••••abcd"].exists)
        capture(app, "02-configured")
        app.buttons["story-model-test"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 5))
        capture(app, "03-connected")
        app.buttons["story-model-remove"].tap()
        XCTAssertTrue(app.secureTextFields["story-model-key"].exists)
        app.terminate()
    }
    func testCustomModelWithoutRemoteListRemainsEditable() {
        let app = launch("P5c2-custom-model")
        app.buttons["now-more"].tap(); app.buttons["故事模型"].tap()
        app.buttons["story-model-provider"].tap()
        app.buttons["自定义"].tap()
        let address = app.textFields["地址"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("https://example.org/v1\n")
        let model = app.textFields["story-model-model-input"]
        XCTAssertTrue(model.exists)
        model.tap(); model.typeText("custom-model-v1\n")
        app.secureTextFields["story-model-key"].tap()
        app.secureTextFields["story-model-key"].typeText("fixture-custom-abcd\n")
        XCTAssertTrue(app.buttons["story-model-masked-key"].waitForExistence(timeout: 5))
        XCTAssertTrue(model.exists); XCTAssertEqual(model.value as? String, "custom-model-v1")
        XCTAssertTrue(app.staticTexts["地址"].exists)
        capture(app, "04-custom-model-fallback")
        app.buttons["story-model-test"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 5))
        app.buttons["story-model-remove"].tap(); app.terminate()
    }
    func testFourteenItemsHorizontalPullReturnAndRelaunch() {
        var app = launch("U6-window", many: true)
        let count = app.staticTexts["crate-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "1–5 / 14")
        let firstHeight = app.otherElements["record-crate"].frame.height
        capture(app, "01-first-window")
        let window = app.scrollViews["crate-window"]
        window.swipeLeft(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.label, "6–10 / 14")
        window.swipeRight(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.label, "1–5 / 14")
        let horizontalStart = window.coordinate(withNormalizedOffset: .init(dx: 0.85, dy: 0.45))
        horizontalStart.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.45)))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.label, "6–10 / 14", "A slower held drag advances exactly one window")
        window.swipeLeft(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count.label, "11–14 / 14")
        XCTAssertEqual(app.otherElements["record-crate"].frame.height, firstHeight, accuracy: 1)
        capture(app, "02-last-window")
        let last = app.buttons["crate-item-csmtv"]
        XCTAssertTrue(last.isHittable)
        let title = last.label.components(separatedBy: "，")[0]
        let start = last.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.07))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(.init(dx: 0, dy: -120)))
        XCTAssertTrue(app.buttons["lifted-object"].waitForExistence(timeout: 4))
        Thread.sleep(forTimeInterval: 0.6); capture(app, "03-pulled-last-item")
        app.buttons["lifted-object"].tap()
        XCTAssertEqual(app.staticTexts["now-title"].label, title)
        app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(count.label, "11–14 / 14")
        app.terminate(); app = launch("U6-window", reset: false, many: true)
        XCTAssertEqual(app.staticTexts["crate-count"].label, "11–14 / 14")
        capture(app, "04-restored")
        app.terminate()
    }
}
