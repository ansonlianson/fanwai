import XCTest

/// #8 G: explicitly selected on an attached phone; never part of simulator acceptance.
@MainActor final class DeviceSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real Apple Music smoke requires the authorized physical iPhone")
        #endif
        continueAfterFailure = false
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // A separate preferences suite, but no simulator playback/network switches.
        app.launchArguments = ["--ui-state=Bridge8Device"] + (reset ? ["--ui-reset"] : [])
        app.launch()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 15))
        return app
    }
    private func find(_ query: String, id: String, in app: XCUIApplication) {
        if !app.searchFields.firstMatch.exists { app.tabBars.buttons["搜索"].tap() }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let clear = field.buttons.matching(NSPredicate(format: "label == 'Clear text' OR label == '清除文本'")).firstMatch
        if clear.exists { clear.tap() }
        else if let value = field.value as? String, !value.isEmpty, value != "搜索" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(query)
        let row = app.buttons["search-result-" + id]
        let link = app.descendants(matching: .any).matching(identifier: "search-result-" + id).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if row.exists { row.tap() } else { link.tap() }
        XCTAssertTrue(app.buttons["now-graph"].waitForExistence(timeout: 5))
    }
    private func feedback(_ app: XCUIApplication, screenshot: String) -> String {
        let result = app.staticTexts.matching(NSPredicate(format: "identifier IN %@", ["now-feedback", "wall-feedback"])).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 25), "The real request must return feedback")
        let message = result.label
        capture(app, screenshot)
        let note = XCTAttachment(string: message); note.name = screenshot + "-result"; note.lifetime = .keepAlways; add(note)
        return message
    }
    private func collectThree(_ app: XCUIApplication) {
        // Short distinguishing terms avoid changing the user's keyboard settings
        // or letting its correction turn "in the pool" into "in pool".
        for (query, id) in [("JANE", "jane"), ("pool", "pool"), ("Kiss", "olk")] {
            find(query, id: id, in: app)
            // 11-20: a song is starred from its card on the relation map.
            app.buttons["now-graph"].tap()
            let star = app.buttons["page-star"]
            XCTAssertTrue(star.waitForExistence(timeout: 5)); star.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let close = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Close' OR label == '关闭'")).firstMatch
        if close.exists { close.tap() }
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["shop-work-jane"].waitForExistence(timeout: 5))
    }
    func test02InsertNextReportsRealResult() {
        let app = launch(reset: true)
        capture(app, "2-before")
        find("JANE DOE", id: "jane", in: app)
        app.buttons["entity-action-下一首播放"].tap()
        let message = feedback(app, screenshot: "2-insert-result")
        // Acceptance is only the app's receipt; the full Music queue still
        // requires the user's observation because SystemMusicPlayer hides it.
        XCTAssertTrue(message.contains("放完"), message)
    }
    /// 收藏 has no 全部播放 since 11-20; each record's note offers 下一首播放 (Apple Music's 插播).
    func test03InsertNextFromCollectionReportsRealResult() {
        let app = launch(reset: true)
        collectThree(app)
        capture(app, "3-box-before")
        app.buttons["shop-work-jane"].tap()
        app.buttons["shop-note-下一首播放"].tap()
        let message = feedback(app, screenshot: "3-insert-from-collection-result")
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(app.buttons["shop-work-jane"].exists, "插播 does not take a record out of 收藏")
    }
    func test06RemovalAndRelaunchPersist() {
        let app = launch(reset: true)
        collectThree(app)
        let olk = app.buttons["shop-work-editorial:one-last-kiss"]
        XCTAssertTrue(olk.waitForExistence(timeout: 5)); olk.tap()
        app.buttons["shop-note-移出"].tap()
        XCTAssertFalse(olk.waitForExistence(timeout: 2))
        capture(app, "6-removed")
        app.terminate()
        let restored = launch(reset: false)
        restored.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(restored.buttons["shop-work-pool"].waitForExistence(timeout: 5))
        XCTAssertTrue(restored.buttons["shop-work-jane"].exists)
        XCTAssertFalse(restored.buttons["shop-work-editorial:one-last-kiss"].exists)
        capture(restored, "6-restored")
    }
}
