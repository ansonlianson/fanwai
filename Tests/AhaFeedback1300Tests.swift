import XCTest
@testable import Pianwai

/// anson's 13:00 feedback on 0.5.26 (11-18).
@MainActor final class AhaFeedback1300Tests: XCTestCase {
    /// #6: the Japanese store lists The Who as ザ・フー; the US listing ties the card's name to the artist number.
    func testTheUSListingTiesALatinCreditToTheLocalArtistName() async throws {
        let saved = ArtistStoreNames.lookup
        defer { ArtistStoreNames.lookup = saved }
        var asked: URL?
        ArtistStoreNames.lookup = { url in
            asked = url
            return Data(#"{"results":[{"artistName":"The Who","artistId":61499,"trackName":"My Generation"},{"artistName":"Hollywood Vampires","artistId":294758731,"trackName":"My Generation"}]}"#.utf8)
        }
        XCTAssertTrue(ArtistStoreNames.needsBridge(creator: "The Who", country: "jp"))
        XCTAssertFalse(ArtistStoreNames.needsBridge(creator: "The Who", country: "us"))
        XCTAssertFalse(ArtistStoreNames.needsBridge(creator: "ザ・フー", country: "jp"))
        let ids = await ArtistStoreNames.artistIDs(named: "The Who", title: "MY GENERATION")
        XCTAssertEqual(ids, ["61499"])
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(asked), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value, "us")
    }

    /// 14:20 feedback: 「拒绝再玩 · 张国荣」 is 「拒絕再玩 · レスリー・チャン」 in the Japanese store.
    func testChineseCreditsAndTraditionalTitlesMatchTheJapaneseListing() async throws {
        XCTAssertEqual(ScriptFold.simplified("拒絕再玩"), "拒绝再玩")
        XCTAssertTrue(ScriptFold.sameTitle("拒絕再玩", "拒绝再玩"))
        XCTAssertTrue(ScriptFold.sameCredits("張國榮", "张国荣"))
        XCTAssertEqual(ArtistStoreNames.bridgeStores(creator: "张国荣", country: "jp"), ["hk", "tw"])
        XCTAssertEqual(ArtistStoreNames.bridgeStores(creator: "张国荣", country: "hk"), ["tw"])
        XCTAssertEqual(ArtistStoreNames.bridgeStores(creator: "安全地帯", country: "jp"), ["hk", "tw"])
        XCTAssertEqual(ArtistStoreNames.bridgeStores(creator: "ずっと真夜中でいいのに。", country: "jp"), [])
        let saved = ArtistStoreNames.lookup
        defer { ArtistStoreNames.lookup = saved }
        var stores: [String] = []
        ArtistStoreNames.lookup = { url in
            stores.append(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value ?? "")
            return Data(#"{"results":[{"artistName":"張國榮","artistId":41759136,"trackName":"拒絕再玩"},{"artistName":"陳奕迅","artistId":1,"trackName":"拒絕再玩"}]}"#.utf8)
        }
        let ids = await ArtistStoreNames.artistIDs(named: "张国荣", title: "拒绝再玩", country: "jp")
        XCTAssertEqual(ids, ["41759136"])
        XCTAssertEqual(stores, ["hk"], "the first store that knows the name is enough")
        // The version picker then accepts the Japanese listing by that number.
        let candidate = Work(id: WorkID(rawValue: "apple:song:1443280749")!, title: "拒絕再玩", creator: "レスリー・チャン", kind: "歌曲", art: "", detail: "", url: nil)
        let card = Work(id: WorkID(rawValue: "lead:recording:test")!, title: "拒绝再玩", creator: "张国荣", kind: "歌曲", art: "", detail: "", url: nil)
        XCTAssertTrue(RecordingCatalogMatch.matchesCandidate(candidate, source: card))
    }

    /// 14:22: a 网易云 share pasted whole; its short link lands on y.music.163.com. QQ's lands on i.y.qq.com.
    func testShareTextsFromNeteaseAndQQAreRecognised() throws {
        let share = "分享Leslie Cheung的单曲《拒絕再玩》: https://163cn.tv/blhtcSRN (来自@网易云音乐)"
        let link = try XCTUnwrap(PlatformSongLink.importURL(in: share))
        XCTAssertEqual(link.absoluteString, "https://163cn.tv/blhtcSRN")
        XCTAssertTrue(PlatformSongLink.isShort(link))
        let landed = URL(string: "https://y.music.163.com/m/song?id=632485&fx-wxqd=&app_version=9.6.25&dlt=0846")!
        XCTAssertEqual(PlatformSongLink.parse(landed), .init(platform: .netease, identifier: "632485"))
        XCTAssertEqual(PlatformSongLink.parse(URL(string: "https://music.163.com/#/song?id=632485")!), .init(platform: .netease, identifier: "632485"))
        let qq = URL(string: "https://i.y.qq.com/v8/playsong.html?ADTAG=cbshare&_wv=1&appshare=iphone&songmid=003OUlho2HcRHC&type=0")!
        XCTAssertEqual(PlatformSongLink.parse(qq), .init(platform: .qq, identifier: "003OUlho2HcRHC"))
        XCTAssertNotNil(PlatformSongLink.importURL(in: "分享周杰伦的单曲《晴天》https://c6.y.qq.com/base/fcgi-bin/u?__=Kp3lG2f @QQ音乐"))
    }

    /// 14:20: a song with nothing playable offers no 稍后听 (it did nothing visible); 能听的版本 instead.
    func testUnplayableSongsOfferNoListenLater() throws {
        let suite = "AhaFeedback1420." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let lead = WorkID(rawValue: "lead:recording:feedback1420")!
        try catalog.merge(.init(works: [Work(id: lead, title: "拒绝再玩", creator: "张国荣", kind: "歌曲", art: "", detail: "", url: nil)], relations: []))
        let library = Library(defaults: defaults, catalog: catalog, music: NoApplePlatformFixture())
        library.playbackPlatform = .apple
        let entity = SeedLibraryBridge.entity(for: lead, in: library)
        XCTAssertFalse(EntityActions.labels(entity, library: library).contains("稍后听"))
    }

    /// 15:03: Douban's own search finds a film under its Japanese title (the autocomplete list
    /// does not). Two rows as www.douban.com/search prints them.
    func testDoubanSearchPageRowsCarryTheNumberBothTitlesAndThePoster() {
        let html = """
        <div class="result-list">
          <div class="result">
            <div class="pic">
              <a class="nbg" href="https://www.douban.com/link2/?type=search&amp;pos=0&amp;query=x&amp;cat_id=1002&amp;url=https%3A%2F%2Fmovie.douban.com%2Fsubject%2F26707472%2F" target="_blank" onclick="moreurl(this,{i: '0', sid: 26707472, qcat: '1002'})" title="ぼくは明日、昨日のきみとデートする" ><img src="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2390682054.jpg"></a>
            </div>
            <div class="content"><div class="title"><h3>
                <span>[电影]</span>
                &nbsp;<a href="https://www.douban.com/link2/?url=https%3A%2F%2Fmovie.douban.com%2Fsubject%2F26707472%2F" target="_blank" >明日的我与昨日的你约会 </a>
            </h3>
            <div class="rating-info"><span class="subject-cast">原名:ぼくは明日、昨日のきみとデートする / 三木孝浩 / 福士苍汰 / 2016</span></div></div></div>
          </div>
          <div class="result">
            <div class="pic">
              <a class="nbg" href="https://www.douban.com/link2/?url=https%3A%2F%2Fmovie.douban.com%2Fsubject%2F37937099%2F" title="ニセ真面目女子はすみ" ><img src="https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2928206972.jpg"></a>
            </div>
            <div class="content"><div class="title"><h3>
                <span>[电视剧]</span>
                &nbsp;<a href="https://www.douban.com/link2/?url=x" target="_blank" >假正经女子莲 </a>
            </h3>
            <div class="rating-info"><span class="subject-cast">原名:ニセ真面目女子はすみ / 八重樫风雅 / 2025</span></div></div></div>
          </div>
        </div>
        """
        let hits = LeadArtwork.parseDoubanSearch(html)
        XCTAssertEqual(hits.map(\.id), ["26707472", "37937099"])
        XCTAssertEqual(hits.first, .init(id: "26707472", title: "明日的我与昨日的你约会", original: "ぼくは明日、昨日のきみとデートする", type: "电影",
            image: "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2390682054.jpg", link: "https://movie.douban.com/subject/26707472/"))
        XCTAssertEqual(hits.last?.type, "电视剧")
        XCTAssertTrue(LeadArtwork.parseDoubanSearch("<html><body>登录</body></html>").isEmpty)
    }

    /// 15:03: 搜索 with nothing typed lists what was searched for, opened or looked up.
    func testTheRecentListKeepsLookedUpPagesAndTakesOlderOnesAtItsEnd() throws {
        let suite = "AhaFeedback1503." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let ids = (1...6).map { WorkID(rawValue: "local:recent-\($0)")! }
        try catalog.merge(.init(works: ids.map { Work(id: $0, title: $0.rawValue, creator: "", kind: "歌曲", art: "", detail: "", url: nil) }, relations: []))
        let library = Library(defaults: defaults, catalog: catalog, music: NoApplePlatformFixture())
        library.visit(ids[0]); library.noteRecent(ids[1])
        XCTAssertEqual(library.recent, [ids[1], ids[0]])
        // Earlier search picks and looked-up songs join the end once; nothing already listed moves.
        library.extendRecent([ids[0], ids[2], ids[3], WorkID(rawValue: "local:not-in-catalogue")!])
        XCTAssertEqual(library.recent, [ids[1], ids[0], ids[2], ids[3]])
        library.removeRecent(ids[0])
        XCTAssertEqual(library.recent, [ids[1], ids[2], ids[3]])
        XCTAssertGreaterThanOrEqual(Library.recentLimit, 300)
        XCTAssertTrue(library.retainedWorkIDs().isSuperset(of: [ids[1], ids[2], ids[3]]), "what the list shows is kept on disk")
    }

    /// 16:00: a 深挖 round that only finds again what the page shows ends the dive.
    func testADeepRoundThatOnlyRefindsKnownCardsIsNothingNew() {
        let topic = ResearchTopic(id: "t", title: "プラネタリウム", creator: "大塚 愛", album: "LOVE COOK", layer: "recording")
        var known = DeepResearch.knownNames(cards: ["用于：花より男子"], facts: ["プラネタリウム | 收录于 | LOVE COOK | https://example.org"], topic: topic)
        XCTAssertEqual(DeepResearch.novelNames([["name": "花より男子", "zh": "花样男子"], ["name": "LOVE COOK"]], known: &known), [])
        XCTAssertEqual(DeepResearch.novelNames([["name": "花样男子"], ["name": "WISH"]], known: &known), ["WISH"], "its Chinese name was learnt in the round before")
        XCTAssertEqual(DeepResearch.novelNames([["name": "WISH"]], known: &known), [])
    }

    /// The wider story is on unless the reader turned it off; its cost is quoted from the chosen model's price.
    func testWiderStoryDefaultsOnAndCostsAreQuotedForAnyPricedModel() {
        let key = ConfiguredResearchTransport.widerStoryKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(ConfiguredResearchTransport.widerStoryEnabled)
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(ConfiguredResearchTransport.widerStoryEnabled)
        let flash = ModelPrice.published(model: "deepseek-flash")
        XCTAssertEqual(ConfiguredResearchTransport.widerStoryCost(flash) ?? 0, 0.0286, accuracy: 0.001)
        XCTAssertEqual(NextWorkPrefetch.cardCost(flash) ?? 0, 0.0626, accuracy: 0.001)
        XCTAssertEqual(SettingsView.extra(0.0286, per: "首"), "按现在的模型每首约多花 ¥0.03。")
        XCTAssertEqual(SettingsView.extra(nil, per: "张"), "花费按「模型」里填的单价估算。")
        XCTAssertEqual(SettingsView.extra(ConfiguredResearchTransport.widerStoryCost(.init(input: 15, output: 60)), per: "首"), "按现在的模型每首约多花 ¥0.18。")
    }

    /// 17:30 (anson): nothing found is said plainly, with how many pages were read; after a 深挖 the
    /// count covers both lookups and no second 深挖 is offered.
    func testNothingFoundCountsThePagesReadAndAFinishedDeepDiveIsNotOfferedAgain() async throws {
        let song = SeedGraph.Entity(id: "local:quiet", kind: .song, title: "夜の窓辺", subtitle: "", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: [])
        XCTAssertEqual(NothingFound.sentence(song, rejected: false), "还没有人写过这首歌的来历。")
        XCTAssertEqual(NothingFound.sentence(SeedGraph.Entity(id: "local:a", kind: .album, title: "窓", subtitle: "", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []), rejected: false), "还没有人写过这张专辑的来历。")
        XCTAssertEqual(NothingFound.sentence(SeedGraph.Entity(id: "local:p", kind: .person, title: "春野", subtitle: "", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []), rejected: false), "还没有人写过春野的幕后。")
        XCTAssertEqual(NothingFound.sentence(song, rejected: true), "找到的说法都对不上出处。")

        actor Rounds { var n = 0; func next() -> Int { n += 1; return n } }
        let rounds = Rounds()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AhaEmpty-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let suite = "AhaEmpty." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let work = Work(id: WorkID(rawValue: "local:quiet")!, title: "夜の窓辺", creator: "春野", kind: "歌曲", art: "", detail: "", url: nil)
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [work], relations: []))
        let library = Library(defaults: defaults, catalog: catalog, music: NoApplePlatformFixture())
        let jobs = DiscoveryJobs(directory: nil)
        let research = LeadResearch(researchOperation: { _ in
            var raw = LeadResearchClient.Raw(leads: [], story: nil)
            raw.observedURLs = await rounds.next() == 1
                ? ["https://a.example/1", "https://b.example/2", "https://a.example/1"]
                : ["https://b.example/2", "https://c.example/3"]
            return raw
        }, evidenceCache: .init(directory: folder), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: jobs)
        let subject = LeadSubject(id: work.id.rawValue, kind: .song, title: work.title, creator: work.creator, album: "")
        await research.load(subject, library: library, force: true)
        XCTAssertEqual(jobs.values[subject.id]?.storyResult, .notFound)
        XCTAssertNil(jobs.values[subject.id]?.deepened)
        XCTAssertEqual(research.pagesRead(subject.id, library: library), 2)
        await research.deepDive(subject, library: library)
        XCTAssertEqual(jobs.values[subject.id]?.deepened, true)
        XCTAssertEqual(research.pagesRead(subject.id, library: library), 3, "default lookup and 深挖 together, each page once")
        // A job saved by an older build has no such field.
        var old = try XCTUnwrap(jobs.values[subject.id]); old.deepened = nil
        let data = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(DiscoveryJob.self, from: data).deepened)
    }

    /// 18:16 (anson): pinching the map made names jump. A name is laid out at the width it will
    /// have once the finger lifts, and it fades in over a stretch of zoom instead of popping.
    func testMapNamesKeepTheirWidthWhenAPinchCommitsAndFadeInSmoothly() {
        for root in [false, true] {
            for (committed, live) in [(1.0, 0.5), (1.0, 1.8), (0.4, 0.9), (0.95, 0.7), (2.2, 0.3), (0.62, 0.62)] as [(CGFloat, CGFloat)] {
                let follow = RelationMapObject.nameSize(live, root: root) / RelationMapObject.nameSize(committed, root: root)
                let during = RelationMapObject.nameWidth(96, live: live, committed: committed, root: root) * follow * live
                let after = RelationMapObject.nameWidth(96, live: live, committed: live, root: root) * live
                XCTAssertEqual(during, after, accuracy: 0.001, "on-screen width at the commit, \(committed)→\(live)")
                // The same name, the same font on screen: it is cut at the same letter.
                let fontDuring = RelationMapObject.nameSize(committed, root: root) * follow * live
                XCTAssertEqual(fontDuring, RelationMapObject.nameSize(live, root: root) * live, accuracy: 0.001)
            }
        }
        var previous = RelationMapObject.nameOpacity(live: 0.3, always: false, showsRelation: true)
        for step in 1...400 {
            let scale = 0.3 + CGFloat(step) * 0.005
            let value = RelationMapObject.nameOpacity(live: scale, always: false, showsRelation: true)
            XCTAssertLessThanOrEqual(abs(value - previous), 0.04, "no pop at \(scale)")
            previous = value
        }
        XCTAssertEqual(RelationMapObject.nameOpacity(live: 0.3, always: false, showsRelation: false), 0)
        XCTAssertEqual(RelationMapObject.nameOpacity(live: 0.8, always: false, showsRelation: false), 1)
        XCTAssertEqual(RelationMapObject.nameOpacity(live: 0.3, always: true, showsRelation: false), 1)
    }
}
