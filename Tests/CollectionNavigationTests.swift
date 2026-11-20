import XCTest
@testable import Pianwai

/// Persisted selection and navigation contracts. These do not substitute for
/// a simulator check of the segmented control or its rendered return position.
@MainActor
final class CollectionNavigationTests: XCTestCase {
    func testWatchLaterDetailRelaunchAndPopReturnToTheSameCollectionSection() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            library.explore(.pool)
            library.open(.film)
            let nowPath = library.path
            library.toggleSaved(.film)
            library.toggleListenLater(.distance)
            let cue = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(.animenz, cue: cue)
            let pending = try XCTUnwrap(library.watchLaterEntry(for: .animenz))

            library.tab = .collection
            library.collectionSection = .watchLater
            library.openWatchLater(pending)
            XCTAssertEqual(library.collectionPath, [.work(.animenz)])

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertNil(restored.persistenceError)
            XCTAssertEqual(restored.tab, .collection)
            XCTAssertEqual(restored.collectionSection, .watchLater)
            XCTAssertEqual(restored.collectionPath, [.work(.animenz)])
            XCTAssertEqual(restored.path, nowPath)
            XCTAssertEqual(restored.reading, .animenz)
            XCTAssertEqual(restored.watchLaterEntry(for: .animenz)?.cue, cue)
            XCTAssertNil(restored.videoCueFocus, "Restoring the page must not replay a navigation or playback command")

            restored.collectionPath.removeLast()
            XCTAssertTrue(restored.collectionPath.isEmpty)
            XCTAssertEqual(restored.collectionSection, .watchLater)
            XCTAssertEqual(restored.saved, [.film])
            XCTAssertEqual(restored.listenLater, [.distance])
            XCTAssertTrue(restored.watchedIDs.isEmpty)
            restored.flushPendingWritesBeforeTermination()
            let returned = makeLibrary(defaults, catalog)
            XCTAssertEqual(returned.tab, .collection)
            XCTAssertEqual(returned.collectionSection, .watchLater)
            XCTAssertTrue(returned.collectionPath.isEmpty)
            XCTAssertEqual(returned.watchLaterEntry(for: .animenz)?.cue, cue)
        }
    }

    func testEverySectionPersistsWithoutChangingEitherStackReadingOrMediaLists() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            library.toggleSaved(.film)
            library.toggleListenLater(.distance)
            library.toggleLater(.animenz)
            library.explore(.pool)
            library.open(.manga)
            library.tab = .collection
            library.open(.film)
            let nowPath = library.path
            let collectionPath = library.collectionPath
            let reading = library.reading

            for section in [CollectionSection.watchLater, .listenLater, .works] {
                library.collectionSection = section
                XCTAssertEqual(library.path, nowPath)
                XCTAssertEqual(library.collectionPath, collectionPath)
                XCTAssertEqual(library.reading, reading)
                XCTAssertNil(library.currentTrack)
                XCTAssertNil(library.next)
                library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
                XCTAssertEqual(restored.collectionSection, section)
                XCTAssertEqual(restored.path, nowPath)
                XCTAssertEqual(restored.collectionPath, collectionPath)
                XCTAssertEqual(restored.reading, reading)
                XCTAssertEqual(restored.saved, [.film])
                XCTAssertEqual(restored.listenLater, [.distance])
                XCTAssertEqual(restored.later, [.animenz])
            }
        }
    }

    func testLegacySnapshotDefaultsToWorksWithoutRewritingOrDroppingItsLists() throws {
        try withStorage { defaults, catalog in
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            let old = Data(#"{"version":1,"saved":["film"],"listenLater":["distance"],"watchLater":["animenz"],"recent":[],"checkpoints":{},"startedBrowsing":false,"country":"jp"}"#.utf8)
            defaults.set(old, forKey: persistence.key)
            let library = makeLibrary(defaults, catalog)

            XCTAssertNil(library.persistenceError)
            XCTAssertEqual(library.collectionSection, .works)
            XCTAssertEqual(library.saved, [.film])
            XCTAssertEqual(library.listenLater, [.distance])
            XCTAssertEqual(library.later, [.animenz])
            XCTAssertEqual(defaults.data(forKey: persistence.key), old)
            XCTAssertNil(defaults.object(forKey: persistence.backupKey))
        }
    }

    func testUnknownOrWronglyTypedSectionFallsBackWithoutClassifyingTheWholeSnapshotAsCorrupt() throws {
        try withStorage { defaults, catalog in
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            let navigation = LibraryNavigationSnapshot(tab: .collection, focus: .pool, reading: .animenz,
                                                        path: [.work(.film)], collectionPath: [.work(.animenz)])
            let snapshot = LibrarySnapshot(saved: [.film], listenLater: [.distance], watchLater: [.animenz],
                                           startedBrowsing: true, navigation: navigation)
            let encoded = try JSONEncoder().encode(snapshot)
            let base = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let unknownValues: [Any] = ["future-section", 99, ["watchLater"], ["kind": "watchLater"], NSNull()]

            for unknown in unknownValues {
                var object = base
                object["collectionSection"] = unknown
                let data = try JSONSerialization.data(withJSONObject: object)
                defaults.set(data, forKey: persistence.key)
                let library = makeLibrary(defaults, catalog)
                XCTAssertNil(library.persistenceError)
                XCTAssertEqual(library.collectionSection, .works)
                XCTAssertEqual(library.saved, [.film])
                XCTAssertEqual(library.listenLater, [.distance])
                XCTAssertEqual(library.later, [.animenz])
                XCTAssertEqual(library.path, navigation.path)
                XCTAssertEqual(library.collectionPath, navigation.collectionPath)
                XCTAssertEqual(defaults.data(forKey: persistence.key), data)
                XCTAssertNil(defaults.object(forKey: persistence.backupKey))

                library.collectionSection = .listenLater
                library.flushPendingWritesBeforeTermination()
                let repaired = makeLibrary(defaults, catalog)
                XCTAssertNil(repaired.persistenceError)
                XCTAssertEqual(repaired.collectionSection, .listenLater)
                XCTAssertEqual(repaired.saved, [.film])
                XCTAssertEqual(repaired.later, [.animenz])
                XCTAssertEqual(repaired.collectionPath, navigation.collectionPath)
            }
        }
    }

    func testInjectedPreferenceSuitesKeepIndependentCollectionSelections() throws {
        try withStorage { firstDefaults, firstCatalog in
            try withStorage { secondDefaults, secondCatalog in
                let first = makeLibrary(firstDefaults, firstCatalog)
                first.collectionSection = .watchLater
                first.toggleSaved(.film)
                let second = makeLibrary(secondDefaults, secondCatalog)
                XCTAssertEqual(second.collectionSection, .works)
                XCTAssertTrue(second.saved.isEmpty)
                second.collectionSection = .listenLater
                second.toggleSaved(.manga)

                first.flushPendingWritesBeforeTermination()
                second.flushPendingWritesBeforeTermination()
                let firstRestored = makeLibrary(firstDefaults, firstCatalog)
                let secondRestored = makeLibrary(secondDefaults, secondCatalog)
                XCTAssertEqual(firstRestored.collectionSection, .watchLater)
                XCTAssertEqual(secondRestored.collectionSection, .listenLater)
                XCTAssertEqual(firstRestored.saved, [.film])
                XCTAssertEqual(secondRestored.saved, [.manga])
            }
        }
    }

    func testCollectionLaunchShortcutOnlyAffectsAnIsolatedDemo() throws {
        try withStorage { defaults, catalog in
            let real = makeLibrary(defaults, catalog)
            real.explore(.pool)
            real.toggleSaved(.film)
            real.collectionSection = .listenLater
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            real.flushPendingWritesBeforeTermination()
            let original = try XCTUnwrap(defaults.data(forKey: persistence.key))

            let demo = makeLibrary(defaults, catalog, arguments: ["--scene=collection", "--collection=later"])
            XCTAssertTrue(demo.demoMode)
            XCTAssertEqual(demo.tab, .collection)
            XCTAssertEqual(demo.collectionSection, .watchLater)
            demo.collectionSection = .works
            demo.toggleSaved(.manga)
            XCTAssertEqual(defaults.data(forKey: persistence.key), original,
                           "Review selection and actions cannot overwrite the injected real snapshot")

            let normal = makeLibrary(defaults, catalog, arguments: ["--collection=later"])
            XCTAssertFalse(normal.demoMode)
            XCTAssertEqual(normal.tab, .now, "A standalone review shortcut must not force the normal app into collection")
            XCTAssertEqual(normal.collectionSection, .listenLater)
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
            normal.collectionSection = .watchLater
            normal.toggleSaved(.manga)
            normal.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.collectionSection, .watchLater)
            XCTAssertTrue(restored.saved.contains(.manga), "Ignoring a stray shortcut must not silently disable normal persistence")
            XCTAssertTrue(restored.saved.contains(.film))
        }
    }

    private func withStorage(_ body: (UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.CollectionNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self)))
    }

    private func makeLibrary(_ defaults: UserDefaults, _ catalog: CatalogStore, arguments: [String] = []) -> Library {
        Library(defaults: defaults, arguments: arguments, catalog: catalog, music: CollectionNavigationMusicStub())
    }
}

@MainActor
private final class CollectionNavigationMusicStub: MusicPlaybackClient {
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
        XCTFail("Switching or restoring a collection section must not issue Apple Music commands")
        return .failure(.init(.configuration, "Playback is disabled for this test"))
    }
}
