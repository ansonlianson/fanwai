import XCTest
@testable import Pianwai

@MainActor final class CrateOrderingTests: XCTestCase {
    private func fixture() throws -> (Library, [CrateItem], UserDefaults) {
        let suite = "ARCH2.order." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let ids = ["root", "other", "a", "b", "c", "d"].map { WorkID(rawValue: "local:" + $0)! }
        try catalog.merge(.init(works: ids.map { .init(id: $0, title: $0.rawValue, creator: "", kind: "歌曲", art: "", detail: "", url: nil) }, relations: []))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: NoApplePlatformFixture())
        let items = ids.dropFirst(2).map { CrateItem(entity: SeedLibraryBridge.entity(for: $0, in: library), relation: "改编", path: [ids[0].rawValue, $0.rawValue]) }
        return (library, items, defaults)
    }
    func testSavedAndOtherArchiveMoveForwardWithoutChangingMembershipPathsOrFacts() throws {
        let (library, items, _) = try fixture()
        library.listenLater = [WorkID(rawValue: "local:d")!]
        try library.catalog.merge(.init(works: [], relations: [
            .init(from: WorkID(rawValue: "local:other")!, to: WorkID(rawValue: "local:c")!, predicate: .coverOf,
                label: "翻唱", inverseLabel: "翻唱版本", source: .init(title: "线索", url: "https://example.com/evidence"), researchRoot: WorkID(rawValue: "local:other")!)
        ]))
        let edges = library.catalog.edges.map(\.id), saved = library.listenLater
        let result = CrateOrdering.ordered(items, from: "local:root", library: library)
        XCTAssertEqual(result.map(\.id), ["local:d", "local:c", "local:a", "local:b"])
        XCTAssertEqual(result.map(\.id).sorted(), items.map(\.id).sorted())
        for item in result { XCTAssertEqual(item.path, items.first { $0.id == item.id }?.path) }
        XCTAssertEqual(library.catalog.edges.map(\.id), edges); XCTAssertEqual(library.listenLater, saved)
    }
    func testLocalExplicitOpensPersistAndOnlyChangeOrder() throws {
        let (library, items, defaults) = try fixture()
        let old = InterestEvent(entityID: items[1].id, fromEntityID: "local:root", relation: "改编", at: .init(timeIntervalSince1970: 1))
        defaults.set(try JSONEncoder().encode([old]), forKey: "redesign.interests")
        let edges = library.catalog.edges.map(\.id)
        library.crateExploration.record(items[2], from: "local:root", at: .init(timeIntervalSince1970: 2))
        library.crateExploration.record(items[2], from: "local:root", at: .init(timeIntervalSince1970: 3))
        XCTAssertEqual(CrateExploration(defaults: defaults).interests.count, 3)
        XCTAssertEqual(CrateOrdering.ordered(items, from: "local:root", library: library).map(\.id), ["local:c", "local:b", "local:a", "local:d"])
        XCTAssertEqual(library.catalog.edges.map(\.id), edges); XCTAssertTrue(library.saved.isEmpty)
    }
    func testCurrentArchiveAndSimilarNamesDoNotCreateCrossSongIdentity() throws {
        let (library, items, _) = try fixture()
        let other = WorkID(rawValue: "local:lookalike")!
        try library.catalog.merge(.init(works: [.init(id: other, title: items[2].entity.title, creator: "", kind: "歌曲", art: "", detail: "", url: nil)], relations: [
            .init(from: WorkID(rawValue: "local:other")!, to: other, predicate: .coverOf, label: "翻唱", inverseLabel: "翻唱版本", source: .init(title: "线索", url: "https://example.com/other"), researchRoot: WorkID(rawValue: "local:other")!),
            .init(from: WorkID(rawValue: "local:root")!, to: WorkID(rawValue: "local:d")!, predicate: .coverOf, label: "翻唱", inverseLabel: "翻唱版本", source: .init(title: "线索", url: "https://example.com/root"), researchRoot: WorkID(rawValue: "local:root")!)
        ]))
        XCTAssertEqual(CrateOrdering.ordered(items, from: "local:root", library: library).map(\.id), items.map(\.id))
    }
}
