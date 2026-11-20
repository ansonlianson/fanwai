import XCTest
import Observation
import UIKit
@testable import Pianwai

final class PerformanceArtworkTests: XCTestCase {
    private actor Loads {
        private(set) var count = 0
        func increment() { count += 1 }
    }
    @MainActor private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.jpegData(compressionQuality: 0.9)!
    }
    @MainActor func testUnrelatedCoverDoesNotInvalidateObservedURL() async {
        let bytes = jpeg()
        let first = URL(string: "https://example.com/first.jpg")!
        let second = URL(string: "https://example.com/second.jpg")!
        let cache = ArtworkImageCache(directory: nil) { request in
            (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let unrelated = expectation(description: "Another URL must not invalidate this cover")
        unrelated.isInverted = true
        withObservationTracking { _ = cache.image(first) } onChange: { unrelated.fulfill() }
        let loaded = await cache.load(second)
        XCTAssertNotNil(loaded)
        XCTAssertNil(cache.image(first))
        await fulfillment(of: [unrelated], timeout: 0.05)
    }
    @MainActor func testConcurrentReadersShareOneDecodeAndTransport() async {
        let bytes = jpeg(), loads = Loads()
        let url = URL(string: "https://example.com/shared.jpg")!
        let cache = ArtworkImageCache(directory: nil) { request in
            await loads.increment()
            try await Task.sleep(for: .milliseconds(30))
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        async let first = cache.load(url)
        async let second = cache.load(url)
        let images = await (first, second)
        XCTAssertNotNil(images.0); XCTAssertNotNil(images.1)
        let count = await loads.count
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(cache.image(url))
    }
    @MainActor func testDiskHitLoadsWithoutStartingTransport() async throws {
        let bytes = jpeg()
        let url = URL(string: "https://example.com/durable.jpg")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ArtworkImageCache(directory: directory) { request in
            (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let written = await writer.load(url)
        XCTAssertNotNil(written)
        let reader = ArtworkImageCache(directory: directory) { _ in
            XCTFail("A fresh disk hit must not request the network")
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertNil(reader.image(url), "A synchronous view read only consults decoded memory")
        let restored = await reader.load(url)
        XCTAssertNotNil(restored)
        XCTAssertNotNil(reader.image(url))
    }
    @MainActor func testRestoredSystemCoverIsNotPublishedBeforeItCanBeResolved() async throws {
        let identity = "perf-disk-restore-" + UUID().uuidString
        let asset = ObservedArtwork.key(identity)
        let directory = try XCTUnwrap(PianwaiRuntime.applicationDirectory("ObservedArtwork"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(asset + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try jpeg().write(to: file)
        XCTAssertNil(ObservedArtwork.remember(identity: identity, image: { nil }),
            "A metadata snapshot must not claim a cover whose async restore is unfinished")
        let loaded = await ObservedArtwork.load(asset)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(ObservedArtwork.remember(identity: identity, image: { nil }), asset,
            "A later capture must publish the newly available cover as a metadata change")
        XCTAssertNotNil(ObservedArtwork.image(asset), "Library must be able to resolve the published identity")
    }

}
