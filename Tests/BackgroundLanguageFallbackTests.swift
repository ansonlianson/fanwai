import XCTest
@testable import Pianwai

final class BackgroundLanguageFallbackTests: XCTestCase, @unchecked Sendable {
    private let chinese = WikiArticleIdentity(qid: "Q1329381", title: "关于莉莉周的一切", language: "zh", pageID: 4883, revision: 92470148)
    private let english = WikiArticleIdentity(qid: "Q1329381", title: "All About Lily Chou-Chou", language: "en", pageID: 3850268, revision: 1379531656)

    func testUsableChineseExcerptsNeverRequestAnotherLanguage() async throws {
        let original = WorkBackgroundResponse(article: chinese, excerpts: [excerpt(language: "zh")])
        let primary = FallbackPrimary([.response(original)])
        let h = FallbackHarness(primary: primary, plans: []); defer { h.close() }
        let result = try await h.service.fetch(article: chinese)
        XCTAssertEqual(result.article, chinese)
        XCTAssertEqual(result.excerpts.map(\.body), original.excerpts.map(\.body))
        XCTAssertNil(result.supplementalArticle)
        let calls = await primary.requests
        XCTAssertEqual(calls, [chinese])
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testEnglishInputNeverRecursesEvenWhenEmpty() async throws {
        let primary = FallbackPrimary([.response(.init(article: english, excerpts: []))])
        let h = FallbackHarness(primary: primary, plans: []); defer { h.close() }
        let result = try await h.service.fetch(article: english)
        XCTAssertTrue(result.excerpts.isEmpty)
        XCTAssertNil(result.supplementalArticle)
        let calls = await primary.requests
        XCTAssertEqual(calls, [english])
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testSameQIDFallbackKeepsChineseContextAndCompleteEnglishRevisionIdentity() async throws {
        let englishExcerpt = excerpt(language: "en")
        let englishCandidate = WorkBackgroundExcerpt(
            id: "\(english.cacheKey):alternative", heading: "Music",
            body: "An additional source account mentions another recording.",
            sourceParagraph: "An additional source account mentions another recording. Its original paragraph remains available.",
            source: Source(title: "Wikipedia", detail: "Additional source excerpt",
                           url: "https://en.wikipedia.org/w/index.php?oldid=\(english.revision)#Music"),
            language: "en", references: [.init(label: "the composer", title: "Takeshi Kobayashi", language: "en")])
        let retainedCandidate = WorkBackgroundExcerpt(
            id: "\(english.cacheKey):original-alternative", heading: englishCandidate.heading,
            body: "The original account first introduced the crew. " + englishCandidate.body,
            sourceParagraph: "The original account first introduced the crew. " + englishCandidate.sourceParagraph,
            source: englishCandidate.source, language: "en", references: englishCandidate.references)
        let primary = FallbackPrimary([
            .response(.init(article: chinese, excerpts: [])),
            .response(.init(article: english, excerpts: [englishExcerpt], continuationCandidates: [englishCandidate],
                            retainedContinuationCandidates: [retainedCandidate]))
        ])
        let h = FallbackHarness(primary: primary, plans: try validPlans()); defer { h.close() }
        let result = try await h.service.fetch(article: chinese)
        XCTAssertEqual(result.article, chinese, "The Chinese work identity and title remain the response's primary identity")
        XCTAssertEqual(result.supplementalArticle, english)
        XCTAssertEqual(result.excerpts.map(\.body), [englishExcerpt.body])
        XCTAssertEqual(result.excerpts.first?.source.url, englishExcerpt.source.url)
        XCTAssertEqual(result.excerpts.first?.references, englishExcerpt.references)
        XCTAssertEqual(result.excerpts.first?.language, "en")
        XCTAssertEqual(result.continuationCandidates, [englishCandidate],
                       "Changing the primary context language must preserve complete continuation candidates, including their English source identity")
        XCTAssertEqual(result.retainedContinuationCandidates, [retainedCandidate],
                       "The retained original must keep its own ID, full body, source paragraph, revision URL and exact links")
        let calls = await primary.requests
        XCTAssertEqual(calls, [chinese, english])
        XCTAssertEqual(h.requests.count, 2)
        let entityQuery = query(h.requests[0])
        XCTAssertEqual(entityQuery["ids"], chinese.qid)
        XCTAssertEqual(entityQuery["sitefilter"], "enwiki")
        let articleQuery = query(h.requests[1])
        XCTAssertEqual(articleQuery["titles"], english.title)
        XCTAssertEqual(articleQuery["ppprop"], "wikibase_item|disambiguation")
        XCTAssertTrue(h.requests.allSatisfy { query($0)["search"] == nil && query($0)["srsearch"] == nil })
        let decoded = try JSONDecoder().decode(WorkBackgroundResponse.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.article, chinese)
        XCTAssertEqual(decoded.supplementalArticle, english, "Cache round trips must not lose the secondary revision identity")
        XCTAssertEqual(decoded.excerpts, [englishExcerpt])
        XCTAssertEqual(decoded.continuationCandidates, [englishCandidate],
                       "Cache round trips must preserve candidate IDs, source paragraphs, revision URLs, and exact article links")
        XCTAssertEqual(decoded.retainedContinuationCandidates, [retainedCandidate],
                       "Cache round trips must not merge the already-read original into the focused candidate pool")
    }

    func testValidEntityWithoutEnglishSitelinkIsSuccessfulEmpty() async throws {
        let emptyArray = try json(["success": 1, "entities": [chinese.qid: ["id": chinese.qid, "type": "item", "sitelinks": []]]])
        for data in [try entity(title: nil), emptyArray] {
            let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: []))])
            let h = FallbackHarness(primary: primary, plans: [.init(host: "www.wikidata.org", data: data)])
            let result = try await h.service.fetch(article: chinese)
            XCTAssertEqual(result.article, chinese)
            XCTAssertTrue(result.excerpts.isEmpty)
            XCTAssertNil(result.supplementalArticle)
            let calls = await primary.requests
            XCTAssertEqual(calls, [chinese])
            h.close()
        }
    }

    func testEmptyEnglishResultStillRecordsWhichVerifiedRevisionWasRead() async throws {
        let primary = FallbackPrimary([
            .response(.init(article: chinese, excerpts: [])),
            .response(.init(article: english, excerpts: []))
        ])
        let h = FallbackHarness(primary: primary, plans: try validPlans()); defer { h.close() }
        let result = try await h.service.fetch(article: chinese)
        XCTAssertTrue(result.excerpts.isEmpty)
        XCTAssertEqual(result.article, chinese)
        XCTAssertEqual(result.supplementalArticle, english)
    }

    func testWrongEntityQIDAndWrongSitelinkSiteDoNotReachEnglishArticle() async throws {
        for data in [try entity(qid: "Q579744"), try entity(site: "frwiki")] {
            let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: []))])
            let h = FallbackHarness(primary: primary, plans: [.init(host: "www.wikidata.org", data: data)])
            await assertRejected(h.service, article: chinese)
            let calls = await primary.requests
            XCTAssertEqual(calls, [chinese])
            XCTAssertEqual(h.requests.count, 1)
            h.close()
        }
    }

    func testUnverifiedEnglishPageNeverReachesExcerptExtraction() async throws {
        let invalidPages = [
            try article(qid: "Q579744"), try article(language: "fr"),
            try article(disambiguation: true), try article(namespace: 1),
            try article(pageID: 0), try article(revision: 0),
            try article(title: "A different work"), try article(missing: true)
        ]
        for data in invalidPages {
            let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: []))])
            let h = FallbackHarness(primary: primary, plans: [
                .init(host: "www.wikidata.org", data: try entity()), .init(host: "en.wikipedia.org", data: data)
            ])
            await assertRejected(h.service, article: chinese)
            let calls = await primary.requests
            XCTAssertEqual(calls, [chinese])
            h.close()
        }
    }

    func testMalformedIdentityResponsesAndHTTPFailuresNeverBecomeEmptySuccess() async throws {
        let badPlans: [[FallbackPlan]] = [
            [.init(host: "www.wikidata.org", data: Data("{}".utf8))],
            [.init(host: "www.wikidata.org", data: try json(["success": 1, "entities": [chinese.qid: ["id": chinese.qid, "type": "item"]]]))],
            [.init(host: "www.wikidata.org", data: try entity(), status: 503)],
            [.init(host: "www.wikidata.org", data: try entity(), responseHost: "evil.example")],
            [.init(host: "www.wikidata.org", data: try entity()), .init(host: "en.wikipedia.org", data: Data("{broken".utf8))],
            [.init(host: "www.wikidata.org", data: try entity()), .init(host: "en.wikipedia.org", data: try article(), status: 429)],
            [.init(host: "www.wikidata.org", data: try entity()), .init(host: "en.wikipedia.org", data: try json(["error": ["code": "maxlag"]]))]
        ]
        for plans in badPlans {
            let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: []))])
            let h = FallbackHarness(primary: primary, plans: plans)
            await assertRejected(h.service, article: chinese)
            let calls = await primary.requests
            XCTAssertEqual(calls, [chinese])
            h.close()
        }
    }

    func testNetworkAndNetworkCancellationErrorsPropagateWithoutFalseEmpty() async throws {
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .cancelled] {
            for failAtArticle in [false, true] {
                let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: []))])
                var plans = [FallbackPlan]()
                if failAtArticle { plans.append(.init(host: "www.wikidata.org", data: try entity())) }
                plans.append(.init(host: failAtArticle ? "en.wikipedia.org" : "www.wikidata.org", data: Data(), failure: code))
                let h = FallbackHarness(primary: primary, plans: plans)
                do { _ = try await h.service.fetch(article: chinese); XCTFail("Network failure became empty success") }
                catch let error as URLError { XCTAssertEqual(error.code, code) }
                let calls = await primary.requests
                XCTAssertEqual(calls, [chinese])
                h.close()
            }
        }
    }

    func testPrimaryFailureCannotTriggerFallback() async throws {
        for reply in [FallbackPrimary.Reply.failure(.timedOut), .cancelled] {
            let primary = FallbackPrimary([reply])
            let h = FallbackHarness(primary: primary, plans: []); defer { h.close() }
            do { _ = try await h.service.fetch(article: chinese); XCTFail("Primary failure became success") }
            catch is CancellationError { }
            catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertTrue(h.requests.isEmpty)
        }
    }

    func testEnglishExtractionFailurePropagatesAfterVerifiedIdentity() async throws {
        let primary = FallbackPrimary([.response(.init(article: chinese, excerpts: [])), .failure(.timedOut)])
        let h = FallbackHarness(primary: primary, plans: try validPlans()); defer { h.close() }
        do { _ = try await h.service.fetch(article: chinese); XCTFail("Secondary extraction failure became cached empty") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let calls = await primary.requests
        XCTAssertEqual(calls, [chinese, english])
    }

    func testCancelledTaskCannotStartPrimary() async throws {
        let primary = FallbackPrimary([])
        let h = FallbackHarness(primary: primary, plans: []); defer { h.close() }
        let article = chinese
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await h.service.fetch(article: article)
        }
        do { _ = try await task.value; XCTFail("Cancelled task started work") }
        catch is CancellationError { }
        let calls = await primary.requests
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testCancellationAfterEitherProviderResponseNeverReturnsSuccess() async throws {
        for cancelEnglish in [false, true] {
            var replies = [FallbackPrimary.Reply]()
            if cancelEnglish {
                replies = [.response(.init(article: chinese, excerpts: [])), .cancelThenRespond(.init(article: english, excerpts: [excerpt(language: "en")]))]
            } else { replies = [.cancelThenRespond(.init(article: chinese, excerpts: []))] }
            let primary = FallbackPrimary(replies)
            let h = FallbackHarness(primary: primary, plans: cancelEnglish ? try validPlans() : [])
            let article = chinese
            let task = Task { try await h.service.fetch(article: article) }
            do { _ = try await task.value; XCTFail("Provider ignored cancellation and wrapper returned success") }
            catch is CancellationError { }
            let calls = await primary.requests
            XCTAssertEqual(calls, cancelEnglish ? [chinese, english] : [chinese])
            h.close()
        }
    }

    func testMismatchedProviderIdentityCannotBeReboundToChineseWork() async throws {
        for mismatchAtEnglish in [false, true] {
            let replies: [FallbackPrimary.Reply] = mismatchAtEnglish
                ? [.response(.init(article: chinese, excerpts: [])), .response(.init(article: chinese, excerpts: [excerpt(language: "en")]))]
                : [.response(.init(article: english, excerpts: []))]
            let primary = FallbackPrimary(replies)
            let h = FallbackHarness(primary: primary, plans: mismatchAtEnglish ? try validPlans() : [])
            await assertRejected(h.service, article: chinese)
            h.close()
        }
    }

    func testExistingCachedResponseWithoutSupplementalIdentityStillDecodes() throws {
        let old = try json([
            "article": ["qid": chinese.qid, "title": chinese.title, "language": chinese.language, "pageID": chinese.pageID, "revision": chinese.revision],
            "excerpts": []
        ])
        let result = try JSONDecoder().decode(WorkBackgroundResponse.self, from: old)
        XCTAssertEqual(result.article, chinese)
        XCTAssertNil(result.supplementalArticle)
        XCTAssertNil(result.continuationCandidates)
        XCTAssertNil(result.retainedContinuationCandidates)
    }

    private func assertRejected(_ service: FallbackWorkBackgroundService, article: WikiArticleIdentity,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await service.fetch(article: article); XCTFail("Invalid evidence became success", file: file, line: line) }
        catch is WorkBackgroundError { }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private func excerpt(language: String) -> WorkBackgroundExcerpt {
        .init(id: language + ":sample", heading: "Production", body: "The director recorded the music with the composer.",
              sourceParagraph: "The director recorded the music with the composer.",
              source: Source(title: "Wikipedia", detail: "Source excerpt", url: "https://\(language).wikipedia.org/w/index.php?oldid=1379531656#Production"),
              language: language, references: [.init(label: "the composer", title: "Takeshi Kobayashi", language: language)])
    }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func validPlans() throws -> [FallbackPlan] {
        [.init(host: "www.wikidata.org", data: try entity()), .init(host: "en.wikipedia.org", data: try article())]
    }
    private func entity(qid: String = "Q1329381", site: String = "enwiki", title: String? = "All About Lily Chou-Chou") throws -> Data {
        let links: [String: Any] = title.map { ["enwiki": ["site": site, "title": $0]] } ?? [:]
        return try json(["success": 1, "entities": [qid: ["id": qid, "type": "item", "sitelinks": links]]])
    }
    private func article(qid: String = "Q1329381", language: String = "en", disambiguation: Bool = false,
                         namespace: Int = 0, pageID: Int = 3850268, revision: Int = 1379531656,
                         title: String = "All About Lily Chou-Chou", missing: Bool = false) throws -> Data {
        var properties = ["wikibase_item": qid]
        if disambiguation { properties["disambiguation"] = "" }
        return try json(["query": ["pages": [["title": title, "ns": namespace, "pageid": pageID, "lastrevid": revision,
                                              "pagelanguage": language, "missing": missing, "pageprops": properties]]]])
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

private actor FallbackPrimary: WorkBackgroundFetching {
    enum Reply: Sendable {
        case response(WorkBackgroundResponse), cancelThenRespond(WorkBackgroundResponse)
        case failure(URLError.Code), cancelled
    }
    private var replies: [Reply]
    private(set) var requests: [WikiArticleIdentity] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse {
        requests.append(article)
        guard !replies.isEmpty else { throw WorkBackgroundError.invalidResponse }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .cancelThenRespond(let response):
            withUnsafeCurrentTask { $0?.cancel() }
            return response
        case .failure(let code): throw URLError(code)
        case .cancelled: throw CancellationError()
        }
    }
}

private struct FallbackPlan: Sendable {
    let host: String
    let data: Data
    var status = 200
    var failure: URLError.Code? = nil
    var responseHost: String? = nil
}
private final class FallbackHarness: @unchecked Sendable {
    let service: FallbackWorkBackgroundService
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: FallbackNetworkState
    init(primary: any WorkBackgroundFetching, plans: [FallbackPlan]) {
        state = FallbackNetworkState(plans)
        FallbackRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FallbackProtocol.self]
        config.httpAdditionalHeaders = ["X-Language-Fallback-Test": token]
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        service = FallbackWorkBackgroundService(primary: primary, session: session)
    }
    var requests: [URLRequest] { state.requests }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.remaining, 0, file: file, line: line)
        session.invalidateAndCancel()
        FallbackRegistry.shared.remove(token)
    }
}
private final class FallbackNetworkState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [FallbackPlan]
    private var observed: [URLRequest] = []
    init(_ plans: [FallbackPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return plans.count }
    func next(_ request: URLRequest) -> FallbackPlan? {
        lock.lock(); defer { lock.unlock() }
        observed.append(request)
        guard let first = plans.first, first.host == request.url?.host else { return nil }
        return plans.removeFirst()
    }
}
private final class FallbackRegistry: @unchecked Sendable {
    static let shared = FallbackRegistry()
    private let lock = NSLock()
    private var states: [String: FallbackNetworkState] = [:]
    func put(_ key: String, _ state: FallbackNetworkState) { lock.lock(); defer { lock.unlock() }; states[key] = state }
    func get(_ key: String?) -> FallbackNetworkState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { states[$0] } }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; states.removeValue(forKey: key) }
}
private final class FallbackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = FallbackRegistry.shared.get(request.value(forHTTPHeaderField: "X-Language-Fallback-Test")),
              let plan = state.next(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if let code = plan.failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let host = plan.responseHost { parts.host = host }
        let response = HTTPURLResponse(url: parts.url!, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
