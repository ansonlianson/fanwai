import XCTest
@testable import Pianwai

/// Persistence/navigation contracts for a relationship exploration session.
/// These do not substitute for a simulator check of the rendered graph position.
@MainActor
final class GraphResumeTests: XCTestCase {
    func testGraphStateSurvivesChildWorkNavigationAndRelaunch() throws {
        try withLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.path.append(.connections(.pool))
            let checkpoint = sampleGraph()
            library.saveGraph(root: .pool, checkpoint: checkpoint)
            library.open(.manga)
            XCTAssertEqual(library.graphCheckpoints[WorkID.pool.rawValue], checkpoint)

            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(restored.path, [.connections(.pool), .work(.manga)])
            XCTAssertEqual(restored.reading, .manga)
            XCTAssertEqual(restored.graphCheckpoints[WorkID.pool.rawValue], checkpoint)
            restored.path.removeLast()
            XCTAssertEqual(restored.path, [.connections(.pool)])
            XCTAssertEqual(restored.graphCheckpoints[WorkID.pool.rawValue], checkpoint,
                           "Returning from a child must not reset the explored center or filter")
        }
    }

    func testGraphRootRemainsWhileEitherTabStillOwnsItsRoute() throws {
        try withLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.path = [.connections(.pool)]
            library.collectionPath = [.connections(.pool)]
            let checkpoint = sampleGraph()
            library.saveGraph(root: .pool, checkpoint: checkpoint)
            library.path = []
            XCTAssertEqual(library.graphCheckpoints[WorkID.pool.rawValue], checkpoint,
                           "The collection stack still owns this exploration")
            library.tab = .collection
            library.open(.film)
            XCTAssertEqual(library.graphCheckpoints[WorkID.pool.rawValue], checkpoint)
            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(restored.collectionPath, [.connections(.pool), .work(.film)])
            XCTAssertEqual(restored.graphCheckpoints[WorkID.pool.rawValue], checkpoint)
            restored.collectionPath = []
            XCTAssertNil(restored.graphCheckpoints[WorkID.pool.rawValue])
        }
    }

    func testExitingGraphPrunesItsStateAndLateDisappearCannotResurrectIt() throws {
        try withLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.path.append(.connections(.pool))
            let checkpoint = sampleGraph()
            library.saveGraph(root: .pool, checkpoint: checkpoint)
            library.path.removeLast()
            XCTAssertNil(library.graphCheckpoints[WorkID.pool.rawValue])
            // SwiftUI can deliver an outgoing view's save after its route was removed.
            library.saveGraph(root: .pool, checkpoint: checkpoint)
            XCTAssertNil(library.graphCheckpoints[WorkID.pool.rawValue])
            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertNil(restored.graphCheckpoints[WorkID.pool.rawValue])
            restored.path.append(.connections(.pool))
            XCTAssertNil(restored.graphCheckpoints[WorkID.pool.rawValue],
                         "A newly opened graph must start from its root, not an exited session")
        }
    }

    func testStartingAnotherExplorationDropsAnUnownedOldGraph() throws {
        try withLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.path = [.connections(.pool)]
            library.saveGraph(root: .pool, checkpoint: sampleGraph())
            library.explore(.jane)
            XCTAssertEqual(library.focus, .jane)
            XCTAssertTrue(library.path.isEmpty)
            XCTAssertNil(library.graphCheckpoints[WorkID.pool.rawValue])
            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(restored.focus, .jane)
            XCTAssertNil(restored.graphCheckpoints[WorkID.pool.rawValue])
        }
    }

    func testGraphRootCenterAndHistoryAliasesCanonicalizeOnReload() throws {
        try withLibrary { _, defaults, catalog in
            let songAlias = try XCTUnwrap(WorkID(rawValue: "apple:song:1837522108"))
            let albumAlias = try XCTUnwrap(WorkID(rawValue: "apple:album:1837521647"))
            let checkpoint = GraphCheckpoint(center: albumAlias,
                                             history: [GraphTrailEntry(id: songAlias, page: 0, filter: 2)],
                                             page: 0, filter: 1, presentation: 1)
            var snapshot = LibrarySnapshot(lastWork: songAlias, startedBrowsing: true)
            snapshot.navigation = LibraryNavigationSnapshot(tab: .now, focus: songAlias, reading: songAlias,
                                                           path: [.connections(songAlias)], collectionPath: [])
            snapshot.graphCheckpoints = [songAlias.rawValue: checkpoint]
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            // Store historical aliases directly so load, not only save, must normalize them.
            defaults.set(try JSONEncoder().encode(snapshot), forKey: persistence.key)
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(restored.path, [.connections(.pool)])
            XCTAssertNil(restored.graphCheckpoints[songAlias.rawValue])
            let graph = try XCTUnwrap(restored.graphCheckpoints[WorkID.pool.rawValue])
            XCTAssertEqual(graph.center, .poolAlbum)
            XCTAssertEqual(graph.history.map(\.id), [.pool])
            XCTAssertEqual(graph.history.first?.filter, 2)
            XCTAssertEqual(graph.presentation, 1)
        }
    }

    func testSnapshotFromBeforeGraphPersistenceStillLoadsItsExistingState() throws {
        try withLibrary { _, defaults, catalog in
            let reading = ReadingCheckpoint(workID: .film, offset: 211, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            var snapshot = LibrarySnapshot(saved: [.jane], listenLater: [.distance], checkpoints: [WorkID.film.rawValue: reading], lastWork: .film, startedBrowsing: true)
            snapshot.navigation = LibraryNavigationSnapshot(tab: .now, focus: .pool, reading: .film,
                                                           path: [.work(.film)], collectionPath: [])
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            object.removeValue(forKey: "graphCheckpoints")
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: persistence.key)
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertNil(restored.persistenceError)
            XCTAssertEqual(restored.saved, [.jane])
            XCTAssertEqual(restored.listenLater, [.distance])
            XCTAssertEqual(restored.reading, .film)
            XCTAssertEqual(restored.checkpoints[WorkID.film.rawValue], reading)
            XCTAssertTrue(restored.graphCheckpoints.isEmpty)
        }
    }

    func testUntrustedGraphStateIsBoundedBeforeItReachesTheView() throws {
        try withLibrary { _, defaults, catalog in
            let history = (0..<120).map { index in
                GraphTrailEntry(id: index.isMultiple(of: 2) ? .pool : .film,
                                page: index.isMultiple(of: 2) ? Int.min : Int.max,
                                filter: index.isMultiple(of: 2) ? Int.max : Int.min)
            }
            let hostile = GraphCheckpoint(center: .film, history: history,
                                          page: Int.max, filter: Int.min, presentation: Int.max)
            var snapshot = LibrarySnapshot(lastWork: .pool, startedBrowsing: true)
            snapshot.navigation = LibraryNavigationSnapshot(tab: .now, focus: .pool, reading: .pool,
                                                           path: [.connections(.pool)], collectionPath: [])
            snapshot.graphCheckpoints = [WorkID.pool.rawValue: hostile]
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            defaults.set(try JSONEncoder().encode(snapshot), forKey: persistence.key)
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertNil(restored.persistenceError, "Out-of-range graph UI values should be safely normalized")
            let graph = try XCTUnwrap(restored.graphCheckpoints[WorkID.pool.rawValue])
            XCTAssertEqual(graph.page, 999)
            XCTAssertEqual(graph.filter, 0)
            XCTAssertEqual(graph.presentation, 1)
            XCTAssertEqual(graph.history.count, 40)
            XCTAssertEqual(graph.history.last?.id, history.last?.id)
            XCTAssertTrue(graph.history.allSatisfy { (0...999).contains($0.page) && (0...2).contains($0.filter) })
            // The graph view additionally clamps page to its actual filtered relation count.
        }
    }

    func testReviewGraphChangesDoNotOverwriteARealExploration() throws {
        try withLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.path = [.connections(.pool)]
            library.saveGraph(root: .pool, checkpoint: sampleGraph())
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            library.flushPendingWritesBeforeTermination()
            let original = try XCTUnwrap(defaults.data(forKey: persistence.key))
            let review = Library(defaults: defaults, arguments: ["--demo", "--relations=pool"], catalog: catalog)
            review.saveGraph(root: .pool, checkpoint: GraphCheckpoint(center: .utada, history: [], page: 0, filter: 2, presentation: 1))
            review.path = []
            review.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
            review.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(restored.graphCheckpoints[WorkID.pool.rawValue], sampleGraph())
        }
    }

    private func sampleGraph() -> GraphCheckpoint {
        GraphCheckpoint(center: .film, history: [GraphTrailEntry(id: .pool, page: 0, filter: 0)],
                        page: 1, filter: 0, presentation: 1)
    }

    private func withLibrary(_ body: (Library, UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.GraphTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        try body(library, defaults, catalog)
    }
}
