import XCTest
@testable import Pianwai

final class AppleMusicCatalogTests: XCTestCase, @unchecked Sendable {
    func testDiscoveryKeepsIDsRelationsEditorialFieldsAndExactExternalCredits() async throws {
        let server = try CatalogFixtureServer()
        let identity = CatalogIdentityService(loader: { try await server.external($0) }, responseCache: nil)
        let service = AppleCatalogService(loader: { try await server.apple($0) }, storefront: nil, alignment: identity)
        let values = try await service.discover(.catalogID("91001"), country: "jp")
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(value.storefront, "jp")
        XCTAssertEqual(value.identity.catalogID, "91001")
        XCTAssertEqual(value.identity.isrc, "JPTST2600001")
        XCTAssertEqual(value.identity.artistIDs, ["93001"])
        XCTAssertEqual(value.identity.wikidata.map(\.qid), ["Q99901"])
        XCTAssertEqual(value.identity.artistsWikidata["93001"]?.map(\.qid), ["Q99902"])
        XCTAssertEqual(value.identity.musicBrainz.map(\.id), ["11111111-2222-3333-4444-555555555555"])
        XCTAssertEqual(Set(value.identity.musicBrainz.flatMap(\.credits).map(\.role)), Set(["composer", "lyricist", "arranger"]))
        XCTAssertTrue(value.identity.musicBrainz.allSatisfy(\.creditsComplete))
        XCTAssertEqual(value.materials.count, 3)
        XCTAssertTrue(value.materials.allSatisfy { $0.location.hasSuffix(".attributes.editorialNotes.standard") && !$0.text.contains("<p>") })
        for field in ["composers", "tracks", "other-versions", "related-albums", "music-videos", "similar-artists", "latest-release"] {
            XCTAssertTrue(value.relations.contains { $0.sourceField.hasSuffix("." + field) }, field)
        }
        XCTAssertTrue(value.incomplete.contains { $0.contains("more pages") })
        let firstRequests = await server.requests
        XCTAssertLessThanOrEqual(firstRequests.count, 12)
        XCTAssertTrue(firstRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        for request in firstRequests where request.url?.host == "musicbrainz.org" {
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Pianwai/") == true)
            // A way to reach the app: its page since 2026-11-18 (which also lifts Wikimedia's limit), an address before.
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            XCTAssertTrue(agent.contains("https://fanwai.xyz") || agent.contains("mailto:"), agent.isEmpty ? "no User-Agent" : "no contact in the User-Agent")
        }
        _ = try await service.discover(.catalogID("91001"), country: "jp")
        let secondCount = await server.requests.count
        XCTAssertEqual(secondCount, firstRequests.count, "Unchanged reads use the existing response caches")
    }
    func testCurrentStorefrontOverridesForeignLinkRegionAndUsesAppleEquivalence() async throws {
        let server = try CatalogFixtureServer(missingSongOnce: true)
        let service = AppleCatalogService(loader: { try await server.apple($0) }, storefront: { "jp" })
        let response = try await service.lookup("18000000", country: "us", entity: nil)
        XCTAssertEqual(response.results.map(\.rawValue), ["apple:song:91001"])
        XCTAssertTrue(response.snapshot.works.allSatisfy { $0.storeCountry == "jp" })
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasPrefix("/v1/catalog/jp/") == true })
        let query = try XCTUnwrap(requests.last?.url).query ?? ""
        XCTAssertTrue(query.contains("equivalents")); XCTAssertTrue(query.contains("18000000"))
        XCTAssertFalse(requests.contains { $0.url?.path.contains("search") == true })
    }
    func testISRCFilterPreservesDistinctReleasesAndRejectsUnmatchedIdentity() async throws {
        let server = try CatalogFixtureServer()
        let original = try await server.fixture("song")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var song = try XCTUnwrap((root["data"] as? [[String: Any]])?.first)
        var second = song; second["id"] = "91011"
        var wrong = song; wrong["id"] = "91012"
        var attributes = try XCTUnwrap(wrong["attributes"] as? [String: Any]); attributes["isrc"] = "JPTST2600002"; wrong["attributes"] = attributes
        song["relationships"] = [:]; second["relationships"] = [:]; wrong["relationships"] = [:]
        root["data"] = [song, second, wrong]
        let bytes = try JSONSerialization.data(withJSONObject: root)
        let identity = CatalogIdentityService(loader: { _ in throw CatalogError.offline }, responseCache: nil)
        let service = AppleCatalogService(loader: { _ in bytes }, storefront: nil, alignment: identity)
        let matches = try await service.discover(.isrc("JP-TST-26-00001"), country: "jp")
        XCTAssertEqual(matches.map { $0.identity.catalogID }, ["91001", "91011"])
        XCTAssertTrue(matches.allSatisfy { !$0.incomplete.isEmpty })
    }
    func testWikidataSearchHitCannotAuthorizeMismatchingProperty() async throws {
        let server = try CatalogFixtureServer(wrongWikidataValue: true)
        let service = CatalogIdentityService(loader: { try await server.external($0) }, responseCache: nil)
        let matches = try await service.wikidata(property: "P1243", value: "JPTST2600001", budget: .init(limit: 12))
        XCTAssertTrue(matches.isEmpty, "Matching title/search hit does not establish ISRC identity")
    }
    func testBudgetStopsRequestsAndDoesNotInventMissingCredits() async throws {
        let server = try CatalogFixtureServer()
        let service = CatalogIdentityService(loader: { try await server.external($0) }, responseCache: nil)
        let result = try await service.musicBrainz(isrc: "JPTST2600001", budget: .init(limit: 1))
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(try XCTUnwrap(result.first).creditsComplete)
        XCTAssertTrue(result[0].credits.isEmpty)
        let count = await server.requests.count; XCTAssertEqual(count, 1)
    }
    func testSongAlbumArtistAndComposerAreTypedWithoutNameBasedMerging() async throws {
        let server = try CatalogFixtureServer()
        let service = AppleCatalogService(loader: { try await server.apple($0) }, storefront: nil)
        let song = try await service.lookup("91001", country: "jp", entity: nil)
        XCTAssertTrue(song.snapshot.relations.contains { $0.predicate == .composedBy && $0.to.rawValue == "apple:artist:93002" })
        XCTAssertTrue(song.snapshot.relations.allSatisfy { $0.source.detail.contains(".") })
        let album = try await service.lookup("92001", country: "jp", entity: "song")
        XCTAssertEqual(album.results.map(\.rawValue), ["apple:album:92001"])
        XCTAssertTrue(album.snapshot.relations.contains { $0.from.rawValue == "apple:song:91002" && $0.predicate == .inAlbum })
        let artist = try await service.resource("93001", kind: .artists, country: "jp")
        XCTAssertEqual(artist.first?.attributes?.genreNames, ["Alternative"])
        XCTAssertEqual(artist.first?.related("latest-release").first?.id, "92004")
    }
}

private actor CatalogFixtureServer {
    private let fixtures: [String: Data]
    private var missingSongOnce: Bool
    private let wrongWikidataValue: Bool
    private(set) var requests: [URLRequest] = []
    init(missingSongOnce: Bool = false, wrongWikidataValue: Bool = false) throws {
        let url = try XCTUnwrap(Bundle(for: AppleMusicCatalogTests.self).url(forResource: "music-kit-contract", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fixtures = try root.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        self.missingSongOnce = missingSongOnce; self.wrongWikidataValue = wrongWikidataValue
    }
    func fixture(_ name: String) throws -> Data { try XCTUnwrap(fixtures[name]) }
    func apple(_ request: URLRequest) throws -> Data {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.music.apple.com")
        if missingSongOnce { missingSongOnce = false; throw CatalogError.notFound }
        if url.path.contains("/albums/") { return try fixture("album") }
        if url.path.contains("/artists/") { return try fixture("artist") }
        if url.path.hasSuffix("/search") { return try fixture("search") }
        return try fixture("song")
    }
    func external(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try XCTUnwrap(request.url)
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let key: String
        if url.host == "musicbrainz.org" { key = url.path.contains("/isrc/") ? "mb-isrc" : "mb-recording" }
        else if fields["action"] == "query" { key = fields["srsearch"]?.contains("P2850") == true ? "artist-search" : "wikidata-search" }
        else { key = fields["ids"] == "Q99902" ? "artist-entity" : "wikidata-entity" }
        var data = try fixture(key)
        if wrongWikidataValue && key == "wikidata-entity" {
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "JPTST2600001", with: "JPTST2600099").utf8)
        }
        return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
