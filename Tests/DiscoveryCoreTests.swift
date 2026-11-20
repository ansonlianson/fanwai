import XCTest
@testable import Pianwai

@MainActor final class DiscoveryCoreTests: XCTestCase {
    private let source = "https://example.com/official/credits"
    private func raw(_ text: String) throws -> LeadResearchClient.Raw {
        var value = try JSONDecoder().decode(LeadResearchClient.Raw.self, from: Data(text.utf8))
        value.observedURLs = [source]
        return value
    }
    private func id(_ value: String) -> WorkID { WorkID(rawValue: "test:e06:" + value)! }
    private func work(_ value: String, identity: DiscoveryIdentity) -> Work {
        Work(id: id(value), title: identity.canonicalTitle, creator: identity.performers.isEmpty ? identity.composer : identity.performers,
             kind: identity.displayKind, art: "", detail: "", url: nil, discovery: identity)
    }
    private func edge(_ from: String, _ to: String, _ relation: DiscoveryRelation, owner: String) -> RelationEdge {
        RelationEdge(from: id(from), to: id(to), predicate: relation.predicate, label: relation.labels.forward,
                     inverseLabel: relation.labels.inverse, source: Source(title: "线索", detail: "Original credits", url: source), researchRoot: id(owner))
    }

    func testRecordingIdentityAndCompositionGroupingHaveDifferentBoundaries() {
        let a = LeadSubject(id: "apple:song:1641255720", kind: .song, title: "To the Edge", creator: "THE PRIMALS", album: "Beyond the Shadow")
        let b = LeadSubject(id: "apple:song:1765495221", kind: .song, title: "To the Edge", creator: "THE PRIMALS", album: "And Back Again")
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
        let composition = DiscoveryIdentity(layer: .musicWork, canonicalTitle: "To the Edge", composer: "祖堅正慶", identitySource: source)
        XCTAssertEqual(DiscoveryCore.provisionalID(composition, creator: "祖堅正慶", subjectID: a.id), DiscoveryCore.provisionalID(composition, creator: "Masayoshi Soken", subjectID: b.id))
        var unanchored = composition; unanchored.identitySource = nil
        XCTAssertNotEqual(DiscoveryCore.provisionalID(unanchored, creator: "祖堅正慶", subjectID: a.id), DiscoveryCore.provisionalID(unanchored, creator: "祖堅正慶", subjectID: b.id), "Names alone do not alias work identities")
        var unrelated = composition; unrelated.composer = "Another composer"
        XCTAssertNotEqual(DiscoveryCore.provisionalID(composition, creator: "", subjectID: a.id), DiscoveryCore.provisionalID(unrelated, creator: "", subjectID: a.id))
    }

    func testTwoSourcePagesCanSupportTheSameCompositionWithoutMergingRecordings() {
        let a = DiscoveryIdentity(layer: .musicWork, canonicalTitle: "To the Edge", composer: "祖堅正慶", identitySource: source)
        var b = a; b.identitySource = "https://another.example/original-interview"
        XCTAssertTrue(DiscoveryCore.sameSourcedComposition(a, b))
        b.arranger = "VaVa"; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(a, b))
        b = a; b.catalogue = "Op. 32"; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(a, b))
        b = a; b.composer = "Another composer"; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(a, b))
        b = a; b.identitySource = nil; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(a, b))
        b = a; b.layer = .recording; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(a, b))
        var japanese = a; japanese.canonicalTitle = "冥き水底"; japanese.aliases = ["'Neath Dark Waters"]
        var english = a; english.canonicalTitle = "'Neath Dark Waters"
        XCTAssertTrue(DiscoveryCore.sameSourcedComposition(japanese, english))
        english.composer = "Other"; XCTAssertFalse(DiscoveryCore.sameSourcedComposition(japanese, english))
    }

    func testTwoOriginalsAndTwoGamesSurviveAsSeparateDirectedPaths() throws {
        let input = try raw(#"""
        {"leads":[
          {"ref":"a","name":"フラワリングナイト","kind":"song","target_type":"music_work","composer":"ZUN","why":"原曲之一"},
          {"ref":"b","name":"月時計","kind":"song","target_type":"music_work","composer":"ZUN","why":"另一首原曲"},
          {"ref":"ga","name":"東方花映塚","kind":"game","why":"原作"},
          {"ref":"gb","name":"東方紅魔郷","kind":"game","why":"原作"}],
        "relations":[
          {"from":"current","to":"a","relation":"arrangement_of","url":"https://example.com/official/credits","evidence_quote":"原曲：フラワリングナイト"},
          {"from":"current","to":"b","relation":"arrangement_of","url":"https://example.com/official/credits","evidence_quote":"原曲：月時計"},
          {"from":"a","to":"ga","relation":"created_for","url":"https://example.com/official/credits","evidence_quote":"原作：東方花映塚"},
          {"from":"b","to":"gb","relation":"created_for","url":"https://example.com/official/credits","evidence_quote":"原作：東方紅魔郷"}],"story":null}
        """#)
        let plan = DiscoveryCore.prepare(input, subject: .init(id: "test:night", kind: .song, title: "ナイト・オブ・ナイツ", creator: "COOL&CREATE", album: ""))
        XCTAssertEqual(plan.nodes.count, 4); XCTAssertEqual(plan.links.count, 4)
        XCTAssertEqual(plan.nodes.filter { $0.identity.layer == .game }.count, 2)
        XCTAssertFalse(plan.links.contains { $0.from == "current" && ["ga", "gb"].contains($0.to) }, "No invented direct edge replaces an actual via path")
    }

    func testClassicalPartDirectionAndConsultedEvidenceAreRequired() throws {
        var input = try raw(#"""
        {"leads":[{"ref":"whole","name":"Pictures at an Exhibition","kind":"song","target_type":"music_work","composer":"Mussorgsky","why":"Whole suite"}],
         "relations":[{"from":"current","to":"whole","relation":"part_of","url":"https://example.com/official/credits","evidence_quote":"Suite"}],"story":null}
        """#)
        let subject = LeadSubject(id: "test:movement", kind: .song, title: "The Great Gate of Kiev", creator: "Mussorgsky", album: "", identity: .init(layer: .movement, canonicalTitle: "The Great Gate of Kiev"))
        XCTAssertEqual(DiscoveryCore.prepare(input, subject: subject).links.count, 1)
        XCTAssertFalse(DiscoveryRelation.partOf.accepts(from: .musicWork, to: .movement))
        XCTAssertTrue(DiscoveryRelation.adaptationOf.accepts(from: .film, to: .manga), "The original cross-media goal must survive the music-domain changes")
        input.observedURLs = []
        XCTAssertTrue(DiscoveryCore.prepare(input, subject: subject).nodes.isEmpty, "A model URL/quote alone is not consulted-source proof")
    }

    func testProviderFieldVariationAndBadNodesAreLocal() throws {
        let input = try XCTUnwrap(DiscoveryResponseDecoder.decode(#"""
        {"leads":[false,{"name":"Original","ref":1,"kind":"song","target_type":"music_work","composer":["ZUN"],"why":"原曲"},{"name":{"bad":"object"}}],
         "relations":[{"from":"current","to":1,"relation":"arrangement_of","url":"https://example.com/official/credits","evidence_quote":"原曲"}],
         "story":null,"observedURLs":["https://untrusted.example/"]}
        """#))
        XCTAssertEqual(input.leads?.count, 1)
        XCTAssertEqual(input.leads?.first?.composer, "ZUN")
        XCTAssertEqual(input.relations?.first?.to, "1")
        XCTAssertNil(input.observedURLs, "Generated JSON cannot supply its own transport evidence")
        let malformed = try XCTUnwrap(DiscoveryResponseDecoder.decode(#"{"leads":[{"name":"X","why":"Y"}],"relations":"not-an-array","story":null}"#))
        XCTAssertEqual(malformed.relations?.count, 0, "A malformed relation list must not trigger legacy star fallback")
    }

    func testWorkPageShowsVersionsWhileRecordingPageKeepsOriginalGame() throws {
        let store = CatalogStore(cacheURL: nil)
        let works = [
            work("live22", identity: .init(layer: .recording, canonicalTitle: "To the Edge", performers: "THE PRIMALS", edition: "2022")),
            work("live24", identity: .init(layer: .recording, canonicalTitle: "To the Edge", performers: "THE PRIMALS", edition: "2024")),
            work("piece", identity: .init(layer: .musicWork, canonicalTitle: "To the Edge", composer: "祖堅正慶")),
            work("game", identity: .init(layer: .game, canonicalTitle: "Shadowbringers"))]
        let links = [edge("live22", "piece", .performanceOf, owner: "live22"), edge("live24", "piece", .performanceOf, owner: "live24"), edge("piece", "game", .createdFor, owner: "live22")]
        try store.merge(.init(works: works, relations: links))
        let recording = DiscoveryNavigation.leads(from: id("live22").rawValue, catalog: store, known: [:], provider: nil)
        XCTAssertEqual(Set(recording.map(\.id)), [id("game").rawValue])
        let context = DiscoveryNavigation.context(from: id("live22").rawValue, catalog: store, provider: nil)
        XCTAssertEqual(context?.work.id, id("piece")); XCTAssertEqual(context?.otherVersions, 1); XCTAssertEqual(context?.canOpen, true)
        XCTAssertEqual(recording.first { $0.id == id("game").rawValue }?.path, [id("live22"), id("piece"), id("game")].map(\.rawValue))
        let piece = DiscoveryNavigation.leads(from: id("piece").rawValue, catalog: store, known: [:], provider: nil)
        XCTAssertEqual(Set(piece.filter { $0.label == "演奏版本" }.map(\.id)), [id("live22").rawValue, id("live24").rawValue])
        XCTAssertFalse(store.work(id("piece")).isSong)
        let game = DiscoveryNavigation.leads(from: id("game").rawValue, catalog: store, known: [:], provider: nil)
        XCTAssertEqual(game.map(\.id), [id("piece").rawValue], "A game page does not inherit a recording's multi-step claims")
    }

    func testOwnedNestedFactsAndRolesSurviveReplacingAnotherRecording() throws {
        let store = CatalogStore(cacheURL: nil)
        let recording = DiscoveryIdentity(layer: .recording, canonicalTitle: "Spring 1", performers: "Daniel Hope")
        let piece = DiscoveryIdentity(layer: .musicWork, canonicalTitle: "Spring 1", composer: "Max Richter", arranger: "Max Richter")
        let origin = DiscoveryIdentity(layer: .movement, canonicalTitle: "Spring I", composer: "Antonio Vivaldi", catalogue: "RV269", movement: "I. Allegro")
        try store.merge(.init(works: [work("a", identity: recording), work("b", identity: recording), work("piece", identity: piece), work("origin", identity: origin)], relations: [edge("a", "piece", .performanceOf, owner: "a"), edge("b", "piece", .performanceOf, owner: "b"), edge("piece", "origin", .arrangementOf, owner: "b")]))
        try store.replaceLeadRelations(from: id("a"), with: .init(works: [], relations: []), researchProvider: nil)
        XCTAssertEqual(store.edges.filter { $0.researchRoot == id("b") }.count, 2)
        XCTAssertEqual(store.work(id("origin")).discovery?.catalogue, "RV269")
        let data = try JSONEncoder().encode(CatalogSnapshot(works: Array(store.works.values), relations: store.edges))
        let restored = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
        XCTAssertEqual(restored.works.first { $0.id == id("piece") }?.discovery?.composer, "Max Richter")
        XCTAssertEqual(restored.relations.first { $0.predicate == .adaptedFrom && $0.researchRoot == id("b") }?.inverseLabel, "改编版本")
    }

    func testSourceSpellingDoesNotEraseTheConnectedGraph() throws {
        let page = "https://www.jp.square-enix.com/music/sem/page/ff14/primals/btsBD/en/setlist"
        var node = LeadResearchClient.RawLead(name: "To the Edge", zh: nil, en: nil, kind: "song", label: nil, why: "直接演奏乐曲", url: page, creator: "祖堅正慶", wiki: nil)
        node.ref = "piece"; node.target_type = "music_work"
        var input = LeadResearchClient.Raw(leads: [node], story: nil)
        input.observedURLs = [page]
        input.relations = [.init(from: "current", to: "piece", relation: "performance_of", label: nil, why: nil, url: page + "/", evidence_quote: "To the Edge")]
        let plan = DiscoveryCore.prepare(input, subject: .init(id: "test:live", kind: .song, title: "BtS: To the Edge", creator: "THE PRIMALS", album: "Beyond the Shadow"))
        XCTAssertEqual(plan.nodes.count, 1); XCTAssertEqual(plan.links.count, 1)
        XCTAssertEqual(DiscoveryCore.sourceKey("https://EXAMPLE.com:443/page/%28a%29/?utm_source=test#part"), "https://example.com/page/(a)")
        XCTAssertNotEqual(DiscoveryCore.sourceKey("https://example.com/page/a%2Fb"), DiscoveryCore.sourceKey("https://example.com/page/a/b"))
        XCTAssertNotEqual(DiscoveryCore.sourceKey(page), DiscoveryCore.sourceKey(page + "-unrelated"))
    }

    func testArticleImagesRequireTheActualWorkTitle() {
        XCTAssertFalse(LeadArtwork.articleTitleMatches("Magnolia grandiflora", names: ["フラワリングナイト", "Flowering Night"]))
        XCTAssertFalse(LeadArtwork.articleTitleMatches("Spring", names: ["Spring 1"]))
        XCTAssertTrue(LeadArtwork.articleTitleMatches("Bad Apple!! (song)", names: ["Bad Apple!!"]))
        XCTAssertFalse(WorkDestinations.youTubeTitleMatches("色は匂へど散りぬるを FullMV", song: "幻想万華鏡 春雪異変の章"), "A citation is not automatically the cited work's own video frame")
        XCTAssertTrue(WorkDestinations.youTubeTitleMatches("幽閉サテライト 色は匂へど散りぬるを FullMV", song: "色は匂へど散りぬるを"))
    }

    func testRejectedResearchDoesNotBecomeAnEmptyAnswerOrEraseKnownFacts() async throws {
        let store = CatalogStore(cacheURL: nil)
        try store.merge(.init(works: [work("recording", identity: .init(layer: .recording, canonicalTitle: "Known performance")), work("piece", identity: .init(layer: .musicWork, canonicalTitle: "Known work", composer: "Composer"))], relations: [edge("recording", "piece", .performanceOf, owner: "recording")]))
        let suite = "E06-failure-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, catalog: store)
        var input = try raw(#"{"leads":[{"ref":"wrong","name":"Unconsulted work","target_type":"music_work","why":"claim"}],"relations":[{"from":"current","to":"wrong","relation":"performance_of","url":"https://example.com/official/credits","evidence_quote":"claim"}],"story":null}"#)
        input.observedURLs = []
        let frozen = input
        let research = LeadResearch(researchOperation: { _ in frozen })
        await research.load(.init(id: id("recording").rawValue, kind: .song, title: "Known performance", creator: "", album: ""), library: library, force: true)
        XCTAssertEqual(research.state(id("recording").rawValue), .ready)
        XCTAssertEqual(store.edges.filter { $0.researchRoot == id("recording") }.count, 1)
        let candidates = research.navigationLeads(id("recording").rawValue, library: library)
        XCTAssertTrue(candidates.isEmpty, "Unconfirmed names stay outside the discovery crate")
        XCTAssertEqual(research.unconfirmedLeads(id("recording").rawValue).count, 1)
        XCTAssertEqual(research.unconfirmedLeads(id("recording").rawValue).first?.unconfirmed, true)
        XCTAssertFalse(research.story(for: id("recording").rawValue)?.entityLinks.values.contains(id("wrong")) ?? false)
    }

    func testNewGraphCacheKeepsThePreviousAppCacheUntouchedForRollback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("E06-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("catalog-v1.json"), current = directory.appendingPathComponent("catalog-v2.json")
        let original = try JSONEncoder().encode(CatalogSnapshot(works: [work("saved", identity: .init(layer: .recording, canonicalTitle: "Saved record"))], relations: []))
        try original.write(to: legacy)
        let store = CatalogStore(cacheURL: current)
        XCTAssertEqual(store.work(id("saved")).title, "Saved record")
        try store.merge(.init(works: [work("piece", identity: .init(layer: .musicWork, canonicalTitle: "Work", composer: "Composer"))], relations: [edge("saved", "piece", .performanceOf, owner: "saved")]))
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        await store.flushPendingWrites()
        let reopened = CatalogStore(cacheURL: current)
        XCTAssertTrue(reopened.edges.contains { $0.from == id("saved") && $0.predicate == .performanceOf })
    }

    func testGameDestinationsAndCompositionActionsDoNotPretendToPlay() throws {
        let store = CatalogStore(cacheURL: nil)
        try store.merge(.init(works: [work("game", identity: .init(layer: .game, canonicalTitle: "東方花映塚")), work("piece", identity: .init(layer: .musicWork, canonicalTitle: "フラワリングナイト", composer: "ZUN"))], relations: []))
        let suite = "E06-contract-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, catalog: store)
        let game = SeedLibraryBridge.entity(for: id("game"), in: library)
        XCTAssertEqual(game.kind, .game)
        let links = WorkDestinations.links(game, library: library, lead: nil)
        XCTAssertFalse(links.contains { $0.url.host?.contains("douban") == true })
        let music = SeedLibraryBridge.entity(for: id("piece"), in: library)
        // anson 11-18 14:20: nothing to listen to later until a version is found; the page offers 能听的版本.
        XCTAssertEqual(EntityActions.labels(music, library: library), [])
    }
}
