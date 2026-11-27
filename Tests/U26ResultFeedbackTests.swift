import XCTest
@testable import Pianwai

@MainActor final class U26ResultFeedbackTests: XCTestCase {
    private func fixture(large: Bool = false) throws -> (ResultFeedbackSnapshot, Library, DiscoveryJobs) {
        let suite = "U26-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let root = WorkID(rawValue: "local:u26-song")!, target = WorkID(rawValue: "local:u26-film")!
        let song = Work(id: root, title: "打开时的歌曲", creator: "测试艺人", kind: "歌曲", art: "https://example.org/cover.jpg", detail: "", url: "https://example.org/song?id=1&token=private")
        let film = Work(id: target, title: "关联作品", creator: "测试导演", kind: "电影", art: "", detail: "", url: nil)
        let source = Source(title: "已核对来源", url: "https://example.org/source", evidenceQuote: String(repeating: "证据", count: large ? 1000 : 2))
        try catalog.merge(.init(works: [song, film], relations: [.init(from: root, to: target, predicate: .soundtrackOf, label: "配乐出自", inverseLabel: "音乐", source: source)]))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let jobs = DiscoveryJobs(directory: nil)
        let research = LeadResearch(researchOperation: { _ in .init(leads: [], story: nil) }, evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: jobs)
        let subject = LeadSubject(id: "original-page-id", kind: .song, title: song.title, creator: song.creator, album: "")
        jobs.start(subject, userInitiated: true)
        let story = Story(id: "frozen-story", entityID: root.rawValue, title: "", body: "用户当时读到的故事", source: source)
        var item = CrateItem(entity: SeedLibraryBridge.entity(for: target, in: library), relation: "配乐出自", path: [root.rawValue, target.rawValue])
        item.note = String(repeating: "关联的说明", count: large ? 300 : 1)
        let snapshot = ResultFeedbackSnapshot.capture(entity: SeedLibraryBridge.entity(for: root, in: library), library: library,
            story: .init(story: story, scope: "歌曲", subject: nil, allowsRoot: true), items: Array(repeating: item, count: large ? 80 : 1),
            visibleIDs: [target.rawValue], research: research, readingPinned: true, lookupID: subject.id)
        return (snapshot, library, jobs)
    }

    func testOpeningFreezesResultAndUsesOriginalPageJob() throws {
        let (snapshot, library, jobs) = try fixture()
        let root = WorkID(rawValue: snapshot.subject.id)!
        let updated = Work(id: root, title: "晚到的新标题", creator: "测试艺人", kind: "歌曲", art: "", detail: "", url: nil)
        try library.catalog.merge(.init(works: [updated], relations: []))
        jobs.fail("original-page-id")
        XCTAssertEqual(snapshot.subject.title, "打开时的歌曲")
        XCTAssertEqual(snapshot.story?.body, "用户当时读到的故事")
        XCTAssertEqual(snapshot.page.state, "loading")
        XCTAssertTrue(snapshot.page.readingPinned)
        XCTAssertEqual(snapshot.cards.first?.sources.first?.quote, "证据证据")
        XCTAssertEqual(snapshot.cards.first?.path, ["local:u26-song", "local:u26-film"])
        XCTAssertEqual(snapshot.app.processorVersion, "")
        XCTAssertEqual(snapshot.subject.sourceURL, "https://example.org/song?id=1")
    }

    func testOfflineSubmissionSurvivesRelaunchAndRetriesSameUUID() async throws {
        let (snapshot, _, _) = try fixture(), draft = ResultFeedbackDraft(snapshot: snapshot)
        let directory = try directory(), backend = U26FeedbackSender()
        let first = ResultFeedbackOutbox(directory: directory) { try await backend.send($0) }
        let outcome = try await first.submit(draft, reasons: [.relation], note: "原作不对")
        XCTAssertEqual(outcome, .queued); XCTAssertEqual(first.pendingCount, 1)
        let relaunched = ResultFeedbackOutbox(directory: directory) { try await backend.send($0) }
        XCTAssertEqual(relaunched.pendingCount, 1)
        await backend.connect()
        await relaunched.flush()
        XCTAssertEqual(relaunched.pendingCount, 0)
        let ids = await backend.ids
        XCTAssertEqual(ids, [draft.id, draft.id])
        let durable = ResultFeedbackOutbox(directory: directory) { try await backend.send($0) }
        XCTAssertEqual(durable.pendingCount, 0)
    }

    func testConcurrentSubmitAndFlushSendOneRequest() async throws {
        let (snapshot, _, _) = try fixture(), draft = ResultFeedbackDraft(snapshot: snapshot), backend = U26FeedbackSender()
        await backend.connect()
        let outbox = ResultFeedbackOutbox(directory: try directory()) { try await backend.send($0) }
        async let first = outbox.submit(draft, reasons: [], note: "")
        async let second = outbox.submit(draft, reasons: [], note: "")
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes, [.sent(draft.id), .sent(draft.id)])
        let count = await backend.ids.count
        XCTAssertEqual(count, 1); XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testUnreadableStorageDoesNotDiscardPendingData() async throws {
        let dir = try directory(), file = dir.appendingPathComponent("outbox.json"), bytes = Data("unreadable pending data".utf8)
        try bytes.write(to: file)
        let outbox = ResultFeedbackOutbox(directory: dir) { _ in XCTFail("should not send"); throw URLError(.badServerResponse) }
        let (snapshot, _, _) = try fixture()
        do { _ = try await outbox.submit(.init(snapshot: snapshot), reasons: [], note: ""); XCTFail("unreadable file overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLongResultIsBoundedAndMarkedWithoutLosingStory() throws {
        let (snapshot, _, _) = try fixture(large: true)
        let bounded = snapshot.boundedForDelivery()
        XCTAssertTrue(bounded.contentTruncated)
        XCTAssertEqual(bounded.story?.body, snapshot.story?.body)
        let payload = ResultFeedbackSubmission(id: UUID(), installationID: UUID(), reasons: [.artwork], note: String(repeating: "字", count: 500), submittedAt: Date(), snapshot: bounded)
        let data = try ResultFeedbackOutbox.encoder().encode(payload)
        XCTAssertLessThan(data.count, 128 * 1024)
        let decoded = try ResultFeedbackOutbox.decoder().decode(ResultFeedbackSubmission.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.snapshot.cards.count, bounded.cards.count)
    }

    func testPrivacyRemovesCredentialsAndUnsafeLinks() {
        let raw = "sk-notrealkey123456 Bearer test-fixtureCredential1234 user@example.org fw_testfixture123456"
        let safe = ResultFeedbackPrivacy.text(raw, limit: 500)
        for value in ["notrealkey123456", "test-fixtureCredential1234", "user@example.org", "fw_testfixture123456"] { XCTAssertFalse(safe.contains(value)) }
        XCTAssertEqual(ResultFeedbackPrivacy.url("https://name:password@example.org/page?id=1&api_key=secret#private"), "https://example.org/page?id=1")
        XCTAssertEqual(ResultFeedbackPrivacy.url("file:///private/secret"), "")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("U26-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
private actor U26FeedbackSender {
    var ids: [UUID] = []
    var connected = false
    func connect() { connected = true }
    func send(_ payload: ResultFeedbackSubmission) async throws -> ResultFeedbackOutbox.Receipt {
        ids.append(payload.id)
        try await Task.sleep(for: .milliseconds(40))
        guard connected else { throw URLError(.notConnectedToInternet) }
        return .init(id: payload.id, received: true)
    }
}
