import XCTest
@testable import Pianwai

/// anson's device feedback of 2026-11-18 (0.5.24).
@MainActor final class AhaFeedbackTests: XCTestCase {
    private func story(_ body: String, mentions: [String] = []) -> Story {
        Story(id: "s", entityID: "apple:song:1", title: "", body: body, source: Source(title: "t", url: "https://example.org"), mentions: mentions)
    }

    func testNamesTheWriterDidNotListCanStillBeOpened() {
        let planetarium = "大塚爱说，《プラネタリウム》最早做出来的版本并不是现在这样的抒情曲，那时她常听GOING STEADY、MONGOL800和THE BLUE HEARTS，就按乐队的感觉写成了一首很快的歌。"
        let names = StoryTextLinks.detected(in: planetarium)
        for name in ["プラネタリウム", "GOING STEADY", "MONGOL800", "THE BLUE HEARTS"] { XCTAssertTrue(names.contains(name), name) }
        let links = StoryTextLinks(story: story(planetarium), excludingNames: [LeadMatch.norm("プラネタリウム")])
        XCTAssertEqual(Set(links.targets.map(\.name)), ["GOING STEADY", "MONGOL800", "THE BLUE HEARTS"])
        XCTAssertEqual(links.spans(in: StoryTextPresentation.clean(planetarium)).map(\.name), ["GOING STEADY", "MONGOL800", "THE BLUE HEARTS"])

        let night = "n-buna在电台采访里说，《幻灯》第二章“踊る動物”把顺序倒了过来：先请加藤隆按主题画好画。"
        let found = StoryTextLinks.detected(in: night)
        XCTAssertTrue(found.contains("n-buna")); XCTAssertTrue(found.contains("幻灯"))
        // What the writer listed is kept as before; a CJK personal name can only come from that list.
        XCTAssertTrue(StoryTextLinks(story: story(night, mentions: ["加藤隆"])).targets.map(\.name).contains("加藤隆"))
    }

    func testFormatAndPlatformWordsAreNotNames() {
        let text = "这支PV先放在TikTok和YouTube上，Live版本和TV size都比CD里的Acoustic version短，OP用的是Remix。"
        XCTAssertEqual(StoryTextLinks.detected(in: text), [])
        // An English word used as a word is not a name (anson's screenshot: 「coupling曲」 was underlined).
        XCTAssertEqual(StoryTextLinks.detected(in: "这是制作单曲的coupling曲期间写的，在studio里录了两个session。"), [])
        // A real name next to such a word is still found.
        XCTAssertEqual(StoryTextLinks.detected(in: "他想写出Men I Trust那样的歌，鼓用了Addictive Drums，Live时再改。"), ["Men I Trust", "Addictive Drums"])
    }

    func testAFailureSaysWhatTheReaderCanDoAboutIt() {
        XCTAssertEqual(DiscoveryJob.Failure.reason(StoryModelError.insufficientBalance), .balance)
        XCTAssertEqual(DiscoveryJob.Failure.reason(ResearchHTTP.Failure.http(402)), .balance)
        XCTAssertEqual(DiscoveryJob.Failure.reason(ResearchHTTP.Failure.http(401)), .key)
        XCTAssertEqual(DiscoveryJob.Failure.reason(StoryModelError.invalidKey), .key)
        XCTAssertEqual(DiscoveryJob.Failure.reason(StoryModelError.unavailableModel), .model)
        XCTAssertEqual(DiscoveryJob.Failure.reason(URLError(.timedOut)), .network)
        XCTAssertEqual(DiscoveryJob.Failure.reason(ResearchHTTP.Failure.http(503)), .network)
        XCTAssertEqual(DiscoveryJob.Failure.balance.line(provider: "DeepSeek"), "DeepSeek 余额不足")
        XCTAssertEqual(DiscoveryJob.Failure.balance.line(provider: "通义千问"), "通义千问余额不足")
        XCTAssertEqual(DiscoveryJob.Failure.key.line(provider: "自定义"), "模型服务的 API Key 用不了")
    }

    private func setting(_ operation: @escaping @Sendable (LeadSubject) async throws -> LeadResearchClient.Raw) throws -> (LeadResearch, DiscoveryJobs, LeadSubject, Library) {
        let suite = "AhaFeedback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let work = Work(id: WorkID(rawValue: "local:feedback-song")!, title: "未来への航跡", creator: "Choro Club", kind: "歌曲", art: "", detail: "", url: nil)
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [work], relations: []))
        let library = Library(defaults: defaults, catalog: catalog, music: NoApplePlatformFixture())
        let jobs = DiscoveryJobs(directory: nil)
        let research = LeadResearch(researchOperation: operation, evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil),
                                    processedDirectory: nil, jobs: jobs)
        let subject = LeadSubject(id: work.id.rawValue, kind: .song, title: work.title, creator: work.creator, album: "")
        return (research, jobs, subject, library)
    }

    func testASleeveFollowedOnTheMapDoesNotClaimThereIsNoStory() async throws {
        let (research, jobs, subject, library) = try setting { _ in .init(leads: [], story: nil) }
        await research.load(subject, library: library, force: true, cardsOnly: true)
        XCTAssertEqual(jobs.values[subject.id]?.phase, .done)
        XCTAssertEqual(jobs.values[subject.id]?.storyResult, .notAsked)
        // Asked in full, the same empty answer is "none found".
        let (full, fullJobs, sameSubject, sameLibrary) = try setting { _ in .init(leads: [], story: nil) }
        await full.load(sameSubject, library: sameLibrary, force: true)
        XCTAssertEqual(fullJobs.values[sameSubject.id]?.storyResult, .notFound)
    }

    func testAnEmptyAccountIsReportedAsSuchNotAsNothingFound() async throws {
        let (research, jobs, subject, library) = try setting { _ in throw StoryModelError.insufficientBalance }
        await research.load(subject, library: library, force: true)
        XCTAssertEqual(jobs.values[subject.id]?.phase, .failed)
        XCTAssertEqual(jobs.values[subject.id]?.failure, .balance)
        XCTAssertEqual(research.state(subject.id), .failed)
    }

    func testSoundingAlikeIsNotWhereASongComesFrom() throws {
        let packet = ResearchMaterialPacket(topic: .init(id: "apple:song:1", title: "プラネタリウム", creator: "大塚 愛", album: "LOVE COOK", layer: "recording"),
            queries: [], sources: [ResearchSource(id: "S1", url: "https://example.org/1", title: "プラネタリウム", publisher: "Example",
                text: "大塚愛のプラネタリウムとRikkiの素敵だねについて。確かにサビの部分が似てますね。大塚愛はGOING STEADYにインスパイアされてプラネタリウムを書いた。", purposes: [.lineage])],
            fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 1, fetches: 0)
        let alike = #"{"leads":[{"ref":"n2","name":"素敵だね","target_type":"music_work","creator":"Rikki"}],"relations":[{"from":"current","to":"n2","relation":"inspired_by","why":"副歌相似","source_id":"S1","quote":"確かにサビの部分が似てますね。"}]}"#
        XCTAssertTrue(try ResearchWriter.groundRelations(alike, packet: packet).relations.isEmpty)
        // A stated influence is kept.
        let stated = #"{"leads":[{"ref":"n3","name":"GOING STEADY","target_type":"group","creator":""}],"relations":[{"from":"current","to":"n3","relation":"inspired_by","why":"受其影响","source_id":"S1","quote":"大塚愛はGOING STEADYにインスパイアされてプラネタリウムを書いた"}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(stated, packet: packet).relations.count, 1)
        XCTAssertTrue(ResearchProofRules.onlyResemblance("The chorus sounds like an older hymn."))
        XCTAssertFalse(ResearchProofRules.onlyResemblance("It is based on a hymn that sounds like a lullaby."))
    }

    /// 0.5.26: once the cards are up, each card's own relations come from the free databases in the
    /// background. Nothing is asked of the model and the card is not marked as looked up.
    func testCardsAreFollowedOneLevelFromTheFreeDatabasesWithoutTheModel() async throws {
        actor Calls { var model = 0, database: [String] = []; func asked() { model += 1 }; func looked(_ id: String) { database.append(id) } }
        let calls = Calls()
        let suite = "AhaPrefetch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let song = Work(id: WorkID(rawValue: "local:prefetch-song")!, title: "On My Own", creator: "岩崎太整", kind: "歌曲", art: "", detail: "", url: nil)
        let show = Work(id: WorkID(rawValue: "local:prefetch-show")!, title: "血界戦線", creator: "", kind: "动画", art: "", detail: "", url: nil)
        let manga = Work(id: WorkID(rawValue: "local:prefetch-manga")!, title: "血界戦線", creator: "内藤泰弘", kind: "漫画", art: "", detail: "", url: nil)
        let person = Work(id: WorkID(rawValue: "local:prefetch-person")!, title: "岩崎太整", creator: "", kind: "创作者", art: "", detail: "", url: nil)
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [song, show, person], relations: []))
        let library = Library(defaults: defaults, catalog: catalog, music: NoApplePlatformFixture())
        let research = LeadResearch(researchOperation: { _ in await calls.asked(); return .init(leads: [], story: nil) },
            evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: DiscoveryJobs(directory: nil),
            databaseOperation: { work, _, _ in
                await calls.looked(work.id.rawValue)
                guard work.id == show.id else { return .init() }
                return .init(snapshot: .init(works: [manga], relations: [.init(from: show.id, to: manga.id, predicate: .adaptedFrom, label: "改编自",
                    inverseLabel: "动画改编", source: .init(title: "Bangumi", url: "https://bgm.tv/subject/1"))]))
            })
        await research.prefetchRelations([show.id, person.id], library: library)
        let looked = await calls.database, asked = await calls.model
        XCTAssertEqual(looked, [show.id.rawValue], "works are followed; people and albums are not")
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(PublicCrateInventory.directEdges(show.id, catalog: catalog).contains { $0.to == manga.id })
        XCTAssertNil(research.state(show.id.rawValue), "its own page still looks it up when opened")
        // The same card is not asked about twice.
        await research.prefetchRelations([show.id], library: library)
        let again = await calls.database
        XCTAssertEqual(again.count, 1)
    }

    /// The names the writer lists must survive the saved answer being read back (they did not from
    /// 0.5.18 to 0.5.25: the decoder never read the list, so only card names could be opened).
    func testTheWritersListOfNamesSurvivesTheSavedAnswer() throws {
        let answer = #"{"leads":[],"relations":[],"story":{"text":"樱井和寿在制作单曲期间写出了这首歌，加藤隆按主题画好了画。","subject":"recording","subject_ref":"current","url":"https://example.org/a","source":"Example","mentions":["樱井和寿","加藤隆"," "]}}"#
        let raw = try XCTUnwrap(DiscoveryResponseDecoder.decode(answer))
        XCTAssertEqual(raw.story?.mentions, ["樱井和寿", "加藤隆"])
        let wider = #"{"leads":[],"relations":[],"story":{"text":"为这部动画做配乐的乐队此前担任过电视剧原声带，这次导演没有特别下指示。","subject":"artist","subject_name":"Choro Club feat.Senoo","url":"https://example.org/a","source":"Example"}}"#
        let widerRaw = try XCTUnwrap(DiscoveryResponseDecoder.decode(wider))
        XCTAssertEqual(widerRaw.story?.subject_name, "Choro Club feat.Senoo")
        var observed = widerRaw; observed.observedURLs = ["https://example.org/a"]
        let story = try XCTUnwrap(LeadResearch.sourcedStory(observed, mentions: []))
        XCTAssertEqual(story.subject, "artist"); XCTAssertEqual(story.focusName, "Choro Club feat.Senoo")
    }
}
