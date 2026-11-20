import XCTest
@testable import Pianwai

@MainActor final class SeedLibraryBridgeTests: XCTestCase {
    func testRecordingCreditsStayAsAppleSuppliedAndAliasesAreNotReplacedTwice() throws {
        let catalog = CatalogStore(cacheURL: nil)
        var person = catalog.work(.utada); person.knowledgeID = "Q234598"
        try catalog.merge(.init(works: [person], relations: []))
        let other = Work(id: WorkID(rawValue: "test:credit-once")!, title: "Related work", creator: "宇多田光",
            kind: "作品", art: "", detail: "", url: nil, linkedCreatorIDs: [.utada])
        XCTAssertEqual(VerifiedDisplayName.creator(other, catalog: catalog), "宇多田光")
        let recording = Work(id: WorkID(rawValue: "apple:song:1987654321")!, title: "あなた", creator: "宇多田ヒカル",
            kind: "歌曲", art: "", detail: "", url: "https://music.apple.com/jp/song/1987654321", linkedCreatorIDs: [.utada], catalogID: "1987654321")
        XCTAssertEqual(VerifiedDisplayName.creator(recording, catalog: catalog), "宇多田ヒカル")
    }
    func testListenAndWishPersistAndDoNotConfuseSameNamedAlbum() throws {
        let suite = "Pianwai.Tests.SeedLibrary." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let graph = try SeedGraph.load(bundle: Bundle(for: Library.self))
        let jane = try XCTUnwrap(graph["jane"])
        let film = try XCTUnwrap(graph["film"])
        let distance = try XCTUnwrap(graph["distance"])
        try SeedLibraryBridge.save(jane, into: library)
        try SeedLibraryBridge.save(jane, into: library)
        try SeedLibraryBridge.save(film, into: library)
        try SeedLibraryBridge.save(distance, into: library)
        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
        XCTAssertTrue(SeedLibraryBridge.saved(jane, in: restored))
        XCTAssertTrue(SeedLibraryBridge.saved(film, in: restored))
        XCTAssertTrue(SeedLibraryBridge.saved(distance, in: restored))
        XCTAssertEqual(restored.saved.filter { $0 == .jane }.count, 1, "a second ☆ on a starred song does not add it twice")
        XCTAssertTrue(restored.listenLater.isEmpty, "收藏 is not a play queue")
        XCTAssertNotEqual(SeedLibraryBridge.workID("distance"), .distance)
        XCTAssertEqual(catalog.work(SeedLibraryBridge.workID("distance")).kind, "专辑")
    }
}
