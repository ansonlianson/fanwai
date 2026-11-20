import XCTest
@testable import Pianwai

@MainActor final class CrateSceneLifecycleTests: XCTestCase {
    private func items(_ ids: [String]) -> [CrateItem] {
        ids.compactMap { SeedGraph.bundled[$0] }.map { .init(entity: $0, relation: "关联", path: [$0.id]) }
    }

    func testChangingEntityDropsOldLabelsGestureAndDelayedWork() async throws {
        let scene = CrateV3Scene(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scene.configure(items: items(["ushio", "film"]), entityID: "pool", reduceMotion: true, loading: false, categories: [])
        scene.flippedID = "ushio"; scene.digSteps = 1; scene.showDigHint()
        XCTAssertNotNil(scene.heldTitle.text)
        scene.windowTransition = true; scene.digging = true; scene.dragID = "ushio"
        scene.later(0.02) { scene.heldTitle.text = "old callback" }
        scene.configure(items: items(["utada"]), entityID: "jane", reduceMotion: true, loading: false, categories: [])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(scene.heldTitle.text); XCTAssertNil(scene.heldDetail.text)
        XCTAssertEqual(scene.heldTitle.alpha, 0)
        XCTAssertFalse(scene.interaction.isBusy); XCTAssertEqual(scene.digSteps, 0)
        XCTAssertEqual(scene.order, ["utada"])
        scene.take("utada")
        XCTAssertEqual(scene.heldID, "utada", "New scene must remain usable after cancelling a window transition")
    }

    func testUpdatesWaitUntilHeldObjectReturns() async throws {
        let scene = CrateV3Scene(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scene.configure(items: items(["ushio", "film"]), entityID: "pool", reduceMotion: true, loading: false, categories: [])
        scene.take("ushio")
        let before = scene.order
        scene.configure(items: items(["ushio", "film", "manga"]), entityID: "pool", reduceMotion: true, loading: false, categories: [])
        XCTAssertEqual(scene.order, before); XCTAssertEqual(scene.heldID, "ushio")
        scene.returnHeld()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(Set(scene.order), Set(["ushio", "film", "manga"]))
        XCTAssertNil(scene.heldTitle.text); XCTAssertNil(scene.pendingContent)
    }
}
