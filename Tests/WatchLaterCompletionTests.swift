import XCTest
@testable import Pianwai

@MainActor
final class WatchLaterCompletionTests: XCTestCase {
    func testCompletingPendingVideoSurvivesRelaunchAndKeepsSavedWorksAndListeningState() throws {
        try withStorage { defaults, catalog in
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            try persistence.save(LibrarySnapshot(saved: [.animenz, .film], listenLater: [.distance],
                                                 watchLater: [.animenz, .film]))
            let library = makeLibrary(defaults, catalog)
            library.explore(.film)
            library.open(.manga)
            let path = library.path
            let reading = library.reading

            library.markWatched(.animenz)

            XCTAssertNil(library.persistenceError)
            XCTAssertEqual(library.later, [.film])
            XCTAssertEqual(library.watchedIDs, [.animenz])
            XCTAssertEqual(library.saved, [.animenz, .film])
            XCTAssertEqual(library.listenLater, [.distance])
            XCTAssertEqual(library.path, path)
            XCTAssertEqual(library.reading, reading)
            XCTAssertNil(library.currentTrack, "Marking watched is not a playback command")

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.later, [.film])
            XCTAssertEqual(restored.watchedIDs, [.animenz])
            XCTAssertEqual(restored.saved, [.animenz, .film])
            XCTAssertEqual(restored.listenLater, [.distance])
            XCTAssertEqual(restored.path, path)
            XCTAssertEqual(restored.reading, reading)
        }
    }

    func testRemovingPendingItemAndSavingAWorkDoNotMarkThemWatched() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            library.toggleSaved(.film)
            library.toggleLater(.animenz)
            library.toggleLater(.animenz) // A plain removal is not completion.
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            library.flushPendingWritesBeforeTermination()
            let before = try XCTUnwrap(defaults.data(forKey: persistence.key))

            library.markWatched(.animenz) // A stale action for an already-removed row.
            library.markWatched(.film) // A saved work was never in watch later.

            XCTAssertTrue(library.watchedIDs.isEmpty)
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), before,
                           "A stale completion must not rewrite unrelated saved state")
            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertTrue(restored.later.isEmpty)
            XCTAssertTrue(restored.watchedIDs.isEmpty)
            XCTAssertEqual(restored.saved, [.film])
        }
    }

    func testReaddingWatchedVideoCreatesANewPendingIntentWithoutErasingHistory() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            library.toggleLater(.animenz)
            library.markWatched(.animenz)
            library.toggleLater(.animenz)

            library.flushPendingWritesBeforeTermination()
            let pendingAgain = makeLibrary(defaults, catalog)
            XCTAssertEqual(pendingAgain.later, [.animenz])
            XCTAssertEqual(pendingAgain.watchedIDs, [.animenz],
                           "Wanting to watch again does not undo the previous completion")
            pendingAgain.markWatched(.animenz)
            pendingAgain.markWatched(.animenz) // Duplicate menu delivery is harmless.

            pendingAgain.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertTrue(restored.later.isEmpty)
            XCTAssertEqual(restored.watchedIDs, [.animenz])
        }
    }

    func testOlderSnapshotWithoutCompletionHistoryStillLoadsAndCanCompleteAnItem() throws {
        try withStorage { defaults, catalog in
            let old = Data(#"{"version":1,"saved":["film"],"listenLater":[],"watchLater":["animenz"],"recent":[],"checkpoints":{},"startedBrowsing":false,"country":"jp"}"#.utf8)
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            defaults.set(old, forKey: persistence.key)
            let library = makeLibrary(defaults, catalog)

            XCTAssertNil(library.persistenceError)
            XCTAssertTrue(library.watchedIDs.isEmpty)
            XCTAssertEqual(library.later, [.animenz])
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), old,
                           "Reading the old format must not rewrite it or lose its lists")
            library.markWatched(.animenz)

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.saved, [.film])
            XCTAssertTrue(restored.later.isEmpty)
            XCTAssertEqual(restored.watchedIDs, [.animenz])
        }
    }

    func testUnavailableCatalogItemCanBeCompletedWithoutLosingItsStableIdentity() throws {
        try withStorage { defaults, catalog in
            let unavailable = try XCTUnwrap(WorkID(rawValue: "wikidata:Q99887766"))
            XCTAssertNil(catalog.works[unavailable])
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            try persistence.save(LibrarySnapshot(saved: [unavailable], watchLater: [unavailable]))
            let library = makeLibrary(defaults, catalog)

            library.markWatched(unavailable)

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertTrue(restored.later.isEmpty)
            XCTAssertEqual(restored.watchedIDs, [unavailable])
            XCTAssertEqual(restored.saved, [unavailable])
        }
    }

    func testReviewCompletionDoesNotOverwriteRealWatchLaterOrCompletionHistory() throws {
        try withStorage { defaults, catalog in
            let real = makeLibrary(defaults, catalog)
            real.toggleLater(.film)
            real.markWatched(.film)
            real.toggleLater(.animenz)
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            real.flushPendingWritesBeforeTermination()
            let original = try XCTUnwrap(defaults.data(forKey: persistence.key))
            let demo = makeLibrary(defaults, catalog, arguments: ["--scene=collection"])

            demo.markWatched(.animenz)

            XCTAssertEqual(demo.watchedIDs, [.animenz])
            demo.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
            demo.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.later, [.animenz])
            XCTAssertEqual(restored.watchedIDs, [.film])
        }
    }

    private func withStorage(_ body: (UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.WatchLaterCompletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        try body(defaults, catalog)
    }

    private func makeLibrary(_ defaults: UserDefaults, _ catalog: CatalogStore, arguments: [String] = []) -> Library {
        Library(defaults: defaults, arguments: arguments, catalog: catalog, music: WatchCompletionMusicStub())
    }
}

@MainActor
private final class WatchCompletionMusicStub: MusicPlaybackClient {
    let snapshot = MusicPlaybackSnapshot(availability: .authorizationRequired, authorization: .notDetermined,
                                         subscription: .unknown, nowPlaying: nil, status: .stopped,
                                         elapsedTime: 0, capturedAt: Date(timeIntervalSince1970: 0))
    let commandInFlight: MusicPlaybackCommand? = nil
    var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
    func refresh() async { }
    func requestAuthorization() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func pause() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func resume() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func skipToNext() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { unexpectedCommand() }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { unexpectedCommand() }
    private func unexpectedCommand() -> MusicPlaybackActionResult {
        XCTFail("Watch completion must not issue playback commands")
        return .failure(.init(.configuration, "Playback is disabled for this test"))
    }
}
