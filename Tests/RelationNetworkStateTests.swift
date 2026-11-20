import XCTest
@testable import Pianwai

/// These verify persistent graph semantics and reserved card geometry, not the
/// rendered hit targets, pinch anchoring or visual quality of the iPhone canvas.
@MainActor
final class RelationNetworkStateTests: XCTestCase {
    func testHighDegreeBranchIncludesEveryNeighborWithoutPagination() {
        var graph = RelationNetworkState(root: .pool)
        let neighbors = (0..<24).map { node($0) }
        graph.expand(.pool, edges: neighbors.map { edge(.pool, $0) })

        XCTAssertEqual(Set(graph.nodes.map(\.id)), Set([.pool] + neighbors))
        XCTAssertEqual(graph.linkIDs.count, 24)
        XCTAssertEqual(graph.expanded, [.pool])
        assertSeparated(graph.nodes)
    }

    func testDeepExpansionPreservesEarlierPositionsAndAllBranches() {
        var graph = RelationNetworkState(root: .pool)
        var parent = WorkID.pool
        for level in 0..<8 {
            let old = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.position) })
            let children = (0..<5).map { node(level * 5 + $0) }
            graph.expand(parent, edges: children.map { edge(parent, $0) })
            for (id, position) in old {
                XCTAssertEqual(graph.nodes.first { $0.id == id }?.position, position,
                               "Opening another branch must not move already explored objects")
            }
            parent = children[0]
        }
        XCTAssertEqual(graph.nodes.count, 41)
        XCTAssertEqual(graph.nodes.map(\.depth).max(), 8)
        XCTAssertEqual(graph.root, .pool)
        assertSeparated(graph.nodes)
    }

    func testRealJourneyReusesFinalDistanceWhenUtadaClosesSharedConnection() throws {
        var graph = RelationNetworkState(root: .pool)
        for id in [WorkID.pool, .film, .jane] {
            graph.expand(id, edges: Relations.seeds)
        }
        let previous = try XCTUnwrap(graph.nodes.first { $0.id == .distance })
        let shared = graph.expand(.utada, edges: Relations.seeds)

        XCTAssertEqual(shared, 1)
        XCTAssertEqual(graph.nodes.filter { $0.id == .distance }.count, 1)
        XCTAssertEqual(graph.nodes.first { $0.id == .distance }, previous)
        XCTAssertEqual(graph.trail, [.pool, .film, .jane, .utada])
        XCTAssertEqual(graph.focus, .utada)
        XCTAssertEqual(graph.root, .pool)
        let mention = try XCTUnwrap(Relations.seeds.first { $0.from == .jane && $0.to == .distance })
        let performance = try XCTUnwrap(Relations.seeds.first { $0.from == .distance && $0.to == .utada })
        XCTAssertEqual(mention.predicate, .interviewMention)
        XCTAssertEqual(performance.predicate, .performedBy)
        XCTAssertTrue(graph.linkIDs.contains(mention.id))
        XCTAssertTrue(graph.linkIDs.contains(performance.id))
        assertSeparated(graph.nodes)
    }

    func testCycleAndRepeatedResponsesNeverDuplicateNodesOrLinks() {
        var graph = RelationNetworkState(root: .pool)
        let relations = [edge(.pool, .film), edge(.film, .jane), edge(.jane, .pool)]
        graph.expand(.pool, edges: relations + relations)
        graph.expand(.film, edges: relations)
        graph.expand(.jane, edges: relations)
        let nodes = graph.nodes
        let links = graph.linkIDs
        let shared = graph.expand(.jane, edges: relations + relations)

        XCTAssertEqual(graph.nodes, nodes)
        XCTAssertEqual(graph.linkIDs, links)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), [.pool, .film, .jane])
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.linkIDs.count, 3)
        XCTAssertEqual(shared, 0, "Repeated data is not a newly discovered connection")
    }

    func testDifferentVerifiedPredicatesBetweenSameObjectsRemainDistinctLinks() {
        var graph = RelationNetworkState(root: .pool)
        let composer = edge(.pool, .ushio, predicate: .composedBy)
        let performer = edge(.pool, .ushio, predicate: .performedBy)
        graph.expand(.pool, edges: [composer, performer])

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(Set(graph.linkIDs), Set([composer.id, performer.id]))
    }

    func testUnrelatedResponseAndUnknownExpansionCannotCreateOrphanNodes() {
        var graph = RelationNetworkState(root: .pool)
        let initial = graph
        graph.expand(.film, edges: [edge(.film, .jane)])
        XCTAssertEqual(graph, initial)
        graph.expand(.pool, edges: [edge(.film, .jane)])
        XCTAssertEqual(graph.nodes, initial.nodes)
        XCTAssertTrue(graph.linkIDs.isEmpty)
    }

    func testExpansionDoesNotChangeCameraOrScaleAndReturningToRootKeepsBranches() {
        var graph = RelationNetworkState(root: .pool)
        graph.camera = NetworkPoint(x: 318, y: -219)
        graph.scale = 1.34
        graph.expand(.pool, edges: [edge(.pool, .film)])
        graph.expand(.film, edges: [edge(.film, .jane)])
        let nodes = graph.nodes
        graph.expand(.pool, edges: [edge(.pool, .film)])

        XCTAssertEqual(graph.nodes, nodes)
        XCTAssertEqual(graph.trail, [.pool])
        XCTAssertEqual(graph.camera, NetworkPoint(x: 318, y: -219))
        XCTAssertEqual(graph.scale, 1.34)
    }

    func testSwitchingToAnotherBranchRestoresItsRealPathInsteadOfJoiningUnrelatedObjects() {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: [edge(.pool, .film), edge(.pool, .ushio)])
        graph.expand(.film, edges: [edge(.film, .jane)])
        graph.expand(.jane, edges: [edge(.film, .jane)])
        XCTAssertEqual(graph.trail, [.pool, .film, .jane])
        let priorPositions = graph.nodes.map(\.position)

        graph.expand(.ushio, edges: [edge(.pool, .ushio)])
        XCTAssertEqual(graph.trail, [.pool, .ushio],
                       "The breadcrumb must not imply that JANE DOE is linked directly to Ushio")
        XCTAssertEqual(graph.nodes.map(\.position), priorPositions)
        XCTAssertEqual(graph.nodes.first { $0.id == .ushio }?.parent, .pool)
    }

    func testActualCrossLinkCanExtendCurrentTrailWithoutChangingDiscoveryParent() {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: [edge(.pool, .film), edge(.pool, .ushio)])
        graph.expand(.film, edges: [edge(.film, .jane)])
        graph.expand(.jane, edges: [edge(.film, .jane)])
        graph.expand(.ushio, edges: [edge(.jane, .ushio)])

        XCTAssertEqual(graph.trail, [.pool, .film, .jane, .ushio])
        XCTAssertEqual(graph.nodes.first { $0.id == .ushio }?.parent, .pool,
                       "A newly discovered shared link must not rewrite the object's original branch")
    }

    func testBreadcrumbFocusTruncatesTrailWithoutExpandingOrMovingCamera() {
        var graph = RelationNetworkState(root: .pool)
        for id in [WorkID.pool, .film, .jane, .utada] { graph.expand(id, edges: Relations.seeds) }
        graph.camera = NetworkPoint(x: 215, y: -91)
        graph.scale = 1.22
        let nodes = graph.nodes
        let links = graph.linkIDs
        let expanded = graph.expanded

        XCTAssertTrue(graph.focusNode(.film))
        XCTAssertEqual(graph.trail, [.pool, .film])
        XCTAssertEqual(graph.focus, .film)
        XCTAssertEqual(graph.nodes, nodes)
        XCTAssertEqual(graph.linkIDs, links)
        XCTAssertEqual(graph.expanded, expanded)
        XCTAssertEqual(graph.camera, NetworkPoint(x: 215, y: -91))
        XCTAssertEqual(graph.scale, 1.22)
        let beforeUnknownFocus = graph
        XCTAssertFalse(graph.focusNode(node(999)))
        XCTAssertEqual(graph, beforeUnknownFocus)
    }

    func testFocusingDeepSiblingUsesItsCompleteParentPath() {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: [edge(.pool, .film), edge(.pool, .ushio)])
        graph.expand(.film, edges: [edge(.film, .manga)])
        graph.expand(.manga, edges: [edge(.manga, .fujimoto)])
        graph.expand(.ushio, edges: [edge(.pool, .ushio)])

        XCTAssertTrue(graph.focusNode(.fujimoto))
        XCTAssertEqual(graph.trail, [.pool, .film, .manga, .fujimoto])
        XCTAssertFalse(graph.expanded.contains(.fujimoto), "Focusing a known object does not investigate it")
    }

    func testOldNetworkWithoutParentsStillDecodesAndDoesNotInventCrossBranchTrail() throws {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: [edge(.pool, .film), edge(.pool, .ushio)])
        graph.expand(.film, edges: [edge(.film, .jane)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)) as? [String: Any])
        let serializedNodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        object["nodes"] = serializedNodes.map { node in
            var legacyNode = node
            legacyNode.removeValue(forKey: "parent")
            return legacyNode
        }
        var restored = try JSONDecoder().decode(RelationNetworkState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(restored.nodes.allSatisfy { $0.parent == nil })
        XCTAssertEqual(restored.nodes.map(\.position), graph.nodes.map(\.position))

        restored.focusNode(.ushio)
        XCTAssertEqual(restored.trail, [.ushio], "Missing provenance must not become a fabricated root-to-object edge")
    }

    func testMalformedParentCycleCannotLoopOrManufactureRootPath() throws {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: [edge(.pool, .film), edge(.pool, .ushio)])
        let filmIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.id == .film })
        let ushioIndex = try XCTUnwrap(graph.nodes.firstIndex { $0.id == .ushio })
        graph.nodes[filmIndex].parent = .ushio
        graph.nodes[ushioIndex].parent = .film

        graph.focusNode(.film)
        XCTAssertEqual(graph.trail, [.film])
        XCTAssertEqual(graph.focus, .film)
    }

    func testOverviewContainsAllReservedCardsAndKeepsWorldCoordinates() {
        var graph = RelationNetworkState(root: .pool)
        graph.expand(.pool, edges: (0..<24).map { edge(.pool, node($0)) })
        let positions = graph.nodes
        graph.fit(width: 390, height: 560)

        for node in graph.nodes {
            let x = 195 + (node.position.x - graph.camera.x) * graph.scale
            let y = 280 + (node.position.y - graph.camera.y) * graph.scale
            XCTAssertGreaterThanOrEqual(x - 75 * graph.scale, 0)
            XCTAssertLessThanOrEqual(x + 75 * graph.scale, 390)
            XCTAssertGreaterThanOrEqual(y - 80 * graph.scale, 0)
            XCTAssertLessThanOrEqual(y + 80 * graph.scale, 560)
        }
        XCTAssertEqual(graph.nodes, positions)
    }

    func testCodableRoundTripRetainsExplorationAndCamera() throws {
        var graph = RelationNetworkState(root: .pool)
        for id in [WorkID.pool, .film, .jane, .utada] { graph.expand(id, edges: Relations.seeds) }
        graph.camera = NetworkPoint(x: -180.25, y: 89.125)
        graph.scale = 0.47
        let restored = try JSONDecoder().decode(RelationNetworkState.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(restored, graph)
    }

    func testLibraryCheckpointPersistsExpandedNetworkAcrossRelaunch() throws {
        let suite = "Pianwai.NetworkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        library.explore(.pool)
        library.path = [.connections(.pool)]
        var network = RelationNetworkState(root: .pool)
        for id in [WorkID.pool, .film, .jane, .utada] { network.expand(id, edges: Relations.seeds) }
        network.camera = NetworkPoint(x: 143.5, y: -28)
        network.scale = 0.53
        let checkpoint = GraphCheckpoint(center: .pool, history: [], page: 0, filter: 0,
                                         presentation: 0, network: network)
        library.saveGraph(root: .pool, checkpoint: checkpoint)
        XCTAssertEqual(library.graphCheckpoints[WorkID.pool.rawValue]?.network, network)

        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
        XCTAssertEqual(restored.path, [.connections(.pool)])
        XCTAssertEqual(restored.graphCheckpoints[WorkID.pool.rawValue]?.network, network,
                       "Library normalization must preserve the graph, not only old page/center fields")
    }

    private func node(_ index: Int) -> WorkID {
        WorkID(rawValue: "test:relation-network:\(index)")!
    }

    private func edge(_ from: WorkID, _ to: WorkID, predicate: RelationKind = .adaptedFrom) -> RelationEdge {
        RelationEdge(from: from, to: to, predicate: predicate, label: "测试关联", inverseLabel: "测试反向关联",
                     source: Source(title: "Test fixture", detail: "Synthetic graph topology only", url: "https://example.com/network-fixture"))
    }

    private func assertSeparated(_ nodes: [NetworkNode], file: StaticString = #filePath, line: UInt = #line) {
        for (index, first) in nodes.enumerated() {
            for second in nodes.dropFirst(index + 1) {
                XCTAssertTrue(abs(first.position.x - second.position.x) >= 146
                              || abs(first.position.y - second.position.y) >= 152,
                              "Reserved artwork and label rectangles overlap: \(first.id.rawValue), \(second.id.rawValue)",
                              file: file, line: line)
            }
        }
    }
}
