import XCTest

@MainActor final class PublicCatalogJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ suite: String, mode: String = "public-catalog", reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "-freezeNowState", "--ui-isolate-data", "--ui-state=" + suite,
                               "--ui-network=" + mode, "--ui-playback=failed"]
        if reset { app.launchArguments.append("--ui-reset") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["搜索"].waitForExistence(timeout: 10))
        return app
    }
    private func search(_ text: String, app: XCUIApplication) {
        app.tabBars.buttons["搜索"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        field.typeText("\n")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSearchTypesOpenSaveAndOfflineRestart() {
        let app = launch("P6-public-save")
        search("in the pool 牛尾憲輔", app: app)
        let song = app.buttons["search-result-apple:song:1840141274"]
        XCTAssertTrue(song.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["apple-music-action-apple:song:1840141274"].exists)
        XCTAssertFalse(app.links["itunes-badge-apple:song:1840141274"].exists)
        capture(app, "public-search-song")
        app.segmentedControls["search-type"].buttons["专辑"].tap()
        XCTAssertTrue(app.buttons["search-result-apple:album:1840140991"].waitForExistence(timeout: 8))
        app.buttons["search-result-apple:album:1840140991"].tap()
        XCTAssertTrue(app.buttons["crate-item-apple:song:1840140993"].waitForExistence(timeout: 8))
        capture(app, "public-album-tracks")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls["search-type"].buttons["音乐人"].tap()
        XCTAssertTrue(app.buttons["search-result-ushio"].waitForExistence(timeout: 8))
        app.segmentedControls["search-type"].buttons["歌曲"].tap()
        XCTAssertTrue(song.waitForExistence(timeout: 8)); song.tap()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "in the pool")
        XCTAssertTrue(app.buttons["entity-action-播放"].exists)
        XCTAssertFalse(app.links["itunes-badge-apple:song:1840141274"].exists)
        XCTAssertTrue(app.buttons["now-graph"].isEnabled)
        // A known creator reached from a new recording starts its own authored
        // graph; the dynamic recording must never become a synthetic graph root.
        let creator = app.buttons["crate-item-ushio"]
        XCTAssertTrue(creator.waitForExistence(timeout: 8))
        creator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        let lifted = app.buttons["lifted-object"]
        XCTAssertTrue(lifted.waitForExistence(timeout: 5)); lifted.tap()
        XCTAssertTrue(app.buttons["entity-action-看全部作品"].waitForExistence(timeout: 5))
        app.buttons["entity-action-看全部作品"].tap()
        XCTAssertTrue(app.segmentedControls["map-segment"].waitForExistence(timeout: 5))
        app.segmentedControls["map-segment"].buttons["关系图"].tap()
        XCTAssertTrue(app.buttons["map-crumb-ushio"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["map-crumb-apple:song:1840141274"].exists)
        capture(app, "public-known-creator-graph")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // 11-20: a song is starred from its card on the relation map.
        star(app)
        capture(app, "public-work-saved")
        app.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["shop-work-apple:song:1840141274"].waitForExistence(timeout: 5))
        app.terminate()
        let restored = launch("P6-public-save", mode: "offline", reset: false)
        restored.tabBars.buttons["收藏"].tap()
        XCTAssertTrue(restored.buttons["shop-work-apple:song:1840141274"].waitForExistence(timeout: 5))
        capture(restored, "public-saved-offline-restart")
        restored.terminate()
    }

    /// Opens the page's relation map and taps the ☆ on the song's own card.
    private func star(_ app: XCUIApplication) {
        let graph = app.buttons["now-graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: graph)
        waitForExpectations(timeout: 6); graph.tap()
        let save = app.buttons["page-star"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        expectation(for: NSPredicate(format: "label == %@", "取消收藏"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
    }

    func testRegionalLinkOpensItsExactRecording() {
        let app = launch("P6-public-region")
        search("https://music.apple.com/us/song/1837522108", app: app)
        // Search preference is JP; this lookup must still use the link's US region.
        let row = app.buttons["search-result-pool"]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-title"].label, "in the pool")
        XCTAssertTrue(app.buttons["now-hero-pool"].exists || app.images["now-hero-pool"].exists)
        capture(app, "public-us-link")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        search("https://music.apple.com/jp/song/1840141274", app: app)
        let jp = app.buttons["search-result-apple:song:1840141274"]
        XCTAssertTrue(jp.waitForExistence(timeout: 8)); jp.tap()
        let badge = app.buttons["entity-action-播放"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5)); badge.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        let openedSafari = safari.wait(for: .runningForeground, timeout: 5)
        let openedMusic = !openedSafari && music.wait(for: .runningForeground, timeout: 3)
        XCTAssertTrue(openedSafari || openedMusic)
        print("PUBLIC_BADGE_DESTINATION safari=\(openedSafari) music=\(openedMusic) source=https://music.apple.com/jp/album/in-the-pool/1840140991?i=1840141274&uo=4")
        if openedSafari { _ = safari.webViews.firstMatch.waitForExistence(timeout: 8) }
        let destination = XCTAttachment(screenshot: (openedSafari ? safari : music).screenshot())
        destination.name = "public-badge-opened"; destination.lifetime = .keepAlways; add(destination)
        app.terminate()
    }

    func testCatalogAndPlaybackFailuresStillAllowLocalSaving() {
        let app = launch("P6-public-failures", mode: "catalog-throttled")
        search("unavailable recording", app: app)
        XCTAssertTrue(app.staticTexts["查询有些频繁，稍等片刻再试。"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["重试"].exists)
        capture(app, "public-catalog-throttled")
        app.tabBars.buttons["此刻"].tap()
        app.buttons["now-more"].tap(); app.buttons["下一首播放"].tap()
        XCTAssertTrue(app.staticTexts["now-feedback"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-feedback"].label, "这首歌暂时无法播放。可以先收藏。")
        star(app)
        app.tabBars.buttons["收藏"].tap()
        let kept = app.buttons["shop-work-pool"]
        XCTAssertTrue(kept.waitForExistence(timeout: 5)); kept.tap()
        app.buttons["shop-note-下一首播放"].tap()
        XCTAssertTrue(app.staticTexts["now-feedback"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["now-feedback"].label, "这首歌暂时无法播放。")
        XCTAssertTrue(app.buttons["shop-work-pool"].exists)
        capture(app, "public-failed-playback-saved")
        app.terminate()
    }
}
