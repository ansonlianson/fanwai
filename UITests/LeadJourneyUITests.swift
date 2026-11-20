import XCTest

/// 0.3 journey on a real catalogue song: leads arrive, the front one is
/// picked up, opened, and its own page is read. Spends real model calls, so
/// it only runs when a track is named:
///   TEST_RUNNER_PIANWAI_LEAD_TRACK="<catalog id>|<title>|<artist>"
@MainActor final class LeadJourneyUITests: XCTestCase {
    func testLeadsArriveThenOpenTheFrontOne() throws {
        guard let track = ProcessInfo.processInfo.environment["PIANWAI_LEAD_TRACK"], track.split(separator: "|").count >= 3 else {
            throw XCTSkip("Explicit live lead review only")
        }
        continueAfterFailure = false
        let name = ProcessInfo.processInfo.environment["PIANWAI_LEAD_NAME"] ?? "lead"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-state=L03-" + name, "--ui-storefront=JPN",
                               "--ui-leads-live", "--ui-track=" + track]
        app.launch()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate-item-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 120), "No lead reached the crate")
        sleep(3)
        save(app, name + "-1-now")

        // Pick up the front sleeve: its sentence moves under it.
        let front = frontItem(app)
        front.tap(); sleep(1)
        save(app, name + "-2-held")

        // Open it. The sentence that led here is on the page at once.
        frontItem(app).tap()
        XCTAssertTrue(app.staticTexts["lead-arrival"].waitForExistence(timeout: 8)
                      || app.staticTexts["story-preview"].waitForExistence(timeout: 2))
        sleep(2)
        save(app, name + "-3-opened")

        // Its own research lands on the same page.
        _ = app.staticTexts["story-preview"].waitForExistence(timeout: 90)
        sleep(4)
        save(app, name + "-4-opened-ready")

        app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        save(app, name + "-5-back")
    }

    /// The map opens with the leads already on it, and says why each is there.
    func testMapOpensWithLeadsAndPersonPhotoGrows() throws {
        guard let track = ProcessInfo.processInfo.environment["PIANWAI_LEAD_TRACK"], track.split(separator: "|").count >= 3 else {
            throw XCTSkip("Explicit live lead review only")
        }
        continueAfterFailure = false
        let name = ProcessInfo.processInfo.environment["PIANWAI_LEAD_NAME"] ?? "lead"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-state=L03-" + name, "--ui-storefront=JPN",
                               "--ui-leads-live", "--ui-track=" + track]
        app.launch()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate-item-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 150), "No lead reached the crate")
        sleep(4)
        save(app, name + "-m0-now")

        app.buttons["now-graph"].tap()
        // Within a second and a half of opening, not after a lookup.
        usleep(1_500_000)
        save(app, name + "-m1-map-at-1.5s")
        let nodes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-node-"))
        XCTAssertGreaterThan(nodes.count, 1, "The map opened with only its root")

        // A lead on the map carries its sentence on the card.
        let root = app.staticTexts["map-card-title"].label
        for index in 0..<nodes.count {
            let node = nodes.element(boundBy: index)
            guard node.isHittable, !node.label.contains(root) else { continue }
            node.tap(); sleep(2)
            if app.staticTexts["map-card-why"].exists { break }
        }
        XCTAssertTrue(app.staticTexts["map-card-why"].exists, "No lead on the map showed its sentence")
        save(app, name + "-m2-map-focus")
        app.segmentedControls["map-segment"].buttons["列表"].tap(); sleep(2)
        save(app, name + "-m3-list")
    }

    /// Pick up each reachable sleeve; a person's print grows out of its divider.
    func testPickUpEachSleeve() throws {
        guard let track = ProcessInfo.processInfo.environment["PIANWAI_LEAD_TRACK"], track.split(separator: "|").count >= 3 else {
            throw XCTSkip("Explicit live lead review only")
        }
        let name = ProcessInfo.processInfo.environment["PIANWAI_LEAD_NAME"] ?? "lead"
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-state=L03-" + name, "--ui-storefront=JPN",
                               "--ui-leads-live", "--ui-track=" + track]
        app.launch()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate-item-"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 150), "No lead reached the crate")
        sleep(5)
        var seen = Set<String>()
        for index in 0..<5 {
            let front = frontItem(app)
            guard front.exists, seen.insert(front.identifier).inserted else { break }
            front.tap()
            save(app, name + "-p\(index)-a")
            usleep(120_000); save(app, name + "-p\(index)-b")
            sleep(1); save(app, name + "-p\(index)-c")
            // Anywhere outside the lifted sleeve puts it back.
            app.otherElements["record-crate"].coordinate(withNormalizedOffset: .init(dx: 0.06, dy: 0.97)).tap(); sleep(2)
            // Bring the next sleeve to the front.
            let crate = app.otherElements["record-crate"]
            crate.coordinate(withNormalizedOffset: .init(dx: 0.62, dy: 0.72)).press(forDuration: 0.05, thenDragTo: crate.coordinate(withNormalizedOffset: .init(dx: 0.30, dy: 0.72)))
            sleep(2)
        }
        save(app, name + "-p-end")
    }

    private func frontItem(_ app: XCUIApplication) -> XCUIElement {
        let raw = app.otherElements["record-crate"].value as? String ?? "{}"
        let state = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        let order = state?["order"] as? [String] ?? []
        let cursor = Int(((state?["cursor"] as? Double) ?? 0).rounded())
        let inventory = state?["inventory"] as? [String] ?? []
        if inventory.indices.contains(cursor), order.contains(inventory[cursor]) { return app.buttons["crate-item-" + inventory[cursor]] }
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate-item-")).firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // Also on disk, where the review folder can read it.
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PIANWAI_SHOTS"] ?? NSTemporaryDirectory())
        try? app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("J-" + name + ".png"))
    }
}
