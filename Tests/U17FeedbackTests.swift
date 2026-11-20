import XCTest
import UIKit
@testable import Pianwai

@MainActor final class U17FeedbackTests: XCTestCase {
    func testDeepSeekSearchDoesNotRequirePageBodyOrDuplicateV1() async throws {
        let backend = U17ProbeHTTP(body: #"{"results":[{"url":"https://musicbrainz.org/","content":""}]}"#)
        let result = try await ResearchCapabilityProbe.check(configuration(backend, base: "https://api.deepseek.com/v1"))
        XCTAssertEqual(result, .available)
        let paths = await backend.paths
        XCTAssertEqual(paths, ["/v1/chat/completions", "/v1/tools/search"])
    }

    func testSearchFailuresDoNotClaimSearchIsUnsupported() async throws {
        for body in [#"{"results":[]}"#, #"{"results":[{"url":"http://127.0.0.1/private"}]}"#, "invalid"] {
            let backend = U17ProbeHTTP(body: body)
            let result = try await ResearchCapabilityProbe.check(configuration(backend))
            XCTAssertEqual(result, .unverified)
        }
        for code in [403, 503] {
            let backend = U17ProbeHTTP(body: "{}", code: code)
            let result = try await ResearchCapabilityProbe.check(configuration(backend))
            XCTAssertEqual(result, .unverified)
        }
        let backend = U17ProbeHTTP(body: "{}", error: .timedOut)
        let result = try await ResearchCapabilityProbe.check(configuration(backend))
        XCTAssertEqual(result, .unverified)
    }

    func testRemovingInternalDeepSeekAccessSurvivesRelaunchAndOwnKeyWorks() throws {
        let suite = "U17.credentials." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? chain.remove("deepseek") }
        let access = InternalStoryModel.Access(preset: .init(id: "internal", name: "Fixture", api: .responses,
            baseURL: "https://example.com/v1", models: ["fixture"], modelsPath: nil, verifiedAt: "", source: ""),
            credential: .init(value: "fixture-internal"), deepseekCredential: .init(value: "fixture-bundled"))
        let http = StoryModelHTTP { request in
            (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: http, internalAccess: access)
        settings.selectProvider("deepseek")
        XCTAssertTrue(settings.hasKey)
        XCTAssertNil(try chain.read("deepseek"), "Bundled access must not be copied to a user's keychain")
        settings.removeKey()
        XCTAssertFalse(settings.hasKey); XCTAssertNil(settings.configuration())
        let relaunched = StoryModelSettings(defaults: defaults, keychain: chain, http: http, internalAccess: access)
        XCTAssertEqual(relaunched.preferences.providerID, "deepseek")
        XCTAssertFalse(relaunched.hasKey); XCTAssertNil(relaunched.configuration())
        relaunched.saveKey("fixture-own")
        XCTAssertTrue(relaunched.hasKey)
        XCTAssertEqual(relaunched.configuration()?.credential.value, "fixture-own")
        relaunched.removeKey()
        XCTAssertFalse(relaunched.hasKey)
    }

    /// anson 11-18: late cards join the end of the bin by themselves; nothing already shown moves.
    func testCrateVisitKeepsOrderAndAppendsLateCards() {
        var visit = CrateVisitInventory()
        visit.observe(root: "a", available: [])
        visit.observe(root: "a", available: ["first", "second", "first"])
        visit.observe(root: "a", available: ["late", "second", "first"])
        XCTAssertEqual(visit.visible(root: "a", available: ["late", "second", "first"]), ["first", "second", "late"])
        XCTAssertEqual(visit.pending(root: "a", available: ["late", "second", "first"]), 0)
        XCTAssertEqual(visit.visible(root: "a", available: ["newer", "late", "second", "first"]), ["first", "second", "late", "newer"])
        XCTAssertEqual(visit.visible(root: "a", available: ["first", "late"]), ["first", "late"])
        visit.observe(root: "b", available: ["other"])
        XCTAssertEqual(visit.visible(root: "b", available: ["other"]), ["other"])
    }

    func testTemporaryImageFailuresAllowAlternativeAndSuccessfulRetry() async throws {
        let data = UIGraphicsImageRenderer(size: .init(width: 2, height: 2)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.blue.setFill(); ctx.fill(.init(x: 0, y: 0, width: 2, height: 2))
        }
        for code in [403, 503] {
            let backend = U17ImageHTTP(data: data, firstCode: code)
            let cache = ArtworkImageCache(directory: nil, loader: { try await backend.load($0) })
            let url = URL(string: "https://example.com/cover-\(code).jpg")!
            let first = await cache.load(url)
            XCTAssertNil(first); XCTAssertTrue(cache.shouldTryAlternative(url)); XCTAssertFalse(cache.permanentlyMissing(url))
            let retry = await cache.load(url)
            XCTAssertNotNil(retry); XCTAssertFalse(cache.shouldTryAlternative(url))
        }
        for error in [URLError.Code.timedOut, .cancelled] {
            let backend = U17ImageHTTP(data: data, firstError: error)
            let cache = ArtworkImageCache(directory: nil, loader: { try await backend.load($0) })
            let url = URL(string: "https://example.com/\(error.rawValue).jpg")!
            let first = await cache.load(url)
            XCTAssertNil(first)
            XCTAssertEqual(cache.shouldTryAlternative(url), error != .cancelled)
            XCTAssertFalse(cache.permanentlyMissing(url))
            let retry = await cache.load(url)
            XCTAssertNotNil(retry)
        }
    }

    func testPartialDatabaseCardKeepsResearchLoading() async throws {
        let suite = "U17.partial." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? chain.remove("deepseek") }
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: .init { request in
            (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        settings.selectProvider("deepseek"); settings.saveKey("fixture-only")
        let catalog = CatalogStore(cacheURL: nil)
        let root = WorkID(rawValue: "local:u17-song")!, target = WorkID(rawValue: "local:u17-game")!
        let song = Work(id: root, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil)
        let game = Work(id: target, title: "Game", creator: "", kind: "游戏", art: "", detail: "", url: nil)
        try catalog.merge(.init(works: [song], relations: []))
        let library = Library(defaults: defaults, catalog: catalog), observation = U17PartialObservation()
        let result = DatabaseDiscoveryResult(snapshot: .init(works: [song, game], relations: [.init(from: root, to: target,
            predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐", source: .init(title: "Fixture", url: "https://example.com/game"), researchRoot: root)]))
        let research = LeadResearch(researchOperation: { _ in .init(leads: [], story: nil) },
            evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, modelSettings: settings,
            databaseOperation: { _, _, partial in
                await partial(result)
                await MainActor.run {
                    XCTAssertEqual(observation.research?.state(root.rawValue), .loading)
                    XCTAssertEqual(observation.research?.navigationLeads(root.rawValue, library: library).map(\.id), [target.rawValue])
                    observation.sawPartial = true
                }
                return result
            })
        observation.research = research
        await research.load(.init(id: root.rawValue, kind: .song, title: song.title, creator: song.creator, album: ""), library: library)
        XCTAssertTrue(observation.sawPartial)
        XCTAssertEqual(research.state(root.rawValue), .ready)
    }

    func testMissingMetadataCanRetryOnForegroundWithoutCachingAFailureAsAbsence() async {
        let service = U17ArtworkMetadata()
        let store = WorkArtworkStore(service: service, directory: nil)
        let work = Work(id: WorkID(rawValue: "local:u17-person")!, title: "Person", creator: "", kind: "人物",
            art: "", detail: "", url: nil, knowledgeID: "Q100")
        await store.loadWork(work)
        XCTAssertNil(store.metadata(for: work))
        XCTAssertNotNil(store.errors["Q100"])
        await store.loadWork(work, retry: true)
        XCTAssertNotNil(store.metadata(for: work))
        XCTAssertNil(store.errors["Q100"])
        let calls = await service.calls
        XCTAssertEqual(calls, 2)
    }

    private func configuration(_ backend: U17ProbeHTTP, base: String = "https://api.deepseek.com") -> ResearchModelConfiguration {
        .init(providerID: "deepseek", endpoint: .init(api: .openAI, baseURL: base, model: "fixture", modelsPath: nil),
            credential: .init(value: "fixture-only"), http: .init { try await backend.load($0) })
    }
}

@MainActor private final class U17PartialObservation {
    var research: LeadResearch?
    var sawPartial = false
}

private actor U17ProbeHTTP {
    let body: String; let code: Int; let error: URLError.Code?
    var paths: [String] = []
    init(body: String, code: Int = 200, error: URLError.Code? = nil) { self.body = body; self.code = code; self.error = error }
    func load(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        let search = request.url!.path.hasSuffix("/tools/search")
        if search, let error { throw URLError(error) }
        return (Data((search ? body : #"{"model":"fixture","choices":[{"message":{"content":"OK"}}]}"#).utf8),
            HTTPURLResponse(url: request.url!, statusCode: search ? code : 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor U17ImageHTTP {
    let data: Data; let firstCode: Int; let firstError: URLError.Code?
    var calls = 0
    init(data: Data, firstCode: Int = 200, firstError: URLError.Code? = nil) { self.data = data; self.firstCode = firstCode; self.firstError = firstError }
    func load(_ request: URLRequest) throws -> (Data, URLResponse) {
        calls += 1
        if calls == 1, let firstError { throw URLError(firstError) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: calls == 1 ? firstCode : 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor U17ArtworkMetadata: WorkArtworkFetching {
    var calls = 0
    func fetch(qid: String) throws -> WorkArtworkResponse {
        calls += 1
        if calls == 1 { throw URLError(.timedOut) }
        return .init(qid: qid, artwork: .init(id: "fixture", fileTitle: "Portrait.jpg",
            thumbnailURL: "https://example.com/portrait.jpg", sourcePageURL: "https://example.com/source",
            articleURL: "https://example.com/person", artist: nil, credit: nil, licenseName: nil, licenseURL: nil,
            isNonFree: nil, width: 100, height: 100))
    }
}
