import XCTest
@testable import Pianwai

/// Store contracts only: the actor spy never contacts Wikipedia or any network.
@MainActor
final class WorkBackgroundStoreTests: XCTestCase {
    func testFreshPreLeadEmptyCacheIsRefetchedAndReplacedWithCurrentVersion() async throws {
        struct PreLeadCache: Encodable {
            var version = 4
            let response: WorkBackgroundResponse
            var fetchedAt = Date()
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let article = identity(revision: 100)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = cacheFile(article, in: directory)
        try JSONEncoder().encode(PreLeadCache(response: .init(article: article, excerpts: []))).write(to: file)
        let expected = response(article, body: "The lead now supplies a complete cited creative sentence.")
        let service = BackgroundStoreSpy(outcomes: [.success(expected)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(article)

        try assertResponse(store.values[article.cacheKey], equals: expected)
        let requests = await service.requests
        XCTAssertEqual(requests, [article], "A fresh old empty cache must not hide newly supported lead material")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 7)
    }

    func testFreshV5MigrationKeepsReadableDataOfflineThenPersistsAndRestoresContinuationCandidates() async throws {
        struct LegacyCache: Encodable {
            var version = 5
            let response: WorkBackgroundResponse
            var fetchedAt = Date()
        }
        struct SavedCache: Decodable {
            let version: Int
            let response: WorkBackgroundResponse
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let article = identity(revision: 102)
        let legacy = response(article, body: "The previously read recording account remains available during migration.")
        let file = cacheFile(article, in: directory)
        let originalBytes = try JSONEncoder().encode(LegacyCache(response: legacy))
        try originalBytes.write(to: file)
        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        let legacyPayload = try XCTUnwrap(legacyJSON["response"] as? [String: Any])
        XCTAssertNil(legacyPayload["continuationCandidates"], "The migration must accept a payload written before this field existed")
        XCTAssertNil(legacyPayload["retainedContinuationCandidates"])

        var upgraded = legacy
        upgraded.continuationCandidates = [
            WorkBackgroundExcerpt(
                id: "en:42:102:continuation:1", heading: "Music",
                body: "A guest ensemble provided the theme song for the film.",
                sourceParagraph: "A guest ensemble provided the theme song for the film. The cited paragraph gives further recording details.",
                source: Source(title: "Wikipedia · Example Film", detail: "章节摘录 · CC BY-SA 4.0",
                               url: "https://en.wikipedia.org/w/index.php?oldid=102#Music"),
                language: "en", references: [.init(label: "guest ensemble", title: "Exact Ensemble", language: "en")])
        ]
        upgraded.retainedContinuationCandidates = [
            WorkBackgroundExcerpt(
                id: "en:42:102:original:1", heading: "Music",
                body: "The original account introduced the recording crew. A guest ensemble provided the theme song for the film.",
                sourceParagraph: "The original account introduced the recording crew. A guest ensemble provided the theme song for the film.",
                source: Source(title: "Wikipedia · Example Film", detail: "章节摘录 · CC BY-SA 4.0",
                               url: "https://en.wikipedia.org/w/index.php?oldid=102#Music"),
                language: "en", references: [.init(label: "guest ensemble", title: "Exact Ensemble", language: "en")])
        ]
        let service = BackgroundStoreSpy(outcomes: [.failure, .success(upgraded)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(article)

        try assertResponse(store.values[article.cacheKey], equals: legacy)
        XCTAssertNotNil(store.errors[article.cacheKey], "Fresh v5 data is readable, but still needs a migration fetch")
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        XCTAssertEqual(try Data(contentsOf: file), originalBytes, "A failed migration must leave the original v5 evidence untouched")
        await store.load(article)
        let afterFailure = await service.requests
        XCTAssertEqual(afterFailure, [article], "A failed migration must not loop whenever the view reloads")

        await store.load(article, retry: true)

        try assertResponse(store.values[article.cacheKey], equals: upgraded)
        XCTAssertNil(store.errors[article.cacheKey])
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        let afterRetry = await service.requests
        XCTAssertEqual(afterRetry, [article, article])
        let upgradedBytes = try Data(contentsOf: file)
        let saved = try JSONDecoder().decode(SavedCache.self, from: upgradedBytes)
        XCTAssertEqual(saved.version, 7)
        try assertResponse(saved.response, equals: upgraded)

        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(article)

        try assertResponse(recreated.values[article.cacheKey], equals: upgraded)
        XCTAssertNil(recreated.errors[article.cacheKey])
        XCTAssertFalse(recreated.loading.contains(article.cacheKey))
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty, "Cold-start v7 restoration must preserve both candidate pools without transport")
        XCTAssertEqual(try Data(contentsOf: file), upgradedBytes)
    }

    func testFreshV6MigrationRetainsTheChosenOriginalWhileAddingFocusedCandidates() async throws {
        struct LegacyCache: Encodable {
            var version = 6
            let response: WorkBackgroundResponse
            var fetchedAt = Date()
        }
        struct SavedCache: Decodable {
            let version: Int
            let response: WorkBackgroundResponse
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let article = WikiArticleIdentity(qid: "Q59788987", title: "Liz and the Blue Bird", language: "en",
                                          pageID: 60304198, revision: 1383036815)
        let source = Source(title: "Wikipedia · Liz and the Blue Bird", detail: "章节摘录 · CC BY-SA 4.0",
                            url: "https://en.wikipedia.org/w/index.php?oldid=1383036815#Music")
        let originalBody = "The crew also included Saito Shigeru as music producer, Yôta Tsuruoka as sound director, and Oowara Masahiro as supervising director of the wind band. The band Homecomings provided the theme song for the film, \"Songbirds\", which is the second song heard during the end credits."
        let focusedBody = "The band Homecomings provided the theme song for the film, \"Songbirds\", which is the second song heard during the end credits."
        let references = [WikiArticleReference(label: "Homecomings", title: "Homecomings (band)", language: "en")]
        let original = WorkBackgroundExcerpt(id: "en:60304198:1383036815:7:4", heading: "Music",
                                              body: originalBody, sourceParagraph: originalBody,
                                              source: source, language: "en", references: references)
        let focused = WorkBackgroundExcerpt(id: original.id + ":focus:151:126", heading: "Music",
                                             body: focusedBody, sourceParagraph: original.sourceParagraph,
                                             source: source, language: "en", references: references)
        XCTAssertEqual(original.body.count, 277)
        XCTAssertEqual(focused.body.count, 126)
        var legacy = response(article, body: "The previously displayed first account remains unchanged.")
        legacy.continuationCandidates = [original]
        let selectedID = original.id
        var upgraded = legacy
        upgraded.continuationCandidates = [focused]
        upgraded.retainedContinuationCandidates = [original]
        let file = cacheFile(article, in: directory)
        let originalBytes = try JSONEncoder().encode(LegacyCache(response: legacy))
        try originalBytes.write(to: file)
        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        let legacyPayload = try XCTUnwrap(legacyJSON["response"] as? [String: Any])
        XCTAssertNotNil(legacyPayload["continuationCandidates"])
        XCTAssertNil(legacyPayload["retainedContinuationCandidates"], "A genuine v6 payload predates the retained pool")

        let requested = expectation(description: "The v6 migration fetch is suspended")
        let service = BackgroundStoreSpy(outcomes: [.failure, .success(upgraded)], held: true, requested: requested)
        let store = WorkBackgroundStore(service: service, directory: directory)
        let migration = Task { await store.load(article) }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(started, .completed)
        guard started == .completed else {
            await service.release()
            await migration.value
            return
        }
        do {
            try assertResponse(store.values[article.cacheKey], equals: legacy)
            XCTAssertTrue(store.loading.contains(article.cacheKey), "The old v6 content must be readable while refresh is still in flight")
            XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        } catch {
            await service.release()
            await migration.value
            throw error
        }

        await service.release()
        await migration.value

        try assertResponse(store.values[article.cacheKey], equals: legacy)
        XCTAssertNotNil(store.errors[article.cacheKey])
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        XCTAssertEqual(store.values[article.cacheKey]?.continuationCandidates?.first(where: { $0.id == selectedID }), original)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes, "Failed migration must not erase the original chosen account")
        await store.load(article)
        let afterFailure = await service.requests
        XCTAssertEqual(afterFailure, [article], "Repeated view loads must not loop the failed migration")

        await store.load(article, retry: true)

        try assertResponse(store.values[article.cacheKey], equals: upgraded)
        XCTAssertNil(store.errors[article.cacheKey])
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        let afterRetry = await service.requests
        XCTAssertEqual(afterRetry, [article, article])
        XCTAssertEqual(store.values[article.cacheKey]?.retainedContinuationCandidates?.first(where: { $0.id == selectedID }), original,
                       "The stored selection must still identify its full original account after a successful refresh")
        XCTAssertFalse(store.values[article.cacheKey]?.continuationCandidates?.contains(where: { $0.id == selectedID }) ?? true,
                       "The focused account must not reuse the original account's identity")
        let upgradedBytes = try Data(contentsOf: file)
        let saved = try JSONDecoder().decode(SavedCache.self, from: upgradedBytes)
        XCTAssertEqual(saved.version, 7)
        try assertResponse(saved.response, equals: upgraded)

        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(article)

        try assertResponse(recreated.values[article.cacheKey], equals: upgraded)
        XCTAssertEqual(recreated.values[article.cacheKey]?.retainedContinuationCandidates?.first(where: { $0.id == selectedID }), original)
        XCTAssertNil(recreated.errors[article.cacheKey])
        XCTAssertFalse(recreated.loading.contains(article.cacheKey))
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty, "Fresh v7 restores both pools on cold start without a transport request")
        XCTAssertEqual(try Data(contentsOf: file), upgradedBytes)
    }

    func testSuccessfulExcerptSurvivesStoreRecreationWithoutFetchingAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let article = identity(revision: 101)
        let expected = response(article, body: "A verified excerpt retained across launches.")
        let firstService = BackgroundStoreSpy(outcomes: [.success(expected)])
        let firstStore = WorkBackgroundStore(service: firstService, directory: directory)

        await firstStore.load(article)
        try assertResponse(firstStore.values[article.cacheKey], equals: expected)
        XCTAssertNil(firstStore.errors[article.cacheKey])
        XCTAssertFalse(firstStore.loading.contains(article.cacheKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(article, in: directory).path))

        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(article)

        try assertResponse(recreated.values[article.cacheKey], equals: expected)
        XCTAssertNil(recreated.errors[article.cacheKey])
        let firstRequests = await firstService.requests
        let offlineRequests = await offlineService.requests
        XCTAssertEqual(firstRequests, [article])
        XCTAssertTrue(offlineRequests.isEmpty, "A fresh store should reuse the valid disk cache")
    }

    func testRevisionsOfTheSameItemRemainSeparateInMemoryAndOnDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = identity(revision: 201)
        let newer = identity(revision: 202)
        let oldResponse = response(older, body: "The earlier revision has this source paragraph.")
        let newResponse = response(newer, body: "The later revision contains a different excerpt.")
        let service = BackgroundStoreSpy(outcomes: [.success(oldResponse), .success(newResponse)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(older)
        await store.load(newer)

        XCTAssertEqual(older.qid, newer.qid)
        XCTAssertNotEqual(older.cacheKey, newer.cacheKey)
        try assertResponse(store.values[older.cacheKey], equals: oldResponse)
        try assertResponse(store.values[newer.cacheKey], equals: newResponse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(older, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(newer, in: directory).path))
        let requests = await service.requests
        XCTAssertEqual(requests, [older, newer])

        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(newer)
        await recreated.load(older)
        try assertResponse(recreated.values[older.cacheKey], equals: oldResponse)
        try assertResponse(recreated.values[newer.cacheKey], equals: newResponse)
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty)
    }

    func testConcurrentLoadsJoinTheSameInFlightFetch() async throws {
        let article = identity(revision: 301)
        let expected = response(article, body: "All readers receive the same completed excerpt.")
        let requested = expectation(description: "The first fetch is suspended")
        let service = BackgroundStoreSpy(outcomes: [.success(expected)], held: true, requested: requested)
        let store = WorkBackgroundStore(service: service, directory: nil)
        let first = Task { await store.load(article) }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(started, .completed)
        guard started == .completed else {
            await service.release()
            await first.value
            return
        }
        XCTAssertTrue(store.loading.contains(article.cacheKey))
        XCTAssertNil(store.values[article.cacheKey])

        let joined = expectation(description: "Other readers request the same article")
        joined.expectedFulfillmentCount = 4
        let followers = (0..<4).map { _ in
            Task { @MainActor in
                joined.fulfill()
                await store.load(article)
            }
        }
        let allStarted = await XCTWaiter.fulfillment(of: [joined], timeout: 3)
        XCTAssertEqual(allStarted, .completed)
        let inFlightRequests = await service.requests
        XCTAssertEqual(inFlightRequests, [article], "Concurrent readers must join the outstanding fetch")
        XCTAssertTrue(store.loading.contains(article.cacheKey))

        await service.release()
        await first.value
        for follower in followers { await follower.value }

        try assertResponse(store.values[article.cacheKey], equals: expected)
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        XCTAssertNil(store.errors[article.cacheKey])
        let completedRequests = await service.requests
        XCTAssertEqual(completedRequests, [article])
    }

    func testFailedRetryKeepsDisplayedExcerptAndValidDiskCacheUntouched() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let article = identity(revision: 401)
        let expected = response(article, body: "This existing excerpt must survive a failed refresh.")
        let service = BackgroundStoreSpy(outcomes: [.success(expected), .failure])
        let store = WorkBackgroundStore(service: service, directory: directory)
        await store.load(article)
        let file = cacheFile(article, in: directory)
        let before = try Data(contentsOf: file)

        await store.load(article, retry: true)

        try assertResponse(store.values[article.cacheKey], equals: expected)
        XCTAssertNotNil(store.errors[article.cacheKey])
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        XCTAssertEqual(try Data(contentsOf: file), before, "A failure must not overwrite the valid cached source")
        let requests = await service.requests
        XCTAssertEqual(requests, [article, article])

        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(article)
        try assertResponse(recreated.values[article.cacheKey], equals: expected)
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty)
    }

    func testFetchFailureIsAnErrorNotASuccessfulEmptyResponseAndRetryCanRecover() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let article = identity(revision: 501)
        let expected = response(article, body: "The retry successfully loads a source excerpt.")
        let service = BackgroundStoreSpy(outcomes: [.failure, .success(expected)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(article)

        XCTAssertNil(store.values[article.cacheKey], "An unavailable source is not a known-empty article")
        XCTAssertNotNil(store.errors[article.cacheKey])
        XCTAssertFalse(store.loading.contains(article.cacheKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile(article, in: directory).path))
        await store.load(article)
        let afterAutomaticReload = await service.requests
        XCTAssertEqual(afterAutomaticReload, [article], "Repeated view tasks must not silently hammer a failed source")
        XCTAssertNotNil(store.errors[article.cacheKey])

        await store.load(article, retry: true)

        try assertResponse(store.values[article.cacheKey], equals: expected)
        XCTAssertNil(store.errors[article.cacheKey])
        let afterRetry = await service.requests
        XCTAssertEqual(afterRetry, [article, article])
    }

    func testSuccessfulArticleWithNoEligibleExcerptsIsCachedAsKnownEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let article = identity(revision: 601)
        let empty = WorkBackgroundResponse(article: article, excerpts: [])
        let service = BackgroundStoreSpy(outcomes: [.success(empty)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(article)
        await store.load(article)

        try assertResponse(store.values[article.cacheKey], equals: empty)
        XCTAssertNil(store.errors[article.cacheKey])
        let requests = await service.requests
        XCTAssertEqual(requests, [article])
        let offlineService = BackgroundStoreSpy(outcomes: [])
        let recreated = WorkBackgroundStore(service: offlineService, directory: directory)
        await recreated.load(article)
        try assertResponse(recreated.values[article.cacheKey], equals: empty)
        XCTAssertNil(recreated.errors[article.cacheKey])
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty, "Known-empty success is useful cache data, not a reason to fetch repeatedly")
    }

    func testServiceResponseForAnotherRevisionIsRejectedWithoutPublishingOrCaching() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = identity(revision: 701)
        let wrong = response(identity(revision: 702), body: "This paragraph belongs to another revision.")
        let service = BackgroundStoreSpy(outcomes: [.success(wrong)])
        let store = WorkBackgroundStore(service: service, directory: directory)

        await store.load(requested)

        XCTAssertNil(store.values[requested.cacheKey])
        XCTAssertNil(store.values[wrong.article.cacheKey])
        XCTAssertNotNil(store.errors[requested.cacheKey])
        XCTAssertFalse(store.loading.contains(requested.cacheKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile(requested, in: directory).path))
    }

    private func identity(revision: Int) -> WikiArticleIdentity {
        WikiArticleIdentity(qid: "Q100", title: "Example Film", language: "en", pageID: 42, revision: revision)
    }

    private func response(_ article: WikiArticleIdentity, body: String) -> WorkBackgroundResponse {
        WorkBackgroundResponse(article: article, excerpts: [
            WorkBackgroundExcerpt(id: "\(article.revision):1", heading: "Production", body: body,
                                  sourceParagraph: body + " The original paragraph retains additional context.",
                                  source: Source(title: "Wikipedia · \(article.title)", detail: "Source excerpt · CC BY-SA 4.0",
                                                 url: "https://en.wikipedia.org/w/index.php?oldid=\(article.revision)#Production"),
                                  language: article.language)
        ])
    }

    private func assertResponse(_ actual: WorkBackgroundResponse?, equals expected: WorkBackgroundResponse,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.article, expected.article, file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.id), expected.excerpts.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.heading), expected.excerpts.map(\.heading), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.body), expected.excerpts.map(\.body), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.sourceParagraph), expected.excerpts.map(\.sourceParagraph), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.source), expected.excerpts.map(\.source), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.language), expected.excerpts.map(\.language), file: file, line: line)
        XCTAssertEqual(actual.excerpts.map(\.references), expected.excerpts.map(\.references), file: file, line: line)
        XCTAssertEqual(actual.supplementalArticle, expected.supplementalArticle, file: file, line: line)
        XCTAssertEqual(actual.continuationCandidates, expected.continuationCandidates, file: file, line: line)
        XCTAssertEqual(actual.retainedContinuationCandidates, expected.retainedContinuationCandidates, file: file, line: line)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiWorkBackgroundStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cacheFile(_ article: WikiArticleIdentity, in directory: URL) -> URL {
        directory.appendingPathComponent(article.cacheKey + ".json")
    }
}

private actor BackgroundStoreSpy: WorkBackgroundFetching {
    enum Outcome: Sendable {
        case success(WorkBackgroundResponse)
        case failure
    }
    enum Failure: Error { case expected, unexpectedRequest }
    private var outcomes: [Outcome]
    private var held: Bool
    private let requested: XCTestExpectation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [WikiArticleIdentity] = []

    init(outcomes: [Outcome], held: Bool = false, requested: XCTestExpectation? = nil) {
        self.outcomes = outcomes
        self.held = held
        self.requested = requested
    }

    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse {
        requests.append(article)
        // The expectation marks the initial suspended request, not later retries.
        if requests.count == 1 { requested?.fulfill() }
        guard !outcomes.isEmpty else { throw Failure.unexpectedRequest }
        let outcome = outcomes.removeFirst()
        if held { await withCheckedContinuation { waiters.append($0) } }
        switch outcome {
        case .success(let response): return response
        case .failure: throw Failure.expected
        }
    }

    func release() {
        held = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
