import XCTest

/// 0.4 shop pages on a real catalogue song: leads arrive in the bin, the lamp turns off/on,
/// the bin scrolls, a work is set aside, then 关系图 / 收藏 / 搜索 in the same style.
/// Spends real model calls, so it only runs when a track is named:
///   TEST_RUNNER_PIANWAI_LEAD_TRACK="<catalog id>|<title>|<artist>"
@MainActor final class ShopJourneyUITests: XCTestCase {
    func testShopJourney() throws {
        guard let track = ProcessInfo.processInfo.environment["PIANWAI_LEAD_TRACK"], track.split(separator: "|").count >= 3 else {
            throw XCTSkip("Explicit live lead review only")
        }
        continueAfterFailure = false
        let name = ProcessInfo.processInfo.environment["PIANWAI_LEAD_NAME"] ?? "lead"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-state=S04-" + name, "--ui-storefront=JPN",
                               "--ui-leads-live", "--ui-track=" + track]
        app.launch()
        save(app, name + "-0-start")
        let works = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shop-work-"))
        XCTAssertTrue(works.firstMatch.waitForExistence(timeout: 180), "No lead reached the bin")
        sleep(5)
        save(app, name + "-1-now")

        // Lamp off: the record goes back first, then the light dims. Then on again.
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'now-hero-'")).firstMatch
        if hero.exists {
            hero.tap()
            usleep(200_000); save(app, name + "-2a-pausing")
            usleep(400_000); save(app, name + "-2b-pausing")
            sleep(2); save(app, name + "-2c-paused")
            hero.tap()
            usleep(250_000); save(app, name + "-2d-playing")
            sleep(2); save(app, name + "-2e-playing")
        }

        // The bin scrolls sideways under the finger.
        // The story above grows with the room it has, so aim at the bin itself, not a fixed screen row.
        let bin = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'shop-bin'")).firstMatch
        XCTAssertTrue(bin.exists, "No bin")
        let start = bin.coordinate(withNormalizedOffset: .init(dx: 0.85, dy: 0.62))
        start.press(forDuration: 0.02, thenDragTo: bin.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.62)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(2)
        save(app, name + "-3-scrolled")
        let back = bin.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.62))
        back.press(forDuration: 0.02, thenDragTo: bin.coordinate(withNormalizedOffset: .init(dx: 0.95, dy: 0.62)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(2)

        // A work's note; set it aside.
        works.firstMatch.tap(); sleep(1)
        save(app, name + "-4-note")
        let later = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shop-note-' AND (label CONTAINS '稍后听' OR label CONTAINS '想看')")).firstMatch
        if later.waitForExistence(timeout: 3) { later.tap(); sleep(3) }

        // Open the work: its page says what it is and where to read up on it.
        works.firstMatch.tap(); sleep(1)
        let open = app.buttons.matching(NSPredicate(format: "identifier == 'shop-note-打开'")).firstMatch
        if open.waitForExistence(timeout: 3) {
            open.tap(); sleep(6)
            save(app, name + "-4b-opened")
            app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        }

        // Map: one player at the bottom, the same objects.
        app.buttons["now-graph"].tap(); sleep(4)
        save(app, name + "-5-map")
        app.segmentedControls["map-segment"].buttons["列表"].tap(); sleep(2)
        save(app, name + "-6-list")
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)

        // 收藏
        app.tabBars.buttons["收藏"].tap(); sleep(3)
        save(app, name + "-7-collection")
        let wall = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shop-work-")).firstMatch
        if wall.waitForExistence(timeout: 3) { wall.tap(); sleep(1); save(app, name + "-8-collection-note") }
        app.tap()

        // 搜索 as you type
        app.tabBars.buttons["搜索"].tap(); sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap(); field.typeText("米津玄師")
            sleep(6)
            save(app, name + "-9-search")
        }
    }

    /// Open a work from the bin and go back, slowly, for a screen recording of the zoom.
    func testOpenAndBack() throws {
        guard let track = ProcessInfo.processInfo.environment["PIANWAI_LEAD_TRACK"], track.split(separator: "|").count >= 3 else {
            throw XCTSkip("Explicit live lead review only")
        }
        continueAfterFailure = false
        let name = ProcessInfo.processInfo.environment["PIANWAI_LEAD_NAME"] ?? "lead"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-state=S04-" + name, "--ui-storefront=JPN",
                               "--ui-leads-live", "--ui-track=" + track]
        app.launch()
        let works = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shop-work-"))
        XCTAssertTrue(works.firstMatch.waitForExistence(timeout: 180), "No lead reached the bin")
        sleep(4)
        for round in 0..<2 {
            works.element(boundBy: round).tap(); sleep(2)
            let open = app.buttons.matching(NSPredicate(format: "identifier == 'shop-note-打开'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 3))
            open.tap(); sleep(4)
            save(app, name + "-z\(round)-opened")
            app.navigationBars.buttons.firstMatch.tap(); sleep(4)
            save(app, name + "-z\(round)-back")
        }
        // The map: a pinch with one finger resting on a sleeve must not re-fit the camera.
        app.buttons["now-graph"].tap(); sleep(5)
        app.buttons["map-fit-all"].tap(); sleep(2)
        save(app, name + "-z-map")
        let canvas = app.otherElements["relation-canvas"]
        let before = canvas.value as? String ?? ""
        canvas.pinch(withScale: 1.8, velocity: 1.5); sleep(3)
        save(app, name + "-z-map-pinched")
        let after = canvas.value as? String ?? ""
        XCTAssertNotEqual(before, after)

        // Open a sleeve on the map, then fold it back with a second tap.
        func count() -> Int { Int((canvas.value as? String ?? "").prefix { $0.isNumber }) ?? 0 }
        app.buttons["map-fit-all"].tap(); sleep(2)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'map-node-apple:artist'")).firstMatch
        guard person.exists else { return }
        // A saved trail may have left it open: fold it first (a first tap may only focus it).
        for _ in 0..<2 where (person.value as? String ?? "").contains("已展开") { person.tap(); sleep(2) }
        let start = count()
        person.tap()
        var waited = 0
        while count() <= start, waited < 150 { sleep(3); waited += 3 }
        sleep(2)
        save(app, name + "-z-map-expanded")
        XCTAssertGreaterThan(count(), start, "the sleeve opened")
        guard count() > start else { return }
        person.tap(); sleep(2)
        save(app, name + "-z-map-collapsed")
        XCTAssertEqual(count(), start, "a second tap folds the sleeve back")
        person.tap(); sleep(3)
        save(app, name + "-z-map-reopened")
        XCTAssertGreaterThan(count(), start)
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PIANWAI_SHOTS"] ?? NSTemporaryDirectory())
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("S-" + name + ".png"))
    }
}
