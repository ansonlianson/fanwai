import XCTest
@testable import Pianwai

/// Metadata-cache contracts. The actor spy never fetches an image or contacts
/// Wikipedia, so network availability cannot masquerade as a known-empty work.
@MainActor
final class WorkArtworkStoreTests: XCTestCase {
    func testArtworkMetadataSurvivesRecreationWithoutAnotherRequest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = response("Q100")
        let service = ArtworkStoreSpy(outcomes: [.success(expected)])
        let store = WorkArtworkStore(service: service, directory: directory)
        await store.load(expected.qid)

        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertNil(store.errors[expected.qid])
        XCTAssertFalse(store.loading.contains(expected.qid))
        let offlineService = ArtworkStoreSpy(outcomes: [])
        let recreated = WorkArtworkStore(service: offlineService, directory: directory)
        await recreated.load(expected.qid)

        try assertResponse(recreated.values[expected.qid], equals: expected)
        let requests = await service.requests
        let offlineRequests = await offlineService.requests
        XCTAssertEqual(requests, [expected.qid])
        XCTAssertTrue(offlineRequests.isEmpty)
        let cached = try JSONDecoder().decode(ArtworkCacheFixture.self, from: Data(contentsOf: file(expected.qid, in: directory)))
        try assertResponse(cached.response, equals: expected)
    }

    func testSuccessfulMissingArtworkIsCachedInMemoryAndAcrossLaunches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = WorkArtworkResponse(qid: "Q200", artwork: nil)
        let service = ArtworkStoreSpy(outcomes: [.success(empty)])
        let store = WorkArtworkStore(service: service, directory: directory)
        await store.load(empty.qid)
        await store.load(empty.qid)
        try assertResponse(store.values[empty.qid], equals: empty)
        XCTAssertNil(store.errors[empty.qid])
        let requests = await service.requests
        XCTAssertEqual(requests, [empty.qid])

        let offlineService = ArtworkStoreSpy(outcomes: [])
        let recreated = WorkArtworkStore(service: offlineService, directory: directory)
        await recreated.load(empty.qid)
        try assertResponse(recreated.values[empty.qid], equals: empty)
        let offlineRequests = await offlineService.requests
        XCTAssertTrue(offlineRequests.isEmpty, "A verified absence is a successful cache result")
    }

    func testLegacyEmptyCacheRefreshesImmediatelyButLegacyRealImageIsReusable() async throws {
        for hasImage in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let expected = response("Q300")
            let old = hasImage ? expected : WorkArtworkResponse(qid: "Q300", artwork: nil)
            try writeCache(old, under: "Q300", version: 1, fetchedAt: Date(), directory: directory)
            let service = ArtworkStoreSpy(outcomes: hasImage ? [] : [.success(expected)])
            let store = WorkArtworkStore(service: service, directory: directory)
            await store.load("Q300")
            try assertResponse(store.values["Q300"], equals: expected)
            let requests = await service.requests
            XCTAssertEqual(requests, hasImage ? [] : ["Q300"])
            if !hasImage {
                let cached = try JSONDecoder().decode(ArtworkCacheFixture.self, from: Data(contentsOf: file("Q300", in: directory)))
                XCTAssertEqual(cached.version, 4)
            }
        }
    }

    func testUnsupportedCacheVersionAndWrongCachedIdentityAreRefetched() async throws {
        for (version, cachedQID) in [(0, "Q300"), (1, "Q999")] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let expected = response("Q300")
            try writeCache(response(cachedQID, fileTitle: "Wrong file.jpg"), under: expected.qid,
                           version: version, fetchedAt: Date(), directory: directory)
            let requested = expectation(description: "Invalid cache triggers a request")
            let service = ArtworkStoreSpy(outcomes: [.success(expected)], held: true, requested: requested)
            let store = WorkArtworkStore(service: service, directory: directory)
            let loading = Task { await store.load(expected.qid) }
            let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
            XCTAssertEqual(started, .completed)
            XCTAssertNil(store.values[expected.qid], "An incompatible cache or another work's image must not be displayed")
            await service.release()
            await loading.value

            try assertResponse(store.values[expected.qid], equals: expected)
            let requests = await service.requests
            XCTAssertEqual(requests, [expected.qid])
        }
    }

    func testExpiredMetadataRemainsVisibleWhileRefreshingThenIsReplaced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = response("Q400", fileTitle: "Earlier poster.jpg")
        let updated = response(old.qid, fileTitle: "Updated poster.jpg")
        try writeCache(old, under: old.qid, fetchedAt: Date().addingTimeInterval(-86_400 * 8), directory: directory)
        let requested = expectation(description: "Expired cache is being refreshed")
        let service = ArtworkStoreSpy(outcomes: [.success(updated)], held: true, requested: requested)
        let store = WorkArtworkStore(service: service, directory: directory)
        let loading = Task { await store.load(old.qid) }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(started, .completed)
        try assertResponse(store.values[old.qid], equals: old)
        XCTAssertTrue(store.loading.contains(old.qid))
        await service.release()
        await loading.value

        try assertResponse(store.values[old.qid], equals: updated)
        XCTAssertFalse(store.loading.contains(old.qid))
        XCTAssertNil(store.errors[old.qid])
        let cached = try JSONDecoder().decode(ArtworkCacheFixture.self, from: Data(contentsOf: file(old.qid, in: directory)))
        try assertResponse(cached.response, equals: updated)
        XCTAssertLessThan(abs(cached.fetchedAt.timeIntervalSinceNow), 10)
    }

    func testConcurrentLoadsJoinOneInFlightMetadataRequest() async throws {
        let expected = response("Q500")
        let requested = expectation(description: "Initial fetch is suspended")
        let service = ArtworkStoreSpy(outcomes: [.success(expected)], held: true, requested: requested)
        let store = WorkArtworkStore(service: service, directory: nil)
        let first = Task { await store.load(expected.qid) }
        let started = await XCTWaiter.fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(started, .completed)
        guard started == .completed else {
            await service.release()
            await first.value
            return
        }
        XCTAssertTrue(store.loading.contains(expected.qid))
        let joined = expectation(description: "Other views join the current fetch")
        joined.expectedFulfillmentCount = 4
        let followers = (0..<4).map { _ in
            Task { @MainActor in
                joined.fulfill()
                await store.load(expected.qid)
            }
        }
        let allStarted = await XCTWaiter.fulfillment(of: [joined], timeout: 3)
        XCTAssertEqual(allStarted, .completed)
        let activeRequests = await service.requests
        XCTAssertEqual(activeRequests, [expected.qid])
        await service.release()
        await first.value
        for follower in followers { await follower.value }

        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertFalse(store.loading.contains(expected.qid))
        let completedRequests = await service.requests
        XCTAssertEqual(completedRequests, [expected.qid])
    }

    func testFailedRefreshKeepsExpiredMetadataAndDiskBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = response("Q600")
        try writeCache(expected, under: expected.qid, fetchedAt: Date().addingTimeInterval(-86_400 * 8), directory: directory)
        let cache = file(expected.qid, in: directory)
        let before = try Data(contentsOf: cache)
        let service = ArtworkStoreSpy(outcomes: [.failure])
        let store = WorkArtworkStore(service: service, directory: directory)
        await store.load(expected.qid)

        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertNotNil(store.errors[expected.qid])
        XCTAssertFalse(store.loading.contains(expected.qid))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        await store.load(expected.qid)
        let requests = await service.requests
        XCTAssertEqual(requests, [expected.qid], "Repeated view appearances must not hammer an unavailable source")
    }

    func testFailureIsNotCachedAsNoArtworkAndExplicitRetryRecovers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = response("Q700")
        let service = ArtworkStoreSpy(outcomes: [.failure, .success(expected)])
        let store = WorkArtworkStore(service: service, directory: directory)
        await store.load(expected.qid)
        XCTAssertNil(store.values[expected.qid])
        XCTAssertNotNil(store.errors[expected.qid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(expected.qid, in: directory).path))
        await store.load(expected.qid)
        let afterAutomaticLoad = await service.requests
        XCTAssertEqual(afterAutomaticLoad, [expected.qid])

        await store.load(expected.qid, retry: true)
        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertNil(store.errors[expected.qid])
        XCTAssertFalse(store.loading.contains(expected.qid))
        let afterRetry = await service.requests
        XCTAssertEqual(afterRetry, [expected.qid, expected.qid])
    }

    func testResponseForAnotherWorkCannotReplaceVerifiedMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = response("Q800")
        let unrelated = response("Q801", fileTitle: "Unrelated poster.jpg")
        let service = ArtworkStoreSpy(outcomes: [.success(expected), .success(unrelated)])
        let store = WorkArtworkStore(service: service, directory: directory)
        await store.load(expected.qid)
        let cache = file(expected.qid, in: directory)
        let before = try Data(contentsOf: cache)
        await store.load(expected.qid, retry: true)

        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertNil(store.values[unrelated.qid])
        XCTAssertNotNil(store.errors[expected.qid])
        XCTAssertFalse(store.loading.contains(expected.qid))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(unrelated.qid, in: directory).path))
    }

    func testDiskWriteFailureDoesNotDiscardFetchedMetadataOrRefetchIt() async throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let occupied = parent.appendingPathComponent("not-a-directory")
        let original = Data("existing file".utf8)
        try original.write(to: occupied)
        let expected = response("Q900")
        let service = ArtworkStoreSpy(outcomes: [.success(expected)])
        let store = WorkArtworkStore(service: service, directory: occupied)
        await store.load(expected.qid)
        await store.load(expected.qid)

        try assertResponse(store.values[expected.qid], equals: expected)
        XCTAssertNil(store.errors[expected.qid])
        XCTAssertFalse(store.loading.contains(expected.qid))
        XCTAssertEqual(try Data(contentsOf: occupied), original)
        let requests = await service.requests
        XCTAssertEqual(requests, [expected.qid])
    }

    func testInvalidIdentitiesNeverReachNetworkOrCachePaths() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ArtworkStoreSpy(outcomes: [])
        let store = WorkArtworkStore(service: service, directory: directory)
        for invalid in ["", "Q", "Q0", "Q001", "q123", "Q12/../../other", "Q１２"] {
            await store.load(invalid, retry: true)
        }
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertTrue(store.loading.isEmpty)
        XCTAssertTrue(store.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func response(_ qid: String, fileTitle: String = "Example poster.jpg") -> WorkArtworkResponse {
        WorkArtworkResponse(qid: qid, artwork: WorkArtwork(
            id: "en:" + fileTitle, fileTitle: fileTitle,
            thumbnailURL: "https://upload.wikimedia.org/wikipedia/en/example-thumb.jpg",
            sourcePageURL: "https://en.wikipedia.org/wiki/File:Example_poster.jpg",
            articleURL: "https://en.wikipedia.org/wiki/Example_Film",
            artist: "Example studio", credit: "Original theatrical poster",
            licenseName: "Fair use", licenseURL: nil, isNonFree: true,
            width: 220, height: 330, nonFreeValue: "true",
            rawMetadata: ["LicenseShortName": "Fair use"]
        ))
    }

    private func assertResponse(_ actual: WorkArtworkResponse?, equals expected: WorkArtworkResponse,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(value.qid, expected.qid, file: file, line: line)
        XCTAssertEqual(value.artwork, expected.artwork, file: file, line: line)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiArtworkStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func file(_ qid: String, in directory: URL) -> URL {
        directory.appendingPathComponent(qid + ".json")
    }

    private func writeCache(_ response: WorkArtworkResponse, under qid: String, version: Int = 1,
                            fetchedAt: Date, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = ArtworkCacheFixture(version: version, response: response, fetchedAt: fetchedAt)
        try JSONEncoder().encode(cache).write(to: file(qid, in: directory), options: .atomic)
    }
}

private struct ArtworkCacheFixture: Codable {
    let version: Int
    let response: WorkArtworkResponse
    let fetchedAt: Date
}

private actor ArtworkStoreSpy: WorkArtworkFetching {
    enum Outcome: Sendable {
        case success(WorkArtworkResponse)
        case failure
    }
    enum Failure: Error { case expected, unexpectedRequest }
    private var outcomes: [Outcome]
    private var held: Bool
    private let requested: XCTestExpectation?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [String] = []

    init(outcomes: [Outcome], held: Bool = false, requested: XCTestExpectation? = nil) {
        self.outcomes = outcomes
        self.held = held
        self.requested = requested
    }

    func fetch(qid: String) async throws -> WorkArtworkResponse {
        requests.append(qid)
        requested?.fulfill()
        guard !outcomes.isEmpty else { throw Failure.unexpectedRequest }
        let outcome = outcomes.removeFirst()
        if held { await withCheckedContinuation { waiters.append($0) } }
        switch outcome {
        case .success(let response): return response
        case .failure: throw Failure.expected
        }
    }

    func release() {
        held = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
