import XCTest
@testable import Pianwai

final class MetadataTransportTests: XCTestCase {
    @MainActor func testDeadlineEndsEvenWhenTheSourceIgnoresCancellation() async {
        actor HeldSource {
            private var continuation: CheckedContinuation<Int?, Never>?
            private var released = false
            func read() async -> Int? {
                if released { return 42 }
                return await withCheckedContinuation { continuation = $0 }
            }
            func release() { released = true; continuation?.resume(returning: 42); continuation = nil }
        }
        let source = HeldSource(), ended = expectation(description: "Optional source stops holding the page")
        var result: Int?
        let lookup = Task {
            result = await MetadataDeadline.value(seconds: 0.03) { await source.read() }
            ended.fulfill()
        }
        let status = await XCTWaiter.fulfillment(of: [ended], timeout: 1)
        await source.release()
        await lookup.value
        XCTAssertEqual(status, .completed)
        XCTAssertNil(result, "A late successful reply must not overwrite the ended lookup")
    }
    func testConcurrentMetadataConsumersShareOneRequestAndReuseTheResult() async throws {
        actor Counter { var calls = 0; func next() { calls += 1 } }
        let counter = Counter()
        let transport = MetadataTransport(directory: nil) { request in
            await counter.next()
            return (Data(#"{"query":{"pages":[]}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let url = URL(string: "https://www.wikidata.org/w/api.php?action=test-dedup")!
        async let first = transport.response(url)
        async let second = transport.response(url)
        let values = await (first, second)
        XCTAssertNotNil(values.0); XCTAssertNotNil(values.1)
        _ = await transport.response(url)
        let count = await counter.calls
        XCTAssertEqual(count, 1)
    }
    func testRateLimitStopsOtherRequestsInTheSameSourceInsteadOfRetrying() async throws {
        actor Counter { var calls = 0; func next() { calls += 1 } }
        let counter = Counter()
        let transport = MetadataTransport(directory: nil) { request in
            await counter.next()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        let first = await transport.response(URL(string: "https://www.wikidata.org/w/api.php?action=limited")!)
        let second = await transport.response(URL(string: "https://ja.wikipedia.org/w/api.php?action=another")!)
        XCTAssertNil(first); XCTAssertNil(second)
        let count = await counter.calls
        XCTAssertEqual(count, 1)
        XCTAssertEqual(MetadataTransport.retryDelay("120"), 120)
    }
}
