import XCTest
@testable import Pianwai

/// anson 2026-11-18 17:00: Wikipedia read directly, search words written from what is known,
/// 深挖 that follows leads, and the film a jazz cover reaches through the piece it plays.
@MainActor final class AhaSearch1118Tests: XCTestCase {
    override func tearDown() {
        WikipediaMaterials.loader = nil
        super.tearDown()
    }

    // MARK: Cinema Paradiso

    private func paradiso(performer: String) throws -> (CatalogStore, WorkID, WorkID) {
        func id(_ name: String) -> WorkID { WorkID(rawValue: "test:paradiso:" + name)! }
        let catalog = CatalogStore(cacheURL: nil)
        let morricone = "エンニオ・モリコーネ / アンドレア・モリコーネ"
        let recording = Work(id: id("root"), title: "ニュー・シネマ・パラダイス", creator: performer, kind: "歌曲", art: "", detail: "", url: nil,
            discovery: .init(layer: .recording, canonicalTitle: "ニュー・シネマ・パラダイス", composer: morricone, performers: performer))
        let piece = Work(id: id("piece"), title: "Nuovo cinema Paradiso", creator: morricone, kind: "音乐作品", art: "", detail: "", url: nil,
            discovery: .init(layer: .musicWork, canonicalTitle: "Nuovo cinema Paradiso", composer: morricone))
        let film = Work(id: id("film"), title: "ニュー・シネマ・パラダイス", creator: "ジュゼッペ・トルナトーレ", kind: "电影", art: "", detail: "", url: nil,
            discovery: .init(layer: .film, canonicalTitle: "ニュー・シネマ・パラダイス"))
        func edge(_ a: String, _ b: String, _ predicate: RelationKind, _ quote: String) -> RelationEdge {
            .init(from: id(a), to: id(b), predicate: predicate, label: predicate == .performanceOf ? "乐曲" : "为此而作",
                  inverseLabel: predicate == .performanceOf ? "演奏版本" : "原声作品",
                  source: .init(title: "线索", detail: quote, url: "https://example.org/paradiso", evidenceQuote: quote), researchRoot: id("root"))
        }
        try catalog.merge(.init(works: [recording, piece, film],
            relations: [edge("root", "piece", .performanceOf, "ニュー・シネマ・パラダイス 演奏者：桑原あい"),
                        edge("piece", "film", .soundtrackOf, "そして何よりもモリコーネの感動的な音楽")]))
        return (catalog, id("root"), id("film"))
    }

    func testJazzCoverReachesTheFilmAsWhereItsOriginalComesFrom() throws {
        let (catalog, root, film) = try paradiso(performer: "桑原あい")
        let leads = DiscoveryNavigation.leads(from: root.rawValue, catalog: catalog, known: [:], provider: nil)
        let card = try XCTUnwrap(leads.first { $0.id == film.rawValue }, "the film card stays")
        XCTAssertEqual(card.label, "原曲出自")
    }

    func testTheComposersOwnRecordingKeepsTheDirectLabel() throws {
        let (catalog, root, film) = try paradiso(performer: "エンニオ・モリコーネ")
        let leads = DiscoveryNavigation.leads(from: root.rawValue, catalog: catalog, known: [:], provider: nil)
        let card = try XCTUnwrap(leads.first { $0.id == film.rawValue })
        XCTAssertNotEqual(card.label, "原曲出自")
    }

    func testMakerComparisonSplitsCredits() {
        XCTAssertTrue(DiscoveryPathPresentation.sameMaker(["光田康典"], ["光田康典 / 植松伸夫"]))
        XCTAssertFalse(DiscoveryPathPresentation.sameMaker(["桑原あい"], ["エンニオ・モリコーネ / アンドレア・モリコーネ"]))
        XCTAssertFalse(DiscoveryPathPresentation.sameMaker([""], [""]))
    }

    // MARK: Wikipedia

    private let lemonJa = """
    『Lemon』は、米津玄師の楽曲。2018年3月14日にソニー・ミュージックレコーズから9枚目のシングルとして発売された。TBS系金曜ドラマ『アンナチュラル』の主題歌。

    == 背景 ==
    制作中に米津の祖父が亡くなり、その経験が歌詞に反映された。仮タイトルは「Memento」だった。米津は松任谷由実の影響についても語っている。\(String(repeating: "楽曲の制作経緯。", count: 40))

    == チャート成績 ==
    オリコン週間ランキングで1位を獲得した。\(String(repeating: "順位。", count: 60))

    == カバー ==
    多くの歌手にカバーされた。

    == 脚注 ==
    出典一覧。
    """
    private let otherLemon = "『Lemon』はU2の楽曲。1993年のアルバム『Zooropa』に収録された。\(String(repeating: "解説。", count: 80))"

    private func stubWikipedia(search: [String: [String]], extracts: [String: String], langlinks: [String: [String: String]] = [:]) {
        WikipediaMaterials.loader = { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let language = url.host?.components(separatedBy: ".").first ?? ""
            let object: [String: Any]
            if value("generator") == "search" {
                let titles = search[language + ":" + (value("gsrsearch") ?? "")] ?? search[language + ":*"] ?? []
                object = titles.isEmpty ? ["batchcomplete": true] : ["batchcomplete": true, "query": ["pages": titles.enumerated().map { index, title in
                    ["title": title, "index": index + 1, "extract": String((extracts[language + ":" + title] ?? "").prefix(120))] as [String: Any]
                }]]
            } else if value("prop") == "extracts|langlinks" {
                guard let text = extracts[language + ":" + (value("titles") ?? "")] else { return nil }
                let links = langlinks[language + ":" + (value("titles") ?? "")] ?? [:]
                object = ["query": ["pages": [["title": value("titles") ?? "", "extract": text,
                                               "langlinks": links.map { ["lang": $0.key, "title": $0.value] }] as [String: Any]]]]
            } else { return nil }
            return try? JSONSerialization.data(withJSONObject: object)
        }
    }

    func testSongArticleIsFoundBySearchAndLosesItsChartsAndReferences() async {
        stubWikipedia(search: ["ja:*": ["Lemon (U2の曲)", "Lemon (米津玄師の曲)"], "zh:*": []],
                      extracts: ["ja:Lemon (U2の曲)": otherLemon, "ja:Lemon (米津玄師の曲)": lemonJa])
        let topic = ResearchTopic(id: "apple:song:1", title: "Lemon", creator: "米津玄師", album: "Lemon - Single", layer: "recording")
        let pages = await WikipediaMaterials.pages(topic: topic, hints: .init())
        XCTAssertEqual(pages.count, 1)
        let page = pages[0]
        XCTAssertEqual(page.direct, true)
        XCTAssertTrue(page.url.hasPrefix("https://ja.wikipedia.org/wiki/Lemon_"))
        XCTAssertTrue(page.text.contains("Memento"))
        XCTAssertTrue(page.text.contains("【カバー】"))
        XCTAssertFalse(page.text.contains("オリコン週間"), "charts are dropped")
        XCTAssertFalse(page.text.contains("出典一覧"), "references are dropped")
        XCTAssertFalse(page.text.contains("Zooropa"), "a same-titled song by someone else is not this one")
    }

    func testTheLongerLanguageWinsForKanjiOnlyNames() async {
        let shortZh = "《Lemon》是日本歌手米津玄师的歌曲。\(String(repeating: "简介。", count: 70))"
        stubWikipedia(search: ["zh:*": ["Lemon (米津玄师歌曲)"], "ja:*": ["Lemon (米津玄師の曲)"]],
                      extracts: ["zh:Lemon (米津玄师歌曲)": shortZh, "ja:Lemon (米津玄師の曲)": lemonJa])
        let topic = ResearchTopic(id: "apple:song:2", title: "Lemon", creator: "米津玄师", album: "", layer: "recording")
        XCTAssertEqual(WikipediaMaterials.languages(topic).prefix(2), ["zh", "ja"])
        let pages = await WikipediaMaterials.pages(topic: topic, hints: .init())
        XCTAssertTrue(pages.first?.url.hasPrefix("https://ja.wikipedia.org") == true)
    }

    func testWorkArticleGivesOnlyItsMusicSectionsAndMustNameTheSong() async {
        let show = """
        『アンナチュラル』は、2018年のテレビドラマ。
        == あらすじ ==
        \(String(repeating: "物語。", count: 100))
        == 音楽 ==
        主題歌は米津玄師「Lemon」。劇伴は得田真裕が担当した。\(String(repeating: "音楽の解説。", count: 40))
        """
        stubWikipedia(search: ["ja:*": ["アンナチュラル"]], extracts: ["ja:アンナチュラル": show])
        let topic = ResearchTopic(id: "apple:song:3", title: "Lemon", creator: "米津玄師", album: "", layer: "recording")
        let pages = await WikipediaMaterials.pages(topic: topic, hints: .init(works: [.init(name: "アンナチュラル")]), songs: false)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].text.contains("得田真裕"))
        XCTAssertFalse(pages[0].text.contains("物語。物語。"), "the plot is not music")
        XCTAssertEqual(pages[0].purposes, [.context, .downstream])
    }

    func testWesternSingerInKatakanaIsReadInEnglishFirstWhenThePlannerNamesHim() {
        let topic = ResearchTopic(id: "apple:song:4", title: "Without You", creator: "ハリー・ニルソン", album: "", layer: "recording")
        XCTAssertEqual(WikipediaMaterials.languages(topic).first, "ja")
        XCTAssertEqual(WikipediaMaterials.languages(topic, names: .init(title: "Without You", artist: "Harry Nilsson")).first, "en")
        XCTAssertTrue(WikipediaMaterials.titleMatches("Without You (Badfinger song)", ["Without You"]))
        XCTAssertFalse(WikipediaMaterials.titleMatches("Without Me", ["Without You"]))
    }

    func testDirectPagesComeFirstAndShareABoundedPart() {
        let topic = ResearchTopic(id: "apple:song:1", title: "Lemon", creator: "米津玄師", album: "", layer: "recording")
        var pages = (0..<12).map { index in
            ResearchPage(url: "https://site\(index).example.org/lemon", title: "Lemon 米津玄師 インタビュー \(index)",
                         text: "米津玄師「Lemon」について。" + String(repeating: "本文。", count: 1500), purposes: [.story], searchRank: 0.9)
        }
        pages.insert(ResearchPage(url: "https://ja.wikipedia.org/wiki/Lemon", title: "Lemon (米津玄師の曲)", text: String(repeating: "記事。", count: 4000),
                                  purposes: [.story], publisher: "Wikipedia", authority: 3, searchRank: 1, direct: true), at: 5)
        let sources = ResearchMaterials.select(pages, topic: topic)
        XCTAssertEqual(sources.first?.url, "https://ja.wikipedia.org/wiki/Lemon")
        XCTAssertLessThanOrEqual(sources.first?.text.count ?? 0, 5000)
        XCTAssertLessThanOrEqual(sources.count, 8)
        XCTAssertLessThanOrEqual(sources.map(\.text.count).reduce(0, +), 20_000)
    }

    func testSearchCopyOfADirectArticleIsDropped() {
        XCTAssertEqual(ResearchMaterialCollection.wikipediaKey("https://ja.wikipedia.org/wiki/Lemon_(%E7%B1%B3%E6%B4%A5%E7%8E%84%E5%B8%AB%E3%81%AE%E6%9B%B2)"),
                       ResearchMaterialCollection.wikipediaKey("https://ja.m.wikipedia.org/wiki/Lemon_(米津玄師の曲)"))
        XCTAssertNil(ResearchMaterialCollection.wikipediaKey("https://example.org/wiki/Lemon"))
    }

    // MARK: search words

    func testPlannerKeepsEveryPurposeAndFallsBackPerPurpose() {
        let draft: [ResearchQuery] = [.init(purpose: .identity, text: "Lemon 米津玄师 歌曲"), .init(purpose: .story, text: "Lemon 米津玄师 采访 创作经过"),
                                      .init(purpose: .lineage, text: "Lemon 米津玄师 原曲"), .init(purpose: .downstream, text: "Lemon 米津玄师 翻唱")]
        let reply = """
        好的：{"names":{"title":"Lemon","artist":"米津玄師","work":"アンナチュラル"},
        "queries":[{"purpose":"identity","text":"Lemon 米津玄師 アンナチュラル 主題歌"},{"purpose":"story","text":"米津玄師 Lemon インタビュー 祖父"},
        {"purpose":"story","text":"Lemon 米津玄師 楽曲解説"},{"purpose":"wrong","text":"x y z"},{"purpose":"downstream","text":"Lemon 米津玄師 カバー"},
        {"purpose":"story","text":"米津玄師 Lemon 制作秘話"}]}
        """
        let parsed = ResearchQueryPlanner.parse(reply, draft: draft)
        XCTAssertNotNil(parsed)
        let queries = parsed?.queries ?? []
        XCTAssertEqual(queries.count, 5, "draft count + one extra story")
        XCTAssertTrue(queries.contains { $0.purpose == .lineage && $0.text == "Lemon 米津玄师 原曲" }, "a dropped purpose keeps its draft")
        XCTAssertFalse(queries.contains { $0.text == "x y z" })
        XCTAssertEqual(parsed?.hints.artist, "米津玄師")
        XCTAssertEqual(parsed?.hints.works.first?.name, "アンナチュラル")
        XCTAssertNil(ResearchQueryPlanner.parse("没有JSON", draft: draft))
    }

    func testPlannerPromptCarriesTheFactsAndTheDraft() {
        let topic = ResearchTopic(id: "apple:song:4", title: "Without You", creator: "ハリー・ニルソン", album: "Nilsson Schmilsson", layer: "recording")
        let prompt = ResearchQueryPlanner.prompt(topic: topic, knownFacts: ["Without You | 翻唱自 | Badfinger | https://musicbrainz.org/x"],
                                                 draft: [.init(purpose: .story, text: "Without You ハリー・ニルソン インタビュー")], storyOnly: true)
        XCTAssertTrue(prompt.contains("Without You | 翻唱自 | Badfinger"))
        XCTAssertFalse(prompt.contains("musicbrainz.org"), "addresses are not search words")
        XCTAssertTrue(prompt.contains("story：Without You ハリー・ニルソン インタビュー"))
    }

    func testCompactPlannerAnswerFollowsTheDraftOrder() {
        let draft: [ResearchQuery] = [.init(purpose: .identity, text: "Lemon 米津玄师 歌曲"), .init(purpose: .lineage, text: "Lemon 米津玄师 原曲"),
                                      .init(purpose: .story, text: "Lemon 米津玄师 采访"), .init(purpose: .downstream, text: "Lemon 米津玄师 翻唱")]
        let reply = #"{"t":"Lemon","a":"米津玄師","w":"アンナチュラル","q":["Lemon 米津玄師 アンナチュラル 主題歌","","米津玄師 Lemon インタビュー","Lemon 米津玄師 カバー","米津玄師 Lemon 楽曲解説"]}"#
        let parsed = ResearchQueryPlanner.parse(reply, draft: draft)
        XCTAssertEqual(parsed?.queries.map(\.purpose), [.identity, .story, .downstream, .lineage, .story])
        XCTAssertEqual(parsed?.queries[3].text, "Lemon 米津玄师 原曲", "an empty slot keeps the draft")
        XCTAssertEqual(parsed?.hints.artist, "米津玄師")
        XCTAssertEqual(parsed?.hints.works.first?.name, "アンナチュラル")
        XCTAssertEqual(WikipediaMaterials.bracketed("TVアニメ「血界戦線」"), "血界戦線")
        XCTAssertNil(WikipediaMaterials.bracketed("Xenogears"))
    }

    func testOneCardPerShowEvenWhenADiveNamesItAgain() throws {
        func id(_ name: String) -> WorkID { WorkID(rawValue: "test:dup:" + name)! }
        let catalog = CatalogStore(cacheURL: nil)
        func show(_ key: String, _ title: String, aliases: [String]) -> Work {
            Work(id: id(key), title: title, creator: "", kind: "电视剧", art: "", detail: "", url: nil,
                 discovery: .init(layer: .tv, canonicalTitle: title, aliases: aliases))
        }
        let song = Work(id: id("root"), title: "Running Up That Hill", creator: "Kate Bush", kind: "歌曲", art: "", detail: "", url: nil,
                        discovery: .init(layer: .recording, canonicalTitle: "Running Up That Hill"))
        func edge(_ to: String) -> RelationEdge {
            .init(from: id("root"), to: id(to), predicate: .usedIn, label: "用于", inverseLabel: "采用音乐",
                  source: .init(title: "线索", detail: "used in Stranger Things", url: "https://example.org/st", evidenceQuote: "used in Stranger Things"), researchRoot: id("root"))
        }
        try catalog.merge(.init(works: [song, show("a", "怪奇物语", aliases: ["Stranger Things", "怪奇物语"]), show("b", "Stranger Things", aliases: ["Stranger Things"])],
                                relations: [edge("a"), edge("b")]))
        let leads = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(leads.filter { $0.kind.rawValue.contains("剧") || $0.id.hasPrefix("test:dup:") }.count, 1)
    }

    // MARK: 深挖

    func testDeepQueriesAreNewOnlyAndAtMostThreePerGap() {
        let reply = """
        {"gaps":["同作其他主题曲","被谁翻唱"],"queries":[
        {"slot":"sibling","target":"アンナチュラル","text":"アンナチュラル 主題歌 挿入歌 一覧"},
        {"slot":"sibling","target":"アンナチュラル","text":"アンナチュラル サウンドトラック 得田真裕 インタビュー"},
        {"slot":"sibling","target":"アンナチュラル","text":"アンナチュラル 劇伴 制作"},
        {"slot":"sibling","target":"アンナチュラル","text":"アンナチュラル 第4の曲"},
        {"slot":"downstream","target":"Lemon","text":"Lemon 米津玄師 cover secondhandsongs"},
        {"slot":"story","target":"Lemon","text":"Lemon 米津玄师 采访 创作经过"},
        {"slot":"homing","target":"Lemon","text":"Lemon 米津玄師 原曲"}]}
        """
        let queries = DeepResearch.followQueries(reply, searched: ["Lemon 米津玄师 采访 创作经过"])
        XCTAssertEqual(queries.count, 5)
        XCTAssertEqual(queries.filter { $0.purpose == .context }.count, 3, "sibling gap capped at three")
        XCTAssertFalse(queries.contains { $0.text == "Lemon 米津玄师 采访 创作经过" }, "already searched")
        XCTAssertEqual(queries.last?.purpose, .lineage)
    }

    func testDeepStrategyDefaultsToFollowingLeads() {
        UserDefaults.standard.removeObject(forKey: DeepResearch.strategyKey)
        XCTAssertEqual(DeepResearch.strategy, .follow)
        UserDefaults.standard.set("rounds", forKey: DeepResearch.strategyKey)
        XCTAssertEqual(DeepResearch.strategy, .rounds)
        UserDefaults.standard.removeObject(forKey: DeepResearch.strategyKey)
    }
}
