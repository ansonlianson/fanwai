import XCTest
@testable import Pianwai

@MainActor
final class BackgroundReadingPersistenceTests: XCTestCase {
    func testLegacySnapshotFieldsRestoreReadingWithoutRewritingChosenExcerpt() throws {
        let variants: [(String, Bool?, String?)] = [
            (#"{"version":1,"saved":[],"listenLater":[],"watchLater":[],"recent":[],"checkpoints":{"film":{"workID":"film","offset":211.5,"updatedAt":0}},"startedBrowsing":false,"country":"jp"}"#, nil, nil),
            (#"{"version":1,"saved":[],"listenLater":[],"watchLater":[],"recent":[],"checkpoints":{"film":{"workID":"film","offset":211.5,"updatedAt":0,"backgroundExpanded":true}},"startedBrowsing":false,"country":"jp"}"#, true, nil),
            (#"{"version":1,"saved":[],"listenLater":[],"watchLater":[],"recent":[],"checkpoints":{"film":{"workID":"film","offset":211.5,"updatedAt":0,"backgroundExpanded":true,"backgroundSecondExcerptID":"en:60304198:1383036815:7:4"}},"startedBrowsing":false,"country":"jp"}"#, true, "en:60304198:1383036815:7:4")
        ]
        for (json, expansion, chosenID) in variants {
            try withStorage { defaults, catalog in
                let legacy = Data(json.utf8)
                let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
                defaults.set(legacy, forKey: persistence.key)

                let restored = makeLibrary(defaults: defaults, catalog: catalog)

                XCTAssertNil(restored.persistenceError)
                let checkpoint = try XCTUnwrap(restored.checkpoints[WorkID.film.rawValue])
                XCTAssertEqual(checkpoint.workID, .film)
                XCTAssertEqual(checkpoint.offset, 211.5)
                XCTAssertEqual(checkpoint.backgroundExpanded, expansion)
                XCTAssertEqual(checkpoint.backgroundSecondExcerptID, chosenID,
                               "An existing original excerpt ID stays opaque to reading persistence; it must not become a focused ID")
                restored.flushPendingWritesBeforeTermination()
                XCTAssertEqual(defaults.data(forKey: persistence.key), legacy,
                               "Reading an older snapshot must not require destructive migration")
            }
        }
    }

    func testChosenSecondSurvivesExpansionScrollColdLaunchCollapseAndReopen() throws {
        try withStorage { defaults, catalog in
            let chosenID = "en:60304198:1383036815:7:4"
            let library = makeLibrary(defaults: defaults, catalog: catalog)
            library.setBackgroundExpanded(.film, expanded: true, secondID: chosenID)
            library.saveReading(.film, offset: 417.25)

            library.flushPendingWritesBeforeTermination()
            let expanded = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(expanded.checkpoints[WorkID.film.rawValue]?.backgroundExpanded, true)
            XCTAssertEqual(expanded.checkpoints[WorkID.film.rawValue]?.offset, 417.25)
            XCTAssertEqual(expanded.checkpoints[WorkID.film.rawValue]?.backgroundSecondExcerptID, chosenID)

            expanded.setBackgroundExpanded(.film, expanded: false)
            expanded.saveReading(.film, offset: 194.25)
            expanded.flushPendingWritesBeforeTermination()
            let collapsed = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(collapsed.checkpoints[WorkID.film.rawValue]?.backgroundExpanded, false)
            XCTAssertEqual(collapsed.checkpoints[WorkID.film.rawValue]?.offset, 194.25)
            XCTAssertEqual(collapsed.checkpoints[WorkID.film.rawValue]?.backgroundSecondExcerptID, chosenID)

            collapsed.setBackgroundExpanded(.film, expanded: true)
            collapsed.flushPendingWritesBeforeTermination()
            let reopened = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(reopened.checkpoints[WorkID.film.rawValue]?.backgroundExpanded, true)
            XCTAssertEqual(reopened.checkpoints[WorkID.film.rawValue]?.offset, 194.25)
            XCTAssertEqual(reopened.checkpoints[WorkID.film.rawValue]?.backgroundSecondExcerptID, chosenID,
                           "Reopening must keep the account already chosen, without requiring a new prepare result")
        }
    }

    func testSubsequentOffsetSavesRetainBothExplicitExpansionStates() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults: defaults, catalog: catalog)
            library.setBackgroundExpanded(.film, expanded: true, secondID: "chosen-second")
            for (expanded, offset) in [(true, 728.5), (false, 194.25)] {
                library.setBackgroundExpanded(.film, expanded: expanded)
                library.saveReading(.film, offset: offset)

                library.flushPendingWritesBeforeTermination()
                let recreated = makeLibrary(defaults: defaults, catalog: catalog)
                let checkpoint = try XCTUnwrap(recreated.checkpoints[WorkID.film.rawValue])
                XCTAssertEqual(checkpoint.offset, offset)
                XCTAssertEqual(checkpoint.backgroundExpanded, expanded,
                               "Scroll callbacks must not erase the reader's explicit expansion choice")
                XCTAssertEqual(checkpoint.backgroundSecondExcerptID, "chosen-second")
            }
        }
    }

    func testAliasNormalizationKeepsNewestOffsetAndExpansionAsOneCheckpoint() throws {
        try withStorage { defaults, catalog in
            let alias = try XCTUnwrap(WorkID(rawValue: "apple:song:1837522108"))
            XCTAssertEqual(catalog.canonicalID(for: alias), .pool)
            let old = ReadingCheckpoint(workID: .pool, offset: 85, updatedAt: Date(timeIntervalSince1970: 100),
                                        backgroundExpanded: false, backgroundSecondExcerptID: "older-second")
            let latest = ReadingCheckpoint(workID: alias, offset: 504.75, updatedAt: Date(timeIntervalSince1970: 200),
                                           backgroundExpanded: true, backgroundSecondExcerptID: "newer-second")
            let snapshot = LibrarySnapshot(checkpoints: [WorkID.pool.rawValue: old, alias.rawValue: latest])
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            // Write the historical aliases directly so the load path performs normalization.
            defaults.set(try JSONEncoder().encode(snapshot), forKey: persistence.key)

            let restored = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(Set(restored.checkpoints.keys), [WorkID.pool.rawValue])
            let checkpoint = try XCTUnwrap(restored.checkpoints[WorkID.pool.rawValue])
            XCTAssertEqual(checkpoint.workID, .pool)
            XCTAssertEqual(checkpoint.offset, 504.75)
            XCTAssertEqual(checkpoint.backgroundExpanded, true)
            XCTAssertEqual(checkpoint.backgroundSecondExcerptID, "newer-second")

            restored.setBackgroundExpanded(alias, expanded: false)
            XCTAssertEqual(restored.checkpoints[WorkID.pool.rawValue]?.offset, 504.75)
            restored.saveReading(alias, offset: 620.5)
            restored.flushPendingWritesBeforeTermination()
            let recreated = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(Set(recreated.checkpoints.keys), [WorkID.pool.rawValue])
            XCTAssertEqual(recreated.checkpoints[WorkID.pool.rawValue]?.offset, 620.5)
            XCTAssertEqual(recreated.checkpoints[WorkID.pool.rawValue]?.backgroundExpanded, false)
            XCTAssertEqual(recreated.checkpoints[WorkID.pool.rawValue]?.backgroundSecondExcerptID, "newer-second")
        }
    }

    func testDemoExpansionAndScrollChangesDoNotOverwriteRealReadingState() throws {
        try withStorage { defaults, catalog in
            let real = makeLibrary(defaults: defaults, catalog: catalog)
            real.saveReading(.film, offset: 333)
            real.setBackgroundExpanded(.film, expanded: true, secondID: "real-second")
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            real.flushPendingWritesBeforeTermination()
            let original = try XCTUnwrap(defaults.data(forKey: persistence.key))
            let demo = makeLibrary(defaults: defaults, catalog: catalog, arguments: ["--demo"])

            demo.setBackgroundExpanded(.film, expanded: true, secondID: "demo-second")
            demo.setBackgroundExpanded(.film, expanded: false)
            demo.saveReading(.film, offset: 10)

            XCTAssertEqual(demo.checkpoints[WorkID.film.rawValue]?.backgroundExpanded, false)
            XCTAssertEqual(demo.checkpoints[WorkID.film.rawValue]?.backgroundSecondExcerptID, "demo-second")
            demo.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
            demo.flushPendingWritesBeforeTermination()
            let recreated = makeLibrary(defaults: defaults, catalog: catalog)
            XCTAssertEqual(recreated.checkpoints[WorkID.film.rawValue]?.offset, 333)
            XCTAssertEqual(recreated.checkpoints[WorkID.film.rawValue]?.backgroundExpanded, true)
            XCTAssertEqual(recreated.checkpoints[WorkID.film.rawValue]?.backgroundSecondExcerptID, "real-second")
        }
    }

    private func withStorage(_ body: (UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.BackgroundReading.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        try body(defaults, catalog)
    }

    private func makeLibrary(defaults: UserDefaults, catalog: CatalogStore, arguments: [String] = []) -> Library {
        Library(defaults: defaults, arguments: arguments, catalog: catalog, music: BackgroundReadingMusicStub())
    }
}

@MainActor
private final class BackgroundReadingMusicStub: MusicPlaybackClient {
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
        XCTFail("Reading persistence must not issue playback commands")
        return .failure(.init(.configuration, "Playback is disabled for this test"))
    }
}
