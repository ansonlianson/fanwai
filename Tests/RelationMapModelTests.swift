import XCTest
@testable import Pianwai

final class RelationMapModelTests: XCTestCase {
    /// 0.4.3: an opened sleeve folds back (with everything opened beyond it) and reopens the same.
    func testCollapseRemovesDescendantsAndReopensInPlace() {
        let graph = SeedGraph.bundled
        var map = RelationMapModel(root: "pool")
        _ = map.expand("pool", graph: graph)
        _ = map.expand("film", graph: graph)
        let children = map.order.filter { map.nodes[$0]?.via == "film" }
        XCTAssertFalse(children.isEmpty)
        let grandchild = try? XCTUnwrap(children.first)
        if let grandchild { _ = map.expand(grandchild, graph: graph); map.setFocus(grandchild) }
        let placed = map.nodes.mapValues(\.position)
        let gone = Set(map.descendants(of: "film"))
        XCTAssertTrue(gone.isSuperset(of: children))
        XCTAssertTrue(map.canCollapse("film"))
        map.collapse("film")
        XCTAssertEqual(map.focus, "film", "focus inside the folded branch returns to the sleeve")
        XCTAssertFalse(map.nodes["film"]!.expanded)
        XCTAssertTrue(gone.allSatisfy { map.nodes[$0] == nil && !map.order.contains($0) })
        XCTAssertFalse(map.edges.contains { gone.contains($0.from) || gone.contains($0.to) })
        XCTAssertFalse(map.canCollapse("film"))
        XCTAssertGreaterThan(map.pending("film", graph: graph), 0, "the badge offers it again")
        let again = map.expand("film", graph: graph)
        XCTAssertEqual(Set(again.fresh), Set(children))
        for id in children { XCTAssertEqual(map.nodes[id]?.position, placed[id], "\(id) reopens where it was") }
    }
    func testFrozenBadgeUsesActualViaEdgesAndCannotGrowAfterAnotherExpansion() {
        let rootEdges: [SeedGraph.Relation] = [.init(from:"root",to:"creator",label:"作者"), .init(from:"root",to:"film",label:"配乐",via:"creator"), .init(from:"root",to:"book",label:"原作")]
        let initial = SeedGraph(version:1,root:"root",entities:[],relations:rootEdges + [
            .init(from:"film",to:"next",label:"配乐",via:"creator"), .init(from:"film",to:"book",label:"原作"),
            .init(from:"creator",to:"next",label:"配乐")])
        var map = RelationMapModel(root:"root"); _ = map.expand("root",graph:initial)
        map.freezeSelection("film",graph:initial)
        XCTAssertEqual(map.pending("film",graph:initial),2)
        _ = map.expand("creator",graph:initial)
        let changed = SeedGraph(version:1,root:"root",entities:[],relations:initial.relations + [.init(from:"film",to:"late",label:"后来载入")])
        XCTAssertEqual(map.pending("film",graph:changed),1,"An already drawn via edge is not another merge; later loads cannot inflate the frozen plan")
        let count = map.pending("film",graph:changed)
        let result = map.expand("film",graph:changed)
        XCTAssertEqual(result.fresh.count + result.meets.count,count)
        XCTAssertEqual(result.meets.map(\.to),["book"])
        XCTAssertEqual(Set(map.edges.map(\.id)).count,map.edges.count)
    }
    func testAuthoredLongJourneyNeverMovesOldNodesOrOverlapsCenters() throws {
        let graph = SeedGraph.bundled
        var map = RelationMapModel(root: "pool")
        var minimum = CGFloat.greatestFiniteMagnitude
        for id in ["pool", "film", "jane", "iris", "utada", "olk", "olkmv", "eva", "ushio", "csmtv", "kickback", "manga", "animenzv", "yonezu"] {
            let oldPositions = map.nodes.mapValues(\.position)
            let result = map.expand(id, graph: graph)
            for (key, position) in oldPositions { XCTAssertEqual(map.nodes[key]?.position, position, "old node moved after \(id): \(key)") }
            if id == "iris" { XCTAssertEqual(result.meets.map(\.to), ["yonezu"]); XCTAssertTrue(result.fresh.isEmpty) }
            for (i, aID) in map.order.enumerated() {
                for bID in map.order.dropFirst(i+1) {
                    let a = map.nodes[aID]!.position, b = map.nodes[bID]!.position
                    let distance = hypot(a.x-b.x, (a.y-b.y)*1.2)
                    minimum = min(minimum, distance)
                    XCTAssertGreaterThanOrEqual(distance, 100, "\(id): \(aID), \(bID)")
                }
            }
        }
        XCTAssertEqual(map.nodes.count, 23)
        XCTAssertEqual(Set(map.edges.map(\.id)).count, map.edges.count)
        print("P3 minimum weighted center distance:", minimum)
    }
    @MainActor func testPinchAnchorAndCompleteTrailRestore() throws {
        let suite = "Pianwai.Tests.MapTrail." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var map = RelationMapModel(root: "pool")
        for id in ["pool", "film", "jane"] { _ = map.expand(id, graph: .bundled) }
        map.setFocus("jane")
        XCTAssertEqual(map.focusPath, ["pool", "film", "jane"])
        map.camera = map.fittedCamera(ids: map.focusNeighborhood, viewport: CGSize(width: 402, height: 874))
        let anchor = CGPoint(x: 111, y: 337)
        let world = CGPoint(x: (anchor.x-map.camera.x)/map.camera.scale, y: (anchor.y-map.camera.y)/map.camera.scale)
        map.camera.zoom(by: 1.5, at: anchor)
        XCTAssertEqual(map.camera.project(world).x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(map.camera.project(world).y, anchor.y, accuracy: 0.001)
        let store = RelationTrailStore(defaults: preferences)
        store.save(map)
        XCTAssertEqual(RelationTrailStore(defaults: preferences).load(root: "pool"), map)
    }
}
