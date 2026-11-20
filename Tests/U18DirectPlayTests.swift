import XCTest
@testable import Pianwai

@MainActor final class U18DirectPlayTests: XCTestCase {
    func testCoverRecordingIsTheDirectPlayTargetAndReadingAndRelationsStayPut() async throws {
        let source = composition(), older = record("900000011", artwork: "", date: "1980-01-01"), pictured = record("900000012", artwork: "pool", date: "1981-01-01")
        let library = try makeLibrary(works: [source, older, pictured], records: [older, pictured])
        let store = RecordingVersionsStore(directory: nil)
        await store.load(source, library: library)
        XCTAssertEqual(WorkArtworkStore.shared.representativeWorks[source.id]?.rawMetadata?["recordingID"], pictured.id.rawValue)
        XCTAssertEqual(store.preferredRecording(for: source, library: library), pictured.id)
        let entity = SeedLibraryBridge.entity(for: source.id, in: library)
        XCTAssertEqual(EntityActions.labels(entity, library: library), ["播放"], "收藏 is the ☆ on the map card")
        XCTAssertEqual(EntityActions.playbackID(entity, library: library), pictured.id)
        let reading = library.reading, edges = library.catalog.edges.map(\.id).sorted()
        library.listen(source.id)
        for _ in 0..<100 where library.listening.busy { await Task.yield() }
        let operation = try XCTUnwrap(library.playbackOperations.first)
        XCTAssertEqual(operation.command, .playNow)
        XCTAssertEqual(operation.catalogID, "900000012")
        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(library.reading, reading)
        XCTAssertEqual(library.catalog.edges.map(\.id).sorted(), edges)
        XCTAssertTrue(library.listenLater.isEmpty)
        library.playbackPlatform = .qq
        XCTAssertEqual(EntityActions.labels(entity, library: library), ["去 QQ 音乐听"])
        library.playbackPlatform = .netease
        XCTAssertEqual(EntityActions.labels(entity, library: library), ["去网易云听"])
    }

    func testArtOrSameTitleAloneDoesNotInventADefaultRecording() throws {
        let source = composition("test:u18-no-default")
        let wrong = record("900000013", creator: "Unrelated singer", artwork: "pool")
        let library = try makeLibrary(works: [source, wrong], records: [])
        WorkArtworkStore.shared.useRepresentative("pool", for: source.id, recording: wrong.id, source: wrong.appleMusicURL!)
        let store = RecordingVersionsStore(directory: nil)
        XCTAssertNil(store.preferredRecording(for: source, library: library))
        let entity = SeedLibraryBridge.entity(for: source.id, in: library)
        XCTAssertNil(EntityActions.playbackID(entity, library: library))
        XCTAssertEqual(EntityActions.labels(entity, library: library), [], "no playable version: no buttons (anson 11-18 14:20)")
        XCTAssertTrue(library.playbackOperations.isEmpty)
        XCTAssertFalse(library.catalog.edges.contains { $0.from == source.id || $0.to == source.id })
    }

    func testCompositionPlaybackKeepsTheConfirmedQQOrNeteaseDestination() throws {
        for platform in [PlaybackPlatform.qq, .netease] {
            let source = composition("test:u18-" + platform.rawValue)
            let domestic = PlatformRecording(platform: platform, identifier: "900000012", numericID: nil,
                title: source.title, artists: [source.creator], album: "", seconds: 200, artwork: "pool")
            var recording = record("900000012", artwork: "pool")
            recording.platformRecording = domestic
            let library = try makeLibrary(works: [source, recording], records: [recording])
            library.playbackPlatform = platform
            library.listen(source.id)
            XCTAssertEqual(library.listening.handoff?.platform, platform)
            XCTAssertEqual(library.listening.handoff?.url, domestic.url)
            XCTAssertNil(library.listening.choice)
            XCTAssertTrue(library.playbackOperations.isEmpty)
        }
    }

    private func composition(_ raw: String = "test:u18-composition") -> Work {
        .init(id: WorkID(rawValue: raw)!, title: "さよならの向う側", creator: "宇崎竜童", kind: "音乐作品", art: "", detail: "", url: nil,
            discovery: .init(layer: .musicWork, canonicalTitle: "さよならの向う側", composer: "宇崎竜童"))
    }
    private func record(_ id: String, creator: String = "宇崎竜童", artwork: String, date: String = "1980-01-01") -> Work {
        .init(id: WorkID(rawValue: "apple:song:" + id)!, title: "さよならの向う側", creator: creator, kind: "歌曲", art: artwork, detail: "",
            url: "https://music.apple.com/jp/song/" + id, catalogID: id, storeCountry: "jp", releaseDate: date)
    }
    private func makeLibrary(works: [Work], records: [Work]) throws -> Library {
        let suite = "U18." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil, service: U18OfflineCatalog())
        let relations = records.map {
            RelationEdge(from: $0.id, to: works[0].id, predicate: .performanceOf, label: "乐曲", inverseLabel: "能听的版本",
                source: .init(title: "离线样本", url: "https://example.org/u18"))
        }
        try catalog.merge(.init(works: works, relations: relations), persist: false)
        return Library(defaults: defaults, arguments: [], catalog: catalog, music: SimulatorPlaybackFixture(mode: .accepted))
    }
}

private actor U18OfflineCatalog: CatalogFetching {
    func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext?) async throws -> CatalogResponse { throw URLError(.notConnectedToInternet) }
    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind?) async throws -> CatalogResponse { throw URLError(.notConnectedToInternet) }
}
