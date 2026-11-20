import XCTest

@MainActor final class P26CrateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func state(_ app: XCUIApplication) -> [String: Any] {
        let raw = app.otherElements["record-crate"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 10), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testFeaturedToAllBrowsePullOpenAndRestore() {
        browsingJourney(reduceMotion: false)
    }
    func testReducedMotionKeepsCompleteBrowsingJourney() {
        browsingJourney(reduceMotion: true)
    }
    func testDirectRummagingAndReverseWithoutPagingButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "-freezeNowState", "--ui-isolate-data", "--ui-reset", "--ui-state=P26-direct-stack", "--ui-network=offline", "--ui-crate-many"]
        app.launch()
        XCTAssertTrue(app.buttons["crate-browse"].waitForExistence(timeout: 10))
        wait { self.state(app)["settled"] as? Bool == true }
        let box = state(app)["frame"] as! [Double]
        let base = app.coordinate(withNormalizedOffset: .zero)
        let right = base.withOffset(CGVector(dx: box[0]+box[2]*0.60, dy: box[1]+box[3]*0.58))
        let left = base.withOffset(CGVector(dx: box[0]+box[2]*0.20, dy: box[1]+box[3]*0.58))
        right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.05)
        wait { self.state(app)["browsing"] as? Bool == true && (self.state(app)["cursor"] as? Double ?? 0) > 0 }
        let cursor = state(app)["cursor"] as! Double
        left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.05)
        wait { (self.state(app)["cursor"] as? Double ?? 99) < cursor }
        XCTAssertEqual(state(app)["rendered"] as? Int, state(app)["total"] as? Int)
        let beforeIndexDrag = state(app)["cursor"] as! Double
        let indexTab = app.buttons["crate-browse"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        indexTab.press(forDuration: 0.05, thenDragTo: indexTab.withOffset(.init(dx: -70, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.05)
        wait { (self.state(app)["cursor"] as? Double ?? 0) > beforeIndexDrag }
        capture(app, "P26-05-reverse-stack"); app.terminate()
    }

    func testGraphReturnKeepsNativeDockAndCratePlacement() {
        let app = XCUIApplication()
        app.launchArguments = ["-nowState", "ready", "-freezeNowState", "--ui-isolate-data", "--ui-reset", "--ui-state=P26-graph-return", "--ui-network=offline"]
        app.launch()
        XCTAssertTrue(app.buttons["now-graph"].waitForExistence(timeout: 10))
        wait { self.state(app)["settled"] as? Bool == true }
        let rootFrame = app.otherElements["record-crate"].frame
        let playerFrame = app.otherElements["now-mini-player"].frame
        let first = (state(app)["order"] as! [String])[0]
        let itemFrame = app.buttons["crate-item-"+first].frame
        app.buttons["now-graph"].tap()
        XCTAssertTrue(app.segmentedControls["map-segment"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["此刻"].isHittable, "Native tabs must retain their space on the map")
        XCTAssertEqual(app.otherElements["now-mini-player"].frame.minY, playerFrame.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(app.otherElements["map-focus-card"].frame.maxY, playerFrame.minY,
            "Map actions must remain above playback")
        capture(app, "P26-map-stable-dock")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait { self.state(app)["settled"] as? Bool == true }
        XCTAssertEqual(app.otherElements["record-crate"].frame.minY, rootFrame.minY, accuracy: 1)
        XCTAssertEqual(app.otherElements["record-crate"].frame.height, rootFrame.height, accuracy: 1)
        XCTAssertEqual(app.buttons["crate-item-"+first].frame.minY, itemFrame.minY, accuracy: 1)
        XCTAssertEqual(app.otherElements["now-mini-player"].frame.minY, playerFrame.minY, accuracy: 1)
        capture(app, "P26-map-return-stable-crate"); app.terminate()
    }
    private func browsingJourney(reduceMotion: Bool) {
        let app = XCUIApplication()
        let args = ["-nowState", "ready", "-freezeNowState", "--ui-isolate-data", "--ui-state=P26-browse" + (reduceMotion ? "-reduce" : ""), "--ui-network=offline", "--ui-crate-many"]
            + (reduceMotion ? ["--ui-reduce-motion"] : [])
        app.launchArguments = args + ["--ui-reset"]; app.launch()
        XCTAssertTrue(app.buttons["crate-browse"].waitForExistence(timeout: 10))
        wait { self.state(app)["settled"] as? Bool == true }
        if reduceMotion { XCTAssertEqual(state(app)["reduceMotion"] as? Bool, true) }
        let order = state(app)["order"] as? [String] ?? []
        XCTAssertLessThanOrEqual(order.count, 3); XCTAssertFalse(order.isEmpty)
        for id in order { XCTAssertTrue(app.buttons["crate-item-"+id].isHittable) }
        XCTAssertEqual(state(app)["rendered"] as? Int, state(app)["total"] as? Int)
        capture(app, "P26-01-stock-and-featured")
        app.buttons["crate-browse"].tap()
        wait { self.state(app)["browsing"] as? Bool == true && self.state(app)["settled"] as? Bool == true }
        XCTAssertEqual(state(app)["rendered"] as? Int, state(app)["total"] as? Int)
        XCTAssertGreaterThan((state(app)["order"] as? [String])?.count ?? 0, 1)
        XCTAssertFalse(app.buttons["crate-next"].exists); XCTAssertFalse(app.buttons["crate-previous"].exists)
        let firstCursor = state(app)["cursor"] as? Double ?? -1
        let box = (state(app)["frame"] as! [Double])
        let base = app.coordinate(withNormalizedOffset: .zero)
        let from = base.withOffset(CGVector(dx: box[0]+box[2]*0.72, dy: box[1]+box[3]*0.65))
        let to = base.withOffset(CGVector(dx: box[0]+box[2]*0.23, dy: box[1]+box[3]*0.65))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.05)
        wait { (self.state(app)["cursor"] as? Double ?? 0) > firstCursor }
        let selected = state(app)["focused"] as! String
        let cursor = state(app)["cursor"] as! Double
        capture(app, "P26-02-continuous-stack")
        app.buttons["crate-item-"+selected].tap()
        wait { self.state(app)["held"] as? String == selected }
        capture(app, "P26-03-held")
        app.buttons["crate-item-"+selected].tap()
        wait { !app.otherElements["crate-page-transition"].exists && self.state(app)["held"] as? String == "" }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait { self.state(app)["cursor"] as? Double == cursor }
        app.terminate(); app.launchArguments = args; app.launch()
        XCTAssertTrue(app.buttons["crate-browse"].waitForExistence(timeout: 10))
        wait { self.state(app)["cursor"] as? Double == cursor }
        app.buttons["crate-browse"].tap()
        wait { self.state(app)["browsing"] as? Bool == false && self.state(app)["settled"] as? Bool == true }
        XCTAssertLessThanOrEqual((state(app)["order"] as? [String])?.count ?? 99, 3)
        capture(app, "P26-04-return-featured"); app.terminate()
    }
}
