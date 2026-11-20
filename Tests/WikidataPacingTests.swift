import XCTest
@testable import Pianwai

final class WikidataPacingTests: XCTestCase {
    func testOnlyShortWikidataRetryIsCountedAndPaced() async throws {
        let loader = WikidataRetryFixture()
        let transport = StoryMaterialTransport(limit: 2, loader: { try await loader.load($0) })
        let data = await transport.api(URL(string: "https://www.wikidata.org/w/api.php?action=fixture")!, purpose: "offline fixture")
        XCTAssertNotNil(data)
        let (requests, _) = await transport.audit(); XCTAssertEqual(requests.map(\.status), [429, 200])
        let dates = await loader.dates
        XCTAssertGreaterThanOrEqual(dates[0].duration(to: dates[1]), .milliseconds(980))
        XCTAssertNil(StoryMaterialTransport.retryDelay("11"))
        let exhausted = StoryMaterialTransport(limit: 1, loader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "0"])!)
        })
        _ = await exhausted.api(URL(string: "https://www.wikidata.org/w/api.php?action=other")!, purpose: "offline fixture")
        let (limited, _) = await exhausted.audit(); XCTAssertEqual(limited.count, 1)
    }
}
private actor WikidataRetryFixture {
    var dates: [ContinuousClock.Instant] = []
    func load(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        dates.append(.now)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: dates.count == 1 ? 429 : 200,
                                               httpVersion: nil, headerFields: ["Retry-After": "0"])!)
    }
}
