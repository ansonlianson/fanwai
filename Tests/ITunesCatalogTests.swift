import XCTest
@testable import Pianwai

final class ITunesCatalogTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "ITunesCatalog")
                                ?? Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func payload(_ name: String) throws -> ITunesCatalogPayload {
        try JSONDecoder().decode(ITunesCatalogPayload.self, from: fixture(name))
    }
    private func artistData() throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("pool-artist")) as? [String: Any])
        let rows = try XCTUnwrap(object["results"] as? [[String: Any]]).filter { $0["wrapperType"] as? String == "artist" }
        return try JSONSerialization.data(withJSONObject: ["resultCount": rows.count, "results": rows])
    }

    func testRecordedSevenSamplesKeepExactVersionRegionAndProvenance() throws {
        let samples = ["pool": "1840141274", "jane": "1840081736", "actor": "1839387171", "kickback": "1648272180",
                       "iris": "1837658529", "diver": "6803304739", "ningen": "6804611280"]
        for (name, number) in samples {
            let response = try payload(name).materialize(country: "jp")
            let song = try XCTUnwrap(response.snapshot.works.first { $0.id.rawValue == "apple:song:" + number })
            XCTAssertEqual(song.storeCountry, "jp")
            XCTAssertEqual(song.catalogSource?.title, "iTunes")
            XCTAssertEqual(song.catalogID, number)
            XCTAssertTrue(response.results.contains(song.id))
            let encoded = String(decoding: try JSONEncoder().encode(response.snapshot), as: UTF8.self)
            XCTAssertFalse(encoded.contains("previewUrl"))
            XCTAssertFalse(encoded.contains("AudioPreview"))
        }
        let kick = try payload("kickback").materialize(country: "jp")
        XCTAssertEqual(Set(kick.results).count, kick.results.count)
        XCTAssertGreaterThan(kick.results.count, 1, "Live/remix/other recordings must not collapse into one")
        let jane = try payload("jane").materialize(country: "jp")
        XCTAssertFalse(jane.snapshot.works.contains { $0.isPerson }, "Combined track credits cannot name the primary artist entity")
        XCTAssertEqual(jane.snapshot.works.first { $0.catalogID == "1840081736" }?.creator, "米津玄師 & 宇多田ヒカル")
    }

    func testAlbumTrackAndArtistLookupsKeepNativeTypedRelations() async throws {
        let artists = try payload("pool-artist").results.filter { $0.wrapperType == "artist" }
        let response = try payload("pool-album").materialize(country: "jp", artists: artists)
        let album = try XCTUnwrap(response.snapshot.works.first { $0.id.rawValue == "apple:album:1840140991" })
        XCTAssertEqual(response.snapshot.works.filter(\.isSong).count, 30)
        XCTAssertEqual(album.creatorIDs.map(\.rawValue), ["apple:artist:939561587"])
        XCTAssertEqual(response.snapshot.relations.filter { $0.predicate == .inAlbum }.count, 30)
        XCTAssertFalse(try XCTUnwrap(album.url).contains("?i="))
        let artist = try XCTUnwrap(response.snapshot.works.first { $0.isPerson })
        XCTAssertEqual(artist.title, "kensuke ushio", "Use the dedicated artist response, never parse a credit string")
        XCTAssertEqual(artist.catalogSource?.title, "iTunes")
    }

    @MainActor func testRegionalLinkWinsAndSavedMetadataSurvivesReload() async throws {
        let data = try fixture("pool-us")
        let artist = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        let recorder = PublicCatalogRecorder { request, _ in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return query.contains { $0.name == "id" && $0.value == "939561587" } ? artist : data
        }
        let service = ITunesCatalogService(transport: .init(loader: { try await recorder.load($0) }, limiter: .init()))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = CatalogStore(cacheURL: cache, service: service, bundle: Bundle(for: Self.self))
        let result = try await store.importLink("https://music.apple.com/us/song/1837522108", country: "jp")
        XCTAssertEqual(result, .pool)
        XCTAssertEqual(store.work(result).storeCountry, "us")
        XCTAssertEqual(Work.seeds[.pool]?.storeCountry, "us")
        let requests = await recorder.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "itunes.apple.com" })
        XCTAssertTrue(requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "country" && $0.value == "us" } == true })
        await store.flushPendingWrites()
        let reloaded = CatalogStore(cacheURL: cache, service: service, bundle: Bundle(for: Self.self))
        XCTAssertEqual(reloaded.work(.pool).catalogID, "1837522108")
        XCTAssertEqual(reloaded.work(.pool).storeCountry, "us")
        XCTAssertNil(reloaded.work(.pool).catalogSource, "Curated artwork remains curated")
    }

    func testSharedCacheAndCoalescingRespectCancellationAndRegion() async throws {
        let data = try artistData()
        let recorder = PublicCatalogRecorder { _, _ in
            try await Task.sleep(for: .milliseconds(250))
            return data
        }
        let transport = ITunesCatalogTransport(loader: { try await recorder.load($0) }, limiter: .init())
        let firstService = ITunesCatalogService(transport: transport), secondService = ITunesCatalogService(transport: transport)
        let first = Task { try await firstService.search("same", country: "jp", kind: .musicArtist) }
        let second = Task { try await secondService.search("same", country: "jp", kind: .musicArtist) }
        try await Task.sleep(for: .milliseconds(80))
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled subscriber returned") } catch is CancellationError { }
        let remaining = try await second.value
        XCTAssertFalse(remaining.results.isEmpty)
        _ = try await firstService.search("same", country: "JP", kind: .musicArtist)
        var count = await recorder.requests.count
        XCTAssertEqual(count, 1, "One subscriber cancelling must not cancel the other or duplicate the request")
        let abandoned = Task { try await firstService.search("abandoned", country: "jp", kind: .musicArtist) }
        try await Task.sleep(for: .milliseconds(70)); abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("Cancelled task returned") } catch is CancellationError { }
        _ = try await firstService.search("abandoned", country: "jp", kind: .musicArtist)
        count = await recorder.requests.count
        XCTAssertEqual(count, 3, "A cancelled-only flight must not cache its result")
        // An empty result is valid in another region, but never aliases the first cache.
        let empty = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        let regions = PublicCatalogRecorder { _, _ in empty }
        let regionService = ITunesCatalogService(transport: .init(loader: { try await regions.load($0) }, limiter: .init()))
        _ = try await regionService.search("same", country: "jp", kind: .song)
        _ = try await regionService.search("same", country: "us", kind: .song)
        let regionCount = await regions.requests.count
        XCTAssertEqual(regionCount, 2)
    }

    func testFailuresRemainDistinctRetryableAndCannotPoisonCache() async throws {
        let data = try artistData()
        let recorder = PublicCatalogRecorder { _, index in
            switch index {
            case 1: throw CatalogError.throttled
            case 2: throw URLError(.notConnectedToInternet)
            case 3: return Data(#"{"resultCount":1,"results":[{}]}"#.utf8)
            default: return data
            }
        }
        let service = ITunesCatalogService(transport: .init(loader: { try await recorder.load($0) }, limiter: .init()))
        for expected in [CatalogError.throttled, .offline, .invalidData] {
            do { _ = try await service.search("recover", country: "jp", kind: .musicArtist); XCTFail("Failure became success") }
            catch { XCTAssertEqual(CatalogError.message(error), expected.localizedDescription) }
        }
        let recovered = try await service.search("recover", country: "jp", kind: .musicArtist)
        XCTAssertFalse(recovered.results.isEmpty)
        let empty = ITunesCatalogService(transport: .init(loader: { _ in Data(#"{"resultCount":0,"results":[]}"#.utf8) }, limiter: .init()))
        do { _ = try await empty.lookup("123", country: "jp", entity: nil); XCTFail("Missing identity became success") }
        catch CatalogError.notFound { }
    }

    func testBudgetIsSharedAcrossAdapterInstances() async throws {
        let empty = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        let recorder = PublicCatalogRecorder { _, _ in empty }
        let limiter = ITunesRequestLimiter()
        let a = ITunesCatalogService(transport: .init(loader: { try await recorder.load($0) }, limiter: limiter))
        let b = ITunesCatalogService(transport: .init(loader: { try await recorder.load($0) }, limiter: limiter))
        for index in 0..<18 { _ = try await (index.isMultiple(of: 2) ? a : b).search(String(index), country: "jp", kind: .song) }
        do { _ = try await b.search("nineteenth", country: "jp", kind: .song); XCTFail("Exceeded shared budget") }
        catch CatalogError.throttled { }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 18)
    }

    func testOptInLivePublicSearchAndLookup() async throws {
        guard ProcessInfo.processInfo.environment["PIANWAI_PUBLIC_SURVEY"] == "1" else {
            throw XCTSkip("Bounded public survey requires explicit opt-in")
        }
        let recorder = PublicCatalogRecorder { request, _ in try await ITunesCatalogTransport.loadPublicData(request) }
        let service = ITunesCatalogService(transport: .init(loader: { try await recorder.load($0) }, limiter: .init()))
        let songs = try await service.search("in the pool 牛尾憲輔", country: "jp", kind: .song)
        XCTAssertTrue(songs.results.contains { $0.rawValue == "apple:song:1840141274" })
        let album = try await service.lookup("1840140991", country: "jp", entity: "song", kind: .albums)
        XCTAssertEqual(album.snapshot.works.filter(\.isSong).count, 30)
        let requests = await recorder.requests
        XCTAssertLessThanOrEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "itunes.apple.com" })
        print("PUBLIC_CATALOG_SURVEY " + requests.compactMap { $0.url?.absoluteString }.joined(separator: "\n"))
    }
}

private actor PublicCatalogRecorder {
    var requests: [URLRequest] = []
    let response: @Sendable (URLRequest, Int) async throws -> Data
    init(response: @escaping @Sendable (URLRequest, Int) async throws -> Data) { self.response = response }
    func load(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        return try await response(request, requests.count)
    }
}
