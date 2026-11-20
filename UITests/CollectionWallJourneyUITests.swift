import XCTest

/// 收藏 since 11-20: 「音乐」 for starred songs (each with its relation map) and 想看 / 想玩 / 想读,
/// face-out on shelves. Every action lives in the note beside a work; no 全部播放, no reordering,
/// no 看过了, no edit mode.
@MainActor final class CollectionWallJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ suite: String, empty: Bool = false, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "--ui-state=" + suite, "--ui-isolate-data", "--ui-network=offline", "-freezeNowState", "--ui-playback=accepted", empty ? "--wallState=empty" : "--wallState=full"]
        if reset { app.launchArguments.append("--ui-reset") }
        app.launch()
        XCTAssertTrue(app.scrollViews["wall-scroll"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.7)
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func work(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["shop-work-" + id] }
    private func note(_ title: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["shop-note-" + title] }
    private func dismissNote(_ app: XCUIApplication) {
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.1, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    func testStarredSongNoteOpensItsMapAndQueuesNext() {
        let app = launch("P4-box")
        capture(app, "wall")
        XCTAssertTrue(app.staticTexts["音乐"].exists)
        XCTAssertFalse(app.staticTexts["稍后听"].exists)
        XCTAssertFalse(app.buttons["wall-play-all"].exists, "no 全部播放: Apple Music's 插播 takes its place")
        let pool = work("pool", app)
        XCTAssertTrue(pool.exists); pool.tap()
        for title in ["打开", "关系图", "下一首播放", "移出"] { XCTAssertTrue(note(title, app).waitForExistence(timeout: 4), title) }
        capture(app, "song-note")
        note("关系图", app).tap()
        XCTAssertTrue(app.segmentedControls["map-segment"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["map-node-pool"].exists, "the starred song's own map opens, as far as it was dug")
        XCTAssertTrue(app.buttons["map-node-utada"].exists)
        XCTAssertFalse(app.buttons["map-fit-all"].exists); XCTAssertFalse(app.buttons["更多"].exists)
        capture(app, "starred-map")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let jane = work("jane", app)
        XCTAssertTrue(jane.waitForExistence(timeout: 4)); jane.tap()
        XCTAssertFalse(note("关系图", app).exists, "a song never dug from has no map to open")
        note("下一首播放", app).tap()
        Thread.sleep(forTimeInterval: 0.8)
        jane.tap()
        XCTAssertTrue(note("打开", app).waitForExistence(timeout: 4))
        XCTAssertFalse(note("下一首播放", app).exists, "already next: not offered twice")
        app.terminate()
    }

    func testWishShelvesHaveNoWatchedButton() {
        let app = launch("P4-shelf")
        // A wish is keyed by its shelf entry, so find it by name.
        let film = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shop-work-' AND label BEGINSWITH %@", "电锯人 蕾塞篇")).firstMatch
        XCTAssertTrue(film.exists); film.tap()
        XCTAssertTrue(note("打开", app).waitForExistence(timeout: 4))
        XCTAssertTrue(note("移出", app).exists)
        XCTAssertFalse(note("看过了", app).exists)
        capture(app, "wish-note")
        app.terminate()
    }

    func testEmptyShelfAndRemovalPersist() {
        let empty = launch("P4-empty", empty: true)
        XCTAssertTrue(empty.descendants(matching: .any).matching(identifier: "wall-empty").firstMatch.exists)
        XCTAssertTrue(empty.staticTexts["还没有收藏"].exists)
        capture(empty, "empty"); empty.terminate()
        let app = launch("P4-remove")
        work("jane", app).tap()
        note("移出", app).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: work("jane", app))
        waitForExpectations(timeout: 4)
        Thread.sleep(forTimeInterval: 2.2)   // the library writes in batches of 1.5 s
        app.terminate()
        let restored = launch("P4-remove", reset: false)
        XCTAssertFalse(work("jane", restored).exists)
        XCTAssertTrue(work("pool", restored).exists)
        restored.terminate()
    }
}
