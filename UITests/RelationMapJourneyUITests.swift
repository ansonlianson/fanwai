import XCTest

@MainActor final class RelationMapJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ suite: String, reset: Bool = true, playback: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "--ui-state=" + suite, "--ui-isolate-data", "-freezeNowState"]
        if reset { app.launchArguments.append("--ui-reset") }
        if playback { app.launchArguments.append("--ui-playback=accepted") }
        app.launch()
        let graph = app.buttons["now-graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            if graph.frame.maxY < app.frame.height-180 { break }
            let scroll = app.scrollViews["now-scroll"]
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.30)).press(forDuration: 0.05,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.10)))
        }
        graph.tap()
        XCTAssertTrue(app.buttons["map-node-film"].waitForExistence(timeout: 8))
        return app
    }
    private func tap(_ id: String, _ app: XCUIApplication, settle: Bool = true) {
        let node = app.buttons["map-node-" + id]
        if !node.exists { XCTAssertTrue(node.waitForExistence(timeout: 5), id) }
        node.tap()
        if settle { Thread.sleep(forTimeInterval: 1.05) }
    }
    private func crumb(_ id: String, _ app: XCUIApplication) {
        let item = app.buttons["map-crumb-" + id]
        if !item.isHittable {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.145))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.145)))
        }
        item.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testAuthoredGraphJourney() {
        let app = launch("P3-capture")
        capture(app, "initial")
        capture(app, "toolbar")
        tap("film", app)
        capture(app, "film-expanded")
        tap("jane", app)
        crumb("film", app)
        print("P3_MEET_BEGIN_EPOCH", Date().timeIntervalSince1970)
        tap("iris", app, settle: false)
        // 2026-11-06 anson: meeting a sleeve already on the map just joins it
        // with a line; no "又遇到" banner.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "map-meet").firstMatch.exists)
        XCTAssertTrue(app.buttons["map-node-yonezu"].exists)
        capture(app, "meet-yonezu")
        crumb("film", app)
        tap("jane", app)
        tap("utada", app)
        tap("olk", app)
        XCTAssertTrue(app.buttons["map-node-eva"].exists)
        crumb("pool", app)
        tap("ushio", app)
        // 11-20: no 看全图 button any more; a pinch takes in the whole map.
        app.otherElements["relation-canvas"].pinch(withScale: 0.45, velocity: -1)
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, "fit-all")
        // The focus is Ushio; these paper objects are outside its path and
        // neighborhood. Review all three fallback materials while shaded.
        for id in ["yoshihara", "iris", "eva"] { XCTAssertTrue(app.buttons["map-node-" + id].exists) }
        capture(app, "dimmed-materials")
        app.segmentedControls.buttons["列表"].tap()
        XCTAssertTrue(app.buttons["map-list-film"].exists)
        XCTAssertTrue(app.buttons["map-list-ushio"].exists)
        XCTAssertFalse(app.buttons["map-list-yonezu"].exists)
        capture(app, "list")
        app.buttons["map-list-animenzv"].tap()
        XCTAssertTrue(app.buttons["map-node-animenz"].waitForExistence(timeout: 5))
        app.terminate()
    }
    /// A new song offers itself even deep inside 此刻; one tap goes back up to it.
    func testSwitchPromptFromInsideTheMap() {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "switch", "--ui-state=switch-depth", "--ui-isolate-data", "--ui-reset", "-freezeNowState"]
        app.launch()
        let graph = app.buttons["now-graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 10))
        graph.tap()
        XCTAssertTrue(app.buttons["map-node-film"].waitForExistence(timeout: 8))
        let prompt = app.buttons["accept-track-switch"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["切过去"].exists)
        capture(app, "switch-prompt-in-map")
        prompt.tap()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "JANE DOE")
        XCTAssertFalse(prompt.exists)
        app.terminate()
    }
    func testPanPinchAndSavedTrailRestore() {
        let app = launch("P3-restore")
        tap("film", app)
        let node = app.buttons["map-node-film"]
        let oldX = node.frame.midX
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.28)).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.36)))
        XCTAssertGreaterThan(abs(node.frame.midX-oldX), 20)
        let canvas = app.otherElements["relation-canvas"]
        let oldZoom = canvas.value as? String
        canvas.pinch(withScale: 1.25, velocity: 1)
        XCTAssertNotEqual(canvas.value as? String, oldZoom)
        let frame = node.frame
        let value = canvas.value as? String
        app.terminate()
        let restored = launch("P3-restore", reset: false)
        XCTAssertEqual(restored.otherElements["relation-canvas"].value as? String, value)
        XCTAssertEqual(restored.buttons["map-node-film"].frame.midX, frame.midX, accuracy: 2)
        XCTAssertEqual(restored.buttons["map-node-film"].frame.midY, frame.midY, accuracy: 2)
        XCTAssertEqual(restored.staticTexts["map-card-title"].label, "电锯人 蕾塞篇")
        restored.terminate()
    }
    func testFocusCardQueueAndSave() {
        let app = launch("P3-actions", playback: true)
        tap("film", app); tap("jane", app)
        let queue = app.buttons["map-action-下一首播放"]
        queue.tap()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: queue)
        waitForExpectations(timeout: 5)
        let save = app.buttons["page-star"]
        XCTAssertEqual(save.label, "收藏")
        save.tap()
        // 11-20: 收藏 is the ☆ beside the song on its card; a second tap takes it back out.
        expectation(for: NSPredicate(format: "label == %@", "取消收藏"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("吉原")
        XCTAssertTrue(app.buttons["search-result-yoshihara"].waitForExistence(timeout: 5))
        capture(app, "missing-search")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        search.typeText("JANE")
        let result = app.buttons["search-result-jane"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.buttons["now-graph"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["now-graph"])
        waitForExpectations(timeout: 6)
        let entityScroll = app.scrollViews["now-scroll"]
        entityScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.72)).press(forDuration: 0.05,
            thenDragTo: entityScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.22)))
        XCTAssertLessThan(app.buttons["now-graph"].frame.maxY, app.otherElements["now-mini-player"].frame.minY)
        app.buttons["now-graph"].tap()
        XCTAssertTrue(app.buttons["map-node-utada"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["map-card-title"].label, "JANE DOE")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        search.typeText("蕾塞")
        let filmResult = app.buttons["search-result-film"]
        XCTAssertTrue(filmResult.waitForExistence(timeout: 4)); filmResult.tap()
        let filmGraph = app.buttons["now-graph"]
        XCTAssertTrue(filmGraph.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: filmGraph)
        waitForExpectations(timeout: 6); filmGraph.tap()
        app.segmentedControls.buttons["列表"].tap()
        XCTAssertTrue(app.buttons["map-list-yoshihara"].exists)
        app.collectionViews.firstMatch.swipeUp()
        capture(app, "missing-list")
        app.terminate()
    }
}
