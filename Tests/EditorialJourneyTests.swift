import XCTest
@testable import Pianwai

@MainActor final class EditorialJourneyTests: XCTestCase {
    func testSourcedSongStoryCanOpenOfficialVideoAndSaveItWithoutStartingPlayback() throws {
        let store = CatalogStore(cacheURL: nil)
        XCTAssertNil(store.storageError)
        let song = WorkID(rawValue: "editorial:one-last-kiss")!
        let video = WorkID(rawValue: "editorial:one-last-kiss-mv")!
        let story = try XCTUnwrap(store.stories.first { $0.id == "editorial:story-one-last-kiss-remote-mv" })
        XCTAssertEqual(story.entityLinks["MV"], video)
        XCTAssertEqual(store.work(video).url, "https://www.youtube.com/watch?v=0Uhh62MUEic")
        XCTAssertTrue(store.work(video).isVideo)
        XCTAssertFalse(store.work(video).isSong)
        XCTAssertNil(store.work(video).catalogRecordingID)
        XCTAssertEqual(store.work(video).externalLinkTitle, "在 YouTube 中观看")
        XCTAssertTrue(store.edges.contains { $0.from == video && $0.to == song && $0.predicate == .musicVideoOf })

        let name = "Pianwai.Editorial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        library.explore(song)
        library.open(try XCTUnwrap(story.entityLinks["MV"]))
        library.toggleLater(video)
        library.toggleSaved(video)
        XCTAssertEqual(library.path.last, .work(video))
        XCTAssertEqual(library.later, [video])
        XCTAssertEqual(library.saved, [video])
        XCTAssertNil(library.currentTrack)
        XCTAssertNil(library.next)
        XCTAssertTrue(library.listenLater.isEmpty)
        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: store)
        XCTAssertEqual(restored.later, [video])
        XCTAssertEqual(restored.saved, [video])
    }

    func testCommissionReferenceRemainsDistinctAndVersionSearchKeepsReleaseContext() throws {
        let store = CatalogStore(cacheURL: nil)
        let original = WorkID(rawValue: "editorial:lotus-sim-city")!
        let commissioned = WorkID(rawValue: "editorial:rotation-lotus-2")!
        let film = WorkID(rawValue: "editorial:millennium-actress")!
        let relation = try XCTUnwrap(store.edges.first { $0.from == commissioned && $0.to == original })
        XCTAssertEqual(relation.predicate, .commissionReference)
        XCTAssertEqual(URLComponents(string: relation.source.url)?.host, "konstone.s-kon.net")
        XCTAssertNotEqual(store.canonicalID(for: original), store.canonicalID(for: commissioned))
        XCTAssertNil(store.work(original).catalogRecordingID)
        XCTAssertNil(store.work(commissioned).catalogRecordingID)
        XCTAssertEqual(store.work(film).knowledgeID, "Q939736")

        let name = "Pianwai.Editorial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        library.explore(film)
        library.findRecording(for: original)
        XCTAssertEqual(library.searchQuery, "Lotus 平沢進 Sim City")
        XCTAssertEqual(library.searchKind, .song)
        XCTAssertTrue(library.searchOnPresentation)
        XCTAssertTrue(library.searchPresented)
        XCTAssertEqual(library.reading, film)
        XCTAssertNil(library.currentTrack)
        XCTAssertTrue(library.saved.isEmpty)
    }

    func testEveryImportedStoryLinkExistsAndAdditionalSourcesSurviveDiskReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.Editorial.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: cache)
        XCTAssertNil(store.storageError)
        XCTAssertGreaterThanOrEqual(store.stories.count, 8)
        for story in store.stories {
            XCTAssertNotNil(store.works[story.workID])
            for (phrase, id) in story.entityLinks {
                XCTAssertTrue(story.body.contains(phrase), "Invisible link phrase: \(phrase)")
                XCTAssertNotNil(store.works[id])
            }
            for source in [story.source] + (story.additionalSources ?? []) {
                XCTAssertEqual(URLComponents(string: source.url)?.scheme, "https")
            }
        }
        let story = try XCTUnwrap(store.stories.first { $0.id == "editorial:story-kon-lotus-reference" })
        XCTAssertEqual(story.additionalSources?.count, 2)
        store.save()
        await store.flushPendingWrites()
        XCTAssertNil(store.storageError)
        let restored = CatalogStore(cacheURL: cache)
        XCTAssertEqual(restored.stories.first { $0.id == story.id }?.additionalSources, story.additionalSources)
        XCTAssertEqual(restored.work(WorkID(rawValue: "editorial:lotus-sim-city")!).versionSearchQuery, "Lotus 平沢進 Sim City")
    }
}
