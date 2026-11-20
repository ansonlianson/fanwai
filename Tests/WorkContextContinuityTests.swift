import XCTest
@testable import Pianwai

/// Exercises the context-to-background cache key across real store lifetimes.
/// Services are isolated actors; no shared stores or network sessions are used.
@MainActor
final class WorkContextContinuityTests: XCTestCase {
    private let qid = "Q1329381"

    func testPartialRefreshAndOfflineColdStartKeepTheExactBackgroundCacheReachable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contextDirectory = directory.appendingPathComponent("context")
        let backgroundDirectory = directory.appendingPathComponent("background")
        let original = context(revision: 101)
        let article = try XCTUnwrap(original.article)
        let title = displayTitle(revision: 101)
        var partial = WorkContext(qid: qid)
        partial.introductionUnavailable = true
        let contextService = ContinuityContextService(bodies: [.success(original), .success(partial)],
                                                      titles: [.success(title)])
        let contexts = WorkContextStore(service: contextService, directory: contextDirectory)
        await contexts.load(qid)
        await contexts.loadDisplayTitle(qid)
        let expected = background(article)
        let backgroundService = ContinuityBackgroundService(responses: [expected])
        let backgrounds = WorkBackgroundStore(service: backgroundService, directory: backgroundDirectory)
        await backgrounds.load(article)
        let backgroundFile = backgroundDirectory.appendingPathComponent(article.cacheKey + ".json")
        let backgroundBytes = try Data(contentsOf: backgroundFile)

        await contexts.load(qid, retry: true)
        let retained = try XCTUnwrap(contexts.values[qid])
        XCTAssertEqual(retained.article, article)
        XCTAssertEqual(retained.displayTitle, title.title)
        XCTAssertEqual(retained.displayTitleSource, title.source)
        XCTAssertEqual(retained.displayTitleState, .available)
        XCTAssertTrue(retained.introductionUnavailable, "Cached reading is not a successful refresh")
        XCTAssertNotNil(contexts.errors[qid])
        XCTAssertEqual(backgrounds.values[try XCTUnwrap(retained.article).cacheKey]?.excerpts.map(\.body), expected.excerpts.map(\.body))
        let titleRequests = await contextService.titleRequests
        XCTAssertEqual(titleRequests, [article], "Retaining a verified revision must not issue another optional title lookup")

        let offlineContextService = ContinuityContextService(bodies: [.failure], titles: [])
        let recreatedContexts = WorkContextStore(service: offlineContextService, directory: contextDirectory)
        await recreatedContexts.load(qid)
        let restored = try XCTUnwrap(recreatedContexts.values[qid])
        let restoredArticle = try XCTUnwrap(restored.article)
        XCTAssertEqual(restoredArticle, article)
        XCTAssertEqual(restored.introductionSource, original.introductionSource)
        XCTAssertEqual(restored.displayTitleSource, title.source)
        XCTAssertTrue(restored.introductionUnavailable)
        XCTAssertNotNil(recreatedContexts.errors[qid])

        let offlineBackgroundService = ContinuityBackgroundService(responses: [])
        let recreatedBackgrounds = WorkBackgroundStore(service: offlineBackgroundService, directory: backgroundDirectory)
        await recreatedBackgrounds.load(restoredArticle)
        let restoredBackground = try XCTUnwrap(recreatedBackgrounds.values[restoredArticle.cacheKey])
        XCTAssertEqual(restoredBackground.article, article)
        XCTAssertEqual(restoredBackground.supplementalArticle, expected.supplementalArticle)
        XCTAssertEqual(restoredBackground.excerpts.map(\.body), expected.excerpts.map(\.body))
        XCTAssertEqual(restoredBackground.excerpts.first?.source, expected.excerpts.first?.source)
        XCTAssertEqual(restoredBackground.excerpts.first?.references, expected.excerpts.first?.references)
        XCTAssertNil(recreatedBackgrounds.errors[restoredArticle.cacheKey])
        XCTAssertEqual(try Data(contentsOf: backgroundFile), backgroundBytes)
        let offlineBackgroundRequests = await offlineBackgroundService.requests
        let offlineContextRequests = await offlineContextService.bodyRequests
        let offlineTitleRequests = await offlineContextService.titleRequests
        XCTAssertTrue(offlineBackgroundRequests.isEmpty, "The context must keep the original disk-cache key usable")
        XCTAssertEqual(offlineContextRequests, [qid], "An incomplete cached context retries, but its failure must not erase retained reading")
        XCTAssertTrue(offlineTitleRequests.isEmpty)
    }

    func testSuccessfulNoSitelinkReplacesOldArticleAndDoesNotResurrectItAfterColdStart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = context(revision: 101)
        let absent = WorkContext(qid: qid)
        let service = ContinuityContextService(bodies: [.success(original), .success(absent)],
                                               titles: [.success(displayTitle(revision: 101))])
        let store = WorkContextStore(service: service, directory: directory)
        await store.load(qid)
        await store.loadDisplayTitle(qid)
        XCTAssertNotNil(store.values[qid]?.article)
        XCTAssertNotNil(store.values[qid]?.displayTitleSource)

        await store.load(qid, retry: true)
        let result = try XCTUnwrap(store.values[qid])
        XCTAssertNil(result.article, "A confirmed lack of sitelink is different from a failed article request")
        XCTAssertNil(result.introduction)
        XCTAssertNil(result.introductionSource)
        XCTAssertNil(result.displayTitle)
        XCTAssertNil(result.displayTitleSource)
        XCTAssertFalse(result.introductionUnavailable)
        XCTAssertNil(store.errors[qid])

        let offline = ContinuityContextService(bodies: [], titles: [])
        let recreated = WorkContextStore(service: offline, directory: directory)
        await recreated.load(qid)
        XCTAssertNil(recreated.values[qid]?.article)
        XCTAssertNil(recreated.values[qid]?.displayTitle)
        XCTAssertEqual(recreated.values[qid]?.introductionUnavailable, false)
        XCTAssertNil(recreated.errors[qid])
        let requests = await offline.bodyRequests
        let titleRequests = await offline.titleRequests
        XCTAssertTrue(requests.isEmpty, "Fresh successful absence should remain a cached outcome")
        XCTAssertTrue(titleRequests.isEmpty)
    }

    func testNewVerifiedRevisionAfterPartialFailureUsesItsOwnTitleAndBackgroundIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = context(revision: 101)
        let next = context(revision: 202)
        let oldArticle = try XCTUnwrap(first.article)
        let newArticle = try XCTUnwrap(next.article)
        var partial = WorkContext(qid: qid)
        partial.introductionUnavailable = true
        let service = ContinuityContextService(bodies: [.success(first), .success(partial), .success(next)],
                                               titles: [.success(displayTitle(revision: 101)), .failure])
        let contextDirectory = directory.appendingPathComponent("context")
        let store = WorkContextStore(service: service, directory: contextDirectory)
        await store.load(qid)
        await store.loadDisplayTitle(qid)
        let oldBackground = background(oldArticle)
        let backgroundService = ContinuityBackgroundService(responses: [oldBackground])
        let backgrounds = WorkBackgroundStore(service: backgroundService, directory: directory.appendingPathComponent("background"))
        await backgrounds.load(oldArticle)
        await store.load(qid, retry: true)
        XCTAssertEqual(store.values[qid]?.article, oldArticle)
        XCTAssertNotNil(store.values[qid]?.displayTitleSource)

        await store.load(qid, retry: true)
        await store.loadDisplayTitle(qid)
        let current = try XCTUnwrap(store.values[qid])
        XCTAssertEqual(current.article, newArticle)
        XCTAssertEqual(current.introductionSource, next.introductionSource)
        XCTAssertFalse(current.introductionUnavailable)
        XCTAssertNil(current.displayTitle, "The cached old display name cannot label a newly verified revision")
        XCTAssertNil(current.displayTitleSource)
        XCTAssertEqual(current.displayTitleState, .failed)
        XCTAssertNil(store.errors[qid], "Optional title failure must not claim the new article failed")
        XCTAssertNotEqual(oldArticle.cacheKey, newArticle.cacheKey)
        XCTAssertNil(backgrounds.values[try XCTUnwrap(current.article).cacheKey], "The old background must not be rebound to the new revision")
        XCTAssertEqual(backgrounds.values[oldArticle.cacheKey]?.article, oldArticle, "Old evidence remains separately cached")
        let saved = try JSONDecoder().decode(WorkContext.self, from: Data(contentsOf: contextDirectory.appendingPathComponent(qid + ".json")))
        XCTAssertEqual(saved.article, newArticle)
        XCTAssertNil(saved.displayTitleSource)
        let requests = await service.titleRequests
        XCTAssertEqual(requests, [oldArticle, newArticle])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.ContextContinuity." + UUID().uuidString, isDirectory: true)
    }

    private func context(revision: Int) -> WorkContext {
        var value = WorkContext(qid: qid)
        value.article = WikiArticleIdentity(qid: qid, title: "關於莉莉周的一切", language: "zh", pageID: 4883, revision: revision)
        value.introduction = "原始简介版本 \(revision)。"
        value.language = "zh"
        value.introductionSource = Source(title: "维基百科 · 關於莉莉周的一切", detail: "导语摘录", url: "https://zh.wikipedia.org/w/index.php?oldid=\(revision)")
        return value
    }

    private func displayTitle(revision: Int) -> WorkDisplayTitle {
        WorkDisplayTitle(title: "关于莉莉周的一切", source: Source(title: "维基百科", detail: "中文显示名",
            url: "https://zh.wikipedia.org/w/index.php?oldid=\(revision)&variant=zh-cn"))
    }

    private func background(_ article: WikiArticleIdentity) -> WorkBackgroundResponse {
        let english = WikiArticleIdentity(qid: qid, title: "All About Lily Chou-Chou", language: "en", pageID: 3850268, revision: 303)
        let excerpt = WorkBackgroundExcerpt(id: "en:3850268:303:production", heading: "Production",
            body: "A previously read production excerpt.", sourceParagraph: "A previously read production excerpt.",
            source: Source(title: "Wikipedia · All About Lily Chou-Chou", detail: "Source excerpt",
                           url: "https://en.wikipedia.org/w/index.php?oldid=303#Production"), language: "en",
            references: [.init(label: "Love & Pop", title: "Love & Pop", language: "en")])
        return WorkBackgroundResponse(article: article, excerpts: [excerpt], supplementalArticle: english)
    }
}

private actor ContinuityContextService: WorkContextFetching {
    enum Body: Sendable { case success(WorkContext), failure }
    enum Title: Sendable { case success(WorkDisplayTitle), failure }
    private var bodies: [Body]
    private var titles: [Title]
    private(set) var bodyRequests: [String] = []
    private(set) var titleRequests: [WikiArticleIdentity] = []
    init(bodies: [Body], titles: [Title]) { self.bodies = bodies; self.titles = titles }
    func fetch(qid: String, includeDisplayTitle: Bool) async throws -> WorkContext {
        bodyRequests.append(qid)
        guard !includeDisplayTitle, !bodies.isEmpty else { throw WorkContextError.invalidResponse }
        switch bodies.removeFirst() {
        case .success(let value): return value
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
    func fetchDisplayTitle(article: WikiArticleIdentity) async throws -> WorkDisplayTitle? {
        titleRequests.append(article)
        guard !titles.isEmpty else { throw WorkContextError.invalidResponse }
        switch titles.removeFirst() {
        case .success(let value): return value
        case .failure: throw URLError(.notConnectedToInternet)
        }
    }
}

private actor ContinuityBackgroundService: WorkBackgroundFetching {
    private var responses: [WorkBackgroundResponse]
    private(set) var requests: [WikiArticleIdentity] = []
    init(responses: [WorkBackgroundResponse]) { self.responses = responses }
    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse {
        requests.append(article)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}
