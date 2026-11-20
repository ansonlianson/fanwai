import XCTest
@testable import Pianwai

@MainActor final class CollectionWallTests: XCTestCase {
    func testOrderedBoxAndNaturalCompletionPersistWithoutTreatingSkipAsCompletion() async throws {
        let suite = "Pianwai.Tests.Wall." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let music = WallMusicStub()
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: music)
        library.toggleListenLater(.pool); library.toggleListenLater(.jane)
        library.moveListenLater(.pool, toPositionOf: .jane)
        library.moveListenLater(.pool, toPositionOf: .jane)
        XCTAssertEqual(library.listenLater, [.jane, .pool], "Dragging forward must also move the sleeve")
        library.moveListenLater(.pool, toPositionOf: .jane)
        library.recordCollectionOrigin(.film, from: "pool")
        let accepted = await library.playListenLater()
        XCTAssertTrue(accepted)
        XCTAssertEqual(music.selections.map(\.catalogID), [catalog.work(.pool).catalogRecordingID!, catalog.work(.jane).catalogRecordingID!])
        XCTAssertEqual(library.listenLater, [.pool, .jane], "Queue acceptance is not having listened")

        library.receivePlayback(music.sample(.pool, occurrence: "one", elapsed: 20))
        library.receivePlayback(music.sample(.jane, occurrence: "two", elapsed: 0))
        XCTAssertEqual(library.listenLater, [.pool, .jane], "Skipping early must not empty the box")
        library.receivePlayback(music.sample(.pool, occurrence: "three", elapsed: 179))
        library.receivePlayback(music.sample(.jane, occurrence: "four", elapsed: 0))
        XCTAssertEqual(library.listenLater, [.jane]); XCTAssertEqual(library.listenedIDs, [.pool])
        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: music)
        XCTAssertEqual(restored.listenLater, [.jane]); XCTAssertEqual(restored.listenedIDs, [.pool])
        XCTAssertEqual(restored.collectionOrigins["film"], "pool")

        library.toggleListenLater(.distanceAlbum)
        let album = try XCTUnwrap(catalog.work(.distanceAlbum).queueSelection)
        XCTAssertEqual(album.kind, .album)
        let albumAccepted = await library.playListenLater()
        XCTAssertTrue(albumAccepted); XCTAssertEqual(music.selections.first, album)
        library.queueCollectedRecordNext(.distanceAlbum)
        for _ in 0..<20 where music.inserted.isEmpty { await Task.yield() }
        XCTAssertEqual(music.inserted, [album]); XCTAssertEqual(library.next, .distanceAlbum)
        var lastTrack = music.sample(.pool, occurrence: "album-last", elapsed: 179)
        lastTrack.collectionEnd = album
        library.receivePlayback(lastTrack)
        library.receivePlayback(music.sample(.jane, occurrence: "after-album", elapsed: 0))
        XCTAssertFalse(library.listenLater.contains(.distanceAlbum)); XCTAssertTrue(library.listenedIDs.contains(.distanceAlbum))
        library.receivePlayback(music.sample(.jane, occurrence: "after-album", elapsed: 179))
        let ended = music.sample(.jane, occurrence: "after-album", elapsed: 180, stopped: true)
        library.receivePlayback(ended)
        XCTAssertTrue(library.listenLater.isEmpty, "A final song can finish while MusicKit retains its entry")
    }
    func testShelfReorderCompletionAndTrailRestoreUseWholeStoredState() throws {
        let suite = "Pianwai.Tests.WallRestore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: WallMusicStub())
        library.toggleLater(.film); library.toggleLater(.manga)
        let film = try XCTUnwrap(library.watchLaterEntry(for: .film))
        let manga = try XCTUnwrap(library.watchLaterEntry(for: .manga))
        library.moveWatchLater(film.id, toPositionOf: manga.id)
        XCTAssertEqual(library.later, [.film, .manga])
        library.markWatched(.film)
        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: WallMusicStub())
        XCTAssertEqual(restored.later, [.manga]); XCTAssertEqual(restored.watchedIDs, [.film])
        var map = RelationMapModel(root: "pool")
        for id in ["pool", "film", "jane", "iris"] { _ = map.expand(id, graph: .bundled) }
        map.setFocus("jane"); map.camera = MapCamera(x: 139, y: 318, scale: 0.73)
        let store = RelationTrailStore(defaults: defaults); store.save(map)
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.map, map)
        let date = entry.updatedAt
        store.save(map)
        XCTAssertEqual(store.entries().first?.updatedAt, date, "Opening an unchanged footprint is not a new visit")
    }
}

@MainActor private final class WallMusicStub: MusicPlaybackClient {
    var selections: [MusicQueueSelection] = []
    var inserted: [MusicQueueSelection] = []
    var snapshot = MusicPlaybackSnapshot(availability: .ready, authorization: .authorized, subscription: .unknown, nowPlaying: nil, status: .stopped, elapsedTime: 0, capturedAt: Date())
    var commandInFlight: MusicPlaybackCommand? { nil }
    var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
    func refresh() async {}
    func requestAuthorization() async -> MusicPlaybackActionResult { unsupported() }
    func pause() async -> MusicPlaybackActionResult { unsupported() }
    func resume() async -> MusicPlaybackActionResult { unsupported() }
    func skipToNext() async -> MusicPlaybackActionResult { unsupported() }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { unsupported() }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { unsupported() }
    func playCollection(_ values: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        selections = values
        return .success(.init(command: .playNow, catalogID: values.first?.catalogID, verification: .acceptedBySystem))
    }
    func insertCollectionNext(_ values: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        inserted = values
        return .success(.init(command: .insertNext, catalogID: values.first?.catalogID, verification: .acceptedBySystem))
    }
    private func unsupported() -> MusicPlaybackActionResult { .failure(.init(.configuration, "Test boundary")) }
    func sample(_ id: WorkID, occurrence: String, elapsed: Double, stopped: Bool = false) -> MusicPlaybackSnapshot {
        .init(availability: .ready, authorization: .authorized, subscription: .unknown,
              nowPlaying: .init(id: id.rawValue, catalogID: id.work.catalogRecordingID, title: id.work.title, artist: id.work.creator, albumTitle: nil, artworkURL: nil, duration: 180, source: .musicKit),
              status: stopped ? .stopped : .playing, elapsedTime: elapsed, capturedAt: Date(), currentEntryID: occurrence)
    }
}
