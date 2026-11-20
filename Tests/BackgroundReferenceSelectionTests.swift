import XCTest
@testable import Pianwai

@MainActor final class BackgroundReferenceSelectionTests: XCTestCase {
    func testVoiceCandidatesSkipShownComposerAndCompanyBeforeTakingThreeNewDestinations() async {
        let names = ["牛尾憲輔", "波麗佳音", "Aiko", "何許人合唱團", "My Generation (歌曲)"]
        let resolver = ReferenceResolverStub(answers: [
            names[0]: [.value("Q11190062")], names[1]: [.value(nil)], names[2]: [.value("Q284066")],
            names[3]: [.value("Q93346")], names[4]: [.value("Q8353114")]
        ])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        await selection.load(self.request(names, excluding: ["Q23925035", "Q11190062"]))
        XCTAssertEqual(selection.references.map(\.qid), ["Q284066", "Q93346", "Q8353114"])
        XCTAssertEqual(selection.references.map(\.article.title), Array(names.suffix(3)))
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls, names, "A company must not consume a visible destination")
    }

    func testExactIdentityDeduplicationDoesNotMergeDifferentWorksWithTheSameLabel() async {
        let candidates = [self.ref("current"), self.ref("alias one", label: "Same name"), self.ref("alias two"),
                          self.ref("other work", label: "Same name"), self.ref("last")]
        let resolver = ReferenceResolverStub(answers: [
            "current": [.value("Q10")], "alias one": [.value("Q20")], "alias two": [.value("Q20")],
            "other work": [.value("Q30")], "last": [.value("Q40")]
        ])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        await selection.load(.init(sourceID: "paragraph", candidates: candidates, excludedQIDs: ["Q10"]))
        XCTAssertEqual(selection.references.map(\.qid), ["Q20", "Q30", "Q40"])
        XCTAssertEqual(selection.references.prefix(2).map(\.article.label), ["Same name", "Same name"])
    }

    func testAtMostEightCandidatesAndThreeVerifiedDestinationsAreProcessed() async {
        let names = (1...9).map { "article-\($0)" }
        let resolver = ReferenceResolverStub(answers: Dictionary(uniqueKeysWithValues:
            names.map { ($0, [ReferenceResolverStub.Answer.value($0 == names[8] ? "Q99" : nil)]) }))
        let selection = BackgroundReferenceSelection(resolver: resolver)
        await selection.load(self.request(names))
        XCTAssertTrue(selection.references.isEmpty)
        let limitedCalls = await resolver.calls
        XCTAssertEqual(limitedCalls, Array(names.prefix(8)))

        let allCreative = ReferenceResolverStub(answers: Dictionary(uniqueKeysWithValues:
            names.enumerated().map { ($0.element, [ReferenceResolverStub.Answer.value("Q\($0.offset + 1)")]) }))
        let three = BackgroundReferenceSelection(resolver: allCreative)
        await three.load(self.request(names))
        XCTAssertEqual(three.references.count, 3)
        let calls = await allCreative.calls
        XCTAssertEqual(calls, Array(names.prefix(3)), "Stop transport once the visible slots are filled")
    }

    func testPartialFailureCanBeRetriedWithoutDuplicatesAndRestoresSourceOrder() async {
        let resolver = ReferenceResolverStub(answers: [
            "first": [.failure, .value("Q10")], "second": [.value("Q20"), .value("Q20")],
            "third": [.value("Q30"), .value("Q30")], "fourth": [.value("Q40")]
        ])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        let input = self.request(["first", "second", "second", "third", "fourth"])
        await selection.load(input)
        XCTAssertEqual(selection.references.map(\.qid), ["Q20", "Q30", "Q40"])
        XCTAssertTrue(selection.hasFailures)
        XCTAssertFalse(selection.isLoading)
        await selection.load(input)
        XCTAssertEqual(selection.references.map(\.qid), ["Q10", "Q20", "Q30"])
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls.filter { $0 == "second" }.count, 2, "Repeated article anchors resolve only once per attempt")
    }

    func testOlderExcerptPayloadWithoutReferencesRemainsReadable() async throws {
        let data = Data(#"{"id":"old","heading":"制作","body":"旧段落。","sourceParagraph":"旧段落。","source":{"title":"维基百科","detail":"章节摘录","url":"https://example.com"},"language":"zh"}"#.utf8)
        let excerpt = try JSONDecoder().decode(WorkBackgroundExcerpt.self, from: data)
        XCTAssertNil(excerpt.references)
        let resolver = ReferenceResolverStub(answers: [:])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        await selection.load(.init(sourceID: excerpt.id, candidates: excerpt.references ?? [], excludedQIDs: []))
        XCTAssertTrue(selection.references.isEmpty)
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPreviousSourceCannotPublishLateSuccessOrFailureIntoTheNewCard() async {
        for answer in [ReferenceResolverStub.Answer.value("Q10"), .failure] {
            let resolver = ReferenceResolverStub(answers: ["new": [.value("Q20")]], held: ["old"])
            let selection = BackgroundReferenceSelection(resolver: resolver)
            let old = Task { await selection.load(self.request(["old"], source: "old-source")) }
            await resolver.waitForCall("old")
            await selection.load(self.request(["new"], source: "new-source"))
            await resolver.release("old", with: answer)
            await old.value
            XCTAssertEqual(selection.references.map(\.qid), ["Q20"])
            XCTAssertFalse(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
        }
    }

    func testDisappearingCardIgnoresAResolverThatFinishesAfterCancellation() async {
        let resolver = ReferenceResolverStub(answers: [:], held: ["old"])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        let task = Task { await selection.load(self.request(["old"])) }
        await resolver.waitForCall("old")
        task.cancel()
        selection.cancel()
        await resolver.release("old", with: .value("Q10"))
        await task.value
        XCTAssertTrue(selection.references.isEmpty)
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.hasFailures)
    }

    func testLateOpenCannotReplaceANewerSelectionOrItsState() async {
        let resolver = ReferenceResolverStub(answers: [:], held: ["old"])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        var navigated: [WorkID] = []
        let old = Task {
            await selection.open(self.resolved("old", qid: "Q10"), load: { _ in
                _ = try await resolver.resolveCreative(self.ref("old"))
                return .pool
            }, isCurrent: { true }, navigate: { navigated.append($0) })
        }
        await resolver.waitForCall("old")
        await selection.open(self.resolved("new", qid: "Q20"), load: { _ in .jane },
                             isCurrent: { true }, navigate: { navigated.append($0) })
        await resolver.release("old", with: .failure)
        await old.value
        XCTAssertEqual(navigated, [.jane])
        XCTAssertNil(selection.openingID)
        XCTAssertNil(selection.openingError, "An old failure must not overwrite the latest successful selection")
    }

    func testNavigationChangeAndCancellationPreventTakingThePageBack() async {
        for cancel in [false, true] {
            let resolver = ReferenceResolverStub(answers: [:], held: ["old"])
            let selection = BackgroundReferenceSelection(resolver: resolver)
            var stillAtOrigin = true
            var navigated: [WorkID] = []
            let task = Task {
                await selection.open(self.resolved("old", qid: "Q10"), load: { _ in
                    _ = try await resolver.resolveCreative(self.ref("old"))
                    return .pool
                }, isCurrent: { stillAtOrigin }, navigate: { navigated.append($0) })
            }
            await resolver.waitForCall("old")
            if cancel { task.cancel(); selection.cancel() }
            else { stillAtOrigin = false }
            await resolver.release("old", with: .value("Q10"))
            await task.value
            XCTAssertTrue(navigated.isEmpty)
            XCTAssertNil(selection.openingID)
            XCTAssertNil(selection.openingError)
        }
    }

    func testOpenFailureCanBeRetriedFromTheSamePage() async {
        let selection = BackgroundReferenceSelection(resolver: ReferenceResolverStub(answers: [:]))
        let reference = self.resolved("work", qid: "Q10")
        var navigated: [WorkID] = []
        await selection.open(reference, load: { _ in throw ReferenceStubFailure.offline },
                             isCurrent: { true }, navigate: { navigated.append($0) })
        XCTAssertNotNil(selection.openingError)
        XCTAssertTrue(navigated.isEmpty)
        await selection.open(reference, load: { _ in .pool }, isCurrent: { true }, navigate: { navigated.append($0) })
        XCTAssertEqual(navigated, [.pool])
        XCTAssertNil(selection.openingError)
    }

    func testEnrichingDisplayedNeighborsDoesNotCancelAnExplicitOpenFromTheSameSource() async {
        let resolver = ReferenceResolverStub(answers: [:], held: ["opening"])
        let selection = BackgroundReferenceSelection(resolver: resolver)
        await selection.load(self.request([]))
        var navigated: [WorkID] = []
        let task = Task {
            await selection.open(self.resolved("opening", qid: "Q10"), load: { _ in
                _ = try await resolver.resolveCreative(self.ref("opening"))
                return .pool
            }, isCurrent: { true }, navigate: { navigated.append($0) })
        }
        await resolver.waitForCall("opening")
        await selection.load(self.request([], excluding: ["Q10"]))
        await resolver.release("opening", with: .value("Q10"))
        await task.value
        XCTAssertEqual(navigated, [.pool])
    }

    private func ref(_ title: String, label: String? = nil) -> WikiArticleReference {
        .init(label: label ?? title, title: title, language: "zh")
    }
    private func resolved(_ title: String, qid: String) -> ResolvedBackgroundReference {
        .init(article: self.ref(title), qid: qid)
    }
    private func request(_ names: [String], excluding qids: Set<String> = [], source: String = "paragraph") -> BackgroundReferenceRequest {
        .init(sourceID: source, candidates: names.map { self.ref($0) }, excludedQIDs: qids)
    }
}

private enum ReferenceStubFailure: Error { case offline }

/// Intentionally ignores cancellation while held, so tests prove the consumer's
/// request identity checks rather than merely relying on a cooperative network.
private actor ReferenceResolverStub: BackgroundReferenceResolving {
    enum Answer: Sendable { case value(String?), failure }
    private var answers: [String: [Answer]]
    private var held: Set<String>
    private var pending: [String: CheckedContinuation<Answer, Never>] = [:]
    private var started: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls: [String] = []

    init(answers: [String: [Answer]], held: Set<String> = []) { self.answers = answers; self.held = held }

    func resolveCreative(_ reference: WikiArticleReference) async throws -> String? {
        let title = reference.title
        calls.append(title)
        for continuation in started.removeValue(forKey: title) ?? [] { continuation.resume() }
        let answer: Answer
        if held.contains(title) { answer = await withCheckedContinuation { pending[title] = $0 } }
        else if var sequence = answers[title], !sequence.isEmpty {
            answer = sequence.removeFirst(); answers[title] = sequence
        } else { answer = .value(nil) }
        switch answer {
        case .value(let qid): return qid
        case .failure: throw ReferenceStubFailure.offline
        }
    }

    func waitForCall(_ title: String) async {
        if calls.contains(title) { return }
        await withCheckedContinuation { started[title, default: []].append($0) }
    }

    func release(_ title: String, with answer: Answer) {
        held.remove(title)
        pending.removeValue(forKey: title)?.resume(returning: answer)
    }
}
