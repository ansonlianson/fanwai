import XCTest
@testable import Pianwai

@MainActor final class FlashGraphIsolationTests: XCTestCase {
    private let provider = "flash-graph-test-v1"
    private let root = WorkID(rawValue: "local:p35-root")!
    private let old = WorkID(rawValue: "lead:film:p35-old")!
    private let fresh = WorkID(rawValue: "lead:film:p35-new")!
    private let other = WorkID(rawValue: "local:p35-other")!

    private func work(_ id: WorkID) -> Work {
        Work(id: id, title: id.rawValue, creator: "", kind: id == root || id == other ? "歌曲" : "电影",
             art: "", detail: "", url: nil)
    }
    private func edge(_ from: WorkID, _ to: WorkID, provider: String?, title: String = "线索") -> RelationEdge {
        RelationEdge(from: from, to: to, predicate: .publicRelation, label: "配乐出自", inverseLabel: "配乐",
                     source: Source(title: title, detail: "fixture", url: "https://example.com/source", researchProvider: provider))
    }

    func testSourceBackwardDecodeAndProviderRoundTrip() throws {
        let legacy = try JSONDecoder().decode(Source.self, from: Data(#"{"title":"线索","url":"https://example.com/source"}"#.utf8))
        XCTAssertNil(legacy.researchProvider)
        let review = Source(title: "线索", url: legacy.url, researchProvider: provider)
        let decoded = try JSONDecoder().decode(Source.self, from: JSONEncoder().encode(review))
        XCTAssertEqual(decoded, review)
    }

    func testAtomicReplacementKeepsOtherProvidersAndUnrelatedEdges() throws {
        let store = CatalogStore(cacheURL: nil)
        let gpt = edge(root, old, provider: nil)
        let review = edge(root, old, provider: provider)
        let unrelated = edge(other, old, provider: provider)
        let catalog = edge(old, root, provider: nil, title: "iTunes")
        XCTAssertNotEqual(gpt.id, review.id, "Provider identity must survive reconciliation of the same target/label")
        try store.merge(.init(works: [root, old, fresh, other].map(work), relations: [gpt, review, unrelated, catalog]))
        XCTAssertTrue(store.edges.contains { $0.id == gpt.id })
        XCTAssertTrue(store.edges.contains { $0.id == review.id })
        let replacement = edge(root, fresh, provider: provider)
        try store.replaceLeadRelations(from: root, with: .init(works: [], relations: [replacement]), researchProvider: provider)
        let ids = Set(store.edges.map(\.id))
        XCTAssertTrue(ids.contains(gpt.id)); XCTAssertFalse(ids.contains(review.id))
        XCTAssertTrue(ids.contains(replacement.id)); XCTAssertTrue(ids.contains(unrelated.id)); XCTAssertTrue(ids.contains(catalog.id))
        XCTAssertNotNil(store.works[old], "A collected old work must remain available")
        let invalid = RelationEdge(from: root, to: old, predicate: .publicRelation, label: "invalid", inverseLabel: "invalid",
                                   source: Source(title: "线索", url: "http://example.com/not-accepted", researchProvider: provider))
        XCTAssertThrowsError(try store.replaceLeadRelations(from: root, with: .init(works: [], relations: [invalid]), researchProvider: provider))
        XCTAssertEqual(Set(store.edges.map(\.id)), ids, "Failed replacement must not delete the current report")
    }

    func testProviderChoiceDoesNotFilterAcceptedTargetsAndAllFactsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("P35Graph-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: file)
        let gpt = edge(root, old, provider: nil)
        let review = edge(root, old, provider: provider)
        let incomingCatalog = edge(fresh, root, provider: nil, title: "iTunes")
        try store.merge(.init(works: [root, old, fresh].map(work), relations: [gpt, review, incomingCatalog]))
        let normal = PublicCrateInventory.directEdges(root, catalog: store, researchProvider: nil)
        let flash = PublicCrateInventory.directEdges(root, catalog: store, researchProvider: provider)
        XCTAssertEqual(normal.first { $0.other(than: root) == old }?.source.researchProvider, nil)
        XCTAssertEqual(Set(normal.map(\.id)), Set(flash.map(\.id)), "Model choice cannot hide an accepted fact")
        XCTAssertTrue(normal.contains { $0.id == incomingCatalog.id })
        XCTAssertTrue(flash.contains { $0.id == incomingCatalog.id }, "Nonresearch relations retain their existing bidirectional behavior")
        await store.flushPendingWrites()
        let saved = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file))
        XCTAssertTrue(saved.relations.contains { $0.id == gpt.id })
        XCTAssertTrue(saved.relations.contains { $0.id == review.id })
        XCTAssertTrue(saved.works.contains { $0.id == old }, "Review-created works remain available to collections")
    }

    func testReviewTrailNamespaceDoesNotReplaceOrEnumerateNormalTrails() throws {
        let suite = "P35.GraphTrails." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let normalStore = RelationTrailStore(defaults: defaults, cacheNamespace: "")
        let flashStore = RelationTrailStore(defaults: defaults, cacheNamespace: provider)
        var normal = RelationMapModel(root: "pool"); _ = normal.expand("pool", graph: .bundled)
        normalStore.save(normal)
        XCTAssertNil(flashStore.load(root: "pool"))
        var review = normal; review.setFocus("film")
        flashStore.save(review)
        XCTAssertEqual(normalStore.load(root: "pool"), normal)
        XCTAssertEqual(flashStore.load(root: "pool"), review)
        XCTAssertEqual(normalStore.entries().map(\.map), [normal])
        XCTAssertEqual(flashStore.entries().map(\.map), [review])
        flashStore.remove(root: "pool")
        XCTAssertNil(flashStore.load(root: "pool"))
        XCTAssertEqual(normalStore.load(root: "pool"), normal)
    }
}
