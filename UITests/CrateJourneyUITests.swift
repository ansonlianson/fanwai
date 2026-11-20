import XCTest

@MainActor final class CrateJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ state: String = "ready", suite: String = "R2-capture", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", state, "--ui-state=" + suite, "--ui-isolate-data", "--ui-reset", "--ui-network=offline", "-freezeNowState"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func revealCrate(_ app: XCUIApplication) {
        let graph = app.buttons["now-graph"]
        for _ in 0..<4 {
            if graph.exists && graph.frame.maxY < app.frame.height-180 { break }
            app.scrollViews["now-scroll"].coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.30))
                .press(forDuration: 0.05, thenDragTo: app.scrollViews["now-scroll"].coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.10)))
        }
    }
    private func pull(_ id: String, _ app: XCUIApplication) {
        let item = app.buttons["crate-item-" + id]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        XCTAssertTrue(app.buttons["lifted-object"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons["lifted-object"].label, id == "film" ? "电锯人 蕾塞篇" : id == "ushio" ? "牛尾宪辅" : "JANE DOE")
        Thread.sleep(forTimeInterval: 0.55)
    }
    private func expand(_ app: XCUIApplication, title: String) {
        app.buttons["lifted-object"].tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, title)
        let storyID = title == "电锯人 蕾塞篇" ? "film-main" : title == "牛尾宪辅" ? "ushio-main" : "jane-main"
        let story = app.descendants(matching: .any).matching(identifier: "story-" + storyID).firstMatch
        if title == "JANE DOE" { XCTAssertTrue(story.waitForExistence(timeout: 2)) }
        else { XCTAssertFalse(story.exists, "P5 hides preset copy that has no source URL") }
        Thread.sleep(forTimeInterval: 3.8)
    }
    func testPullExpandReturnAndDirectDrag() {
        let app = launch()
        XCTAssertTrue(app.otherElements["now-mini-player"].exists)
        XCTAssertLessThan(app.buttons["now-graph"].frame.maxY+10, app.otherElements["now-mini-player"].frame.minY)
        capture(app, "now-ready")
        revealCrate(app); capture(app, "crate-A")
        print("R2_PULL_BEGIN_EPOCH", Date().timeIntervalSince1970)
        pull("film", app); capture(app, "lifted")
        app.otherElements["crate-veil"].coordinate(withNormalizedOffset: .init(dx: 0.92, dy: 0.35)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["lifted-object"])
        waitForExpectations(timeout: 3)
        capture(app, "put-back")
        pull("film", app)
        expand(app, title: "电锯人 蕾塞篇"); capture(app, "entity-film")
        app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(app.buttons["crate-item-film"].exists)
        let item = app.buttons["crate-item-jane"]
        let from = item.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.07))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.12))
        from.press(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "JANE DOE")
        Thread.sleep(forTimeInterval: 0.8)
        app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.1)
        print("R2_PULL_END_EPOCH", Date().timeIntervalSince1970)
        pull("ushio", app); expand(app, title: "牛尾宪辅")
        let portrait = app.images["now-hero-ushio"]
        XCTAssertGreaterThanOrEqual(portrait.frame.minY, app.navigationBars.firstMatch.frame.maxY + 8)
        capture(app, "entity-person")
        XCTAssertLessThan(app.buttons["now-graph"].frame.maxY, app.otherElements["now-mini-player"].frame.minY)
        XCTAssertFalse(app.buttons["entity-action-稍后听"].exists)
        XCTAssertTrue(app.buttons["entity-action-看全部作品"].exists)
        app.terminate()
    }
    func testLoadingSparseAndDepthVariant() {
        let loading = launch("prep"); capture(loading, "now-loading")
        XCTAssertTrue(loading.staticTexts["正在读这首歌的资料"].exists)
        loading.terminate()
        let sparse = launch("sparse"); capture(sparse, "sparse")
        XCTAssertEqual(sparse.staticTexts["now-title"].label, "Actor")
        XCTAssertLessThan(sparse.buttons["now-graph"].frame.maxY+10, sparse.otherElements["now-mini-player"].frame.minY)
        sparse.terminate()
        let b = launch(extra: ["-crateB"]); revealCrate(b); capture(b, "crate-B"); b.terminate()
    }
    func testPlaybackActionsAndSynchronizedGraph() {
        let app = launch(suite: "R2-actions", extra: ["--ui-playback=accepted"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "story-pool-main").firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["两年前，它是先导片没用上的 B 方案"].exists)
        let hero = app.buttons["now-hero-pool"]
        let previous = hero.value as? String
        hero.tap()
        expectation(for: NSPredicate(format: "value != %@", previous ?? ""), evaluatedWith: hero)
        waitForExpectations(timeout: 5)
        revealCrate(app); pull("jane", app); expand(app, title: "JANE DOE")
        XCTAssertEqual(app.staticTexts["now-playback-title"].label, "in the pool", "Reading JANE DOE must not relabel the actual current song")
        XCTAssertTrue(app.tabBars.buttons["此刻"].exists, "Navigation must be the native tab bar")
        let queue = app.buttons["entity-action-下一首播放"]
        queue.tap()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: queue)
        waitForExpectations(timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap(); Thread.sleep(forTimeInterval: 1.1)
        app.buttons["now-graph"].tap()
        XCTAssertTrue(app.staticTexts["map-card-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["map-card-title"].label, "JANE DOE")
        XCTAssertTrue(app.buttons["map-node-utada"].exists)
        // 11-20: 收藏 is the ☆ beside the song on its map card.
        let save = app.buttons["page-star"]; save.tap()
        expectation(for: NSPredicate(format: "label == %@", "取消收藏"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        app.terminate()
    }
}
