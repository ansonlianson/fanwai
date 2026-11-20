import XCTest
@testable import Pianwai

@MainActor final class FlashStoryPublicationTests: XCTestCase {
    func testReviewResearchesKnownDemoSongsInsteadOfSilentlyUsingTheirBundledStory() throws {
        guard FlashReviewAccess.isEnabled else { return }
        let suite = "P35.SeedGate." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, arguments: [], catalog: CatalogStore(cacheURL: nil))
        XCTAssertFalse(FlashReviewAccess.usesBundledContent("jane"))
        XCTAssertNotNil(LeadResearch().subject("jane", library: library))
        XCTAssertNotNil(LeadResearch().subject("pool", library: library))
    }

    func testUnknownMusicCreatorDoesNotGuessAnUnrelatedSameNameRecording() async throws {
        guard FlashReviewAccess.isEnabled else { return }
        let token = UUID().uuidString
        let suite = "P35.UnknownCreator." + token
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = WorkID(rawValue: "local:p35-unknown-" + token)!
        let subject = LeadSubject(id: root.rawValue, kind: .song, title: token, creator: "Fixture", album: "")
        let service = HeldPublicationCatalog()
        await service.release()
        let catalog = CatalogStore(cacheURL: nil, service: service)
        try catalog.merge(.init(works: [Work(id: root, title: token, creator: "Fixture", kind: "歌曲", art: "", detail: "", url: nil)], relations: []))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let raw = LeadResearchClient.Raw(leads: [.init(name: "Reze", zh: "", en: "", kind: "song", label: "候选主题曲", why: "同一项目的另一首候选。", url: "https://example.com/source", creator: "", wiki: "")], story: nil)
        let research = LeadResearch(researchOperation: { _ in raw })
        await research.load(subject, library: library, force: true)
        let queried = await service.hasStarted()
        XCTAssertFalse(queried)
        XCTAssertEqual(research.leads(root.rawValue).first?.id, "lead:song:reze")
        if let folder = PianwaiRuntime.applicationDirectory("Leads") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(FlashReviewAccess.cacheNamespace + "-" + subject.cacheKey + ".json"))
        }
        if let folder = PianwaiRuntime.applicationDirectory("FlashReviewDiagnostics") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(subject.cacheKey + "-ready.json"))
        }
    }

    func testStoryAndUnresolvedNameAppearBeforeCatalogThenGainAnEntityLink() async throws {
        let token = UUID().uuidString
        let suite = "P35.StoryPublication." + token
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = WorkID(rawValue: "local:p35-publication-" + token)!
        let subject = LeadSubject(id: root.rawValue, kind: .song, title: "Publication " + token,
                                  creator: "Fixture Composer、Another Artist", album: "")
        defer {
            defaults.removePersistentDomain(forName: suite)
            let prefix = FlashReviewAccess.isEnabled ? FlashReviewAccess.cacheNamespace + "-" : "v3-"
            if let cache = PianwaiRuntime.applicationDirectory("Leads") {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent(prefix + subject.cacheKey + ".json"))
            }
            if let diagnostics = PianwaiRuntime.applicationDirectory("FlashReviewDiagnostics") {
                for phase in ["story", "ready"] {
                    try? FileManager.default.removeItem(at: diagnostics.appendingPathComponent(subject.cacheKey + "-" + phase + ".json"))
                }
            }
        }
        let service = HeldPublicationCatalog()
        let catalog = CatalogStore(cacheURL: nil, service: service)
        try catalog.merge(.init(works: [
            Work(id: root, title: subject.title, creator: subject.creator, kind: "歌曲", art: "", detail: "", url: nil)
        ], relations: []))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let body = "Fixture Composer制作这首曲子时，先把关联曲作为编曲参照，再根据画面的节奏调整旋律和乐器配置。这段有来源的文字已经可以阅读，不应等待另一条目录或图片请求完成。"
        let raw = LeadResearchClient.Raw(leads: [
            .init(name: "Linked Song", zh: "关联曲", en: "Linked Song", kind: "song", label: "创作参照",
                  why: "创作者把它作为编曲参照。", url: "https://example.com/publication", creator: "Fixture Composer", wiki: "")
        ], story: .init(text: body, subject: "song", url: "https://example.com/publication", source: "离线测试",
                       additionalSources: [.init(title: "补充原文", url: "https://example.com/additional")]))
        let research = LeadResearch(researchOperation: { _ in raw })
        let loading = Task { await research.load(subject, library: library, force: true) }

        // The held service cannot finish early, so this observes the actual
        // publication boundary instead of relying on arbitrary sleep timing.
        let deadline = Date().addingTimeInterval(2)
        var lookupStarted = false
        while Date() < deadline {
            if await service.hasStarted() { lookupStarted = true; break }
            await Task.yield()
        }
        if !lookupStarted {
            await service.release()
            await loading.value
            XCTFail("The injected catalog lookup did not begin")
            return
        }
        XCTAssertEqual(research.state(subject.id), .loading)
        XCTAssertTrue(research.leads(subject.id).isEmpty)
        let early = research.story(for: subject.id)
        XCTAssertEqual(early?.body, body, "Research text must appear before cover/identity matching")
        XCTAssertEqual(early?.additionalSources?.first?.url, "https://example.com/additional")
        if let early {
            XCTAssertTrue(early.mentions?.contains("关联曲") == true)
            XCTAssertTrue(early.mentions?.contains("Fixture Composer") == true)
            XCTAssertTrue(early.mentions?.contains("Another Artist") == true)
            XCTAssertNotNil(StoryTextLinks(story: early).targets.first { $0.name == "Fixture Composer" })
            let target = StoryTextLinks(story: early).targets.first { $0.name == "关联曲" }
            XCTAssertNotNil(target, "An unresolved literal name must already offer the existing explicit lookup")
            XCTAssertNil(target?.entityID, "A pending name must not invent a catalog identity")
        }

        await service.release()
        await loading.value
        XCTAssertEqual(research.state(subject.id), .ready)
        XCTAssertEqual(research.leads(subject.id).count, 1)
        let ready = try XCTUnwrap(research.story(for: subject.id))
        XCTAssertEqual(ready.body, body, "Adding covers/identities must not replace the readable story")
        XCTAssertEqual(ready.additionalSources?.first?.url, "https://example.com/additional")
        XCTAssertNotNil(StoryTextLinks(story: ready).targets.first { $0.name == "关联曲" }?.entityID)
    }
}

private actor HeldPublicationCatalog: CatalogFetching {
    private var started = false
    private var released = false
    private var pending: CheckedContinuation<CatalogResponse, Never>?
    private let empty = CatalogResponse(results: [], snapshot: .init(works: [], relations: []))

    func hasStarted() -> Bool { started }
    func release() {
        released = true
        pending?.resume(returning: empty)
        pending = nil
    }
    func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext?) async throws -> CatalogResponse {
        started = true
        if released { return empty }
        return await withCheckedContinuation { pending = $0 }
    }
    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind?) async throws -> CatalogResponse {
        throw CatalogError.invalidData
    }
}
