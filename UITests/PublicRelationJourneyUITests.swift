import XCTest
import UIKit

@MainActor final class PublicRelationJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ name: String, track: String = "poolJP") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-isolate-data", "--ui-reset", "--ui-state=Bridge14-" + name,
                               "--ui-network=real-relations", "--ui-search-delay", "--ui-playback=" + track, "--ui-storefront=JPN"]
        app.launch()
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 10))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func waitForCrate(_ app: XCUIApplication, creator: String, count: Int) {
        XCTAssertTrue(app.buttons["crate-item-" + creator].waitForExistence(timeout: 35))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let raw = app.otherElements["record-crate"].value as? String ?? "{}"
                let state = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String:Any]
                return app.buttons["now-graph"].isEnabled && app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate-item-")).count == count && state?["settled"] as? Bool == true
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        let crate = app.otherElements["record-crate"], player = app.otherElements["now-mini-player"]
        let state = try! JSONSerialization.jsonObject(with: Data((crate.value as! String).utf8)) as! [String:Any]
        let rect = state["frame"] as! [Double]
        print("P15_CRATE_LAYOUT", rect, "player", player.frame)
        XCTAssertLessThanOrEqual(rect[1] + rect[3] + 12, player.frame.minY + 1, "Crate must fit without scrolling")
        XCTAssertTrue(app.buttons["now-graph"].isHittable)
    }
    private func held(_ app: XCUIApplication) -> String {
        let raw = app.otherElements["record-crate"].value as? String ?? "{}"
        let state = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String:Any]
        return state?["held"] as? String ?? ""
    }
    private func waitHeld(_ app: XCUIApplication, _ id: String) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { self.held(app) == id } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed, "expected held=\(id), got \(held(app))")
    }
    /// A partial lift leaves the object in hand.
    private func pull(_ app: XCUIApplication, _ id: String) {
        let object=app.buttons["crate-item-"+id]
        let start=object.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.03))
        start.press(forDuration:0.12,thenDragTo:start.withOffset(.init(dx:12,dy:-120)),withVelocity:.slow,thenHoldForDuration:0.1)
        waitHeld(app, id)
    }
    /// A touch anywhere but the object puts it back.
    private func putBack(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.16)).tap(); waitHeld(app, "")
    }
    /// The object in hand opens with a second tap on itself.
    private func openHeld(_ app: XCUIApplication, _ id: String) {
        app.buttons["crate-item-"+id].tap()
    }
    private func crateState(_ app: XCUIApplication) -> [String: Any] {
        let raw = app.otherElements["record-crate"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String:Any] ?? [:]
    }
    /// Pulling toward yourself digs through the bin one sleeve at a time.
    func testDigThroughCrateThenPickTheUncovered() {
        let app = launch("crate-dig")
        waitForCrate(app, creator: "ushio", count: 5)
        let hero = app.buttons["now-hero-apple:song:1840141274"]
        let heroFrame = hero.frame
        let titleFrame = app.staticTexts["now-title"].frame
        hero.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: hero.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertEqual(hero.frame.minY, heroFrame.minY, accuracy: 1)
        XCTAssertEqual(app.staticTexts["now-title"].frame.minY, titleFrame.minY, accuracy: 1)
        XCTAssertFalse(app.scrollViews["now-scroll"].exists)
        let order = crateState(app)["order"] as! [String]
        let crate = app.otherElements["record-crate"]
        let start = crate.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(.init(dx: 0, dy: 100)), withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.8)
        let exposed = crateState(app)["exposed"] as? String ?? ""
        XCTAssertEqual(exposed, order[order.count-3], "two 44pt steps tip the two front sleeves")
        capture(app, "crate-dig")
        app.buttons["crate-item-"+exposed].tap()
        waitHeld(app, exposed)
        XCTAssertEqual(crateState(app)["exposed"] as? String, "")
        putBack(app)
        app.terminate()
    }
    func testPoolFivePullFilmAndOpenAlbum() {
        print("P14_MOTION_ARRIVAL_START", Date().timeIntervalSince1970)
        let app = launch("crate")
        waitForCrate(app, creator: "ushio", count: 5)
        print("P14_MOTION_ARRIVAL_END", Date().timeIntervalSince1970)
        let state = try! JSONSerialization.jsonObject(with: Data((app.otherElements["record-crate"].value as! String).utf8)) as! [String:Any]
        print("P15_SYSTEM_REDUCE_MOTION",state["systemReduceMotion"]!)
        if state["systemReduceMotion"] as? Bool == true { XCTAssertEqual(state["reduceMotion"] as? Bool,true) }
        XCTAssertTrue(app.buttons["crate-item-film"].label.contains("配乐"))
        XCTAssertFalse(app.buttons["故事模型"].exists)
        capture(app, "crate-full")
        // One tap picks an object up; a tap elsewhere puts it back.
        let rear=app.buttons["crate-item-apple:album:1840140991"].coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.025))
        rear.tap(); waitHeld(app, "apple:album:1840140991")
        Thread.sleep(forTimeInterval:0.5); capture(app,"crate-held")
        putBack(app); Thread.sleep(forTimeInterval:0.6)
        pull(app, "bangumi:subject:529431"); capture(app, "crate-pull")
        putBack(app); Thread.sleep(forTimeInterval: 0.6)
        // Pulled all the way up, an object goes straight into its page.
        let film=app.buttons["crate-item-film"].coordinate(withNormalizedOffset:.init(dx:0.5,dy:0.03))
        film.press(forDuration:0.12,thenDragTo:film.withOffset(.init(dx:6,dy:-330)),withVelocity:.fast,thenHoldForDuration:0)
        XCTAssertTrue(app.staticTexts["now-title"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["now-title"].label, "电锯人 蕾塞篇")
        capture(app, "opened-film")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["crate-item-apple:album:1840140991"].waitForExistence(timeout: 8))
        pull(app, "apple:album:1840140991"); Thread.sleep(forTimeInterval:0.4); openHeld(app, "apple:album:1840140991")
        XCTAssertTrue(app.buttons["entity-action-播放"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.links["itunes-badge-apple:album:1840140991"].exists)
        waitForCrate(app, creator: "ushio", count: 5)
        capture(app, "album-crate")
        print("P14_MOTION_SAVE_START", Date().timeIntervalSince1970)
        // 11-20: a record is starred from its card on the relation map, the page's own record included.
        star(app)
        let receipt = try! JSONSerialization.jsonObject(with: Data((app.otherElements["now-mini-player"].value as! String).utf8)) as! [String:Any]
        let target = receipt["target"] as! [Double]
        print("P15_COLLECTION_TARGET",target,"native tab",app.tabBars.buttons["收藏"].frame)
        XCTAssertGreaterThan(target[2],12)
        XCTAssertTrue(app.tabBars.buttons["收藏"].frame.contains(CGPoint(x:target[0]+target[2]/2,y:target[1]+target[3]/2)))
        XCTAssertTrue(app.staticTexts["now-feedback"].label.hasPrefix("已收藏《"))
        capture(app, "saved-album")
        Thread.sleep(forTimeInterval: 0.4)
        print("P14_MOTION_SAVE_END", Date().timeIntervalSince1970)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["now-save"].exists, "此刻 has no ☆ of its own: it would cover the record")
        star(app)
        app.tabBars.buttons["收藏"].tap()
        let pool = app.buttons["shop-work-apple:song:1840141274"], album = app.buttons["shop-work-apple:album:1840140991"]
        XCTAssertTrue(pool.waitForExistence(timeout: 5)); XCTAssertTrue(album.exists)
        if state["systemReduceMotion"] as? Bool == true { capture(app,"reduce-motion-collection") }
        capture(app, "collection-saved")
        app.terminate()
    }
    /// Opens the page's relation map and taps the ☆ on the record's own card.
    private func star(_ app: XCUIApplication) {
        let graph = app.buttons["now-graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: graph)
        waitForExpectations(timeout: 6); graph.tap()
        let save = app.buttons["page-star"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertTrue(app.staticTexts["now-feedback"].waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "取消收藏")
    }
    private func nodes(_ app: XCUIApplication) -> [String: [String: Any]] {
        guard let raw = app.otherElements["relation-canvas"].value as? String,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return [:] }
        return value["nodes"] as? [String: [String: Any]] ?? [:]
    }
    private func assertClear(_ app: XCUIApplication) {
        let card = app.otherElements["map-focus-card"], player = app.otherElements["now-mini-player"]
        XCTAssertTrue(card.exists); XCTAssertTrue(player.exists)
        XCTAssertLessThanOrEqual(card.frame.maxY + 8, player.frame.minY)
        // The zoom buttons are gone in 0.4.2 (pinch and 「适合屏幕」 remain); nodes must only stay clear of the card.
        // SwiftUI's transformed canvas exposes a full-screen AX rectangle for
        // its first node. Assert the rendered footprint from the live camera
        // and world coordinates, against the actual measured native card.
        for (id, frame) in projectedFrames(app) {
            XCTAssertFalse(frame.intersects(card.frame), id)
        }

    }
    private func projectedFrames(_ app: XCUIApplication) -> [String: CGRect] {
        guard let raw = app.otherElements["relation-canvas"].value as? String,
              let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let camera = value["camera"] as? [String: Double], let k = camera["scale"],
              let x = camera["x"], let y = camera["y"] else { XCTFail("Missing live camera"); return [:] }
        return nodes(app).compactMapValues { node in
            guard let point = node["position"] as? [Double], point.count == 2 else { return nil }
            // 104pt is the largest physical object; 24pt includes its name.
            return CGRect(x: x + (point[0]-64)*k, y: y+(point[1]-52)*k-20,
                          width: 134*k, height: 128*k+20)
        }
    }
    private func assertVisiblePixels(_ app: XCUIApplication, screenshot: XCUIScreenshot) {
        let raw = app.otherElements["relation-canvas"].value as! String
        print("P15_MAP_RENDERING", raw)
        let value = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        let camera = value["camera"] as! [String: Double], sizes = value["objects"] as! [String: [Double]]
        let k = camera["scale"]!, x = camera["x"]!, y = camera["y"]!
        let image = screenshot.image.cgImage!
        let w = image.width, h = image.height, factor = Double(w)/app.frame.width
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0,y: 0,width: w,height: h))
        func brightness(_ px: Int, _ py: Int) -> Double {
            let i = (py*w+px)*4
            return (Double(rgba[i])*299+Double(rgba[i+1])*587+Double(rgba[i+2])*114)/1000
        }
        for (id, node) in nodes(app) {
            let point = node["position"] as! [Double], size = sizes[id]!
            let rect = CGRect(x: (x+(point[0]-size[0]/2)*k)*factor,
                              y: (y+(point[1]-size[1]/2)*k)*factor,
                              width: size[0]*k*factor, height: size[1]*k*factor).integral
            let sampleX = Int(8*factor), sampleY = min(h-1,max(0,Int(rect.midY)))
            let felt = brightness(sampleX, sampleY)
            var contrast = 0, total = 0
            for py in max(0,Int(rect.minY))..<min(h,Int(rect.maxY)) {
                for px in max(0,Int(rect.minX))..<min(w,Int(rect.maxX)) {
                    total += 1; if abs(brightness(px,py)-felt) > 12 { contrast += 1 }
                }
            }
            let fraction = Double(contrast)/Double(max(1,total))
            print("P15_NODE_PIXELS",id,fraction)
            XCTAssertGreaterThanOrEqual(fraction,0.25,"Not rendered: \(id)")
        }
    }
    func testDynamicGraphExpansionPreservesPositionsAndAvoidsCard() {
        let app = launch("graph")
        waitForCrate(app, creator: "ushio", count: 5)
        app.buttons["now-graph"].tap()
        XCTAssertTrue(app.buttons["map-node-ushio"].waitForExistence(timeout: 10))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard let raw = app.otherElements["relation-canvas"].value as? String,
                      let state = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any],
                      let rendering = state["rendering"] as? [String:Any] else { return false }
                return (rendering["born"] as? [String])?.isEmpty == true && self.nodes(app).count == 6
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10),.completed)
        Thread.sleep(forTimeInterval: 0.8)
        let firstFrame = app.screenshot()
        let firstAttachment = XCTAttachment(screenshot: firstFrame)
        firstAttachment.name = "graph-dynamic"; firstAttachment.lifetime = .keepAlways; add(firstAttachment)
        assertVisiblePixels(app, screenshot: firstFrame); assertClear(app)
        print("P16_BADGE_INITIAL",app.otherElements["relation-canvas"].value as! String)
        let before = nodes(app); XCTAssertEqual(before.count, 6)
        let target = try! XCTUnwrap(projectedFrames(app)["ushio"])
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: target.midX, dy: target.midY)).tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.nodes(app).count > before.count }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 35), .completed)
        let after = nodes(app)
        XCTAssertEqual(after.count, 9)
        XCTAssertTrue(app.buttons["map-node-bangumi:subject:443168"].exists)
        for (id, node) in before { XCTAssertEqual(node["position"] as? NSArray, after[id]?["position"] as? NSArray, id) }
        XCTAssertTrue(app.buttons["map-node-film"].exists)
        Thread.sleep(forTimeInterval: 1.5)
        for id in ["film","bangumi:subject:551455","bangumi:subject:529431","bangumi:subject:515869","bangumi:subject:493016","bangumi:subject:443168"] {
            XCTAssertTrue(app.staticTexts["map-name-" + id].exists,id)
            XCTAssertFalse(app.staticTexts["map-name-" + id].label.isEmpty,id)
        }
        capture(app, "graph-expanded"); assertClear(app)
        let rawBefore = app.otherElements["relation-canvas"].value as! String
        print("P16_BADGE_BEFORE", rawBefore)
        let targetFilm = try! XCTUnwrap(projectedFrames(app)["film"])
        app.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx:targetFilm.midX,dy:targetFilm.midY)).tap()
        let filmExpanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.nodes(app)["film"]?["expanded"] as? Bool == true }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for:[filmExpanded],timeout:35),.completed)
        Thread.sleep(forTimeInterval:1)
        let rawAfter = app.otherElements["relation-canvas"].value as! String
        print("P16_BADGE_AFTER",rawAfter)
        let receipt = try! JSONSerialization.jsonObject(with:Data(rawAfter.utf8)) as! [String:Any]
        let expansion = receipt["lastExpansion"] as! [String:Any]
        XCTAssertEqual(expansion["preparedCount"] as? Int, (expansion["fresh"] as! [String]).count + (expansion["meets"] as! [String]).count)
        let oldBadges = (try! JSONSerialization.jsonObject(with:Data(rawBefore.utf8)) as! [String:Any])["badges"] as! [String:Int]
        let newBadges = receipt["badges"] as! [String:Int]
        for (id,count) in oldBadges { XCTAssertLessThanOrEqual(newBadges[id] ?? 0,count,id) }
        capture(app,"film-expanded-badge-check")
        app.terminate()
    }
    func testSparseDiverHasCreatorAndNoSingleAlbum() {
        let app = launch("sparse", track: "diver")
        waitForCrate(app, creator: "apple:artist:1779486576", count: 4)
        XCTAssertEqual(app.staticTexts["now-title"].label, "Diver")
        XCTAssertFalse(app.buttons["crate-item-apple:album:6803304738"].exists)
        XCTAssertFalse(app.buttons["crate-item-film"].exists)
        let expected = ["apple:artist:1779486576","apple:song:6778229289","apple:song:1824577027","apple:song:1791458949"]
        let raw = app.otherElements["record-crate"].value as! String
        let state = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String:Any]
        XCTAssertEqual(state["order"] as? [String], expected)
        XCTAssertFalse(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","story-")).firstMatch.exists)
        XCTAssertFalse(app.buttons["crate-item-apple:song:6803304740"].exists)
        capture(app, "sparse-creator"); capture(app, "no-image-person-crate")
        app.buttons["now-graph"].tap()
        XCTAssertTrue(app.buttons["map-node-apple:artist:1779486576"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1)
        capture(app, "no-image-person-map")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["搜索"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        print("P17_SEARCH_START", Date().timeIntervalSince1970)
        search.typeText("in the pool\n")
        XCTAssertTrue(app.otherElements["search-drawer"].waitForExistence(timeout: 3))
        capture(app, "search-drawer")
        XCTAssertTrue(app.buttons["search-result-apple:song:1840141274"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        capture(app, "search-results")
        print("P17_SEARCH_END", Date().timeIntervalSince1970)
        app.terminate()
    }
}
