import XCTest
@testable import Pianwai

@MainActor final class PerformancePersistenceTests: XCTestCase {
    func testCatalogBatchesArrivalsUntilExplicitFlushAndReloadsLatestFacts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: file, bundle: Bundle(for: Self.self))
        let first = Work(id: WorkID(rawValue: "test:batched-first")!, title: "First", creator: "", kind: "作品", art: "", detail: "", url: nil)
        let second = Work(id: WorkID(rawValue: "test:batched-second")!, title: "Second", creator: "", kind: "作品", art: "", detail: "", url: nil)
        try store.merge(.init(works: [first], relations: []))
        try store.merge(.init(works: [second], relations: []))
        let expectedFirst = try XCTUnwrap(store.works[first.id])
        let expectedSecond = try XCTUnwrap(store.works[second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "A burst must not serialize the full catalog for every arrival")
        await store.flushPendingWrites()
        let restored = CatalogStore(cacheURL: file, bundle: Bundle(for: Self.self))
        XCTAssertEqual(restored.works[first.id], expectedFirst)
        XCTAssertEqual(restored.works[second.id], expectedSecond)
        XCTAssertNil(store.storageError)
    }

    func testEmptyMergeKeepsRevisionAndIdentityIndexWhileRealRefinementChangesIt() throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let revision = store.revision
        try store.merge(.init(works: [], relations: []))
        XCTAssertEqual(store.revision, revision)
        let item = Work(id: WorkID(rawValue: "test:revision")!, title: "Item", creator: "", kind: "作品", art: "", detail: "", url: nil)
        try store.merge(.init(works: [item], relations: []))
        XCTAssertGreaterThan(store.revision, revision)
        let installed = store.revision
        try store.merge(.init(works: [item], relations: []))
        XCTAssertEqual(store.revision, installed)
    }

    func testTerminationBarrierMakesTheNewestPendingCatalogDurable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: file, bundle: Bundle(for: Self.self))
        let item = Work(id: WorkID(rawValue: "test:termination")!, title: "Pending", creator: "", kind: "作品", art: "", detail: "", url: nil)
        try store.merge(.init(works: [item], relations: []))
        let expected = try XCTUnwrap(store.works[item.id])
        store.flushPendingWritesBeforeTermination()
        XCTAssertEqual(CatalogStore(cacheURL: file, bundle: Bundle(for: Self.self)).works[item.id], expected)
    }

    func testLibraryNavigationAndCollectionsShareOneFlushWithoutLosingState() async throws {
        let suite = "Pianwai.PerformancePersistence." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: NoApplePlatformFixture())
        library.explore(.pool)
        library.open(.film)
        library.toggleSaved(.jane)
        library.saveReading(.film, offset: 217)
        XCTAssertNil(defaults.data(forKey: "pianwai.library.v1"))
        await library.flushPendingWrites()
        let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: NoApplePlatformFixture())
        XCTAssertEqual(restored.path, [.work(.film)])
        XCTAssertEqual(restored.saved, [.jane])
        XCTAssertEqual(restored.checkpoints[WorkID.film.rawValue]?.offset, 217)
    }
}
