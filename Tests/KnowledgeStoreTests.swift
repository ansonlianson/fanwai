import XCTest
@testable import Pianwai

/// The real store imports results produced by the real service. The fixture only
/// replaces HTTP transport; entity identity, graph materialization, merge and disk
/// persistence all run through production code.
@MainActor
final class KnowledgeStoreTests: XCTestCase {
    func testKnownQIDReusesCuratedNodesAndKeepsOriginalRelationSources() async throws {
        let h = try KnowledgeStoreHarness(plans: [
            knowledgeStoreResponse([knowledgeStoreEntity("Q123906765", title: "A different API title", type: "Q20650540", claims: [
                "P57": [knowledgeStoreClaim("Q123906765", "Q125871279")],
                "P86": [knowledgeStoreClaim("Q123906765", "Q11190062")],
                "P144": [knowledgeStoreClaim("Q123906765", "Q65240543")]
            ])]),
            knowledgeStoreResponse([
                knowledgeStoreEntity("Q125871279", title: "Tatsuya Yoshihara", type: "Q5"),
                knowledgeStoreEntity("Q11190062", title: "Kensuke Ushio", type: "Q5"),
                knowledgeStoreEntity("Q65240543", title: "Chainsaw Man", type: "Q21198342")
            ])
        ]); defer { h.close() }
        let store = h.store()
        let before = store.work(.film)
        let originalSources = Dictionary(uniqueKeysWithValues: store.edges.map { ($0.id, $0.source) })
        let initialCount = store.works.count

        await store.expandKnowledge(.film)
        XCTAssertNil(store.knowledgeErrors[.film])
        XCTAssertFalse(store.knowledgeLoading.contains(.film))
        let selected = try await store.openKnowledgeCandidate("Q123906765")
        XCTAssertEqual(selected, .film)
        XCTAssertEqual(store.work(selected).title, before.title)
        XCTAssertEqual(store.work(selected).art, before.art)
        XCTAssertEqual(store.works.count, initialCount, "Every returned identity already has a verified curated anchor")
        XCTAssertEqual(store.works.values.filter { $0.knowledgeID == "Q123906765" }.map(\.id), [.film])
        XCTAssertNil(store.works[WorkID(rawValue: "wikidata:Q123906765")!])
        XCTAssertNil(store.works[WorkID(rawValue: "wikidata:Q65240543")!])
        for edge in store.edges where originalSources[edge.id] != nil {
            XCTAssertEqual(edge.source, originalSources[edge.id], "Structured credits must not replace the original official source")
        }
        let added = try XCTUnwrap(store.edges.first { $0.from == .film && $0.to == .ushio && $0.predicate == .composedBy })
        XCTAssertTrue(added.source.title.hasPrefix("Wikidata · "))
        XCTAssertEqual(URLComponents(string: added.source.url)?.host, "www.wikidata.org")
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertNil(store.storageError)
    }

    func testSameNameAppleRecordingAndSelectedKnowledgeWorkStaySeparate() async throws {
        let apple: [String: Any] = ["results": [[
            "wrapperType": "track", "kind": "song", "trackId": 770001,
            "trackName": "Shared Title", "trackViewUrl": "https://music.apple.com/us/song/770001",
            "artistId": 770002, "artistName": "Shared Artist",
            "collectionId": 770003, "collectionName": "Shared Album"
        ]]]
        let h = try KnowledgeStoreHarness(plans: [
            apple,
            knowledgeStoreResponse([knowledgeStoreEntity("Q770001", title: "Shared Title", type: "Q7366", claims: ["P175": [knowledgeStoreClaim("Q770001", "Q770002")]])]),
            knowledgeStoreResponse([knowledgeStoreEntity("Q770002", title: "Shared Artist", type: "Q5")])
        ]); defer { h.close() }
        let store = h.store()
        let recordings = try await store.search("Shared Title", country: "us", kind: .song)
        let recording = try XCTUnwrap(recordings.first)
        let knowledge = try await store.openKnowledgeCandidate("Q770001")

        XCTAssertEqual(recording.rawValue, "apple:song:770001")
        XCTAssertEqual(knowledge.rawValue, "wikidata:Q770001")
        XCTAssertNotEqual(store.canonicalID(for: recording), store.canonicalID(for: knowledge))
        XCTAssertEqual(store.work(recording).title, store.work(knowledge).title)
        XCTAssertNil(store.work(recording).knowledgeID, "Candidate selection must not assign an encyclopedia identity to a recording")
        XCTAssertEqual(store.work(knowledge).knowledgeID, "Q770001")
        XCTAssertEqual(store.work(recording).catalogID, "770001")
        XCTAssertNil(store.work(knowledge).catalogID)
        XCTAssertNotEqual(store.work(recording).url, store.work(knowledge).url)
        XCTAssertEqual(store.edges.filter { $0.from == recording && $0.predicate == .performedBy }.first?.to.rawValue, "apple:artist:770002")
        XCTAssertEqual(store.edges.filter { $0.from == knowledge && $0.predicate == .performedBy }.first?.to.rawValue, "wikidata:Q770002")
        XCTAssertEqual(h.requests.count, 3)
    }

    func testExpandedKnowledgeAndStatementSourcesSurviveCacheReload() async throws {
        let h = try KnowledgeStoreHarness(plans: [
            knowledgeStoreResponse([knowledgeStoreEntity("Q880001", title: "New Book", type: "Q571", claims: ["P50": [knowledgeStoreClaim("Q880001", "Q880002")]])]),
            knowledgeStoreResponse([knowledgeStoreEntity("Q880002", title: "New Author", type: "Q5")])
        ]); defer { h.close() }
        let store = h.store()
        let selected = try await store.openKnowledgeCandidate("Q880001")
        let relation = try XCTUnwrap(store.edges.first { $0.from == selected })
        await store.flushPendingWrites()
        XCTAssertNil(store.storageError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.cacheURL.path))

        let restored = h.store()
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.work(selected).knowledgeID, "Q880001")
        XCTAssertEqual(restored.work(relation.to).knowledgeID, "Q880002")
        XCTAssertEqual(restored.work(selected).title, "New Book")
        XCTAssertEqual(restored.work(selected).kind, "书籍")
        XCTAssertEqual(restored.edges.first { $0.id == relation.id }?.source, relation.source)
        XCTAssertEqual(restored.edges.first { $0.id == relation.id }?.predicate, .authoredBy)
        XCTAssertEqual(h.requests.count, 2, "Reload must recover persisted knowledge without issuing a request")
        let disk = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: h.cacheURL))
        XCTAssertEqual(disk.works.first { $0.id == selected }?.knowledgeID, "Q880001")
        XCTAssertEqual(disk.relations.first { $0.id == relation.id }?.source.url, relation.source.url)
    }

    func testPersistedExactKnowledgeWorkCanReopenOfflineAndLaterRefreshNormally() async throws {
        let qid = "Q880001"
        let h = try KnowledgeStoreHarness(readyPlans: [
            .json(knowledgeStoreResponse([knowledgeStoreEntity(qid, title: "A literary work", type: "Q7725634")])),
            .failure(.notConnectedToInternet),
            .json(knowledgeStoreResponse([knowledgeStoreEntity(qid, title: "A novel", type: "Q7725634", claims: ["P7937": [knowledgeStoreClaim(qid, "Q8261")]])]))
        ]); defer { h.close() }
        let original = h.store()
        let id = try await original.openKnowledgeCandidate(qid)
        await original.flushPendingWrites()
        let bytes = try Data(contentsOf: h.cacheURL)
        let restored = h.store(freshKnowledge: true)
        let offline = try await restored.openKnowledgeCandidate(qid)
        XCTAssertEqual(offline, id)
        XCTAssertEqual(restored.work(id).knowledgeID, qid)
        XCTAssertEqual(restored.work(id).kind, "文学作品")
        XCTAssertNotNil(restored.knowledgeErrors[id], "Keep the optional refresh failure visible")
        XCTAssertEqual(try Data(contentsOf: h.cacheURL), bytes, "An offline open must not rewrite cached evidence")
        let recovered = try await restored.openKnowledgeCandidate(qid)
        XCTAssertEqual(recovered, id)
        XCTAssertEqual(restored.work(id).kind, "书籍", "Online opening still performs the original refinement contract")
        XCTAssertNil(restored.knowledgeErrors[id])
        XCTAssertEqual(h.requests.count, 3, "Recreated service cannot use the previous actor's HTTP cache")
    }

    func testKnownCuratedIdentityCanOpenDuringTransportOrThrottleFailure() async throws {
        for plan in [KnowledgeStorePlan.failure(.timedOut), .failure(.networkConnectionLost),
                     try .json(["error": ["code": "maxlag"]]), try .json([:], status: 503)] {
            let h = try KnowledgeStoreHarness(readyPlans: [plan]); defer { h.close() }
            let store = h.store()
            let before = store.work(.film)
            let result = try await store.openKnowledgeCandidate("Q123906765")
            XCTAssertEqual(result, .film)
            XCTAssertEqual(store.work(.film).knowledgeID, before.knowledgeID)
            XCTAssertEqual(store.work(.film).title, before.title)
            XCTAssertNotNil(store.knowledgeErrors[.film])
            XCTAssertEqual(h.requests.count, 1)
        }
    }

    func testCachedIdentityNeverSwallowsCancellationOrMalformedIdentityEvidence() async throws {
        let plans: [KnowledgeStorePlan] = [
            try .json(["success": 1, "entities": ["Q123906765": knowledgeStoreEntity("Q999999", title: "Wrong identity", type: "Q11424")]]),
            try .json(["success": 1])
        ]
        for plan in plans {
            let h = try KnowledgeStoreHarness(readyPlans: [plan]); defer { h.close() }
            let store = h.store()
            do { _ = try await store.openKnowledgeCandidate("Q123906765"); XCTFail("Non-retryable evidence failure became cached success") }
            catch KnowledgeError.invalidResponse { }
            XCTAssertNil(store.knowledgeErrors[.film], "Only a supported fallback publishes a refresh error")
            XCTAssertEqual(h.requests.count, 1)
        }
        let h = try KnowledgeStoreHarness(plans: []); defer { h.close() }
        let store = h.store()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.openKnowledgeCandidate("Q123906765")
        }
        do { _ = try await task.value; XCTFail("Cancelled caller received cached work") }
        catch is CancellationError { }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testProviderOnlyCancellationOfCachedIdentityPropagatesWithoutPublishingAndRecovers() async throws {
        let qid = "Q123906765"
        let h = try KnowledgeStoreHarness(readyPlans: [
            .failure(.cancelled),
            .json(knowledgeStoreResponse([knowledgeStoreEntity(qid, title: "Verified film", type: "Q11424")]))
        ]); defer { h.close() }
        let store = h.store()
        store.save()
        await store.flushPendingWrites()
        let bytes = try Data(contentsOf: h.cacheURL)
        let originalIDs = Set(store.works.keys)
        let originalEdges = store.edges.map(\.id)
        do { _ = try await store.openKnowledgeCandidate(qid); XCTFail("Provider cancellation borrowed a cached successful open") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(Set(store.works.keys), originalIDs)
        XCTAssertEqual(store.edges.map(\.id), originalEdges)
        XCTAssertEqual(try Data(contentsOf: h.cacheURL), bytes)
        XCTAssertNil(store.knowledgeErrors[.film], "The thrown failure belongs to the caller's retry state, not an accepted cached open")
        XCTAssertEqual(h.requests.count, 1)

        let recovered = try await store.openKnowledgeCandidate(qid)
        XCTAssertEqual(recovered, .film)
        XCTAssertEqual(store.work(recovered).knowledgeID, qid)
        XCTAssertNil(store.knowledgeErrors[recovered])
        XCTAssertEqual(h.requests.count, 2, "A cancelled provider response cannot be reused as an identity cache hit")
    }

    func testTaskCancelledDuringCachedIdentityRefreshPreservesDiskAndCanRetry() async throws {
        let requested = XCTestExpectation(description: "Cached identity refresh is in flight")
        let qid = "Q123906765"
        let h = try KnowledgeStoreHarness(readyPlans: [
            .waiting { requested.fulfill() },
            .json(knowledgeStoreResponse([knowledgeStoreEntity(qid, title: "Verified film", type: "Q11424")]))
        ]); defer { h.close() }
        let store = h.store()
        store.save()
        await store.flushPendingWrites()
        let bytes = try Data(contentsOf: h.cacheURL)
        let originalIDs = Set(store.works.keys)
        let originalEdges = store.edges.map(\.id)
        let task = Task { @MainActor in try await store.openKnowledgeCandidate(qid) }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(started, .completed)
        task.cancel()
        do { _ = try await task.value; XCTFail("An in-flight cancelled caller received the cached identity") }
        catch is CancellationError { }
        XCTAssertEqual(Set(store.works.keys), originalIDs)
        XCTAssertEqual(store.edges.map(\.id), originalEdges)
        XCTAssertEqual(try Data(contentsOf: h.cacheURL), bytes)
        XCTAssertNil(store.knowledgeErrors[.film])
        XCTAssertEqual(h.requests.count, 1)
        let recovered = try await store.openKnowledgeCandidate(qid)
        XCTAssertEqual(recovered, .film)
        XCTAssertEqual(h.requests.count, 2)
    }

    func testUncachedQIDCannotBorrowSameNamedCachedWorkOrRecordingOffline() async throws {
        let h = try KnowledgeStoreHarness(readyPlans: [.failure(.notConnectedToInternet)]); defer { h.close() }
        let store = h.store()
        let cached = Work(id: WorkID(rawValue: "wikidata:Q880001")!, title: "Shared title", creator: "", kind: "音乐作品", art: "", detail: "", url: nil, linkedCreatorIDs: [], knowledgeID: "Q880001")
        let recording = Work(id: WorkID(rawValue: "apple:song:880002")!, title: "Shared title", creator: "", kind: "歌曲", art: "", detail: "", url: "https://music.apple.com/us/song/880002", linkedCreatorIDs: [], catalogID: "880002")
        try store.merge(CatalogSnapshot(works: [cached, recording], relations: []))
        do { _ = try await store.openKnowledgeCandidate("Q880002"); XCTFail("Uncached QID borrowed a same-name identity") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertNil(store.works[WorkID(rawValue: "wikidata:Q880002")!])
        XCTAssertNil(store.work(recording.id).knowledgeID)
        XCTAssertEqual(store.work(cached.id).knowledgeID, "Q880001")
        XCTAssertEqual(h.requests.count, 1)
    }

    func testInvalidOrConflictingKnowledgeImportIsAtomicIncludingDisk() async throws {
        let h = try KnowledgeStoreHarness(plans: []); defer { h.close() }
        let store = h.store()
        store.save()
        await store.flushPendingWrites()
        let originalDisk = try Data(contentsOf: h.cacheURL)
        let originalIDs = Set(store.works.keys)
        let originalEdges = store.edges.map(\.id)
        let good = Work(id: WorkID(rawValue: "editorial:should-not-appear")!, title: "Valid companion", creator: "", kind: "作品", art: "", detail: "", url: nil, linkedCreatorIDs: [])
        var conflicting = store.work(.film); conflicting.knowledgeID = "Q990001"
        let mismatched = Work(id: WorkID(rawValue: "wikidata:Q990002")!, title: "Mismatched identity", creator: "", kind: "作品", art: "", detail: "", url: nil, linkedCreatorIDs: [], knowledgeID: "Q990003")

        for invalid in [conflicting, mismatched] {
            XCTAssertThrowsError(try store.merge(CatalogSnapshot(works: [good, invalid], relations: []))) { error in
                guard case CatalogError.invalidData = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(Set(store.works.keys), originalIDs)
            XCTAssertEqual(store.edges.map(\.id), originalEdges)
            XCTAssertEqual(store.work(.film).knowledgeID, "Q123906765")
            XCTAssertNil(store.works[good.id])
            XCTAssertEqual(try Data(contentsOf: h.cacheURL), originalDisk)
        }
    }

    func testVerifiedNovelFormRefinesCachedLiteratureWithoutChangingItsIdentity() async throws {
        let qid = "Q952100"
        let h = try KnowledgeStoreHarness(plans: [knowledgeStoreResponse([
            knowledgeStoreEntity(qid, title: "A novel", type: "Q7725634", claims: ["P7937": [knowledgeStoreClaim(qid, "Q8261")]])
        ])]); defer { h.close() }
        let store = h.store()
        let id = try XCTUnwrap(WorkID(rawValue: "wikidata:\(qid)"))
        let cached = Work(id: id, title: "A literary work", creator: "", kind: "文学作品", art: "", detail: "",
                          url: "https://www.wikidata.org/wiki/\(qid)", linkedCreatorIDs: [], knowledgeID: qid)
        try store.merge(CatalogSnapshot(works: [cached], relations: []))
        let opened = try await store.openKnowledgeCandidate(qid)
        XCTAssertEqual(opened, id)
        XCTAssertEqual(store.work(id).kind, "书籍")
        XCTAssertEqual(store.work(id).knowledgeID, qid)
        await store.flushPendingWrites()
        XCTAssertEqual(h.store().work(id).kind, "书籍", "Refinement remains valid when persisted literature is reloaded")
    }

    func testConflictingKnowledgeIDsOnSameNewAppleIdentityRejectWholeImport() async throws {
        let h = try KnowledgeStoreHarness(plans: []); defer { h.close() }
        let store = h.store()
        store.save()
        await store.flushPendingWrites()
        let originalDisk = try Data(contentsOf: h.cacheURL)
        let originalIDs = Set(store.works.keys)
        let a = Work(id: WorkID(rawValue: "editorial:collision-a")!, title: "Same Recording", creator: "", kind: "歌曲", art: "", detail: "", url: "https://music.apple.com/us/song/99887766", linkedCreatorIDs: [], catalogID: "99887766", knowledgeID: "Q990011")
        let b = Work(id: WorkID(rawValue: "editorial:collision-b")!, title: "Same Recording", creator: "", kind: "歌曲", art: "", detail: "", url: "https://music.apple.com/us/song/99887766", linkedCreatorIDs: [], catalogID: "99887766", knowledgeID: "Q990012")
        XCTAssertThrowsError(try store.merge(CatalogSnapshot(works: [a, b], relations: []))) { error in
            guard case CatalogError.invalidData = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(Set(store.works.keys), originalIDs)
        XCTAssertEqual(try Data(contentsOf: h.cacheURL), originalDisk)
    }

    /// Deliberate opt-in only. Normal test runs never depend on Wikidata uptime.
    func testLivePaprikaToKonExpansionPersistsVerifiedStatementLinks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 to run the live integration probe")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.KnowledgeLive.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self), knowledgeService: KnowledgeGraphService())
        let film = try await store.openKnowledgeCandidate("Q578595")
        let director = try XCTUnwrap(store.edges.first { $0.from == film && $0.predicate == .directedBy })
        XCTAssertEqual(store.work(director.to).knowledgeID, "Q333643")
        XCTAssertEqual(URLComponents(string: director.source.url)?.host, "www.wikidata.org")
        XCTAssertEqual(URLComponents(string: director.source.url)?.path, "/wiki/Q578595")
        XCTAssertTrue(URLComponents(string: director.source.url)?.fragment?.contains("$") == true)

        let selectedDirector = try await store.openKnowledgeCandidate("Q333643")
        XCTAssertEqual(selectedDirector, director.to)
        let films = store.edges.filter { $0.to == selectedDirector && $0.predicate == .directedBy }
        XCTAssertGreaterThanOrEqual(films.count, 2, "The live expansion should discover another credited work")
        XCTAssertTrue(films.allSatisfy { URLComponents(string: $0.source.url)?.host == "www.wikidata.org" })
        XCTAssertNil(store.storageError)
        await store.flushPendingWrites()
        let restored = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.work(selectedDirector).knowledgeID, "Q333643")
        XCTAssertEqual(Set(restored.edges.filter { $0.to == selectedDirector && $0.predicate == .directedBy }.map(\.id)), Set(films.map(\.id)))
    }
}

private func knowledgeStoreClaim(_ from: String, _ to: String) -> [String: Any] {
    ["id": from + "$22222222-2222-2222-2222-222222222222", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": to]]]]
}
private func knowledgeStoreEntity(_ id: String, title: String, type: String, claims: [String: Any] = [:]) -> [String: Any] {
    var values = claims; values["P31"] = [knowledgeStoreClaim(id, type)]
    return ["id": id, "type": "item", "labels": ["zh": ["value": title]], "claims": values]
}
private func knowledgeStoreResponse(_ entities: [[String: Any]]) -> [String: Any] {
    ["success": 1, "entities": Dictionary(uniqueKeysWithValues: entities.map { ($0["id"] as! String, $0) })]
}

private struct KnowledgeStorePlan: Sendable {
    let data: Data?
    let status: Int
    let error: URLError.Code?
    var waitForCancellation = false
    var onStart: (@Sendable () -> Void)? = nil
    static func json(_ object: [String: Any], status: Int = 200) throws -> Self {
        .init(data: try JSONSerialization.data(withJSONObject: object), status: status, error: nil)
    }
    static func failure(_ code: URLError.Code) -> Self { .init(data: nil, status: 0, error: code) }
    static func waiting(_ onStart: @escaping @Sendable () -> Void) -> Self {
        .init(data: nil, status: 0, error: nil, waitForCancellation: true, onStart: onStart)
    }
}

@MainActor
private final class KnowledgeStoreHarness {
    let cacheURL: URL
    let knowledge: KnowledgeGraphService
    let apple: AppleCatalogService
    private let directory: URL
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: KnowledgeStoreStubState
    convenience init(plans: [[String: Any]]) throws {
        try self.init(readyPlans: plans.map { try KnowledgeStorePlan.json($0) })
    }
    init(readyPlans: [KnowledgeStorePlan]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.KnowledgeStore.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("catalog.json")
        state = KnowledgeStoreStubState(plans: readyPlans)
        KnowledgeStoreStubRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KnowledgeStoreURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Knowledge-Store-Test": token]
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        knowledge = KnowledgeGraphService(session: session)
        apple = AppleCatalogService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func store(freshKnowledge: Bool = false) -> CatalogStore {
        CatalogStore(cacheURL: cacheURL, service: apple, bundle: Bundle(for: KnowledgeStoreTests.self),
                     knowledgeService: freshKnowledge ? KnowledgeGraphService(session: session) : knowledge)
    }
    func close() { session.invalidateAndCancel(); KnowledgeStoreStubRegistry.shared.remove(token); try? FileManager.default.removeItem(at: directory) }
}
private final class KnowledgeStoreStubRegistry: @unchecked Sendable {
    static let shared = KnowledgeStoreStubRegistry()
    private let lock = NSLock()
    private var values: [String: KnowledgeStoreStubState] = [:]
    func put(_ key: String, _ value: KnowledgeStoreStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> KnowledgeStoreStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class KnowledgeStoreStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [KnowledgeStorePlan]
    private var observed: [URLRequest] = []
    init(plans: [KnowledgeStorePlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> KnowledgeStorePlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class KnowledgeStoreURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = KnowledgeStoreStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Knowledge-Store-Test")),
              let plan = state.next(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        plan.onStart?()
        if plan.waitForCancellation { return }
        if let error = plan.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        guard let data = plan.data,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MusicKitTestFixture.transcode(data, url: request.url))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
