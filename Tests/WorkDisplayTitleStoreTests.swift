import XCTest
@testable import Pianwai

@MainActor
final class WorkDisplayTitleStoreTests: XCTestCase {
    private let qid = "Q105481082"

    func testBodyAndArticleReturnWhileTitleIsHeldThenTitlePublishesWithoutAnotherLoad() async throws {
        let context = titleContext()
        let titleStarted = expectation(description: "Title request is held")
        let loadReturned = expectation(description: "Body load returns before title")
        let service = DisplayTitleStoreSpy(contexts: [context], outcomes: [.success(titleResult())], held: true, requested: [titleStarted])
        let store = WorkContextStore(service: service, directory: nil)
        let load = Task { await store.load(qid); loadReturned.fulfill() }
        let state = await XCTWaiter.fulfillment(of: [titleStarted, loadReturned], timeout: 3)
        XCTAssertEqual(state, .completed)
        guard state == .completed else { await service.release(); await load.value; return }

        XCTAssertEqual(store.values[qid]?.introduction, context.introduction)
        XCTAssertEqual(store.values[qid]?.facts.map(\.id), context.facts.map(\.id))
        XCTAssertEqual(store.values[qid]?.article, context.article, "Background reading can immediately use the verified article")
        XCTAssertNil(store.values[qid]?.displayTitle)
        XCTAssertFalse(store.loading.contains(qid))
        XCTAssertTrue(store.displayTitleLoading.contains(qid))
        let flags = await service.includeTitleFlags
        XCTAssertEqual(flags, [false])

        await service.release()
        await store.loadDisplayTitle(qid)
        await load.value
        XCTAssertEqual(store.values[qid]?.displayTitle, "偶然与想像")
        XCTAssertEqual(store.values[qid]?.displayTitleState, .available)
        XCTAssertFalse(store.displayTitleLoading.contains(qid))
        let bodyRequests = await service.bodyRequests
        XCTAssertEqual(bodyRequests, [qid], "Finishing the scheduled title must not require a new page load")
    }

    func testFailedRefreshKeepsSameRevisionTitleAndCanRetryOnlyTheTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = titleContext()
        let service = DisplayTitleStoreSpy(contexts: [context, context], outcomes: [.success(titleResult()), .failure, .success(titleResult("已恢复的标题"))])
        let store = WorkContextStore(service: service, directory: directory)
        await store.load(qid)
        await store.loadDisplayTitle(qid)
        let source = store.values[qid]?.displayTitleSource
        await store.load(qid, retry: true)
        await store.loadDisplayTitle(qid)

        XCTAssertEqual(store.values[qid]?.displayTitle, "偶然与想像")
        XCTAssertEqual(store.values[qid]?.displayTitleSource, source)
        XCTAssertEqual(store.values[qid]?.displayTitleState, .failed)
        XCTAssertEqual(store.values[qid]?.introduction, context.introduction)
        XCTAssertNil(store.errors[qid], "An optional title failure does not become a body error")
        let disk = try JSONDecoder().decode(WorkContext.self, from: Data(contentsOf: directory.appendingPathComponent(qid + ".json")))
        XCTAssertEqual(disk.displayTitleState, .failed, "The disk cache must retain retryable failure rather than a successful absence")
        XCTAssertEqual(disk.displayTitleSource, source)

        await store.load(qid)
        let heldBackRequests = await service.titleRequests
        XCTAssertEqual(heldBackRequests.count, 2, "A view update during the short cooldown must not retry in a loop")
        await store.loadDisplayTitle(qid, retry: true)
        XCTAssertEqual(store.values[qid]?.displayTitle, "已恢复的标题")
        XCTAssertEqual(store.values[qid]?.displayTitleState, .available)
        let bodyRequests = await service.bodyRequests
        let titleRequests = await service.titleRequests
        XCTAssertEqual(bodyRequests.count, 2, "Title retry must not redownload the introduction")
        XCTAssertEqual(titleRequests.count, 3)
    }

    func testFreshBodyCacheRetriesFailedOrLegacyUnknownTitlesButKeepsDefiniteAbsence() async throws {
        for previousState: WorkDisplayTitleState? in [.failed, nil, .absent] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var cached = titleContext()
            cached.displayTitleState = previousState
            cached.displayTitleAttemptedAt = Date(timeIntervalSinceNow: -31)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent(qid + ".json"))
            let shouldRequest = previousState != .absent
            let service = DisplayTitleStoreSpy(contexts: [], outcomes: shouldRequest ? [.success(titleResult())] : [])
            let store = WorkContextStore(service: service, directory: directory)
            await store.load(qid)
            await store.loadDisplayTitle(qid)
            let bodyRequests = await service.bodyRequests
            let titleRequests = await service.titleRequests
            XCTAssertTrue(bodyRequests.isEmpty, "A title failure does not invalidate a fresh body")
            XCTAssertEqual(titleRequests.count, shouldRequest ? 1 : 0)
            XCTAssertEqual(store.values[qid]?.displayTitleState, shouldRequest ? .available : .absent)
        }
    }

    func testNewArticleRevisionDoesNotBorrowTheOldTitleWhenItsLookupFails() async throws {
        let first = titleContext(revision: 101)
        let next = titleContext(revision: 202)
        let service = DisplayTitleStoreSpy(contexts: [first, next], outcomes: [.success(titleResult(revision: 101)), .failure])
        let store = WorkContextStore(service: service, directory: nil)
        await store.load(qid)
        await store.loadDisplayTitle(qid)
        XCTAssertNotNil(store.values[qid]?.displayTitle)
        await service.hold()
        await store.load(qid, retry: true)
        XCTAssertEqual(store.values[qid]?.article?.revision, 202)
        XCTAssertNil(store.values[qid]?.displayTitle)
        XCTAssertNil(store.values[qid]?.displayTitleSource)
        await service.release()
        await store.loadDisplayTitle(qid)
        XCTAssertNil(store.values[qid]?.displayTitle)
        XCTAssertNil(store.values[qid]?.displayTitleSource)
        XCTAssertEqual(store.values[qid]?.displayTitleState, .failed)
    }

    func testLateOldRevisionResponseCannotOverwriteTheNewArticleTitle() async throws {
        let firstRequested = expectation(description: "Old revision title is held")
        let secondRequested = expectation(description: "New revision title is held")
        let joined = expectation(description: "A caller joins the old title task")
        let service = DisplayTitleStoreSpy(contexts: [titleContext(revision: 101), titleContext(revision: 202)],
            outcomes: [.success(titleResult("旧版本标题", revision: 101)), .success(titleResult("新版本标题", revision: 202))],
            held: true, requested: [firstRequested, secondRequested])
        let store = WorkContextStore(service: service, directory: nil)
        await store.load(qid)
        let oldWaiter = Task { joined.fulfill(); await store.loadDisplayTitle(qid) }
        let firstState = await XCTWaiter.fulfillment(of: [firstRequested, joined], timeout: 3)
        XCTAssertEqual(firstState, .completed)
        guard firstState == .completed else { await service.release(); await oldWaiter.value; return }
        await store.load(qid, retry: true)
        let state = await XCTWaiter.fulfillment(of: [secondRequested], timeout: 3)
        XCTAssertEqual(state, .completed)
        XCTAssertNil(store.values[qid]?.displayTitle)
        await service.release()
        await store.loadDisplayTitle(qid)
        await oldWaiter.value
        XCTAssertEqual(store.values[qid]?.article?.revision, 202)
        XCTAssertEqual(store.values[qid]?.displayTitle, "新版本标题")
        XCTAssertEqual(store.values[qid]?.displayTitleSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=202&variant=zh-cn")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiDisplayTitle-" + UUID().uuidString, isDirectory: true)
    }

    private func titleContext(revision: Int = 92804669) -> WorkContext {
        var context = WorkContext(qid: qid)
        context.article = WikiArticleIdentity(qid: qid, title: "偶然與想像", language: "zh", pageID: 7606247, revision: revision)
        context.introduction = "一部由三个短篇故事组成的电影。"
        context.language = "zh"
        context.introductionSource = Source(title: "维基百科 · 偶然與想像", detail: "导语摘录", url: "https://zh.wikipedia.org/w/index.php?oldid=\(revision)")
        context.facts = [.init(label: "发行年份", value: "2021", source: context.introductionSource!)]
        return context
    }

    private func titleResult(_ title: String = "偶然与想像", revision: Int = 92804669) -> WorkDisplayTitle {
        WorkDisplayTitle(title: title, source: Source(title: "维基百科 · 偶然與想像", detail: "中文显示名",
            url: "https://zh.wikipedia.org/w/index.php?oldid=\(revision)&variant=zh-cn"))
    }
}

private actor DisplayTitleStoreSpy: WorkContextFetching {
    enum Outcome: Sendable { case success(WorkDisplayTitle?), failure }
    enum Failure: Error { case expected, unexpectedRequest }
    private var contexts: [WorkContext]
    private var outcomes: [Outcome]
    private var held: Bool
    private var requested: [XCTestExpectation]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var bodyRequests: [String] = []
    private(set) var includeTitleFlags: [Bool] = []
    private(set) var titleRequests: [WikiArticleIdentity] = []

    init(contexts: [WorkContext], outcomes: [Outcome], held: Bool = false, requested: [XCTestExpectation] = []) {
        self.contexts = contexts; self.outcomes = outcomes; self.held = held; self.requested = requested
    }

    func fetch(qid: String, includeDisplayTitle: Bool) async throws -> WorkContext {
        bodyRequests.append(qid); includeTitleFlags.append(includeDisplayTitle)
        guard !includeDisplayTitle, !contexts.isEmpty else { throw Failure.unexpectedRequest }
        return contexts.removeFirst()
    }

    func fetchDisplayTitle(article: WikiArticleIdentity) async throws -> WorkDisplayTitle? {
        titleRequests.append(article)
        if !requested.isEmpty { requested.removeFirst().fulfill() }
        guard !outcomes.isEmpty else { throw Failure.unexpectedRequest }
        let outcome = outcomes.removeFirst()
        if held { await withCheckedContinuation { waiters.append($0) } }
        switch outcome {
        case .success(let result): return result
        case .failure: throw Failure.expected
        }
    }

    func hold() { held = true }
    func release() {
        held = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
