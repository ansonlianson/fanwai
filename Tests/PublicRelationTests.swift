import XCTest
@testable import Pianwai

final class PublicRelationTests: XCTestCase, @unchecked Sendable {
    private func recorded(_ path: String, _ query: [String: String] = [:], host: String = "musicbrainz.org") throws -> Data {
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = path
        url.queryItems = query.map { .init(name: $0.key, value: $0.value) }
        return try PublicRelationsFixture.response(XCTUnwrap(url.url)).0
    }
    private func catalog(_ number: String = "1840141274") async throws -> CatalogResponse {
        let service = ITunesCatalogService(transport: .init(loader: PublicRelationsFixture.load, limiter: .init()))
        return try await service.lookup(number, country: "jp", entity: nil, kind: .songs)
    }
    func testFiveRecordedSongsBindOnlyTheirExactReleaseRecording() async throws {
        let cases = [("1840141274", "1ce0036d-77aa-453b-be9a-bb1e78e0e8a3"),
                     ("1840081736", "79943016-2bbb-4126-8f15-b546d5d1ec47"),
                     ("1839387171", "190aa7fe-e80b-413d-9f82-e0c5b4b4929d"),
                     ("1648272180", "d3b47582-8395-4b55-b428-b64eca7761d0"),
                     ("1837658529", "83dbaf01-8a59-47c8-971c-e0b07cd12c95")]
        for (number, recording) in cases {
            let response = try await catalog(number)
            let work = try XCTUnwrap(response.snapshot.works.first { $0.catalogID == number })
            let collector = PublicRelationService(loader: PublicRelationsFixture.load, directory: nil, paced: false)
            let report = try await collector.resolve(work, known: response.snapshot.works)
            XCTAssertEqual(report.recordingID, recording, number)
            XCTAssertTrue(report.failures.isEmpty, "\(number): \(report.failures)")
            XCTAssertTrue(report.hops.contains { $0.field == "collectionId" && $0.verified })
            XCTAssertFalse(report.snapshot.relations.contains { $0.from == work.id && $0.source.title == "Bangumi" })
        }
    }
    func testWikidataBatchArrivesWhileMusicBrainzIsStillLoading() async throws {
        actor Receipt {
            var mbFinished=false
            var sawEarlyBatch=false
            var urls:[URL]=[]
            func requested(_ url:URL) { urls.append(url) }
            func mbDone() { mbFinished=true }
            func partial(_ value:PublicRelationReport) {
                if !mbFinished && value.hops.contains(where: { $0.source.title == "Wikidata" && $0.verified }) { sawEarlyBatch=true }
            }
            func result() -> (Bool,[URL]) { (sawEarlyBatch,urls) }
        }
        let response=try await catalog(), work=try XCTUnwrap(response.snapshot.works.first { $0.catalogID == "1840141274" })
        let receipt=Receipt()
        let collector=PublicRelationService(loader: { request in
            let url=try XCTUnwrap(request.url); await receipt.requested(url)
            if url.host == "musicbrainz.org" { try await Task.sleep(for:.milliseconds(100)) }
            let data=try await PublicRelationsFixture.load(request)
            if url.path.contains("/ws/2/release/") { await receipt.mbDone() }
            return data
        },directory:nil,paced:false)
        let report=try await collector.resolve(work,known:response.snapshot.works) { await receipt.partial($0) }
        let (early,urls)=await receipt.result()
        XCTAssertTrue(early)
        XCTAssertFalse(report.snapshot.relations.isEmpty)
        XCTAssertTrue(urls.contains { URLComponents(url:$0,resolvingAgainstBaseURL:false)?.queryItems?.contains { $0.name == "srsearch" && $0.value?.contains("|") == true } == true })
        XCTAssertFalse(urls.contains { $0.absoluteString.contains("%20OR%20") })
        XCTAssertEqual(report.recordingID,"1ce0036d-77aa-453b-be9a-bb1e78e0e8a3")
    }
    func testWikimediaRetryIsBoundedAndKeepsValidRelations() async throws {
        actor Attempts {
            var counts:[URL:Int]=[:]
            func next(_ url:URL) -> Int { counts[url,default:0] += 1; return counts[url]! }
            func maximum() -> Int { counts.values.max() ?? 0 }
        }
        let response=try await catalog(), work=try XCTUnwrap(response.snapshot.works.first { $0.catalogID == "1840141274" })
        let attempts=Attempts()
        let collector=PublicRelationService(loader: { request in
            let url=try XCTUnwrap(request.url)
            let attempt=await attempts.next(url)
            if WikidataRequestPacer.isWikimedia(url) && attempt == 1 { throw PublicRelationRetry(delay:0) }
            return try await PublicRelationsFixture.load(request)
        },directory:nil,paced:false)
        let report=try await collector.resolve(work,known:response.snapshot.works)
        XCTAssertTrue(report.failures.isEmpty,report.failures.description)
        let maximum=await attempts.maximum(); XCTAssertEqual(maximum,2)
        XCTAssertEqual(PublicRelationService.retryDelay("120"),30)
        XCTAssertEqual(PublicRelationService.retryDelay(nil),5)
    }
    func testMultiTrackReleaseRejectsEveryWrongCoordinateAndTitle() async throws {
        let response = try await catalog()
        let work = try XCTUnwrap(response.snapshot.works.first { $0.catalogID == "1840141274" })
        let data = try recorded("/ws/2/release/0f0de693-4769-405d-876f-6e1cb85e82ac")
        let release = try JSONDecoder().decode(PublicMBRelease.self, from: data)
        XCTAssertNotNil(release.matchingRecording(work))
        let identity = try XCTUnwrap(work.catalogTrack)
        for field in 0..<5 {
            var changed = work
            changed.catalogTrack = .init(albumID: field == 0 ? "999" : identity.albumID, artistID: identity.artistID,
                disc: identity.disc + (field == 1 ? 1 : 0), track: identity.track + (field == 2 ? 1 : 0),
                trackCount: identity.trackCount + (field == 3 ? 1 : 0), milliseconds: identity.milliseconds + (field == 4 ? 2001 : 0))
            XCTAssertNil(release.matchingRecording(changed), "coordinate \(field)")
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var media = try XCTUnwrap(object["media"] as? [[String: Any]])
        var tracks = try XCTUnwrap(media[0]["tracks"] as? [[String: Any]])
        tracks[8]["title"] = "same ID, conflicting title"
        media[0]["tracks"] = tracks; object["media"] = media
        XCTAssertNil(try JSONDecoder().decode(PublicMBRelease.self, from: JSONSerialization.data(withJSONObject: object)).matchingRecording(work))
    }
    func testAmbiguousReleaseCandidatesRemainUnbound() async throws {
        let response = try await catalog()
        let work = try XCTUnwrap(response.snapshot.works.first { $0.catalogID == "1840141274" })
        let collector = PublicRelationService(loader: { request in
            if request.url?.path.contains("/ws/2/url") == true {
                return Data(#"{"relations":[{"type":"streaming","release":{"id":"0f0de693-4769-405d-876f-6e1cb85e82ac"}},{"type":"streaming","release":{"id":"821db450-c1af-4e18-9146-91da1460ce77"}}]}"#.utf8)
            }
            return try await PublicRelationsFixture.load(request)
        }, directory: nil, paced: false)
        let report = try await collector.resolve(work, known: response.snapshot.works)
        XCTAssertNil(report.recordingID)
        let hop = try XCTUnwrap(report.hops.first { $0.candidates.count == 2 && $0.field == "collectionId" })
        XCTAssertFalse(hop.verified)
        XCTAssertFalse(report.snapshot.relations.contains { $0.source.title == "MusicBrainz" })
    }
    @MainActor func testFilmRelationsStayOnFilmAndSourcesSurviveDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(cacheURL: nil)
        let film = store.work(.film)
        let collector = PublicRelationService(loader: PublicRelationsFixture.load, directory: directory, paced: false)
        let report = try await collector.resolve(film, known: Array(store.works.values))
        XCTAssertTrue(report.failures.isEmpty, report.failures.description)
        XCTAssertTrue(report.hops.contains { $0.field == "P5732" && $0.candidates == ["470660"] && $0.verified })
        XCTAssertTrue(report.snapshot.relations.contains { $0.label == "原声集" })
        XCTAssertTrue(report.snapshot.relations.contains { $0.label == "片尾曲" })
        XCTAssertTrue(report.snapshot.relations.allSatisfy { $0.from == film.id && !$0.source.url.isEmpty })
        let cached = PublicRelationService(loader: { _ in XCTFail("Disk cache unexpectedly fetched"); throw CatalogError.offline }, directory: directory, paced: false)
        let second = try await cached.resolve(film, known: [])
        XCTAssertEqual(second.hops.map(\.fetchedAt), report.hops.map(\.fetchedAt))
        XCTAssertEqual(second.snapshot.relations.map(\.id), report.snapshot.relations.map(\.id))
        let encoded = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
        XCTAssertFalse(encoded.contains("lain.bgm.tv"))
    }
    @MainActor func testSameNameDifferentIDAndCrateMapBoundary() async throws {
        let response = try await catalog()
        let service = ITunesCatalogService(transport: .init(loader: PublicRelationsFixture.load, limiter: .init()))
        let store = CatalogStore(cacheURL: nil, service: service)
        try store.merge(response.snapshot)
        let root = WorkID(rawValue: "apple:song:1840141274")!
        let other = Work(id: WorkID(rawValue: "apple:song:9999")!, title: "in the pool", creator: "牛尾憲輔", kind: "歌曲", art: "", detail: "", url: nil, linkedCreatorIDs: [], catalogID: "9999")
        try store.merge(.init(works: [other], relations: []))
        XCTAssertNotEqual(store.canonicalID(for: root), store.canonicalID(for: other.id))
        let collector = PublicRelationService(loader: PublicRelationsFixture.load, directory: nil, paced: false)
        await store.enrichPublicRelations(root, collector: collector)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PublicRelationsTest-" + UUID().uuidString))
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        let items = PublicCrateInventory.items(for: root.rawValue, library: library)
        XCTAssertGreaterThanOrEqual(items.count, 2)
        XCTAssertLessThanOrEqual(items.count, 5)
        XCTAssertFalse(items.contains { $0.id == "film" || $0.id == "manga" })
        XCTAssertEqual(SeedLibraryBridge.entity(for: root, in: library).subtitle, "牛尾宪辅")
        let album = try XCTUnwrap(store.work(root).albumID)
        await store.enrichCatalog(album)
        XCTAssertTrue(store.work(album).creatorIDs.contains(.ushio))
        XCTAssertEqual(SeedLibraryBridge.entity(for: album, in: library).subtitle, "牛尾宪辅")
        let graph = PublicCrateInventory.graph(root: root.rawValue, expanding: [root.rawValue], library: library)
        XCTAssertEqual(graph.outgoing(from: root.rawValue).map(\.to), PublicCrateInventory.items(for: root.rawValue, library: library).map(\.id))
        var map = RelationMapModel(root: root.rawValue)
        _ = map.expand(root.rawValue, graph: graph)
        let positions = map.nodes.mapValues(\.position)
        let creator = try XCTUnwrap(items.first { $0.entity.kind == .person })
        let expanded = PublicCrateInventory.graph(root: root.rawValue, expanding: map.order, library: library)
        let result = map.expand(creator.id, graph: expanded)
        XCTAssertLessThanOrEqual(result.fresh.count, 6)
        for (id, point) in positions { XCTAssertEqual(map.nodes[id]?.position, point) }
    }
    func testSparseSamplesPreserveUnboundState() async throws {
        for number in ["6803304739", "6804611280"] {
            let response = try await catalog(number)
            let work = try XCTUnwrap(response.snapshot.works.first { $0.catalogID == number })
            let collector = PublicRelationService(loader: PublicRelationsFixture.load, directory: nil, paced: false)
            let report = try await collector.resolve(work, known: response.snapshot.works)
            XCTAssertNil(report.recordingID)
            XCTAssertTrue(report.failures.isEmpty, report.failures.description)
            XCTAssertTrue(report.snapshot.relations.isEmpty)
        }
    }
    func testBadgeAppParameterReplacedWithoutChangingStoredSource() {
        for original in ["https://music.apple.com/jp/album/1840140991?i=1840141274&uo=4", "https://music.apple.com/jp/album/1840140991?i=1840141274&app=music&app=other"] {
            let work = Work(id: .pool, title: "in the pool", creator: "", kind: "歌曲", art: "", detail: "", url: original,
                            catalogSource: .init(title: "iTunes", url: original))
            let query = work.appleMusicURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            XCTAssertNil(work.iTunesStoreURL)
            XCTAssertTrue(query.filter { $0.name == "app" }.isEmpty)
            XCTAssertEqual(query.first { $0.name == "i" }?.value, "1840141274")
            XCTAssertEqual(work.url, original); XCTAssertEqual(work.catalogSource?.url, original)
        }
    }
    @MainActor func testResolvedPlaybackRegionPersistsThroughCatalogMerge() async throws {
        let service = ITunesCatalogService(transport: .init(loader: PublicRelationsFixture.load, limiter: .init()))
        let store = CatalogStore(cacheURL: nil, service: service)
        let id = WorkID(rawValue: "apple:song:1840141274")!
        try store.merge(.init(works: [Work(id: id, title: "in the pool", creator: "牛尾憲輔", kind: "歌曲", art: "", detail: "", url: nil, catalogID: "1840141274")], relations: []))
        await store.resolvePlaybackRegion(id, browsingRegion: "jp", storefront: "JPN")
        XCTAssertNil(store.lookupErrors[id])
        XCTAssertEqual(store.work(id).resolvedRegion, "jp")
        XCTAssertEqual(store.work(id).regionOrigin, .appStore)
    }
    @MainActor func testPublicProductionPipelineHasNoMusicKitNetworkRoute() async throws {
        let requests = PublicRelationRequestLog()
        let service = ITunesCatalogService(transport: .init(loader: { try await requests.load($0) }, limiter: .init()))
        let store = CatalogStore(cacheURL: nil, service: service)
        let root = WorkID(rawValue: "apple:song:1840141274")!
        try store.merge(.init(works: [Work(id: root, title: "System title", creator: "System artist", kind: "歌曲", art: "", detail: "", url: nil, catalogID: "1840141274")], relations: []))
        await store.resolvePlaybackRegion(root, browsingRegion: "cn", storefront: "JPN")
        let collector = PublicRelationService(loader: { try await requests.load($0) }, directory: nil, paced: false)
        await store.enrichPublicRelations(root, collector: collector)
        XCTAssertNotNil(store.publicReports[root]?.recordingID)
        let hosts = await requests.hosts
        XCTAssertEqual(Set(hosts), ["itunes.apple.com", "musicbrainz.org", "www.wikidata.org", "api.bgm.tv"])
    }
    func testRegionOrderDeduplicatesLimitsAndRejectsWrongTrack() async throws {
        XCTAssertEqual(PlaybackRegionResolver.country("JPN"), "jp")
        XCTAssertEqual(PlaybackRegionResolver.country("USA"), "us")
        XCTAssertEqual(PlaybackRegionResolver.country("CHN"), "cn")
        XCTAssertEqual(PlaybackRegionResolver.candidates(known: "us", storefront: "JPN", browsing: "jp").map(\.0), ["us", "jp"])
        let response = try await catalog()
        let service = RegionFixture(response: response)
        let match = await PlaybackRegionResolver.resolve(number: "1840141274", known: "us", storefront: "JPN", browsing: "cn", service: service)
        XCTAssertEqual(match?.region, "jp"); XCTAssertEqual(match?.origin, .appStore)
        let requests = await service.regions
        XCTAssertEqual(requests, ["us", "jp"])
        let wrong = RegionFixture(response: response)
        let absent = await PlaybackRegionResolver.resolve(number: "99999", known: "us", storefront: "JPN", browsing: "cn", service: wrong)
        XCTAssertNil(absent)
        let attempts = await wrong.regions
        XCTAssertEqual(attempts, ["us", "jp"])
    }
}

private actor PublicRelationRequestLog {
    var hosts: [String] = []
    func load(_ request: URLRequest) async throws -> Data {
        hosts.append(request.url?.host ?? "invalid")
        return try await PublicRelationsFixture.load(request)
    }
}

private actor RegionFixture: CatalogFetching {
    let response: CatalogResponse
    var regions: [String] = []
    init(response: CatalogResponse) { self.response = response }
    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind?) async throws -> CatalogResponse {
        regions.append(country)
        if country == "us" { return .init(results: [], snapshot: .init(works: [], relations: [])) }
        return response
    }
    func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext?) async throws -> CatalogResponse { XCTFail("Region resolution must not search names"); return response }
}
