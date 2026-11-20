import XCTest
@testable import Pianwai

@MainActor
final class WorkContextEditionTests: XCTestCase {
    func testExactEditionChainPreservesEverySourceAndUsesVerifiedEditionYear() async throws {
        var root = editionRoot()
        root = changingEditionClaim(root, property: "P747") { claim in
            claim["qualifiers"] = ["P407": [editionSnak("P407", datatype: "wikibase-item", value: ["id": "Q13414913"])]]
        }
        var edition = editionItem()
        edition = changingEditionClaim(edition, property: "P6442") { claim in
            claim["qualifiers"] = ["P1810": [editionSnak("P1810", datatype: "string", value: "挪威的森林")]]
        }
        let h = try EditionHarness(root: root, editions: [edition]); defer { h.close() }
        let results = try await h.service.fetch(qid: "Q100")
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(result.originalQID, "Q100")
        XCTAssertEqual(result.editionQID, "Q200")
        XCTAssertEqual(result.destination.title, "豆瓣 · 2014版")
        XCTAssertEqual(result.destination.url, "https://book.douban.com/subject/25859657/")
        XCTAssertEqual(URLComponents(string: result.discoverySource.url)?.fragment, editionStatement("Q100", "P747"))
        XCTAssertEqual(URLComponents(string: result.correspondenceSource.url)?.fragment, editionStatement("Q200", "P629"))
        XCTAssertEqual(URLComponents(string: result.editionTypeSource.url)?.fragment, editionStatement("Q200", "P31"))
        XCTAssertEqual(URLComponents(string: result.destination.source.url)?.fragment, editionStatement("Q200", "P6442"))
        XCTAssertEqual(URLComponents(string: try XCTUnwrap(result.publicationSource).url)?.fragment, editionStatement("Q200", "P577"))
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q200")
        XCTAssertEqual(h.parameters(at: 1)["props"], "labels|claims")
    }

    func testWrongBacklinkWrongTypeAndConflictingOriginalsNeverBecomeDestinations() async throws {
        var conflict = editionItem()
        var claims = conflict["claims"] as! [String: [[String: Any]]]
        claims["P629"] = [editionClaim("Q200", "P629", item: "Q100"), editionClaim("Q200", "P629", item: "Q999")]
        conflict["claims"] = claims
        for edition in [editionItem(original: "Q999"), editionItem(type: "Q571"), conflict] {
            let h = try EditionHarness(root: editionRoot(), editions: [edition]); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(results.isEmpty)
        }
    }

    func testDeprecatedClaimsAtEveryProofStepAreRejected() async throws {
        for property in ["P747", "P31", "P629", "P6442"] {
            var root = editionRoot(); var edition = editionItem()
            if property == "P747" { root = changingEditionClaim(root, property: property) { $0["rank"] = "deprecated" } }
            else { edition = changingEditionClaim(edition, property: property) { $0["rank"] = "deprecated" } }
            let h = try EditionHarness(root: root, editions: property == "P747" ? nil : [edition]); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(results.isEmpty, property)
        }
    }

    func testUnknownQualifiersAtEveryProofStepAreNotSilentlyDiscarded() async throws {
        for property in ["P747", "P31", "P629", "P6442"] {
            let qualify: (inout [String: Any]) -> Void = {
                $0["qualifiers"] = ["P518": [editionSnak("P518", datatype: "wikibase-item", value: ["id": "Q999"])]]
            }
            var root = editionRoot(); var edition = editionItem()
            if property == "P747" { root = changingEditionClaim(root, property: property, qualify) }
            else { edition = changingEditionClaim(edition, property: property, qualify) }
            let h = try EditionHarness(root: root, editions: property == "P747" ? nil : [edition]); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(results.isEmpty, property)
        }
    }

    func testLanguageQualifierMustBeARealItemValue() async throws {
        let variants: [[String: Any]] = [
            ["P407": []],
            ["P407": [editionSnak("P407", datatype: "string", value: "zh")]],
            ["P407": [editionSnak("P407", datatype: "wikibase-item", value: ["id": "Q0"])]]
        ]
        for qualifiers in variants {
            let root = changingEditionClaim(editionRoot(), property: "P747") { $0["qualifiers"] = qualifiers }
            let h = try EditionHarness(root: root, editions: nil); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(results.isEmpty)
        }
    }

    func testSameNameEditionsRemainSeparateAndCandidateLookupIsBounded() async throws {
        let candidates = ["Q200", "Q200", "Q201", "Q202", "Q203", "Q204", "Q205"]
        let editions = (200...203).map { editionItem(qid: "Q\($0)", bookID: "\($0)", year: 2014 + $0 - 200) }
        let h = try EditionHarness(root: editionRoot(candidates: candidates), editions: editions); defer { h.close() }
        let results = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(results.map(\.editionQID), ["Q200", "Q201", "Q202", "Q203"])
        XCTAssertEqual(Set(results.map(\.id)).count, 4)
        XCTAssertEqual(results.map { $0.destination.title }, ["豆瓣 · 2014版", "豆瓣 · 2015版", "豆瓣 · 2016版", "豆瓣 · 2017版"])
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q200|Q201|Q202|Q203")
        XCTAssertEqual(h.requests.count, 2)
    }

    func testMissingUncertainQualifiedOrConflictingYearUsesEditionTitle() async throws {
        var missing = editionItem(); var claims = missing["claims"] as! [String: [[String: Any]]]
        claims["P577"] = []; missing["claims"] = claims
        var conflict = editionItem(); claims = conflict["claims"] as! [String: [[String: Any]]]
        claims["P577"] = [editionDate("Q200", 2014), editionDate("Q200", 2015)]; conflict["claims"] = claims
        let qualified = changingEditionClaim(editionItem(), property: "P577") {
            $0["qualifiers"] = ["P291": [editionSnak("P291", datatype: "wikibase-item", value: ["id": "Q148"])]]
        }
        var uncertain = editionItem(); claims = uncertain["claims"] as! [String: [[String: Any]]]
        claims["P577"] = [editionDate("Q200", 2014, precision: 8)]; uncertain["claims"] = claims
        for edition in [missing, conflict, qualified, uncertain] {
            let h = try EditionHarness(root: editionRoot(), editions: [edition]); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertEqual(results.first?.destination.title, "豆瓣 · 版本书名")
            XCTAssertNil(results.first?.publicationSource)
        }
    }

    func testInvalidExternalIDsWrongStatementOwnersAndWrongPropertiesAreRejected() async throws {
        let invalidIDs = ["", "025859657", "25859657/other", "25859657?x=1", "２５８５９６５７"]
        var variants = invalidIDs.map { editionItem(bookID: $0) }
        variants.append(changingEditionClaim(editionItem(), property: "P6442") { $0["id"] = editionStatement("Q999", "P6442") })
        variants.append(changingEditionClaim(editionItem(), property: "P6442") {
            var snak = $0["mainsnak"] as! [String: Any]; snak["property"] = "P4529"; $0["mainsnak"] = snak
        })
        for edition in variants {
            let h = try EditionHarness(root: editionRoot(), editions: [edition]); defer { h.close() }
            let results = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(results.isEmpty)
        }
    }

    func testInvalidQIDAndCancelledCallerDoNotReachTransport() async throws {
        let h = EditionHarness(plans: []); defer { h.close() }
        for qid in ["Q0", "Q01", "q100", "Q100|Q200", "Q100&ids=Q200", "Q１００", "Q"] {
            do { _ = try await h.service.fetch(qid: qid); XCTFail("Accepted \(qid)") }
            catch WorkContextError.invalidIdentity { }
        }
        let service = h.service
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.fetch(qid: "Q100")
        }
        do { _ = try await task.value; XCTFail("Cancelled request returned") }
        catch is CancellationError { }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testHTTPAndAPIErrorDoNotMasqueradeAsNoEditions() async throws {
        for plan in [
            try EditionPlan(ids: ["Q100"], payload: [:], status: 503),
            try EditionPlan(ids: ["Q100"], payload: ["error": ["code": "maxlag"]])
        ] {
            let h = EditionHarness(plans: [plan]); defer { h.close() }
            do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Failure became an empty result") }
            catch WorkContextError.unavailable { }
        }
    }

    func testMissingEditionIsSkippedButMismatchedReturnedIdentityThrows() async throws {
        let missing = try EditionPlan(ids: ["Q200"], payload: ["success": 1, "entities": ["Q200": ["id": "Q200", "missing": ""]]])
        let mismatch = try EditionPlan(ids: ["Q200"], payload: ["success": 1, "entities": ["Q200": editionItem(qid: "Q999")]])
        let root = try EditionPlan(entities: [editionRoot()])
        let absentHarness = EditionHarness(plans: [root, missing]); defer { absentHarness.close() }
        let absent = try await absentHarness.service.fetch(qid: "Q100")
        XCTAssertTrue(absent.isEmpty)
        let mismatchHarness = EditionHarness(plans: [root, mismatch]); defer { mismatchHarness.close() }
        do { _ = try await mismatchHarness.service.fetch(qid: "Q100"); XCTFail("Accepted mismatched edition identity") }
        catch WorkContextError.invalidResponse { }
    }

    func testStoreLoadsContextBeforeEditionsAndReloadsCompleteEditionEvidenceFromCache() async throws {
        let h = EditionHarness(plans: [
            try EditionPlan(entities: [editionContextRoot()]),
            try EditionPlan.article(text: "A source introduction.", revision: 101),
            try EditionPlan(entities: [editionRoot()]),
            try EditionPlan(entities: [editionItem()])
        ]); defer { h.close() }
        let store = WorkContextStore(service: h.contextService, directory: h.directory, editionService: h.service)
        await store.load("Q100")
        let context = try XCTUnwrap(store.values["Q100"])
        let edition = try XCTUnwrap(context.editions?.first)
        XCTAssertEqual(context.introduction, "A source introduction.")
        XCTAssertEqual(context.hasEditionCandidates, true)
        XCTAssertEqual(context.editionLookupUnavailable, false)
        XCTAssertNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertEqual(h.requests.count, 4)
        XCTAssertEqual(h.parameters(at: 0)["ids"], "Q100")
        XCTAssertEqual(h.parameters(at: 0)["props"], "labels|claims|sitelinks")
        XCTAssertEqual(h.parameters(at: 1)["titles"], "Exact Book")
        XCTAssertEqual(h.parameters(at: 2)["ids"], "Q100")
        XCTAssertEqual(h.parameters(at: 2)["props"], "labels|claims")
        XCTAssertEqual(h.parameters(at: 3)["ids"], "Q200")

        let reloaded = WorkContextStore(service: h.contextService, directory: h.directory, editionService: h.service)
        await reloaded.load("Q100")
        let cachedContext = try XCTUnwrap(reloaded.values["Q100"])
        let cachedEdition = try XCTUnwrap(cachedContext.editions?.first)
        XCTAssertEqual(cachedContext.introduction, context.introduction)
        XCTAssertEqual(cachedContext.introductionSource, context.introductionSource)
        XCTAssertEqual(cachedEdition.originalQID, edition.originalQID)
        XCTAssertEqual(cachedEdition.editionQID, edition.editionQID)
        XCTAssertEqual(cachedEdition.destination.url, edition.destination.url)
        XCTAssertEqual(cachedEdition.destination.source, edition.destination.source)
        XCTAssertEqual(cachedEdition.discoverySource, edition.discoverySource)
        XCTAssertEqual(cachedEdition.correspondenceSource, edition.correspondenceSource)
        XCTAssertEqual(cachedEdition.editionTypeSource, edition.editionTypeSource)
        XCTAssertEqual(cachedEdition.publicationSource, edition.publicationSource)
        XCTAssertEqual(h.requests.count, 4, "Fresh cache restores editions without another network lookup")
    }

    func testStoreRetriesContextAndEditionFailuresWithoutLosingIntroductionOrPreviousEditions() async throws {
        let root = try EditionPlan(entities: [editionContextRoot()])
        let editionRootPlan = try EditionPlan(entities: [editionRoot()])
        let h = EditionHarness(plans: [
            root, try EditionPlan.article(text: "Original introduction.", revision: 101),
            editionRootPlan, try EditionPlan(entities: [editionItem()]),
            try EditionPlan(ids: ["Q100"], payload: [:], status: 503),
            root, try EditionPlan.article(text: "Updated introduction.", revision: 202),
            try EditionPlan(ids: ["Q100"], payload: [:], status: 503),
            root, try EditionPlan.article(text: "Recovered introduction.", revision: 303),
            editionRootPlan, try EditionPlan(entities: [editionItem(year: 2015)])
        ]); defer { h.close() }
        let store = WorkContextStore(service: h.contextService, directory: h.directory, editionService: h.service)
        await store.load("Q100")
        let originalSource = store.values["Q100"]?.introductionSource
        let originalEdition = try XCTUnwrap(store.values["Q100"]?.editions?.first)

        await store.load("Q100", retry: true)
        XCTAssertEqual(store.values["Q100"]?.introduction, "Original introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource, originalSource)
        XCTAssertEqual(store.values["Q100"]?.editions?.first?.destination.url, originalEdition.destination.url)
        XCTAssertNotNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertEqual(h.requests.count, 5)

        await store.load("Q100", retry: true)
        XCTAssertEqual(store.values["Q100"]?.introduction, "Updated introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=202")
        XCTAssertEqual(store.values["Q100"]?.editions?.first?.destination.title, "豆瓣 · 2014版")
        XCTAssertEqual(store.values["Q100"]?.editions?.first?.correspondenceSource, originalEdition.correspondenceSource)
        XCTAssertEqual(store.values["Q100"]?.editionLookupUnavailable, true)
        XCTAssertEqual(store.errors["Q100"], "版本资料暂未载入")
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertEqual(h.requests.count, 8)
        await store.load("Q100")
        XCTAssertEqual(h.requests.count, 8, "A page render must not retry a failed lookup in a loop")

        await store.load("Q100", retry: true)
        XCTAssertEqual(store.values["Q100"]?.introduction, "Recovered introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=303")
        XCTAssertEqual(store.values["Q100"]?.editions?.first?.destination.title, "豆瓣 · 2015版")
        XCTAssertEqual(store.values["Q100"]?.editionLookupUnavailable, false)
        XCTAssertNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertEqual(h.requests.count, 12)
    }

    func testLiveNorwegianWoodFindsVerifiedChineseEdition() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 for the public edition lookup")
        let results = try await WorkContextEditionService().fetch(qid: "Q751348")
        let edition = try XCTUnwrap(results.first { $0.editionQID == "Q69966015" })
        XCTAssertEqual(edition.originalQID, "Q751348")
        XCTAssertEqual(edition.destination.title, "豆瓣 · 2014版")
        XCTAssertEqual(edition.destination.url, "https://book.douban.com/subject/25859657/")
        XCTAssertEqual(URLComponents(string: edition.discoverySource.url)?.path, "/wiki/Q751348")
        XCTAssertEqual(URLComponents(string: edition.correspondenceSource.url)?.path, "/wiki/Q69966015")
        XCTAssertNotNil(URLComponents(string: edition.destination.source.url)?.fragment)
        XCTAssertNotNil(edition.publicationSource)
    }
}

private func editionStatement(_ qid: String, _ property: String) -> String {
    qid + "$00000000-0000-0000-0000-" + String(format: "%012d", Int(property.dropFirst())!)
}
private func editionSnak(_ property: String, datatype: String, value: Any) -> [String: Any] {
    ["property": property, "snaktype": "value", "datatype": datatype, "datavalue": ["value": value]]
}
private func editionClaim(_ qid: String, _ property: String, datatype: String, value: Any) -> [String: Any] {
    ["id": editionStatement(qid, property), "rank": "normal", "mainsnak": editionSnak(property, datatype: datatype, value: value)]
}
private func editionClaim(_ qid: String, _ property: String, item: String) -> [String: Any] {
    editionClaim(qid, property, datatype: "wikibase-item", value: ["id": item])
}
private func editionDate(_ qid: String, _ year: Int, precision: Int = 10) -> [String: Any] {
    editionClaim(qid, "P577", datatype: "time", value: ["time": "+\(year)-04-00T00:00:00Z", "precision": precision,
                                                         "calendarmodel": "http://www.wikidata.org/entity/Q1985727", "before": 0, "after": 0])
}
private func editionRoot(candidates: [String] = ["Q200"]) -> [String: Any] {
    ["id": "Q100", "type": "item", "labels": ["zh": ["value": "原作"]],
     "claims": ["P747": candidates.map { editionClaim("Q100", "P747", item: $0) }]]
}
private func editionContextRoot() -> [String: Any] {
    var root = editionRoot()
    var claims = root["claims"] as! [String: [[String: Any]]]
    claims["P31"] = [editionClaim("Q100", "P31", item: "Q7725634")]
    root["claims"] = claims
    root["sitelinks"] = ["zhwiki": ["site": "zhwiki", "title": "Exact Book"]]
    return root
}
private func editionItem(qid: String = "Q200", original: String = "Q100", type: String = "Q3331189", bookID: String = "25859657", year: Int = 2014) -> [String: Any] {
    ["id": qid, "type": "item", "labels": ["zh": ["value": "版本书名"]],
     "claims": ["P31": [editionClaim(qid, "P31", item: type)], "P629": [editionClaim(qid, "P629", item: original)],
                "P6442": [editionClaim(qid, "P6442", datatype: "external-id", value: bookID)], "P577": [editionDate(qid, year)]]]
}
private func changingEditionClaim(_ input: [String: Any], property: String, _ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var entity = input; var claims = entity["claims"] as! [String: [[String: Any]]]
    var statement = claims[property]![0]; change(&statement); claims[property] = [statement]; entity["claims"] = claims
    return entity
}

private struct EditionPlan: Sendable {
    let ids: Set<String>
    let data: Data
    let status: Int
    let articleTitle: String?
    init(ids: Set<String>, payload: [String: Any], status: Int = 200, articleTitle: String? = nil) throws {
        self.ids = ids; self.status = status; self.articleTitle = articleTitle
        data = try JSONSerialization.data(withJSONObject: payload)
    }
    init(entities: [[String: Any]]) throws {
        let records = Dictionary(uniqueKeysWithValues: entities.map { ($0["id"] as! String, $0) })
        try self.init(ids: Set(records.keys), payload: ["success": 1, "entities": records])
    }
    static func article(text: String, revision: Int) throws -> EditionPlan {
        try EditionPlan(ids: [], payload: ["query": ["pages": [[
            "title": "Exact Book", "ns": 0, "extract": text, "lastrevid": revision,
            "pageprops": ["wikibase_item": "Q100"]
        ]]]], articleTitle: "Exact Book")
    }
    func matches(_ request: URLRequest) -> Bool {
        guard let raw = request.url, let url = URLComponents(url: raw, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.path == "/w/api.php" else { return false }
        let params = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let articleTitle {
            return url.host == "zh.wikipedia.org" && params["action"] == "query" && params["titles"] == articleTitle
        }
        return url.host == "www.wikidata.org" && params["action"] == "wbgetentities"
            && Set((params["ids"] ?? "").split(separator: "|").map(String.init)) == ids
    }
}

private final class EditionHarness: @unchecked Sendable {
    let service: WorkContextEditionService
    let contextService: WorkContextService
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiEditionStore-" + UUID().uuidString, isDirectory: true)
    private let session: URLSession
    private let token = UUID().uuidString
    private let state: EditionStubState
    convenience init(root: [String: Any], editions: [[String: Any]]?) throws {
        var plans = [try EditionPlan(entities: [root])]
        if let editions { plans.append(try EditionPlan(entities: editions)) }
        self.init(plans: plans)
    }
    init(plans: [EditionPlan]) {
        state = EditionStubState(plans: plans)
        EditionStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Edition-Test": token]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        service = WorkContextEditionService(session: session)
        contextService = WorkContextService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(at index: Int) -> [String: String] {
        guard requests.indices.contains(index), let raw = requests[index].url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: raw, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.remaining, 0, "Expected requests were not made", file: file, line: line)
        XCTAssertTrue(state.unexpected.isEmpty, "Unexpected requests: \(state.unexpected)", file: file, line: line)
        session.invalidateAndCancel(); EditionStubRegistry.shared.remove(token)
        try? FileManager.default.removeItem(at: directory)
    }
}
private final class EditionStubRegistry: @unchecked Sendable {
    static let shared = EditionStubRegistry()
    private let lock = NSLock()
    private var states: [String: EditionStubState] = [:]
    func put(_ key: String, _ state: EditionStubState) { lock.lock(); states[key] = state; lock.unlock() }
    func get(_ key: String?) -> EditionStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { states[$0] } }
    func remove(_ key: String) { lock.lock(); states.removeValue(forKey: key); lock.unlock() }
}
private final class EditionStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [EditionPlan]
    private var observed: [URLRequest] = []
    private var unmatched: [String] = []
    init(plans: [EditionPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return plans.count }
    var unexpected: [String] { lock.lock(); defer { lock.unlock() }; return unmatched }
    func next(_ request: URLRequest) -> EditionPlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        guard let index = plans.firstIndex(where: { $0.matches(request) }) else {
            unmatched.append(request.url?.absoluteString ?? "missing URL"); return nil
        }
        return plans.remove(at: index)
    }
}
private final class EditionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = EditionStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Edition-Test")),
              let plan = state.next(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
