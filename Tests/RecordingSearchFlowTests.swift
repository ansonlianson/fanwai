import XCTest
@testable import Pianwai

/// Model presentation contracts only; these do not prove SwiftUI sheet timing.
@MainActor
final class RecordingSearchFlowTests: XCTestCase {
    func testSongSheetDefersRecordingSearchUntilDismissalWithoutChangingListeningSession() throws {
        try withLibrary { library, song, music in
            library.songSheet = song
            let before = Continuity(library)

            library.findRecording(for: song)

            XCTAssertNil(library.songSheet)
            XCTAssertFalse(library.searchPresented, "Do not present another sheet while the song sheet is dismissing")
            assertPreparedSearch(library)
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)

            library.songSheetDidDismiss()
            XCTAssertTrue(library.searchPresented)
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)

            // A late duplicate dismissal callback must not reopen a closed search.
            library.searchPresented = false
            library.songSheetDidDismiss()
            XCTAssertFalse(library.searchPresented)
        }
    }

    func testWorkPageOpensPrefilledSongSearchImmediatelyWithoutQueueingOrNavigating() throws {
        try withLibrary { library, song, music in
            let before = Continuity(library)

            library.findRecording(for: song)

            XCTAssertNil(library.songSheet)
            XCTAssertTrue(library.searchPresented)
            assertPreparedSearch(library)
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)
            XCTAssertNil(library.pendingSong)
            XCTAssertNil(library.activePlaybackCommand)
            XCTAssertFalse(library.catalog.work(song).hasCatalogRecording,
                           "Finding a version must not assign an unverified recording identity")
        }
    }

    func testOrdinarySongSheetDismissalDoesNotStartOrResetSearch() throws {
        try withLibrary { library, song, music in
            library.songSheet = song
            let before = Continuity(library)
            library.songSheet = nil

            library.songSheetDidDismiss()

            XCTAssertFalse(library.searchPresented)
            XCTAssertFalse(library.searchOnPresentation)
            XCTAssertEqual(library.searchQuery, "Previous book search")
            XCTAssertEqual(library.searchKind, .ebook)
            XCTAssertEqual(library.searchResults, [.manga])
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)
        }
    }

    func testOneLastKissMusicWorkOpensSongSearchAndRetainsItsKnowledgeIdentity() throws {
        try withLibrary(kind: "音乐作品", qid: "Q108033774", title: "One Last Kiss", creator: "宇多田光") { library, single, music in
            let before = Continuity(library)
            let workCount = library.catalog.works.count

            library.findRecording(for: single)

            XCTAssertTrue(library.searchPresented)
            XCTAssertTrue(library.searchOnPresentation)
            XCTAssertEqual(library.searchKind, .song)
            XCTAssertEqual(library.searchQuery, "One Last Kiss 宇多田光")
            XCTAssertTrue(library.searchResults.isEmpty)
            XCTAssertEqual(library.catalog.work(single).kind, "音乐作品")
            XCTAssertEqual(library.catalog.work(single).knowledgeID, "Q108033774")
            XCTAssertEqual(library.catalog.canonicalID(for: single), single)
            XCTAssertEqual(library.catalog.works.count, workCount)
            XCTAssertNil(library.catalog.work(single).catalogRecordingID)
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)
        }
    }

    func testKnowledgeSoundtrackOpensAlbumSearchWithoutQueueingARelease() throws {
        try withLibrary(kind: "专辑", qid: "Q3894905", title: "Paprika", creator: "平沢進") { library, album, music in
            let before = Continuity(library)

            library.findRecording(for: album)

            XCTAssertTrue(library.searchPresented)
            XCTAssertTrue(library.searchOnPresentation)
            XCTAssertEqual(library.searchKind, .album)
            XCTAssertEqual(library.searchQuery, "Paprika 平沢進")
            XCTAssertTrue(library.searchResults.isEmpty)
            XCTAssertEqual(library.catalog.work(album).kind, "专辑")
            XCTAssertEqual(library.catalog.work(album).knowledgeID, "Q3894905")
            XCTAssertNil(library.catalog.work(album).catalogRecordingID)
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)
        }
    }

    func testExistingCatalogAlbumAndNonMusicWorkDoNotTriggerVersionLookup() throws {
        try withLibrary { library, _, music in
            let before = Continuity(library)
            for id in [WorkID.poolAlbum, .film, .manga] {
                library.findRecording(for: id)
                XCTAssertFalse(library.searchPresented)
                XCTAssertFalse(library.searchOnPresentation)
                XCTAssertEqual(library.searchQuery, "Previous book search")
                XCTAssertEqual(library.searchKind, .ebook)
                XCTAssertEqual(library.searchResults, [.manga])
            }
            XCTAssertEqual(Continuity(library), before)
            XCTAssertTrue(music.calls.isEmpty)
        }
    }

    func testSearchResultSelectionContinuesEitherOriginStackWithoutChangingPlayback() throws {
        for tab in [AppTab.now, .collection] {
            try withLibrary { library, song, music in
                library.tab = tab
                if tab == .collection { library.collectionPath = [.work(song)] }
                let nowPath = library.path
                let collectionPath = library.collectionPath
                let listening = ListeningState(library)
                let saved = library.saved, listenLater = library.listenLater, later = library.later
                let checkpoints = library.checkpoints
                let focus = library.focus

                library.findRecording(for: song)
                library.openSearchResult(.jane)

                XCTAssertEqual(library.tab, tab)
                XCTAssertEqual(library.path, tab == .now ? nowPath + [.work(.jane)] : nowPath)
                XCTAssertEqual(library.collectionPath, tab == .collection ? collectionPath + [.work(.jane)] : collectionPath)
                XCTAssertEqual(library.focus, focus)
                XCTAssertEqual(library.reading, .jane)
                XCTAssertEqual(ListeningState(library), listening)
                XCTAssertEqual(library.saved, saved)
                XCTAssertEqual(library.listenLater, listenLater)
                XCTAssertEqual(library.later, later)
                XCTAssertEqual(library.checkpoints, checkpoints)
                XCTAssertTrue(music.calls.isEmpty)

                // A duplicate selection callback does not append the same page twice.
                library.openSearchResult(.jane)
                XCTAssertEqual(library.path, tab == .now ? nowPath + [.work(.jane)] : nowPath)
                XCTAssertEqual(library.collectionPath, tab == .collection ? collectionPath + [.work(.jane)] : collectionPath)
            }
        }
    }

    func testFirstSearchResultStartsExplorationFromAnEmptyCollection() throws {
        try withLibrary { library, _, music in
            library.startedBrowsing = false
            library.path = []
            library.collectionPath = []
            library.tab = .collection
            let listening = ListeningState(library)

            library.openSearchResult(.film)

            XCTAssertTrue(library.startedBrowsing)
            XCTAssertEqual(library.tab, .now)
            XCTAssertEqual(library.focus, .film)
            XCTAssertEqual(library.reading, .film)
            XCTAssertTrue(library.path.isEmpty)
            XCTAssertTrue(library.collectionPath.isEmpty)
            XCTAssertEqual(ListeningState(library), listening)
            XCTAssertTrue(music.calls.isEmpty)
        }
    }

    func testCollectionRecordingSelectionAndListenLaterSurviveReloadAndReturnToOriginalWork() async throws {
        let suite = "Pianwai.CollectionRecording.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let catalog = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        let origin = WorkID(rawValue: "wikidata:Q987766")!
        let recording = WorkID(rawValue: "apple:song:987766")!
        try catalog.merge(CatalogSnapshot(works: [
            Work(id: origin, title: "Night Walk", creator: "A Composer", kind: "音乐作品", art: "", detail: "",
                 url: "https://www.wikidata.org/wiki/Q987766", linkedCreatorIDs: [], knowledgeID: "Q987766"),
            Work(id: recording, title: "Night Walk", creator: "A Composer", kind: "歌曲", art: "", detail: "Album version",
                 url: "https://music.apple.com/jp/song/987766", linkedCreatorIDs: [], catalogID: "987766", storeCountry: "jp")
        ], relations: []))
        let music = RecordingSearchMusicSpy()
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: music)
        library.explore(.pool)
        library.path = [.connections(.film), .work(.manga)]
        let nowPath = library.path
        library.toggleSaved(origin)
        library.tab = .collection
        library.open(origin)
        library.saveReading(origin, offset: 215)
        library.findRecording(for: origin)
        library.openSearchResult(recording)
        library.toggleListenLater(recording)
        XCTAssertEqual(library.tab, .collection)
        XCTAssertEqual(library.collectionPath, [.work(origin), .work(recording)])
        XCTAssertEqual(library.path, nowPath)
        XCTAssertEqual(library.saved, [origin])
        XCTAssertEqual(library.listenLater, [recording])
        XCTAssertNil(catalog.work(origin).catalogRecordingID)
        XCTAssertNotEqual(catalog.canonicalID(for: origin), catalog.canonicalID(for: recording))
        XCTAssertNil(library.persistenceError)
        XCTAssertNil(catalog.storageError)

        await catalog.flushPendingWrites()
        let restoredCatalog = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        library.flushPendingWritesBeforeTermination()
        let restored = Library(defaults: defaults, arguments: [], catalog: restoredCatalog, music: music)
        XCTAssertEqual(restored.tab, .collection)
        XCTAssertEqual(restored.collectionPath, [.work(origin), .work(recording)])
        XCTAssertEqual(restored.path, nowPath)
        XCTAssertEqual(restored.reading, recording)
        XCTAssertEqual(restored.saved, [origin])
        XCTAssertEqual(restored.listenLater, [recording])
        XCTAssertEqual(restoredCatalog.work(recording).catalogRecordingID, "987766")
        restored.collectionPath.removeLast()
        XCTAssertEqual(restored.reading, origin)
        XCTAssertEqual(restored.collectionPath, [.work(origin)])
        XCTAssertEqual(restored.checkpoints[origin.rawValue]?.offset, 215)
        XCTAssertEqual(restored.path, nowPath)
        XCTAssertNil(restored.currentTrack)
        XCTAssertNil(restored.next)
        XCTAssertTrue(music.calls.isEmpty)
    }

    func testLotusRecordingSearchRanksRealAppleFixtureWithoutSelectingOrMerging() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingSearchFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = AppleCatalogService(session: session)
        let catalog = CatalogStore(cacheURL: nil, service: service, bundle: Bundle(for: Self.self))
        let original = lotusSource()
        try catalog.merge(CatalogSnapshot(works: [original], relations: []), persist: false)
        let suite = "Pianwai.LotusRanking.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let music = RecordingSearchMusicSpy()
        let library = Library(defaults: defaults, arguments: ["--demo"], catalog: catalog, music: music)
        library.explore(original.id)
        let before = Continuity(library)
        library.findRecording(for: original.id)
        let context = try XCTUnwrap(library.recordingSearchContext)
        XCTAssertEqual(context.sourceID, original.id)
        XCTAssertEqual(context.title, "Lotus")
        XCTAssertEqual(context.artistNames, ["平泽进"])
        XCTAssertTrue(context.releaseTitles.isEmpty, "A free-form hint is not a structured album assertion")

        let ordinary = try await catalog.search(library.searchQuery, country: "jp", kind: .song)
        XCTAssertEqual(ordinary.first?.rawValue, "apple:song:495941508", "Fixture reproduces BERSERK first in Apple's ranking")
        let ranked = try await catalog.search(library.searchQuery, country: "jp", kind: .song, recordingContext: context)
        XCTAssertEqual(ranked.first?.rawValue, "apple:song:1442459598", "Lotus from Sim City must precede the live version and unrelated songs")
        XCTAssertEqual(ranked.dropFirst().first?.rawValue, "apple:song:1596344629")
        XCTAssertEqual(Set(ranked), Set(ordinary), "All separate catalog candidates remain available")
        let unrelated = Set(ranked.prefix(2))
        XCTAssertEqual(ranked.filter { !unrelated.contains($0) }, ordinary.filter { !unrelated.contains($0) }, "Ties retain Apple's order")
        XCTAssertEqual(Continuity(library), before)
        XCTAssertTrue(library.searchResults.isEmpty, "Fetching and ranking candidates does not choose one")
        XCTAssertNil(catalog.work(original.id).catalogRecordingID)
        XCTAssertEqual(catalog.canonicalID(for: original.id), original.id)
        XCTAssertNotEqual(catalog.canonicalID(for: original.id), ranked.first)
        XCTAssertTrue(music.calls.isEmpty)

        let unscopedAgain = try await service.search(context.query, country: "jp", kind: .song)
        XCTAssertEqual(unscopedAgain.results.first?.rawValue, "apple:song:495941508", "Contextual ranking must not alter the cached Apple response")
        let changedQuery = try await service.search("a different song", country: "jp", kind: .song, recordingContext: context)
        XCTAssertEqual(changedQuery.results.first?.rawValue, "apple:song:495941508")
        let changedKind = try await service.search(context.query, country: "jp", kind: .album, recordingContext: context)
        XCTAssertFalse(changedKind.results.isEmpty)
        XCTAssertTrue(changedKind.results.allSatisfy { $0.rawValue.hasPrefix("apple:album:") })
    }

    func testRecordingRankingUsesArtistThenReleaseAndKeepsRelatedTitlesSeparate() throws {
        let fixture = try JSONDecoder().decode(AppleCatalogPayload.self, from: RecordingSearchFixtureProtocol.fixtureData())
        let response = fixture.materialize(country: "jp")
        let studio = try XCTUnwrap(response.snapshot.works.first { $0.id.rawValue == "apple:song:1442459598" })
        let album = try XCTUnwrap(studio.linkedAlbumID.flatMap { id in response.snapshot.works.first { $0.id == id } })
        let otherAlbum = Work(id: WorkID(rawValue: "apple:album:987770")!, title: "Another Release", creator: "平沢進", kind: "专辑", art: "", detail: "", url: nil)
        let differentRelease = Work(id: WorkID(rawValue: "apple:song:987771")!, title: "Lotus", creator: "平沢進", kind: "歌曲", art: "", detail: "", url: nil, linkedAlbumID: otherAlbum.id)
        let otherArtist = Work(id: WorkID(rawValue: "apple:song:987772")!, title: "Lotus", creator: "Another Artist", kind: "歌曲", art: "", detail: "", url: nil, linkedAlbumID: album.id)
        let relatedComposition = Work(id: WorkID(rawValue: "apple:song:987773")!, title: "LOTUS-2", creator: "平沢進", kind: "歌曲", art: "", detail: "", url: nil, linkedAlbumID: album.id)
        let live = try XCTUnwrap(response.snapshot.works.first { $0.id.rawValue == "apple:song:1596344629" })
        let candidates = CatalogResponse(results: [otherArtist.id, relatedComposition.id, differentRelease.id, live.id, studio.id],
                                         snapshot: CatalogSnapshot(works: response.snapshot.works + [otherAlbum, differentRelease, otherArtist, relatedComposition], relations: response.snapshot.relations))
        let creator = Work(id: WorkID(rawValue: "editorial:hirasawa-ranking")!, title: "平沢進", creator: "音乐人", kind: "创作者", art: "", detail: "", url: nil)
        let structured = RecordingSearchContext(source: lotusSource(), creators: [creator], release: album, query: "Lotus 平沢進 Sim City", kind: .song)
        let ranked = structured.ranked(candidates).results
        XCTAssertEqual(Array(ranked.prefix(2)), [studio.id, differentRelease.id])
        XCTAssertLessThan(try XCTUnwrap(ranked.firstIndex(of: live.id)), try XCTUnwrap(ranked.firstIndex(of: otherArtist.id)), "The known artist's live recording must precede another artist's exact-title namesake")
        XCTAssertLessThan(try XCTUnwrap(ranked.firstIndex(of: live.id)), try XCTUnwrap(ranked.firstIndex(of: relatedComposition.id)))
        XCTAssertEqual(Set(ranked), Set(candidates.results))

        // The existing curated query can help ordering without inventing a
        // structured album link or transliterated artist identity.
        let hinted = RecordingSearchContext(source: lotusSource(), creators: [], release: nil, query: "Lotus 平沢進 Sim City", kind: .song)
        XCTAssertEqual(hinted.ranked(candidates).results.first, studio.id)
        XCTAssertTrue(hinted.releaseTitles.isEmpty)
    }

    func testEditingQueryOrChangingCategoryPermanentlyClearsRecordingContext() throws {
        try withLibrary { library, song, _ in
            library.findRecording(for: song)
            let initial = try XCTUnwrap(library.recordingSearchContext)
            library.country = "us"
            XCTAssertEqual(library.recordingSearchContext, initial, "Storefront changes may reuse source context")
            library.searchQuery = "Another work"
            XCTAssertNil(library.recordingSearchContext)
            library.searchQuery = initial.query
            XCTAssertNil(library.recordingSearchContext, "Typing the old words back must not revive stale provenance")

            library.findRecording(for: song)
            XCTAssertNotNil(library.recordingSearchContext)
            library.searchKind = .album
            XCTAssertNil(library.recordingSearchContext)
            library.searchKind = .song
            XCTAssertNil(library.recordingSearchContext)
        }
    }

    private func lotusSource() -> Work {
        Work(id: WorkID(rawValue: "editorial:lotus-sim-city")!, title: "Lotus", creator: "平泽进", kind: "音乐作品", art: "", detail: "Sim City · 原版作品", url: "https://konstone.s-kon.net/modules/notebook/archives/162", linkedCreatorIDs: [], versionSearchQuery: "Lotus 平沢進 Sim City")
    }

    private func assertPreparedSearch(_ library: Library, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(library.searchQuery, "Night Walk A Composer", file: file, line: line)
        XCTAssertEqual(library.searchKind, .song, file: file, line: line)
        XCTAssertTrue(library.searchOnPresentation, "The presented search should submit this query", file: file, line: line)
        XCTAssertTrue(library.searchResults.isEmpty, "Do not show results from the previous search", file: file, line: line)
    }

    private func withLibrary(kind: String = "歌曲", qid: String = "Q987654",
                             title: String = "Night Walk", creator: String = "A Composer",
                             _ body: (Library, WorkID, RecordingSearchMusicSpy) throws -> Void) throws {
        let suite = "Pianwai.RecordingSearch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let song = try XCTUnwrap(WorkID(rawValue: "wikidata:\(qid)"))
        let item = Work(id: song, title: title, creator: creator, kind: kind,
                        art: "", detail: "", url: "https://www.wikidata.org/wiki/\(qid)",
                        linkedCreatorIDs: [], knowledgeID: qid)
        try catalog.merge(CatalogSnapshot(works: [item], relations: []), persist: false)
        let music = RecordingSearchMusicSpy()
        let library = Library(defaults: defaults, arguments: ["--demo"], catalog: catalog, music: music)
        library.path = [.connections(.film), .work(song)]
        library.collectionPath = [.work(.distance)]
        library.reading = song
        library.saved = [.film, song]
        library.listenLater = [.distance]
        library.later = [.animenz]
        library.recent = [song, .film]
        library.next = .jane
        library.saveReading(song, offset: 215)
        library.searchQuery = "Previous book search"
        library.searchKind = .ebook
        library.searchResults = [.manga]
        try body(library, song, music)
    }

    private struct Continuity: Equatable {
        let tab: AppTab
        let focus: WorkID
        let reading: WorkID
        let path: [Route]
        let collectionPath: [Route]
        let playing: WorkID
        let currentTrack: WorkID?
        let currentEntryID: String?
        let isPlaying: Bool
        let next: WorkID?
        let saved: [WorkID]
        let listenLater: [WorkID]
        let later: [WorkID]
        let recent: [WorkID]
        let checkpoints: [String: ReadingCheckpoint]

        @MainActor init(_ library: Library) {
            tab = library.tab; focus = library.focus; reading = library.reading
            path = library.path; collectionPath = library.collectionPath
            playing = library.playing; currentTrack = library.currentTrack
            currentEntryID = library.currentEntryID; isPlaying = library.isPlaying; next = library.next
            saved = library.saved; listenLater = library.listenLater; later = library.later
            recent = library.recent; checkpoints = library.checkpoints
        }
    }

    private struct ListeningState: Equatable {
        let playing: WorkID
        let currentTrack: WorkID?
        let currentEntryID: String?
        let isPlaying: Bool
        let next: WorkID?
        let pendingSong: WorkID?
        let activeCommand: MusicPlaybackCommand?

        @MainActor init(_ library: Library) {
            playing = library.playing; currentTrack = library.currentTrack
            currentEntryID = library.currentEntryID; isPlaying = library.isPlaying
            next = library.next; pendingSong = library.pendingSong; activeCommand = library.activePlaybackCommand
        }
    }
}

/// Injected even in demo mode so an accidental production command cannot touch MusicKit.
@MainActor
private final class RecordingSearchMusicSpy: MusicPlaybackClient {
    let snapshot = MusicPlaybackSnapshot(availability: .authorizationRequired, authorization: .notDetermined,
                                         subscription: .unknown, nowPlaying: nil, status: .stopped,
                                         elapsedTime: 0, capturedAt: Date(timeIntervalSince1970: 0))
    let commandInFlight: MusicPlaybackCommand? = nil
    var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    private(set) var calls: [MusicPlaybackCommand] = []
    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
    func refresh() async { }
    func requestAuthorization() async -> MusicPlaybackActionResult { reject(.requestAuthorization) }
    func pause() async -> MusicPlaybackActionResult { reject(.pause) }
    func resume() async -> MusicPlaybackActionResult { reject(.resume) }
    func skipToNext() async -> MusicPlaybackActionResult { reject(.skipToNext) }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { reject(.insertNext) }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { reject(.playNow) }
    private func reject(_ command: MusicPlaybackCommand) -> MusicPlaybackActionResult {
        calls.append(command)
        XCTFail("Opening recording search must not issue a Music command: \(command.rawValue)")
        return .failure(.init(.configuration, "Test playback is disabled"))
    }
}

/// Transcodes a historical public search response for ranking regressions; no live MusicKit coverage is claimed.
private final class RecordingSearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func fixtureData() throws -> Data {
        let bundle = Bundle(for: RecordingSearchFixtureProtocol.self)
        let url = try XCTUnwrap(bundle.url(forResource: "recording-search-lotus-jp", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    override func startLoading() {
        do {
            let data = try Self.fixtureData()
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: MusicKitTestFixture.transcode(data, url: request.url))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { }
}
