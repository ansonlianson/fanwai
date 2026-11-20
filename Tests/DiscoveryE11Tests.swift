import XCTest
import UIKit
@testable import Pianwai

@MainActor final class DiscoveryE11Tests: XCTestCase {
    func testEveryVisibleKindHasItsOwnBundledObjectAndCoverGeometry() throws {
        for kind in SeedGraph.Kind.allCases {
            let object = ShopStyle.objectKind(kind)
            let tile = try XCTUnwrap(ShopPlates.shared.tile(object), kind.rawValue)
            XCTAssertEqual(tile.item?.quad.count, 4, kind.rawValue)
        }
        XCTAssertEqual(ShopStyle.objectKind(.game), "game")
        XCTAssertEqual(ShopStyle.objectKind(.video), "video")
        XCTAssertEqual(ShopStyle.objectKind(.film), "bd")
        for kind in ["game", "video"] { XCTAssertTrue((0.72...0.85).contains(ShopSprite.aspect(kind))) }
    }
    func testPickerCandidateCoverIsSharedAndDurableWithoutCreatingAPerformanceFact() async throws {
        let folder = temporary("versions"); defer { try? FileManager.default.removeItem(at: folder) }
        let source = musicWork(), recording = version()
        let service = VersionsService(recording: recording)
        let library = try library(service: service, works: [source])
        let store = RecordingVersionsStore(directory: folder)
        await store.load(source, library: library)
        XCTAssertEqual(store.versions(for: source, library: library).candidates, [recording.id])
        XCTAssertEqual(WorkArtworkStore.shared.metadata(for: source)?.thumbnailURL, recording.art)
        XCTAssertEqual(WorkArtworkStore.shared.metadata(for: source)?.rawMetadata?["recordingID"], recording.id.rawValue)
        XCTAssertTrue(library.catalog.work(source.id).art.isEmpty)
        XCTAssertNotEqual(library.catalog.canonicalID(for: source.id), library.catalog.canonicalID(for: recording.id))
        XCTAssertFalse(library.catalog.edges.contains { $0.predicate == .performanceOf })

        let offline = VersionsService(recording: recording, offline: true)
        let reopened = try self.library(service: offline, works: [source])
        let restored = RecordingVersionsStore(directory: folder)
        restored.restore(source, library: reopened)
        await restored.load(source, library: reopened)
        XCTAssertEqual(restored.versions(for: source, library: reopened).candidates, [recording.id])
        let calls = await offline.calls; XCTAssertEqual(calls, 0)
    }

    func testRepresentativeCoverRequiresMatchingCreditsAndRejectsDerivedOrGameIdentity() {
        let source = musicWork()
        XCTAssertTrue(RecordingVersionsStore.qualifiesAsRepresentative(version(), source: source))
        let wrong = version(creator: "Unrelated performer")
        XCTAssertFalse(RecordingVersionsStore.qualifiesAsRepresentative(wrong, source: source))
        let live = version(title: "召喚獣の祠 (Live)")
        XCTAssertFalse(RecordingVersionsStore.qualifiesAsRepresentative(live, source: source))
        let game = Work(id: source.id, title: source.title, creator: source.creator, kind: "游戏", art: "", detail: "", url: nil,
            discovery: .init(layer: .game, canonicalTitle: source.title))
        XCTAssertFalse(RecordingVersionsStore.qualifiesAsRepresentative(version(), source: game))
    }

    func testExactOfficialRegistrationSuppliesFilmImageWithoutTitleSearch() async throws {
        let work = Work(id: WorkID(rawValue: "test:e11-film")!, title: "漂流家园", creator: "", kind: "电影", art: "", detail: "", url: nil,
            knowledgeID: "Q109602795", discovery: .init(layer: .film, canonicalTitle: "雨を告げる漂流団地"))
        let service = OfficialWorkArtwork(loader: { request in
            let url = try XCTUnwrap(request.url)
            let text: String
            if url.host == "www.wikidata.org" {
                text = #"{"entities":{"Q109602795":{"id":"Q109602795","type":"item","claims":{"P856":[{"rank":"normal","mainsnak":{"property":"P856","snaktype":"value","datatype":"url","datavalue":{"value":"https://www.hyoryu-danchi.com/"}}}]}}}}"#
            } else if url.path == "/robots.txt" { text = "User-agent: *\nAllow: /\n" }
            else { text = #"<html><title>映画「雨を告げる漂流団地」公式サイト</title><meta property="og:image" content="https://www.hyoryu-danchi.com/share02.jpg"></html>"# }
            return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": url.path == "/robots.txt" ? "text/plain" : "text/html"])!)
        })
        let fetched = try await service.fetch(work)
        let image = try XCTUnwrap(fetched)
        XCTAssertEqual(image.thumbnailURL, "https://www.hyoryu-danchi.com/share02.jpg")
        XCTAssertEqual(image.rawMetadata?["identitySource"], "https://www.wikidata.org/wiki/Q109602795")
        XCTAssertNil(try OfficialWorkArtwork.parse("<title>Other film</title><meta property='og:image' content='/wrong.jpg'>",
            url: URL(string: "https://example.com/")!, name: "雨を告げる漂流団地", identityURL: "Q109602795"))
    }

    func testOneHopTargetsNeverIncludeGrandchildrenOrPendingNames() {
        let ids = (0..<10).map { WorkID(rawValue: "test:child:\($0)")! }
        let root = WorkID(rawValue: "test:root")!, context = WorkID(rawValue: "test:composition")!
        let planned = NextWorkPrefetch.targets(ids, context: context, excluding: root)
        XCTAssertEqual(planned, Array(ids.prefix(6)) + [context])
        XCTAssertFalse(planned.contains(WorkID(rawValue: "test:grandchild")!))
        XCTAssertEqual(NextWorkPrefetch.targets([root, ids[0], ids[0]], context: ids[0], excluding: root), [ids[0]])
    }

    func testPublicStreamingEventsExcludeReasoningAndRetainFinalUsage() throws {
        var parser = DiscoveryResponseStream.Parser()
        XCTAssertTrue(try parser.line(#"data: {"type":"response.reasoning_text.delta","delta":"PRIVATE_REASONING_MARKER"}"#).isEmpty)
        let events = try parser.line(#"data: {"type":"response.output_item.done","item":{"type":"web_search_call","action":{"type":"search","queries":["雨を告げる漂流団地 ACAね interview"]}}}"#)
        XCTAssertEqual(events.count, 1)
        _ = try parser.line(#"data: {"type":"response.completed","response":{"status":"completed","model":"test","output":[{"type":"reasoning","content":"PRIVATE_REASONING_MARKER"},{"type":"message","content":[{"type":"output_text","text":"{\"leads\":[],\"story\":null}"}]}],"usage":{"input_tokens":5,"output_tokens":7}}}"#)
        let data = try XCTUnwrap(parser.finalData)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_REASONING_MARKER"))
        let answer = try ResearchNativeResponse.decode(data, fallbackModel: "test", seconds: 1)
        XCTAssertEqual(answer.answer.usage.outputTokens, 7); XCTAssertTrue(answer.answer.completed)
    }

    func testInterruptedPaidTaskSurvivesRestartAndDoesNotAutomaticallySpendAgain() async throws {
        let folder = temporary("jobs"); defer { try? FileManager.default.removeItem(at: folder) }
        let counter = Calls(), source = musicWork(), library = try library(service: VersionsService(recording: version()), works: [musicWork()])
        let subject = LeadSubject(id: source.id.rawValue, kind: .song, title: source.title, creator: source.creator, album: "")
        let jobs = DiscoveryJobs(directory: folder)
        let research = LeadResearch(researchOperation: { _ in
            await counter.add(); try await Task.sleep(for: .seconds(60)); return .init(leads: [], story: nil)
        }, evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: jobs)
        let operation = Task { await research.load(subject, library: library, force: true) }
        for _ in 0..<100 where jobs.values[subject.id] == nil { await Task.yield() }
        research.stop(subject.id)
        await operation.value
        XCTAssertEqual(jobs.values[subject.id]?.phase, .stopped)
        await research.load(subject, library: library)
        let count = await counter.value; XCTAssertEqual(count, 1)
        let reopened = DiscoveryJobs(directory: folder)
        XCTAssertEqual(reopened.values[subject.id]?.phase, .stopped)
        jobs.start(subject, userInitiated: true); jobs.event(.sent, id: subject.id)
        let killed = DiscoveryJobs(directory: folder)
        XCTAssertEqual(killed.values[subject.id]?.phase, .interrupted)
        XCTAssertEqual(killed.values[subject.id]?.requestSent, true)
        let cold = LeadResearch(researchOperation: { _ in await counter.add(); throw URLError(.notConnectedToInternet) },
            evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: killed)
        await cold.load(subject, library: library)
        XCTAssertEqual(cold.state(subject.id), .empty, "An interrupted first lookup is settled stock, never four still-loading cards")
        let afterRestart = await counter.value; XCTAssertEqual(afterRestart, 1)
    }

    func testNoStoryAndRejectedStoryAreDifferentFromNetworkFailure() async throws {
        for rejected in [false, true] {
            let source = musicWork(), library = try library(service: VersionsService(recording: version()), works: [musicWork()])
            let raw = LeadResearchClient.Raw(leads: [], story: rejected ? .init(text: String(repeating: "没有对应出处的内容。", count: 5), subject: "recording", url: "https://example.com/unobserved", source: "") : nil)
            let jobs = DiscoveryJobs(directory: nil)
            let research = LeadResearch(researchOperation: { _ in raw }, evidenceCache: .init(directory: nil),
                diagnostics: .init(directory: nil), processedDirectory: nil, metadataRefinement: { leads, _ in leads }, jobs: jobs)
            await research.load(.init(id: source.id.rawValue, kind: .song, title: source.title, creator: "", album: ""), library: library, force: true)
            XCTAssertEqual(jobs.values[source.id.rawValue]?.phase, .done)
            XCTAssertEqual(jobs.values[source.id.rawValue]?.storyResult, rejected ? .rejected : .notFound)
        }
    }

    /// ISLAND A (2026-11-16): the system island says what is looked for and the step really taken.
    func testSystemIslandWordsFollowRealSteps() {
        let jobs = DiscoveryJobs(directory: nil)
        let subject = LeadSubject(id: "island", kind: .song, title: "夏枯れ", creator: "", album: "")
        jobs.start(subject, userInitiated: true)
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).title, "查《夏枯れ》背后的作品")
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).subtitle, "正在连上资料")
        jobs.event(.sent, id: "island")
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).subtitle, "在找资料")
        jobs.event(.search("夏枯れ 主題歌"), id: "island"); jobs.event(.search("夏枯れ 映画"), id: "island")
        jobs.event(.read(URL(string: "https://natalie.mu/music/news/1")!), id: "island")
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).subtitle, "搜了 2 次 · 读到第 1 页")
        jobs.event(.received(5), id: "island")
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).subtitle, "找到 5 个名字，逐个核对")
        jobs.event(.checking("电影 A", 2, 5), id: "island")
        XCTAssertEqual(DiscoveryBackground.running(jobs.values["island"]!).subtitle, "核对 电影 A（2/5）")
        XCTAssertEqual(DiscoveryBackground.done("夏枯れ", leads: 5, story: true).subtitle, "5 件关联 · 有幕后故事")
        XCTAssertEqual(DiscoveryBackground.done("夏枯れ", leads: 0, story: false).subtitle, "这次没找到有出处的关联")
        XCTAssertEqual(DiscoveryBackground.short("一二三四五六七八九十十一十二"), "一二三四五六七八九十十…")
    }

    func testSavedAnswerAfterInterruptionIsProcessedWithoutAnotherModelCall() async throws {
        let folder = temporary("recovery"); defer { try? FileManager.default.removeItem(at: folder) }
        let source = musicWork(), library = try library(service: VersionsService(recording: version()), works: [musicWork()])
        let subject = LeadSubject(id: source.id.rawValue, kind: .song, title: source.title, creator: "", album: "")
        let jobDirectory = folder.appendingPathComponent("jobs"), evidence = DiscoveryEvidenceCache(directory: folder.appendingPathComponent("evidence"))
        let before = DiscoveryJobs(directory: jobDirectory); before.start(subject, userInitiated: true); before.event(.sent, id: subject.id)
        var raw = LeadResearchClient.Raw(leads: [], story: .init(text: String(repeating: "制作人和歌手在同一录音室核对演唱段落。", count: 4), subject: "recording", url: "https://example.com/interview", source: "采访"))
        raw.observedURLs = ["https://example.com/interview"]
        evidence.save(raw, subject: subject, namespace: "gpt-" + InternalStoryModel.model, seconds: 1)
        before.event(.received(0), id: subject.id)
        let jobs = DiscoveryJobs(directory: jobDirectory), calls = Calls()
        let research = LeadResearch(researchOperation: { _ in await calls.add(); throw URLError(.notConnectedToInternet) },
            evidenceCache: evidence, diagnostics: .init(directory: nil), processedDirectory: nil,
            metadataRefinement: { leads, _ in leads }, jobs: jobs)
        // The recovery button uses force, but an already-saved new answer is
        // still processed for free rather than becoming another paid retry.
        await research.load(subject, library: library, force: true)
        let count = await calls.value; XCTAssertEqual(count, 0)
        XCTAssertNotNil(research.reports[subject.id]?.story)
        XCTAssertEqual(jobs.values[subject.id]?.phase, .done)
    }

    func testCancelledImageIsRetriableAndDownloadedBytesSurviveOfflineRestart() async throws {
        let folder = temporary("images"); defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 24, height: 24)) }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 1)), calls = Calls(), url = URL(string: "https://example.com/art.jpg")!
        let cache = ArtworkImageCache(directory: folder, loader: { request in
            let count = await calls.add()
            if count == 1 { throw URLError(.cancelled) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let first = await cache.load(url); XCTAssertNil(first); XCTAssertFalse(cache.permanentlyMissing(url))
        let second = await cache.load(url); XCTAssertNotNil(second)
        let reopened = ArtworkImageCache(directory: folder, loader: { _ in XCTFail("Downloaded art must not re-fetch"); throw URLError(.notConnectedToInternet) })
        let restored = await reopened.load(url); XCTAssertNotNil(restored)
        XCTAssertNotNil(reopened.image(url))
    }

    private func musicWork() -> Work {
        Work(id: WorkID(rawValue: "test:e11-music-work")!, title: "召喚獣の祠", creator: "裏谷玲央", kind: "音乐作品", art: "", detail: "", url: nil,
            discovery: .init(layer: .musicWork, canonicalTitle: "召喚獣の祠", composer: "裏谷玲央"))
    }
    private func version(title: String = "召喚獣の祠 (FF7 Rebirth OST Ver.)", creator: String = "裏谷玲央") -> Work {
        Work(id: WorkID(rawValue: "apple:song:1738190146")!, title: title, creator: creator, kind: "歌曲",
            art: "https://example.com/ost.jpg", detail: "", url: "https://music.apple.com/jp/song/1738190146", catalogID: "1738190146", storeCountry: "jp", releaseDate: "2024-04-10")
    }
    private func library(service: any CatalogFetching, works: [Work]) throws -> Library {
        let defaults = UserDefaults(suiteName: "E11.tests." + UUID().uuidString)!
        let catalog = CatalogStore(cacheURL: nil, service: service)
        try catalog.merge(.init(works: works, relations: []), persist: false)
        return Library(defaults: defaults, catalog: catalog)
    }
    private func temporary(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("E11-" + name + UUID().uuidString) }
    private actor Calls {
        var value = 0
        @discardableResult func add() -> Int { value += 1; return value }
    }
    private actor VersionsService: CatalogFetching {
        let recording: Work; let offline: Bool
        var calls = 0
        init(recording: Work, offline: Bool = false) { self.recording = recording; self.offline = offline }
        func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext?) async throws -> CatalogResponse {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return .init(results: [recording.id], snapshot: .init(works: [recording], relations: []))
        }
        func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind?) async throws -> CatalogResponse { throw CatalogError.notFound }
    }
}
