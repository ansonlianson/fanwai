import XCTest
@testable import Pianwai

@MainActor final class DiscoveryJointReviewTests: XCTestCase {
    private let page = "https://example.com/original-interview"
    private func id(_ s: String) -> WorkID { WorkID(rawValue: "test:joint:" + s)! }
    private func piece(_ s: String, _ title: String, _ layer: DiscoveryIdentity.Layer, creator: String = "") -> Work {
        let identity = DiscoveryIdentity(layer: layer, canonicalTitle: title, composer: layer.isComposition ? creator : "")
        return Work(id: id(s), title: title, creator: creator, kind: identity.displayKind, art: "", detail: "", url: nil, discovery: identity)
    }
    private func fact(_ a: String, _ b: String, _ r: DiscoveryRelation, owner: String = "root") -> RelationEdge {
        .init(from: id(a), to: id(b), predicate: r.predicate, label: r.labels.forward, inverseLabel: r.labels.inverse,
            source: .init(title: "线索", detail: "Source-backed relation", url: page), researchRoot: id(owner))
    }
    func testOriginalRecordingAndDuetSurviveWithoutCreditPeopleOrOtherLiveDates() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("root", "Cover", .recording, creator: "Main Artist & Guest"),
            piece("piece", "Cover", .musicWork), piece("original", "Original", .recording, creator: "Original Singer"),
            piece("otherlive", "Cover live", .recording), piece("guest", "Guest", .person),
            piece("main", "Main Artist", .person), piece("composer", "Composer", .person), piece("mv", "Cover MV", .video)],
            relations: [fact("root", "piece", .performanceOf), fact("root", "original", .coverOf),
                fact("original", "piece", .performanceOf), fact("otherlive", "piece", .performanceOf),
                fact("root", "guest", .featuredBy), fact("root", "main", .featuredBy),
                fact("root", "composer", .composedBy), fact("mv", "root", .musicVideoOf)]))
        let leads = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(Set(leads.map(\.id)), Set([id("original"), id("guest"), id("mv")].map(\.rawValue)))
        XCTAssertEqual(leads.first?.label, "原曲")
        XCTAssertEqual(leads.last?.name, "Guest", "Joint credit must not exclude the featured participant")
    }
    func testThreeOriginalGamePairsAreKeptTogetherWithoutAnArbitraryFiveWorkCut() throws {
        let catalog = CatalogStore(cacheURL: nil)
        var works = [piece("root", "Medley", .recording)], edges: [RelationEdge] = []
        for i in 1...3 {
            works += [piece("p\(i)", "Original \(i)", .musicWork, creator: "Composer"), piece("g\(i)", "Game \(i)", .game)]
            edges += [fact("root", "p\(i)", .arrangementOf), fact("p\(i)", "g\(i)", .createdFor)]
        }
        try catalog.merge(.init(works: works, relations: edges))
        let leads = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(leads.map(\.id), ["p1", "g1", "p2", "g2", "p3", "g3"].map { id($0).rawValue })
        XCTAssertEqual(leads[3].path, [id("root"), id("p2"), id("g2")].map(\.rawValue))
    }
    func testCapturedOrdinarySongRepliesRetainOriginalAndDuet() throws {
        struct Case: Decodable { let title: String; let creator: String; let raw: LeadResearchClient.Raw }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/E06/e06-ordinary-captured.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: path))
        for (index, item) in cases.enumerated() {
            let subject = LeadSubject(id: id("ordinary-\(index)").rawValue, kind: .song, title: item.title, creator: item.creator, album: "")
            let plan = DiscoveryCore.prepare(item.raw, subject: subject), catalog = CatalogStore(cacheURL: nil)
            var works = [piece("ordinary-\(index)", item.title, .recording, creator: item.creator)]
            let refs = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.ref, WorkID(rawValue: $0.provisionalID)!) })
                .merging(["current": WorkID(rawValue: subject.id)!]) { _, b in b }
            works += plan.nodes.map { node in Work(id: refs[node.ref]!, title: node.raw.name!, creator: node.raw.creator ?? "",
                kind: node.identity.displayKind, art: "", detail: "", url: nil, discovery: node.identity) }
            let edges = plan.links.map { link in RelationEdge(from: refs[link.from]!, to: refs[link.to]!, predicate: link.relation.predicate,
                label: link.label, inverseLabel: link.inverse, source: .init(title: "线索", url: link.url), researchRoot: WorkID(rawValue: subject.id)) }
            try catalog.merge(.init(works: works, relations: edges))
            let leads = DiscoveryNavigation.leads(from: subject.id, catalog: catalog, known: [:], provider: nil)
            if index == 0 {
                XCTAssertEqual(leads.count, 2); XCTAssertTrue(leads.contains { $0.name == "あいみょん" })
                XCTAssertTrue(leads.contains { $0.kind == .video })
            } else {
                let original = try XCTUnwrap(leads.first { $0.label == "原曲" })
                XCTAssertEqual(original.original, "白い色は恋人の色"); XCTAssertTrue(original.creator.contains("ベッツィ"))
                XCTAssertTrue(edges.contains { $0.predicate == .coverOf })
            }
        }
    }
    func testThemeToAdaptationAndItsOriginalKeepsTheRealViaPath() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("theme", "Theme", .recording), piece("screen", "Anime", .tv), piece("manga", "Original manga", .manga)],
            relations: [fact("theme", "screen", .createdFor, owner: "theme"), fact("screen", "manga", .adaptationOf, owner: "theme")]))
        let leads = DiscoveryNavigation.leads(from: id("theme").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(leads.map(\.id), [id("screen"), id("manga")].map(\.rawValue))
        XCTAssertEqual(leads.last?.path, [id("theme"), id("screen"), id("manga")].map(\.rawValue))
        XCTAssertFalse(catalog.edges.contains { $0.from == id("theme") && $0.to == id("manga") })
    }
    func testInvalidCandidateCannotDropTheValidSubgraph() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("root", "Song", .recording)], relations: []))
        var invalid = piece("bad", "MV", .video)
        invalid.catalogID = "not-a-store-id"
        let valid = piece("game", "Game", .game)
        let rejected = catalog.replaceValidLeadRelations(from: id("root"),
            with: .init(works: [invalid, valid], relations: [fact("root", "bad", .usedIn), fact("root", "game", .createdFor)]),
            researchProvider: nil, preserveExisting: false)
        XCTAssertEqual(rejected, [id("bad")]); XCTAssertNotNil(catalog.works[id("game")])
        XCTAssertEqual(catalog.edges.filter { $0.researchRoot == id("root") }.map(\.to), [id("game")])
    }
    func testTypeUniqueDirectionRepairDoesNotGuessBetweenTwoMusicWorks() throws {
        let text = #"{"leads":[{"ref":"song","name":"Work","target_type":"music_work"},{"ref":"game","name":"Game","target_type":"game"}],"relations":[{"from":"song","to":"current","relation":"performance_of","url":"https://example.com/original-interview","evidence_quote":"work performed"},{"from":"game","to":"song","relation":"created_for","url":"https://example.com/original-interview","evidence_quote":"game music"}],"story":null}"#
        var raw = try XCTUnwrap(DiscoveryResponseDecoder.decode(text)); raw.observedURLs = [page]
        let plan = DiscoveryCore.prepare(raw, subject: .init(id: "test:joint:direction", kind: .song, title: "Live", creator: "Artist", album: ""))
        XCTAssertEqual(plan.links.map { $0.from + ">" + $0.to }, ["current>song", "song>game"])
        XCTAssertTrue(DiscoveryRelation.arrangementOf.accepts(from: .musicWork, to: .musicWork))
        XCTAssertEqual(DiscoveryRelation.parse("based_on"), .adaptationOf)
    }
    func testMediaQIDRequiresAnExactTypedPageAndAliasesAcrossDifferentSongs() throws {
        let response: [String: Any] = ["title": "東方紅魔郷", "pageprops": ["wikibase_item": "Q98765432"],
            "extract": "東方紅魔郷は、同人サークルの弾幕シューティングゲーム。"]
        let match = try XCTUnwrap(DiscoveryMediaIdentity.match(page: response, names: ["東方紅魔郷"], layer: .game, language: "ja"))
        XCTAssertNil(DiscoveryMediaIdentity.match(page: response, names: ["東方花映塚"], layer: .game, language: "ja"))
        XCTAssertNil(DiscoveryMediaIdentity.match(page: response, names: ["東方紅魔郷"], layer: .book, language: "ja"))
        let catalog = CatalogStore(cacheURL: nil)
        var first = piece("game-from-song-A", "東方紅魔郷", .game)
        first.knowledgeID = match.qid; first.knowledgeIdentitySource = match.source
        var second = piece("game-from-song-B", "东方红魔乡", .game)
        second.knowledgeID = match.qid; second.knowledgeIdentitySource = match.source
        try catalog.merge(.init(works: [first, second], relations: []))
        XCTAssertEqual(catalog.canonicalID(for: first.id), catalog.canonicalID(for: second.id))
        let suite = "joint-bookmark-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
        try persistence.save(.init(watchLater: [second.id]))
        XCTAssertEqual(try persistence.load().watchLater, [catalog.canonicalID(for: first.id)], "A name bookmarked before enrichment survives as its canonical media identity")
    }
    func testVisibleEvidenceIsReusableAcrossProcessorsButNotRecordingEditions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("E06-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiscoveryEvidenceCache(directory: folder)
        let a = LeadSubject(id: "apple:song:1", kind: .song, title: "Song", creator: "Artist", album: "Live A")
        let b = LeadSubject(id: "apple:song:2", kind: .song, title: "Song", creator: "Artist", album: "Live B")
        cache.write(.init(subject: a, namespace: "test", visibleText: #"{"leads":[],"relations":[],"story":null,"observedURLs":["https://forged.example"]}"#,
            observedURLs: [page], usage: nil, researchSeconds: 12, fetchedAt: Date()))
        let saved = try XCTUnwrap(cache.read(a, namespace: "test"))
        XCTAssertEqual(try saved.decode().observedURLs, [page]); XCTAssertNil(cache.read(b, namespace: "test"))
        let translated = LeadSubject(id: a.id, kind: .song, title: "Localized song title", creator: "Localized artist", album: "Localized release")
        XCTAssertNotNil(cache.read(translated, namespace: "test"), "Exact recording IDs survive display-language and alias corrections without another paid query")
        XCTAssertNil(cache.read(a, namespace: "other-model"))
        cache.write(.init(subject: a, namespace: "test", visibleText: "{ malformed", observedURLs: [], usage: nil, researchSeconds: 5, fetchedAt: Date()))
        XCTAssertThrowsError(try cache.read(a, namespace: "test")?.decode())
    }
    func testMalformedCachedAnswerNeverCallsTheProviderAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("E06-paid-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiscoveryEvidenceCache(directory: folder)
        let root = "test:joint:" + UUID().uuidString
        let subject = LeadSubject(id: root, kind: .song, title: "No repeat charge", creator: "Artist", album: "Edition")
        cache.write(.init(subject: subject, namespace: "gpt-" + InternalStoryModel.model, visibleText: "{ malformed",
            observedURLs: [], usage: nil, researchSeconds: 60, fetchedAt: Date()))
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter()
        let research = LeadResearch(researchOperation: { _ in await counter.increment(); return .init(leads: [], story: nil) }, evidenceCache: cache)
        let suite = "joint-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [Work(id: WorkID(rawValue: root)!, title: subject.title, creator: subject.creator, kind: "歌曲", art: "", detail: "", url: nil)], relations: []))
        await research.load(subject, library: Library(defaults: defaults, catalog: catalog))
        let calls = await counter.value
        XCTAssertEqual(calls, 0); XCTAssertEqual(research.state(root), .failed)
    }
}
