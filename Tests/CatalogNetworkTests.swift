import XCTest
@testable import Pianwai

/// Exercises the real URLSession/AppleCatalogService boundary. Every session has
/// its own stub token; unmatched requests fail locally rather than using a network.
final class CatalogNetworkTests: XCTestCase, @unchecked Sendable {
    func testMalformedJSONIsRejectedAndDoesNotPoisonTheResponseCache() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .http(status: 200, data: Data("{\"results\":[".utf8)),
            .http(status: 200, data: try payload(id: 91001))
        ])
        defer { harness.close() }
        do {
            _ = try await harness.service.search("malformed then recovered", country: "jp", kind: .song)
            XCTFail("Malformed JSON must not become a successful empty result")
        } catch CatalogError.invalidData { }
        catch { XCTFail("Expected invalidData, got \(error)") }

        let recovered = try await harness.service.search("malformed then recovered", country: "jp", kind: .song)
        XCTAssertEqual(recovered.results.map(\.rawValue), ["apple:song:91001"])
        XCTAssertEqual(harness.requests.count, 2, "Retry must reach the transport instead of reusing malformed bytes")
    }

    func testHTTP429RemainsRetryableAndIsNotCachedAsAnEmptyResult() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .http(status: 429, data: Data("rate limited".utf8)),
            .http(status: 200, data: try payload(id: 91002))
        ])
        defer { harness.close() }
        do {
            _ = try await harness.service.search("rate-limited query", country: "jp", kind: .song)
            XCTFail("HTTP 429 must report throttling")
        } catch CatalogError.throttled { }
        catch { XCTFail("Expected throttled, got \(error)") }
        let retry = try await harness.service.search("rate-limited query", country: "jp", kind: .song)
        XCTAssertEqual(retry.results.map(\.rawValue), ["apple:song:91002"])
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testTransportFailureStaysDistinctFromNoResultsAndCanRecover() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .failure(.notConnectedToInternet),
            .http(status: 200, data: try payload(id: 91003))
        ])
        defer { harness.close() }
        do {
            _ = try await harness.service.search("offline then online", country: "jp", kind: .song)
            XCTFail("A disconnected transport must not return an empty successful catalog")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
            XCTAssertEqual(CatalogError.message(error), CatalogError.offline.localizedDescription)
        } catch CatalogError.offline { }
        catch { XCTFail("Expected an offline transport failure, got \(error)") }
        let retry = try await harness.service.search("offline then online", country: "jp", kind: .song)
        XCTAssertEqual(retry.results.map(\.rawValue), ["apple:song:91003"])
        XCTAssertEqual(harness.requests.count, 2)
    }

    func testEquivalentRequestsUseCacheButDifferentRegionDoesNot() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .http(status: 200, data: try payload(id: 91004)),
            .http(status: 200, data: try payload(id: 91005))
        ])
        defer { harness.close() }
        let first = try await harness.service.search("  cache query\n", country: "JP", kind: .song)
        let equivalent = try await harness.service.search("cache query", country: "jp", kind: .song)
        XCTAssertEqual(first.results, equivalent.results)
        XCTAssertEqual(harness.requests.count, 1)
        let otherRegion = try await harness.service.search("cache query", country: "us", kind: .song)
        XCTAssertEqual(otherRegion.results.map(\.rawValue), ["apple:song:91005"])
        XCTAssertEqual(harness.requests.count, 2)
        let urls = try harness.requests.map { try XCTUnwrap($0.url) }
        XCTAssertEqual(urls.map { $0.pathComponents[3] }, ["jp", "us"])
    }

    func testCancellingAnInFlightRequestNeitherReturnsNorCachesItsResponse() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .held(status: 200, data: try payload(id: 91006)),
            .http(status: 200, data: try payload(id: 91007))
        ])
        defer { harness.close() }
        let started = harness.expectRequest(1)
        let service = harness.service
        let cancelled = Task { try await service.search("cancel query", country: "jp", kind: .song) }
        guard await waitForRequest(started) else { cancelled.cancel(); return }
        cancelled.cancel()
        await assertCancelled(cancelled)
        // Release even the old response. A stopped URLProtocol must not publish it.
        harness.releaseHeld()
        let fresh = try await service.search("cancel query", country: "jp", kind: .song)
        XCTAssertEqual(fresh.results.map(\.rawValue), ["apple:song:91007"])
        XCTAssertEqual(harness.requests.count, 2, "Cancelled work must not populate the reusable service cache")
    }

    func testAnAlreadyCancelledCallerCannotPublishAnExistingCacheHit() async throws {
        let harness = CatalogNetworkHarness(plans: [.http(status: 200, data: try payload(id: 91008))])
        defer { harness.close() }
        let service = harness.service
        let accepted = try await service.search("cached cancellation", country: "jp", kind: .song)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.search("cached cancellation", country: "jp", kind: .song)
        }
        await assertCancelled(cancelled)
        let later = try await service.search("cached cancellation", country: "jp", kind: .song)
        XCTAssertEqual(later.results, accepted.results, "A cancelled reader must not invalidate an earlier accepted response")
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testCancelledOlderSearchCannotMergeStaleEntitiesAfterANewerSearch() async throws {
        let harness = CatalogNetworkHarness(plans: [
            .held(status: 200, data: try payload(id: 91009)),
            .http(status: 200, data: try payload(id: 91010)),
            .http(status: 200, data: try payload(id: 91011))
        ])
        defer { harness.close() }
        let service = harness.service
        let store = await MainActor.run {
            CatalogStore(cacheURL: nil, service: service, bundle: Bundle(for: CatalogNetworkTests.self))
        }
        let started = harness.expectRequest(1)
        let oldSearch = Task { try await store.search("older query", country: "jp", kind: .song) }
        guard await waitForRequest(started) else { oldSearch.cancel(); return }
        let latest = try await store.search("newer query", country: "jp", kind: .song)
        oldSearch.cancel()
        await assertCancelled(oldSearch)
        harness.releaseHeld()
        XCTAssertEqual(latest.map(\.rawValue), ["apple:song:91010"])
        let storedIDs = await MainActor.run { Set(store.works.keys.map(\.rawValue)) }
        XCTAssertTrue(storedIDs.contains("apple:song:91010"))
        XCTAssertFalse(storedIDs.contains("apple:song:91009"), "A cancelled older request must never publish to the catalog")
        let retry = try await store.search("older query", country: "jp", kind: .song)
        XCTAssertEqual(retry.map(\.rawValue), ["apple:song:91011"])
        XCTAssertEqual(harness.requests.count, 3)
    }

    func testNetworkSearchKeepsStudioLiveAndReissueIdentitiesSeparate() async throws {
        let items: [[String: Any]] = [
            recording(id: 91012, album: 92001, title: "Signal", release: "Original Release"),
            recording(id: 91013, album: 92002, title: "Signal (Live)", release: "Concert Recording"),
            recording(id: 91014, album: 92003, title: "Signal", release: "Anniversary Reissue")
        ]
        let body = try JSONSerialization.data(withJSONObject: ["results": items])
        let harness = CatalogNetworkHarness(plans: [.http(status: 200, data: body)])
        defer { harness.close() }
        let result = try await harness.service.search("Signal", country: "jp", kind: .song)
        XCTAssertEqual(result.results.map(\.rawValue), ["apple:song:91012", "apple:song:91013", "apple:song:91014"])
        let recordings = result.snapshot.works.filter { result.results.contains($0.id) }
        XCTAssertEqual(Set(recordings.compactMap(\.albumID)).count, 3)
        XCTAssertEqual(recordings.filter { $0.title == "Signal" }.count, 2, "Same display title is not an identity")
        XCTAssertEqual(harness.requests.count, 1)
        let request = try XCTUnwrap(harness.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/catalog/jp/search")
        XCTAssertEqual(request.url?.host, "api.music.apple.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    private func waitForRequest(_ expectation: XCTestExpectation, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed, "The isolated URLProtocol did not receive the expected request", file: file, line: line)
        return result == .completed
    }

    private func assertCancelled<Value: Sendable>(_ task: Task<Value, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled work published a successful response", file: file, line: line)
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { XCTFail("Cancellation became an unrelated error: \(error)", file: file, line: line) }
    }

    private func payload(id: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["results": [recording(id: id, album: 92999, title: "Signal", release: "Test Release")]])
    }

    private func recording(id: Int, album: Int, title: String, release: String) -> [String: Any] {
        ["wrapperType": "track", "kind": "song", "trackId": id, "trackName": title,
         "trackViewUrl": "https://music.apple.com/jp/song/\(id)", "artistId": 93001,
         "artistName": "Test Artist", "collectionId": album, "collectionName": release,
         "trackTimeMillis": 180_000, "releaseDate": "2020-01-01T00:00:00Z"]
    }
}

private enum NetworkPlan: Sendable {
    case http(status: Int, data: Data)
    case held(status: Int, data: Data)
    case failure(URLError.Code)
}

/// The only shared object is a locked routing registry. Per-test responses,
/// observations and sessions live in independent token-addressed state objects.
private final class NetworkStubRegistry: @unchecked Sendable {
    static let shared = NetworkStubRegistry()
    static let tokenHeader = "X-Pianwai-Network-Test"
    private let lock = NSLock()
    private var states: [String: NetworkStubState] = [:]
    func put(_ state: NetworkStubState, token: String) { lock.lock(); defer { lock.unlock() }; states[token] = state }
    func get(_ token: String?) -> NetworkStubState? {
        guard let token else { return nil }
        lock.lock(); defer { lock.unlock() }; return states[token]
    }
    func remove(_ token: String) { lock.lock(); defer { lock.unlock() }; states[token] = nil }
}

private final class CatalogNetworkHarness: @unchecked Sendable {
    let service: AppleCatalogService
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: NetworkStubState
    init(plans: [NetworkPlan]) {
        state = NetworkStubState(plans: plans)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogTestURLProtocol.self]
        configuration.httpAdditionalHeaders = [NetworkStubRegistry.tokenHeader: token]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        service = AppleCatalogService(session: session)
        NetworkStubRegistry.shared.put(state, token: token)
    }
    var requests: [URLRequest] { state.requests }
    func expectRequest(_ count: Int) -> XCTestExpectation { state.expectRequest(count) }
    func releaseHeld() { state.releaseHeld() }
    func close() {
        session.invalidateAndCancel()
        state.discardHeld()
        NetworkStubRegistry.shared.remove(token)
    }
}

private final class NetworkStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [NetworkPlan]
    private var observed: [URLRequest] = []
    private var waiters: [(count: Int, expectation: XCTestExpectation)] = []
    private var held: [(loader: CatalogTestURLProtocol, plan: NetworkPlan)] = []
    init(plans: [NetworkPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func expectRequest(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "isolated request \(count)")
        lock.lock()
        let alreadyObserved = observed.count >= count
        if !alreadyObserved { waiters.append((count, expectation)) }
        lock.unlock()
        if alreadyObserved { expectation.fulfill() }
        return expectation
    }
    func start(_ loader: CatalogTestURLProtocol) {
        lock.lock()
        observed.append(loader.request)
        let completed = waiters.filter { observed.count >= $0.count }
        waiters.removeAll { observed.count >= $0.count }
        let plan = plans.isEmpty ? .failure(.resourceUnavailable) : plans.removeFirst()
        if case .held = plan { held.append((loader, plan)) }
        lock.unlock()
        completed.forEach { $0.expectation.fulfill() }
        if case .held = plan { return }
        loader.deliver(plan)
    }
    func releaseHeld() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        pending.forEach { $0.loader.deliver($0.plan) }
    }
    func discardHeld() { lock.lock(); held = []; lock.unlock() }
}

private final class CatalogTestURLProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = NetworkStubRegistry.shared.get(request.value(forHTTPHeaderField: NetworkStubRegistry.tokenHeader)) else {
            // Never fall back to the internet if session configuration is wrong.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        state.start(self)
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func deliver(_ plan: NetworkPlan) {
        stateLock.lock(); let mayDeliver = !stopped; stateLock.unlock()
        guard mayDeliver else { return }
        switch plan {
        case let .failure(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .http(status, data), let .held(status, data):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: MusicKitTestFixture.transcode(data, url: request.url))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
