import XCTest
@testable import Pianwai

final class KnowledgeIdentityTests: XCTestCase, @unchecked Sendable {
    func testArtistResolvesOnlyThroughExactExternalClaimAndReturnsItsSource() async throws {
        let h = try IdentityHarness(plans: [identitySearch(["Q44190"]), identityEntities([identityEntity("Q44190", artistID: "657515", type: "Q215380")])]); defer { h.close() }
        let resolved = try await h.service.resolveAppleArtist(id: "657515")
        let match = try XCTUnwrap(resolved)
        XCTAssertEqual(match.qid, "Q44190")
        XCTAssertEqual(h.parameters(at: 0)["srsearch"], "haswbstatement:P2850=657515")
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q44190")
        XCTAssertEqual(URLComponents(string: match.source.url)?.path, "/wiki/Q44190")
        XCTAssertEqual(URLComponents(string: match.source.url)?.fragment, "Q44190$33333333-3333-3333-3333-333333333333")
        XCTAssertTrue(match.source.title.hasPrefix("Wikidata · "))
        XCTAssertEqual(h.requests.count, 2)
    }

    func testDatabaseDisplayNameQualifierAllowsExactArtistAliasIdentity() async throws {
        var named = identityClaim("Q11190062", artistID: "322356337")
        named["qualifiers"] = ["P1810": [["snaktype": "value", "datatype": "string", "datavalue": ["value": "agraph"]]]]
        var entity = identityEntity("Q11190062", artistID: "939561587")
        entity["claims"] = ["P31": [identityTypeClaim("Q5")], "P2850": [identityClaim("Q11190062", artistID: "939561587"), named]]
        let h = try IdentityHarness(plans: [identitySearch(["Q11190062"]), identityEntities([entity])]); defer { h.close() }
        let match = try await h.service.resolveAppleArtist(id: "322356337")
        XCTAssertEqual(match?.qid, "Q11190062", "A non-restrictive database name can differ from the creator label")
        XCTAssertEqual(h.parameters(at: 0)["srsearch"], "haswbstatement:P2850=322356337")
    }

    func testStaleSearchIndexOrMatchingNameDoesNotEstablishIdentity() async throws {
        let h = try IdentityHarness(plans: [identitySearch(["Q44190"]), identityEntities([identityEntity("Q44190", artistID: "999999")])]); defer { h.close() }
        let result = try await h.service.resolveAppleArtist(id: "657515")
        XCTAssertNil(result, "Search candidates must be checked against current exact P2850 values")
        XCTAssertEqual(h.requests.count, 2)
    }

    func testTwoVerifiedEntitiesWithSameArtistIDReturnNoAutomaticMatch() async throws {
        let h = try IdentityHarness(plans: [identitySearch(["Q100", "Q200"]), identityEntities([identityEntity("Q100", artistID: "657515"), identityEntity("Q200", artistID: "657515")])]); defer { h.close() }
        let result = try await h.service.resolveAppleArtist(id: "657515")
        XCTAssertNil(result)
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q100|Q200", "Both candidates must be verified in the same batch")
    }

    func testIncompleteOrTruncatedIndexPageCannotProveUniqueness() async throws {
        for total in [2, 6] {
            let h = try IdentityHarness(plans: [identitySearch(["Q100"], total: total)]); defer { h.close() }
            let result = try await h.service.resolveAppleArtist(id: "657515")
            XCTAssertNil(result)
            XCTAssertEqual(h.requests.count, 1, "A partial candidate page must not pick its first result")
        }
    }

    func testDeprecatedTemporalAndNonArtistClaimsCannotCreateMapping() async throws {
        var deprecated = identityClaim("Q100", artistID: "657515"); deprecated["rank"] = "deprecated"
        var temporal = identityClaim("Q100", artistID: "657515")
        temporal["qualifiers"] = ["P582": [["snaktype": "value", "datatype": "time", "datavalue": ["value": ["time": "+2020-01-01T00:00:00Z"]]]]]
        var scoped = identityClaim("Q100", artistID: "657515")
        scoped["qualifiers"] = ["P518": [identityTypeClaim("Q200")["mainsnak"]!]]
        let wrongStatementOwner = identityClaim("Q200", artistID: "657515")
        for invalidClaim in [deprecated, temporal, scoped, wrongStatementOwner] {
            var entity = identityEntity("Q100", artistID: "657515")
            entity["claims"] = ["P31": [identityTypeClaim("Q5")], "P2850": [invalidClaim]]
            let h = try IdentityHarness(plans: [identitySearch(["Q100"]), identityEntities([entity])]); defer { h.close() }
            let result = try await h.service.resolveAppleArtist(id: "657515")
            XCTAssertNil(result)
        }
        let h = try IdentityHarness(plans: [identitySearch(["Q100"]), identityEntities([identityEntity("Q100", artistID: "657515", type: "Q7366")])]); defer { h.close() }
        let result = try await h.service.resolveAppleArtist(id: "657515")
        XCTAssertNil(result, "Even an exact ID on a song is not an artist identity")
    }

    func testInvalidArtistIdentifiersNeverReachTransport() async throws {
        let h = try IdentityHarness(plans: []); defer { h.close() }
        for id in ["", "0", "0657515", "657515 OR haswbstatement:P31=Q5", "Q44190", "１２３", "-12", "12.0"] {
            do { _ = try await h.service.resolveAppleArtist(id: id); XCTFail("Accepted invalid ID \(id)") }
            catch KnowledgeError.invalidIdentifier { }
        }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testExactMatchReusesValidatedCacheButCancelledCallerPublishesNothing() async throws {
        let h = try IdentityHarness(plans: [identitySearch(["Q44190"]), identityEntities([identityEntity("Q44190", artistID: "657515", type: "Q215380")])]); defer { h.close() }
        let first = try await h.service.resolveAppleArtist(id: "657515")
        let second = try await h.service.resolveAppleArtist(id: "657515")
        XCTAssertEqual(first?.qid, second?.qid)
        XCTAssertEqual(first?.source, second?.source)
        let service = h.service
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resolveAppleArtist(id: "657515")
        }
        do { _ = try await task.value; XCTFail("Cancelled resolution published a match") }
        catch is CancellationError { }
        XCTAssertEqual(h.requests.count, 2)
    }

    func testMalformedIndexResponseThrowsAndDoesNotPoisonRecovery() async throws {
        let malformed: [String: Any] = ["query": ["search": [["title": "Q44190"]]]]
        let h = try IdentityHarness(plans: [malformed, identitySearch(["Q44190"]), identityEntities([identityEntity("Q44190", artistID: "657515", type: "Q215380")])]); defer { h.close() }
        do { _ = try await h.service.resolveAppleArtist(id: "657515"); XCTFail("Malformed index was treated as no match") }
        catch KnowledgeError.invalidResponse { }
        let result = try await h.service.resolveAppleArtist(id: "657515")
        XCTAssertEqual(result?.qid, "Q44190")
        XCTAssertEqual(h.requests.count, 3)
    }

    func testThrottleIsAnErrorRatherThanNoIdentity() async throws {
        let h = try IdentityHarness(plans: [["error": ["code": "maxlag"]]]); defer { h.close() }
        for _ in 0..<2 {
            do { _ = try await h.service.resolveAppleArtist(id: "657515"); XCTFail("Throttle was treated as no match") }
            catch KnowledgeError.throttled { }
        }
        XCTAssertEqual(h.requests.count, 1)
    }
}

private func identityClaim(_ qid: String, artistID: String) -> [String: Any] {
    ["id": qid + "$33333333-3333-3333-3333-333333333333", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "external-id", "datavalue": ["value": artistID]]]
}
private func identityTypeClaim(_ type: String) -> [String: Any] {
    ["rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": type]]]]
}
private func identityEntity(_ qid: String, artistID: String, type: String = "Q5") -> [String: Any] {
    ["id": qid, "type": "item", "labels": ["zh": ["value": "A label that is never used for matching"]], "claims": ["P31": [identityTypeClaim(type)], "P2850": [identityClaim(qid, artistID: artistID)]]]
}
private func identityEntities(_ entities: [[String: Any]]) -> [String: Any] {
    ["success": 1, "entities": Dictionary(uniqueKeysWithValues: entities.map { ($0["id"] as! String, $0) })]
}
private func identitySearch(_ qids: [String], total: Int? = nil) -> [String: Any] {
    ["query": ["searchinfo": ["totalhits": total ?? qids.count], "search": qids.map { ["title": $0] }]]
}
private final class IdentityHarness: @unchecked Sendable {
    let service: KnowledgeGraphService
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: IdentityStubState
    init(plans: [[String: Any]]) throws {
        state = IdentityStubState(plans: try plans.map { try JSONSerialization.data(withJSONObject: $0) })
        IdentityStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Identity-Test": token]
        session = URLSession(configuration: configuration)
        service = KnowledgeGraphService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(at index: Int) -> [String: String] {
        guard requests.indices.contains(index), let url = requests[index].url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close() { session.invalidateAndCancel(); IdentityStubRegistry.shared.remove(token) }
}
private final class IdentityStubRegistry: @unchecked Sendable {
    static let shared = IdentityStubRegistry()
    private let lock = NSLock()
    private var values: [String: IdentityStubState] = [:]
    func put(_ key: String, _ value: IdentityStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> IdentityStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class IdentityStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [Data]
    private var observed: [URLRequest] = []
    init(plans: [Data]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> Data? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class IdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = IdentityStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Identity-Test")),
              let data = state.next(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
