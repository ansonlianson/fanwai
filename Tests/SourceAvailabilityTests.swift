import XCTest
@testable import Pianwai

/// Access observations use controlled responses. They do not assert that an
/// external browser opened a page, or that an article proves its quoted claim.
final class SourceAvailabilityTests: XCTestCase, @unchecked Sendable {
    func testPinnedRevisionQueryAndFragmentRemainExactForOpeningAndObservation() async throws {
        let raw = "https://en.wikipedia.org/w/index.php?title=One_Last_Kiss&oldid=12345#Production"
        let source = source(raw)
        let spy = SourceResponseSpy([.http(200)])
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })

        let observation = try await service.observe(source)

        XCTAssertEqual(SourceAvailabilityService.openableURL(raw)?.absoluteString, raw)
        XCTAssertEqual(observation.sourceURL, raw)
        XCTAssertEqual(observation.outcome, .responded)
        XCTAssertNil(observation.outcome.message, "An HTTP response must not create a verified-fact badge")
        let requests = await spy.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, raw)
        XCTAssertEqual(request.httpMethod, "GET", "A server refusing HEAD is not a missing page")
        XCTAssertEqual(request.timeoutInterval, 6)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testDifferentRevisionsAndEvidenceFragmentsNeverOverwriteTheirCacheIdentity() async throws {
        let urls = [
            "https://example.org/article?oldid=12#recording",
            "https://example.org/article?oldid=13#recording",
            "https://example.org/article?oldid=13#release"
        ]
        let spy = SourceResponseSpy([.http(200), .http(404), .http(403)])
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        for raw in urls { _ = try await service.observe(source(raw)) }
        let first = try await service.observe(source(urls[0]))
        let second = try await service.observe(source(urls[1]))
        let third = try await service.observe(source(urls[2]))

        XCTAssertEqual(first.outcome, .responded)
        XCTAssertEqual(second.outcome, .notFoundThisTime)
        XCTAssertEqual(third.outcome, .browserRequired)
        XCTAssertEqual([first.sourceURL, second.sourceURL, third.sourceURL], urls)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testDeniedThrottledAndMissingResponsesStayDistinctAndRetainOriginalSource() async throws {
        let cases: [(Int, SourceAvailabilityOutcome)] = [
            (200, .responded), (206, .responded),
            (401, .browserRequired), (403, .browserRequired), (407, .browserRequired),
            (429, .browserRequired), (451, .browserRequired),
            (404, .notFoundThisTime), (410, .notFoundThisTime),
            (500, .temporarilyUnavailable), (503, .temporarilyUnavailable)
        ]
        let spy = SourceResponseSpy(cases.map { .http($0.0) })
        let clock = SourceObservationClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = SourceAvailabilityService(now: { clock.date }, loadResponse: { try await spy.respond($0) })
        let original = source("https://example.org/interview?edition=original#composer")

        for (status, expected) in cases {
            let observation = try await service.observe(original, forceRefresh: true)
            XCTAssertEqual(observation.outcome, expected, "HTTP \(status)")
            XCTAssertEqual(observation.httpStatus, status)
            XCTAssertEqual(observation.checkedAt, clock.date)
            XCTAssertEqual(observation.sourceURL, original.url)
            XCTAssertFalse(observation.outcome.message?.contains("删除") ?? false)
        }
    }

    func testNetworkAndTLSFailuresDoNotBecomeNotFoundOrAuthenticationClaims() async throws {
        let errors: [URLError.Code] = [.notConnectedToInternet, .timedOut, .secureConnectionFailed, .cannotFindHost]
        let spy = SourceResponseSpy(errors.map { .failure($0) })
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        for _ in errors {
            let observation = try await service.observe(source(), forceRefresh: true)
            XCTAssertEqual(observation.outcome, .temporarilyUnavailable)
            XCTAssertNil(observation.httpStatus)
            XCTAssertNil(observation.responseURL)
        }
    }

    func testHomepageLoginAndRevisionRedirectsAreNotSuccessfulOriginalEvidenceChecks() async throws {
        let original = source("https://example.org/article?oldid=12#music")
        let redirects = [
            "https://example.org/",
            "https://example.org/login?return=article",
            "https://example.org/article?oldid=13",
            "https://other.example.org/article?oldid=12"
        ]
        let spy = SourceResponseSpy(redirects.map { .redirect(200, $0) })
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        for target in redirects {
            let observation = try await service.observe(original, forceRefresh: true)
            XCTAssertEqual(observation.outcome, .browserRequired)
            XCTAssertEqual(observation.sourceURL, original.url, "Never replace a fact's source with a redirect destination")
            XCTAssertEqual(observation.responseURL?.absoluteString, target)
        }
    }

    func testResponseOmittingHTTPFragmentStillRefersToSamePinnedResource() async throws {
        let original = source("https://example.org/article?oldid=12#music")
        let spy = SourceResponseSpy([.redirect(200, "https://example.org/article?oldid=12")])
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        let observation = try await service.observe(original)
        XCTAssertEqual(observation.outcome, .responded)
        XCTAssertEqual(observation.sourceURL, original.url)
    }

    func testFreshCacheSuppressesRepeatedRequestsAndRetryBypassesIt() async throws {
        let clock = SourceObservationClock(Date(timeIntervalSince1970: 1_700_000_000))
        let spy = SourceResponseSpy([.http(404), .http(200), .http(503)])
        let service = SourceAvailabilityService(ttl: 300, now: { clock.date }, loadResponse: { try await spy.respond($0) })
        let first = try await service.observe(source())
        clock.advance(299)
        let fresh = try await service.observe(source())
        XCTAssertEqual(fresh, first)
        let firstRequests = await spy.requests
        XCTAssertEqual(firstRequests.count, 1)

        let retried = try await service.observe(source(), forceRefresh: true)
        XCTAssertEqual(retried.outcome, .responded)
        XCTAssertEqual(retried.checkedAt, clock.date)
        clock.advance(300)
        let expired = try await service.observe(source())
        XCTAssertEqual(expired.outcome, .temporarilyUnavailable)
        XCTAssertEqual(expired.checkedAt, clock.date)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testClockMovingBackwardsCannotKeepAnObservationFreshIndefinitely() async throws {
        let clock = SourceObservationClock(Date(timeIntervalSince1970: 1_700_000_000))
        let spy = SourceResponseSpy([.http(404), .http(200)])
        let service = SourceAvailabilityService(now: { clock.date }, loadResponse: { try await spy.respond($0) })
        _ = try await service.observe(source())
        clock.advance(-60)
        let refreshed = try await service.observe(source())
        XCTAssertEqual(refreshed.outcome, .responded)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testObservationCacheIsBoundedWithoutChangingSourceData() async throws {
        let clock = SourceObservationClock(Date(timeIntervalSince1970: 1_700_000_000))
        let spy = SourceResponseSpy([.http(200), .http(200), .http(200), .http(404)])
        let service = SourceAvailabilityService(capacity: 2, now: { clock.date }, loadResponse: { try await spy.respond($0) })
        for number in 1...3 {
            _ = try await service.observe(source("https://example.org/article/\(number)"))
            clock.advance(1)
        }
        _ = try await service.observe(source("https://example.org/article/2"))
        let oldest = try await service.observe(source("https://example.org/article/1"))
        XCTAssertEqual(oldest.outcome, .notFoundThisTime)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 4, "Only the evicted URL needs another observation")
    }

    func testLeavingSurfaceCancelsTransportWithoutCachingAFalseFailure() async throws {
        let started = expectation(description: "The selected source check started")
        let spy = SourceResponseSpy([.suspend, .http(200)], suspensionStarted: started)
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        let original = source()
        let loading = Task { try await service.observe(original) }
        let wait = await XCTWaiter.fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(wait, .completed)
        loading.cancel()
        do { _ = try await loading.value; XCTFail("A cancelled observation was returned") }
        catch is CancellationError { }

        let restored = try await service.observe(original)
        XCTAssertEqual(restored.outcome, .responded)
        let cancelled = await spy.cancelledRequests
        let requests = await spy.requests
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(requests.count, 2, "Cancellation must not leave a cached unavailable result")
    }

    func testURLSessionCancellationIsNotAnUnavailableObservation() async throws {
        let spy = SourceResponseSpy([.failure(.cancelled), .http(200)])
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        do { _ = try await service.observe(source()); XCTFail("URL cancellation became a result") }
        catch is CancellationError { }
        let next = try await service.observe(source())
        XCTAssertEqual(next.outcome, .responded)
        let requests = await spy.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testUnsupportedURLsDoNotContactTransportOrBecomeExternalActions() async throws {
        let spy = SourceResponseSpy([])
        let service = SourceAvailabilityService(loadResponse: { try await spy.respond($0) })
        for raw in ["javascript:alert(1)", "file:///private/article", "/article/123", "https:///", "https://name:secret@example.org/article"] {
            XCTAssertNil(SourceAvailabilityService.openableURL(raw))
            let observation = try await service.observe(source(raw))
            XCTAssertEqual(observation.outcome, .unsupportedURL)
            XCTAssertEqual(observation.sourceURL, raw)
        }
        let requests = await spy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func source(_ url: String = "https://example.org/article#original") -> Source {
        Source(title: "原访谈", detail: "发布者 · 原始资料", url: url)
    }
}

private actor SourceResponseSpy {
    enum Plan: Sendable {
        case http(Int)
        case redirect(Int, String)
        case failure(URLError.Code)
        case suspend
    }
    private var plans: [Plan]
    private let suspensionStarted: XCTestExpectation?
    private(set) var requests: [URLRequest] = []
    private(set) var cancelledRequests = 0

    init(_ plans: [Plan], suspensionStarted: XCTestExpectation? = nil) {
        self.plans = plans
        self.suspensionStarted = suspensionStarted
    }

    func respond(_ request: URLRequest) async throws -> URLResponse {
        requests.append(request)
        guard !plans.isEmpty, let url = request.url else { throw URLError(.badServerResponse) }
        switch plans.removeFirst() {
        case .http(let status):
            return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        case .redirect(let status, let target):
            return HTTPURLResponse(url: URL(string: target)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        case .failure(let error): throw URLError(error)
        case .suspend:
            suspensionStarted?.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelledRequests += 1; throw error }
            throw URLError(.timedOut)
        }
    }
}

private final class SourceObservationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}
