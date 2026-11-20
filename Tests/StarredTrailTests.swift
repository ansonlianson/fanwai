import XCTest
@testable import Pianwai

/// A starred song keeps its relation map, however deep it was dug (anson 11-20): 清除浏览记录
/// leaves it, and slimming the catalogue keeps every work on it.
@MainActor final class StarredTrailTests: XCTestCase {
    func testStarredSongKeepsItsMapThroughClearingAndSlimming() throws {
        let suite = "Pianwai.Tests.StarredTrail." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let graph = try SeedGraph.load(bundle: Bundle(for: Library.self))
        let pool = try XCTUnwrap(graph["pool"]), jane = try XCTUnwrap(graph["jane"])
        XCTAssertTrue(pool.kind.isMusic); XCTAssertTrue(jane.kind.isMusic)

        let trails = RelationTrailStore(defaults: defaults)
        var kept = RelationMapModel(root: "pool")
        for id in ["pool", "film", "jane"] { _ = kept.expand(id, graph: .bundled) }
        XCTAssertGreaterThan(kept.nodes.count, 3, "the starred map was dug a few levels")
        var other = RelationMapModel(root: "jane")
        _ = other.expand("jane", graph: .bundled)
        trails.save(kept); trails.save(other)

        try SeedLibraryBridge.save(pool, into: library)
        XCTAssertTrue(SeedLibraryBridge.saved(pool, in: library))
        XCTAssertFalse(SeedLibraryBridge.saved(jane, in: library))
        XCTAssertEqual(library.starredTrailRoots(trails.roots()), ["pool"])

        let retained = library.retainedWorkIDs(trails: trails)
        XCTAssertTrue(retained.isSuperset(of: kept.nodes.keys.map(SeedLibraryBridge.workID)), "every work on the starred map stays on disk")

        library.clearRelationTrails(trails)
        XCTAssertEqual(trails.load(root: "pool"), kept, "清除浏览记录 leaves the starred song's map as it was")
        XCTAssertNil(trails.load(root: "jane"), "an unstarred map is cleared")

        SeedLibraryBridge.unsave(pool, in: library)
        XCTAssertFalse(SeedLibraryBridge.saved(pool, in: library))
        XCTAssertTrue(library.starredTrailRoots(trails.roots()).isEmpty)
        library.clearRelationTrails(trails)
        XCTAssertNil(trails.load(root: "pool"), "once unstarred, the map is ordinary history again")
    }
}
