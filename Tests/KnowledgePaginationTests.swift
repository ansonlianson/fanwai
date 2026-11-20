import XCTest
@testable import Pianwai

@MainActor
final class KnowledgePaginationTests: XCTestCase {
    func testRepresentativeWorksStayWhileTwoBoundedPagesAppendAndReachTheTail() async throws {
        let qid = "Q961000"
        let ids = (961001...961014).map { "Q\($0)" }
        let h = try PaginationHarness(plans: [
            pgEntities([pgPerson(qid, notable: [ids[0]])]), pgEntities([pgFilm(ids[0], person: qid)]),
            pgSearch(Array(ids.prefix(12)), total: 14, next: 12), pgEntities(ids[1..<12].map { pgFilm($0, person: qid) }),
            pgSearch([ids[12]], total: 14, next: 13), pgEntities([pgFilm(ids[12], person: qid)]),
            pgSearch([ids[13]], total: 14), pgEntities([pgFilm(ids[13], person: qid)]),
            pgSearch([], total: 0), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try await store.openKnowledgeCandidate(qid)
        let representative = try XCTUnwrap(store.edges.first { $0.to == person && $0.predicate == .directedBy })
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .unqueried, "P800 alone does not prove that another search page exists")
        let suite = "Pianwai.PaginationGraph.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        library.explore(person)
        library.path.append(.connections(person))
        let checkpoint = GraphCheckpoint(center: person, history: [], page: 0, filter: 1, presentation: 1)
        library.saveGraph(root: person, checkpoint: checkpoint)
        let path = library.path

        await store.loadMoreKnowledge(person)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        XCTAssertEqual(pgNeighbors(store, person).count, 13, "One representative plus at most 12 new neighbors")
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .more)
        XCTAssertEqual(store.edges.first { $0.id == representative.id }?.source, representative.source)
        XCTAssertEqual(library.path, path)
        XCTAssertEqual(library.graphCheckpoints[person.rawValue], checkpoint)
        XCTAssertEqual(h.searches.map { $0["sroffset"] ?? "" }, ["0", "12"])
        XCTAssertEqual(h.searches.last?["srlimit"], "1")
        XCTAssertEqual(h.searches.last?["continue"], "-||")

        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person).count, 14)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .exhausted)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        XCTAssertFalse(store.knowledgeMoreLoading.contains(person))
        XCTAssertEqual(Set(store.edges.filter { $0.to == person }.map(\.id)).count, store.edges.filter { $0.to == person }.count)
        XCTAssertEqual(library.graphCheckpoints[person.rawValue], checkpoint)
        let requestCount = h.requests.count
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(h.requests.count, requestCount, "Only a proven tail disables more requests")
    }

    func testFailedSecondPageKeepsItsCursorAndPreviouslyLoadedWorksForRetry() async throws {
        let qid = "Q962000"
        let ids = (962001...962013).map { "Q\($0)" }
        let h = try PaginationHarness(plans: [
            pgEntities([pgPerson(qid)]), pgSearch(Array(ids.prefix(12)), total: 13),
            pgEntities(ids.prefix(12).map { pgFilm($0, person: qid) }),
            pgSearch([ids[12]], total: 13), .http(500),
            pgEntities([pgFilm(ids[12], person: qid)]), pgSearch([], total: 0), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try pgSeed(qid, into: store)
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person).count, 12)
        let firstSources = Dictionary(uniqueKeysWithValues: store.edges.filter { $0.to == person }.map { ($0.id, $0.source) })
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person).count, 12)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .more)
        XCTAssertNotNil(store.knowledgeMoreErrors[person])
        XCTAssertFalse(store.knowledgeMoreLoading.contains(person))
        XCTAssertNil(store.works[WorkID(rawValue: "wikidata:\(ids[12])")!])
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person).count, 13)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .exhausted)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        for edge in store.edges where firstSources[edge.id] != nil { XCTAssertEqual(edge.source, firstSources[edge.id]) }
        XCTAssertEqual(h.requests.filter { pgParameters($0)["ids"] == ids[12] }.count, 2, "Retry validates the same failed candidate before advancing")
        XCTAssertEqual(h.searches.filter { $0["srsearch"] == "haswbstatement:P57=\(qid)" }.map { $0["sroffset"] ?? "" }, ["0", "12"])
    }

    func testDuplicateSearchHitsAndRolesNeverAppendTheSameNeighborTwice() async throws {
        let qid = "Q963000", first = "Q963001", second = "Q963002"
        let h = try PaginationHarness(plans: [
            pgEntities([pgPerson(qid)]), pgSearch([first, first], total: 4, next: 2), pgEntities([pgFilm(first, person: qid)]),
            pgSearch([first, second], total: 4), pgEntities([pgFilm(second, person: qid)]),
            pgSearch([first, second], total: 2), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try pgSeed(qid, into: store)
        await store.loadMoreKnowledge(person)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        XCTAssertEqual(pgNeighbors(store, person), Set([first, second]))
        XCTAssertEqual(store.edges.filter { $0.to == person }.count, 2)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .exhausted)
        XCTAssertEqual(h.requests.filter { pgParameters($0)["action"] == "wbgetentities" }.count, 3, "Each candidate is verified once even when it reappears under another role")
    }

    func testMissingOrNonprogressingPageMetadataNeverBecomesAnEmptyTail() async throws {
        let qid = "Q964000"
        let invalid: [PaginationPlan] = [
            try pgSearch([]), try pgSearch([], total: 1), try pgSearch(["Q964001"], total: 2, next: 0),
            try pgSearch(["Q964001"], total: 0)
        ]
        for bad in invalid {
            let h = try PaginationHarness(plans: [pgEntities([pgPerson(qid)]), bad, bad]); defer { h.close() }
            let store = h.store()
            let person = try pgSeed(qid, into: store)
            for _ in 0..<2 {
                await store.loadMoreKnowledge(person)
                XCTAssertNotNil(store.knowledgeMoreErrors[person])
                XCTAssertEqual(store.knowledgeMoreStatus(for: person), .unqueried)
                XCTAssertTrue(pgNeighbors(store, person).isEmpty)
            }
            XCTAssertEqual(h.searches.count, 2, "Malformed page metadata must not enter the successful-response cache")
        }
    }

    func testUnsupportedCreditsEndAsLimitedRatherThanClaimingCompleteCoverage() async throws {
        let qid = "Q965000"
        let good = pgFilm("Q965001", person: qid)
        var qualified = pgClaim("Q965002", qid)
        qualified["qualifiers"] = ["P580": [["snaktype": "value", "datatype": "time"]]]
        var wrongOwner = pgClaim("Q965003", qid)
        wrongOwner["id"] = "Q999999$11111111-1111-1111-1111-111111111111"
        let h = try PaginationHarness(plans: [
            pgEntities([pgPerson(qid)]), pgSearch(["Q965001", "Q965002", "Q965003"], total: 3),
            pgEntities([good, pgEntity("Q965002", type: "Q11424", claims: ["P57": [qualified]]), pgEntity("Q965003", type: "Q11424", claims: ["P57": [wrongOwner]])]),
            pgSearch([], total: 0), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try pgSeed(qid, into: store)
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person), ["Q965001"])
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .limited)
        XCTAssertTrue(store.knowledgePartial.contains(person))
        XCTAssertNil(store.knowledgeMoreErrors[person])
    }

    func testCallerCancellationPublishesNeitherPartialWorksNorAnAdvancedCursor() async throws {
        let qid = "Q966000", film = "Q966001"
        let h = try PaginationHarness(plans: [
            pgEntities([pgPerson(qid)]), pgSearch([film], total: 1), pgEntities([pgFilm(film, person: qid)]), .hold,
            pgSearch([], total: 0), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try pgSeed(qid, into: store)
        let before = Set(store.works.keys)
        let task = Task { await store.loadMoreKnowledge(person) }
        let held = await XCTWaiter.fulfillment(of: [h.heldRequest], timeout: 3)
        XCTAssertEqual(held, .completed)
        task.cancel()
        await task.value
        XCTAssertEqual(Set(store.works.keys), before)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .unqueried)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        XCTAssertFalse(store.knowledgeMoreLoading.contains(person))
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person), [film])
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .exhausted)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        XCTAssertEqual(h.searches.filter { $0["srsearch"] == "haswbstatement:P50=\(qid)" }.count, 2)
    }

    func testCacheReloadRestartsAtHeadSkipsSavedNeighborsAndStillFindsTheNextWork() async throws {
        let qid = "Q967000"
        let ids = (967001...967013).map { "Q\($0)" }
        let head = try pgSearch(Array(ids.prefix(12)), total: 13, next: 12)
        let root = try pgEntities([pgPerson(qid)])
        let h = try PaginationHarness(plans: [
            root, head, pgEntities(ids.prefix(12).map { pgFilm($0, person: qid) }),
            root, head, pgSearch([ids[12]], total: 13), pgEntities([pgFilm(ids[12], person: qid)]),
            pgSearch([], total: 0), pgSearch([], total: 0), pgSearch([], total: 0)
        ]); defer { h.close() }
        let store = h.store()
        let person = try pgSeed(qid, into: store)
        await store.loadMoreKnowledge(person)
        XCTAssertEqual(pgNeighbors(store, person).count, 12)
        XCTAssertEqual(store.knowledgeMoreStatus(for: person), .more)
        await store.flushPendingWrites()
        let restored = h.store(freshService: true)
        XCTAssertEqual(pgNeighbors(restored, person).count, 12)
        XCTAssertEqual(restored.knowledgeMoreStatus(for: person), .unqueried)
        await restored.loadMoreKnowledge(person)
        XCTAssertNil(restored.knowledgeMoreErrors[person])
        XCTAssertEqual(pgNeighbors(restored, person).count, 13)
        XCTAssertEqual(restored.knowledgeMoreStatus(for: person), .exhausted)
        XCTAssertEqual(h.searches.prefix(3).map { $0["sroffset"] ?? "" }, ["0", "0", "12"])
        XCTAssertEqual(h.requests.filter { pgParameters($0)["ids"] == ids.prefix(12).sorted().joined(separator: "|") }.count, 1,
                       "Reload uses persisted verified edges to skip the old head without refetching each work")
    }

    func testBoundedScanningReturnsAContinuationEvenWhenAllHitsWereAlreadyLoaded() async throws {
        let qid = "Q968000", known = "Q968001"
        var plans: [PaginationPlan] = [try pgEntities([pgPerson(qid)])]
        for offset in 0..<8 { plans.append(try pgSearch([known], next: offset + 1)) }
        let h = try PaginationHarness(plans: plans); defer { h.close() }
        let page = try await h.knowledge.moreWorks(qid: qid, excluding: [known])
        XCTAssertTrue(page.snapshot.relations.isEmpty)
        XCTAssertEqual(page.status, .more)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertEqual(h.searches.count, 8)
        let count = h.requests.count
        do {
            _ = try await h.knowledge.moreWorks(qid: "Q968999", after: page.nextCursor)
            XCTFail("A continuation cannot be reused for another person")
        } catch KnowledgeError.invalidIdentifier { }
        XCTAssertEqual(h.requests.count, count)
    }

    func testAppleArtistProfilesDoNotExposePersonWorkPagination() throws {
        let h = try PaginationHarness(plans: []); defer { h.close() }
        let store = h.store()
        let id = WorkID(rawValue: "apple:artist:969001")!
        let profile = Work(id: id, title: "Alias", creator: "音乐人", kind: "创作者", art: "", detail: "", url: "https://music.apple.com/jp/artist/969001",
                           linkedCreatorIDs: [], catalogID: "969001", storeCountry: "jp", knowledgeID: "Q969000")
        try store.merge(CatalogSnapshot(works: [profile], relations: []))
        XCTAssertNil(store.knowledgeMoreStatus(for: id))
        XCTAssertNil(store.knowledgeMoreStatus(for: .pool))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testLiveMiyazakiLoadsTwoBoundedVerifiedBatchesBeyondRepresentativeWorks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 for creator pagination against Wikidata")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.PaginationLive.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(cacheURL: directory.appendingPathComponent("catalog.json"), bundle: Bundle(for: Self.self))
        let person = try await store.openKnowledgeCandidate("Q55400")
        let initial = pgNeighbors(store, person)
        await store.loadMoreKnowledge(person)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        let first = pgNeighbors(store, person)
        XCTAssertGreaterThan(first.subtracting(initial).count, 0)
        XCTAssertLessThanOrEqual(first.subtracting(initial).count, 12)
        await store.loadMoreKnowledge(person)
        XCTAssertNil(store.knowledgeMoreErrors[person])
        let second = pgNeighbors(store, person)
        XCTAssertGreaterThan(second.subtracting(first).count, 0)
        XCTAssertLessThanOrEqual(second.subtracting(first).count, 12)
        XCTAssertGreaterThan(second.count, 12)
        for edge in store.edges where edge.to == person && [.directedBy, .authoredBy, .composedBy, .performedBy].contains(edge.predicate) {
            let qid = try XCTUnwrap(store.work(edge.from).knowledgeID)
            let source = try XCTUnwrap(URLComponents(string: edge.source.url))
            XCTAssertEqual(source.host, "www.wikidata.org")
            XCTAssertEqual(source.path, "/wiki/\(qid)")
            // Real statement IDs can start with a lower-case q; the source URL
            // must preserve that exact DOM anchor, while identity is case-insensitive.
            let statement = try XCTUnwrap(source.fragment)
            let parts = statement.split(separator: "$", maxSplits: 1)
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts.first?.uppercased(), qid)
            if parts.count == 2 { XCTAssertNotNil(UUID(uuidString: String(parts[1]))) }
        }
        await store.flushPendingWrites()
        let restored = CatalogStore(cacheURL: directory.appendingPathComponent("catalog.json"), bundle: Bundle(for: Self.self))
        XCTAssertEqual(pgNeighbors(restored, person), second)
        XCTAssertEqual(restored.knowledgeMoreStatus(for: person), .unqueried)
    }
}

@MainActor private func pgNeighbors(_ store: CatalogStore, _ person: WorkID) -> Set<String> {
    Set(store.edges.filter { $0.to == person && [.directedBy, .authoredBy, .composedBy, .performedBy].contains($0.predicate) }.compactMap { store.works[$0.from]?.knowledgeID })
}
@MainActor private func pgSeed(_ qid: String, into store: CatalogStore) throws -> WorkID {
    let id = WorkID(rawValue: "wikidata:\(qid)")!
    try store.merge(CatalogSnapshot(works: [Work(id: id, title: "Creator", creator: "", kind: "创作者", art: "", detail: "", url: "https://www.wikidata.org/wiki/\(qid)", linkedCreatorIDs: [], knowledgeID: qid)], relations: []))
    return id
}
private func pgClaim(_ owner: String, _ target: String) -> [String: Any] {
    ["id": owner + "$11111111-1111-1111-1111-111111111111", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": target]]]]
}
private func pgEntity(_ qid: String, type: String, claims: [String: Any] = [:]) -> [String: Any] {
    var claims = claims; claims["P31"] = [pgClaim(qid, type)]
    return ["id": qid, "type": "item", "labels": ["zh": ["value": "Test \(qid)"]], "claims": claims]
}
private func pgPerson(_ qid: String, notable: [String] = []) -> [String: Any] {
    pgEntity(qid, type: "Q5", claims: ["P800": notable.map { pgClaim(qid, $0) }])
}
private func pgFilm(_ qid: String, person: String) -> [String: Any] { pgEntity(qid, type: "Q11424", claims: ["P57": [pgClaim(qid, person)]]) }
private func pgEntities(_ values: [[String: Any]]) throws -> PaginationPlan {
    try pgJSON(["success": 1, "entities": Dictionary(uniqueKeysWithValues: values.map { ($0["id"] as! String, $0) })])
}
private func pgSearch(_ ids: [String], total: Int? = nil, next: Int? = nil) throws -> PaginationPlan {
    var query: [String: Any] = ["search": ids.map { ["title": $0] }]
    if let total { query["searchinfo"] = ["totalhits": total] }
    var object: [String: Any] = ["query": query]
    if let next { object["continue"] = ["sroffset": next, "continue": "-||"] }
    return try pgJSON(object)
}
private func pgJSON(_ value: [String: Any]) throws -> PaginationPlan { .response(try JSONSerialization.data(withJSONObject: value)) }
private func pgParameters(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []).map { ($0.name, $0.value ?? "") })
}
private enum PaginationPlan: Sendable { case response(Data), http(Int), hold }

@MainActor private final class PaginationHarness {
    let cacheURL: URL
    let knowledge: KnowledgeGraphService
    private let directory: URL
    private let session: URLSession
    private let token = UUID().uuidString
    private let state: PaginationStubState
    init(plans: [PaginationPlan]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.Pagination.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("catalog.json")
        state = PaginationStubState(plans: plans)
        PaginationRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaginationURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Pagination-Test": token]
        session = URLSession(configuration: config)
        knowledge = KnowledgeGraphService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    var searches: [[String: String]] { requests.map(pgParameters).filter { $0["list"] == "search" } }
    var heldRequest: XCTestExpectation { state.heldRequest }
    func store(freshService: Bool = false) -> CatalogStore {
        CatalogStore(cacheURL: cacheURL, bundle: Bundle(for: KnowledgePaginationTests.self),
                     knowledgeService: freshService ? KnowledgeGraphService(session: session) : knowledge)
    }
    func close() { session.invalidateAndCancel(); PaginationRegistry.shared.remove(token); try? FileManager.default.removeItem(at: directory) }
}
private final class PaginationRegistry: @unchecked Sendable {
    static let shared = PaginationRegistry()
    private let lock = NSLock()
    private var values: [String: PaginationStubState] = [:]
    func put(_ key: String, _ value: PaginationStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> PaginationStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class PaginationStubState: @unchecked Sendable {
    let heldRequest = XCTestExpectation(description: "Pagination request is waiting for cancellation")
    private let lock = NSLock()
    private var plans: [PaginationPlan]
    private var observed: [URLRequest] = []
    init(plans: [PaginationPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> PaginationPlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class PaginationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = PaginationRegistry.shared.get(request.value(forHTTPHeaderField: "X-Pagination-Test")), let plan = state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch plan {
        case .response(let data): respond(data, status: 200)
        case .http(let status): respond(Data("{}".utf8), status: status)
        case .hold: state.heldRequest.fulfill()
        }
    }
    private func respond(_ data: Data, status: Int) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
