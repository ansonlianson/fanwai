import Foundation

/// What the free databases already established for a lookup, handed to the search stage:
/// the song's own Wikidata item, the works it belongs to, and the names a query planner
/// reported for it in the language of its sources.
struct ResearchHints: Codable, Sendable, Equatable {
    struct Work: Codable, Sendable, Equatable {
        let name: String; var qid: String? = nil
        /// Established by the free databases, or named by the album itself (「アニメ『ヴァイオレット・
        /// エヴァーガーデン』ピアノアレンジアルバム」); its article need not list this track.
        var known: Bool? = nil
    }
    var songQID: String? = nil
    var works: [Work] = []
    /// The song and its maker as the original sources write them ("Without You" / "Harry Nilsson"
    /// for 「Without You · ハリー・ニルソン」); from the planner, used only to find articles.
    var title: String? = nil
    var artist: String? = nil
}

/// Wikipedia read directly (anson 2026-11-18 17:00, item 1): free, no search call, no model call.
/// The song's article (in the language of its sources, and one more through the article's own
/// language links) and the music section of the work it belongs to. Most of what readers find
/// surprising is written there: Lemon's 楽曲解説 has the grandfather and the working title
/// 「Memento」, its カバー section the covers, its タイアップ the drama.
///
/// An article found by search must carry the song's title and, for a song, its singer; an article
/// reached through Wikidata or another article's language link is the same item and is trusted.
enum WikipediaMaterials {
    static let enabledKey = "research.wikipedia"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Replaced in tests (which then skip the cache and the allowance below).
    nonisolated(unsafe) static var loader: (@Sendable (URL) async -> Data?)? = nil
    /// Without a web address in the User-Agent Wikimedia allows 10 requests a minute per IP for all its
    /// sites, and the free databases' Wikidata lookups need them more: Wikipedia takes at most four
    /// new requests a minute, none for a minute after any Wikimedia 429, and saved answers cost nothing.
    static let perMinute = SourceHTTP.homepage == nil ? 4 : 60
    private actor Allowance {
        var times: [ContinuousClock.Instant] = []
        func take(_ limit: Int) -> Bool {
            times.removeAll { $0.advanced(by: .seconds(60)) < .now }
            guard times.count < limit else { return false }
            times.append(.now); return true
        }
    }
    private static let allowance = Allowance()
    static func fetch(_ url: URL) async -> Data? {
        if let loader { return await loader(url) }
        let http = PublicDatabaseHTTP.shared
        if let saved = await http.saved(url) { return saved }
        guard await !http.wikimediaThrottled(), await allowance.take(perMinute) else { return nil }
        return try? await http.get(url)
    }

    struct Article: Sendable, Equatable { let language: String; let title: String; let text: String }

    /// The languages to read, most likely first: kana → Japanese; Han → Chinese then Japanese;
    /// Latin only → English. The planner's own names can add English (a Western singer written
    /// in katakana in the Japanese store).
    static func languages(_ topic: ResearchTopic, names: ResearchHints? = nil) -> [String] {
        let text = [topic.title, topic.creator, topic.album].joined(separator: " ")
        var order: [String]
        if ResearchMaterials.hasKana(text) { order = ["ja", "en", "zh"] }
        else if text.range(of: #"\p{Han}"#, options: .regularExpression) != nil { order = ["zh", "ja", "en"] }
        else { order = ["en", "ja", "zh"] }
        if let artist = names?.artist, artist.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) == nil,
           artist.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil {
            order.removeAll { $0 == "en" }; order.insert("en", at: 0)
        }
        return order
    }

    // MARK: pages for the research packet

    /// The song's longest readable article, a second language only when the first is short (or for
    /// 深挖), and the works' music sections, interleaved so a long song article cannot crowd out the
    /// work (the packet gives all of them 9,000 characters). Never throws; an unreachable Wikipedia
    /// simply adds nothing.
    static func pages(topic: ResearchTopic, hints: ResearchHints, songs: Bool = true, works: Bool = true,
                      songLimit: Int = 2, workLimit: Int = 2) async -> [ResearchPage] {
        guard enabled else { return [] }
        async let songArticles = songs ? songArticles(topic: topic, hints: hints, limit: songLimit) : []
        async let workArticles = works ? workArticles(topic: topic, hints: hints, limit: workLimit) : []
        var songPages: [ResearchPage] = []
        for article in await songArticles {
            let text = songText(article.text)
            if songLimit <= 2, let first = songPages.first, first.text.count >= 3000 { break }
            songPages.append(page(article, text: text, purposes: [.identity, .lineage, .story, .downstream]))
        }
        var workPages: [ResearchPage] = []
        for article in await workArticles {
            let text = workText(article.text)
            guard text.count >= 200 else { continue }
            workPages.append(page(article, text: text, purposes: [.context, .downstream]))
        }
        var pages: [ResearchPage] = []
        for index in 0..<max(songPages.count, workPages.count) {
            if index < songPages.count { pages.append(songPages[index]) }
            if index < workPages.count { pages.append(workPages[index]) }
        }
        return pages.filter { $0.text.count >= 160 }
    }

    static func page(_ article: Article, text: String, purposes: [ResearchQuery.Purpose]) -> ResearchPage {
        ResearchPage(url: url(article), title: article.title, text: text, purposes: purposes,
                     publisher: "Wikipedia", authority: 3, searchRank: 1, direct: true)
    }
    static func url(_ article: Article) -> String {
        let path = article.title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? article.title
        return "https://\(article.language).wikipedia.org/wiki/" + path
    }

    // MARK: finding the articles
    //
    // Wikimedia limits clients since 2026 (https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits):
    // a client without a web address in its User-Agent gets 10 requests a minute per IP, shared by
    // every Wikimedia site (the Wikidata lookups of the free databases included). A lookup therefore
    // spends two requests per language: one search that returns each candidate's opening paragraph,
    // one read that returns the whole text with its language links. Measured 11-18: one probe of 59
    // songs at one request per 0.55 s was throttled for 15 minutes.

    /// The song's articles, longest readable text first. Kanji-only names (米津玄師) could be Chinese or
    /// Japanese, so both are searched side by side; otherwise only the likeliest language. A second
    /// language comes through the first article's own links when the first is short, or for 深挖.
    static func songArticles(topic: ResearchTopic, hints: ResearchHints, limit: Int) async -> [Article] {
        let order = Array(languages(topic, names: hints).prefix(3))
        let ambiguous = order.first == "zh" && !ResearchMaterials.hasKana(topic.title + topic.creator)
        let primary = Array(order.prefix(ambiguous || limit > 2 ? 2 : 1))
        var found: [(article: Article, links: [String: String])] = []
        if let qid = hints.songQID, let links = await sitelinks(qid) {
            let languages = primary.filter { links[$0] != nil }
            found = await reads(languages.isEmpty ? Array(order.filter { links[$0] != nil }.prefix(1)) : languages, titles: links)
        }
        if found.isEmpty {
            found = await withTaskGroup(of: (Int, (Article, [String: String])?).self) { group in
                for (index, language) in primary.enumerated() {
                    group.addTask { (index, await searchSong(language, topic: topic, hints: hints)) }
                }
                var values: [Int: (Article, [String: String])] = [:]
                for await (index, article) in group { if let article { values[index] = article } }
                return values.keys.sorted().compactMap { values[$0] }.map { (article: $0.0, links: $0.1) }
            }
        }
        var ranked = found.sorted { songText($0.article.text).count > songText($1.article.text).count }
        // One more language through the article's own links (no search needed).
        if let first = ranked.first, ranked.count < limit, limit > 2 || songText(first.article.text).count < 3000 {
            let missing = order.filter { language in !ranked.contains { $0.article.language == language } && first.links[language] != nil }
            if let language = missing.first { ranked += await reads([language], titles: first.links) }
            ranked.sort { songText($0.article.text).count > songText($1.article.text).count }
        }
        return Array(ranked.map(\.article).prefix(limit))
    }
    /// Whole articles in these languages, read side by side (each language is its own host).
    private static func reads(_ languages: [String], titles: [String: String]) async -> [(article: Article, links: [String: String])] {
        await withTaskGroup(of: (Int, (Article, [String: String])?).self) { group in
            for (index, language) in languages.enumerated() {
                guard let title = titles[language] else { continue }
                group.addTask { (index, await read(language, title).map { (Article(language: language, title: $0.title, text: $0.text), $0.links) }) }
            }
            var values: [Int: (Article, [String: String])] = [:]
            for await (index, article) in group { if let article { values[index] = article } }
            return values.keys.sorted().compactMap { values[$0] }.map { (article: $0.0, links: $0.1) }
        }
    }

    static func workArticles(topic: ResearchTopic, hints: ResearchHints, limit: Int) async -> [Article] {
        var articles: [Article] = []
        var seen = Set<String>()
        let songs = songNames(topic, hints)
        for work in hints.works where articles.count < limit {
            // 「TVアニメ「血界戦線」」 is 血界戦線.
            let name = bracketed(work.name) ?? work.name
            guard seen.insert(LeadMatch.norm(name)).inserted else { continue }
            // The song's languages; a work written in kana is Japanese whatever the song's credit looks like,
            // and kanji alone could be either (two languages then).
            var order = languages(topic, names: hints)
            if ResearchMaterials.hasKana(name) { order.removeAll { $0 == "ja" }; order.insert("ja", at: 0) }
            let ambiguous = !ResearchMaterials.hasKana(name + topic.title + topic.creator + topic.album) && name.range(of: #"\p{Han}"#, options: .regularExpression) != nil
            var found: Article?
            if let qid = work.qid, let links = await sitelinks(qid), let language = order.first(where: { links[$0] != nil }) {
                found = await reads([language], titles: links).first?.article
            }
            if found == nil {
                // The likeliest language only (two requests); the work must name this song unless the
                // databases or the album itself established it. The article may carry the work's local
                // name (ゼノギアス for Xenogears) when its opening gives the other.
                for language in order.prefix(limit > 2 || ambiguous ? 2 : 1) {
                    guard let candidates = await candidates(language, name),
                          let title = candidates.enumerated().first(where: { index, item in
                              titleMatches(item.title, [name]) || index == 0 && mentions(String(item.intro.prefix(300)), [name])
                          })?.element.title,
                          let article = await read(language, title), work.known == true || mentions(article.text, songs) else { continue }
                    found = .init(language: language, title: article.title, text: article.text); break
                }
            }
            if let found { articles.append(found) }
        }
        return articles
    }
    static func bracketed(_ name: String) -> String? {
        for (open, close) in [("「", "」"), ("『", "』"), ("《", "》")] {
            if let a = name.range(of: open), let b = name.range(of: close, range: a.upperBound..<name.endIndex), a.upperBound < b.lowerBound {
                return String(name[a.upperBound..<b.lowerBound])
            }
        }
        return nil
    }

    /// One search, a second only when the first found no article of that title. `intitle:` keeps the
    /// singer's albums and the singer's own article out of the four results (「美しい人 坂本真綾」 alone
    /// returns the albums; with `intitle:"美しい人"` the song's article is second, after the disambiguation page).
    private static func searchSong(_ language: String, topic: ResearchTopic, hints: ResearchHints) async -> (Article, [String: String])? {
        let names = songNames(topic, hints)
        let singers = credits(topic, hints)
        guard let name = names.first else { return nil }
        let quoted = name.replacingOccurrences(of: "\"", with: " ")
        let queries = singers.first.map { ["intitle:\"\(quoted)\" \($0)", name + " " + $0] } ?? ["intitle:\"\(quoted)\""]
        for query in queries {
            guard let candidates = await candidates(language, query) else { return nil }
            // A same-titled song by someone else is not this one: its opening must name the singer.
            let match = candidates.first { titleMatches($0.title, names) && (singers.isEmpty || mentions($0.title + " " + $0.intro, singers)) }
            if let match {
                guard let article = await read(language, match.title) else { return nil }
                return (Article(language: language, title: article.title, text: article.text), article.links)
            }
            if candidates.contains(where: { titleMatches($0.title, names) && !$0.intro.isEmpty && $0.intro.count > 60 }) { return nil }
        }
        return nil
    }

    static func songNames(_ topic: ResearchTopic, _ hints: ResearchHints) -> [String] {
        var names = DatabaseTitleKeys.keys(topic.title) + [ResearchMaterials.versionParts(topic.title).bare, topic.canonicalTitle ?? ""]
        if let title = hints.title { names.insert(title, at: 0) }
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 1 && seen.insert(LeadMatch.norm($0)).inserted && !LeadMatch.norm($0).isEmpty }
    }
    static func credits(_ topic: ResearchTopic, _ hints: ResearchHints) -> [String] {
        var names = topic.creator.components(separatedBy: CharacterSet(charactersIn: ",，、&＆/／;；"))
            .flatMap { $0.components(separatedBy: " feat. ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        if let artist = hints.artist { names.insert(artist, at: 0) }
        var seen = Set<String>()
        return names.filter { LeadMatch.norm($0).count >= 2 && seen.insert(LeadMatch.norm($0)).inserted }
    }
    /// 「Lemon (米津玄師の曲)」 is the article 「Lemon」 about a song.
    static func titleMatches(_ title: String, _ names: [String]) -> Bool {
        let bare = title.replacingOccurrences(of: #"\s*[(（][^)）]*[)）]\s*$"#, with: "", options: .regularExpression)
        return names.contains { ScriptFold.sameTitle(bare, $0) }
    }
    static func mentions(_ text: String, _ names: [String]) -> Bool {
        let body = LeadMatch.norm(text)
        return names.contains { name in let key = LeadMatch.norm(name); return key.count >= 2 && body.contains(key) }
    }

    // MARK: choosing the text

    private static let junk = #"(?i)脚注|出典|注釈|参考|外部リンク|関連項目|チャート|記録|受賞|収録曲|収録内容|演奏|クレジット|スタッフ|キャスト|personnel|track\s*listing|charts?|certifications?|references|external links|see also|notes|credits|accolades|sales|注释|参考资料|外部链接|曲目|销量|排行|榜单|获奖|相关条目|参见"#
    private static let music = #"(?i)主題歌|音楽|楽曲|テーマ|サウンドトラック|劇伴|挿入歌|music|soundtrack|theme|score|主题曲|音乐|歌曲|插曲|片头|片尾|配乐|原声"#

    /// Splits a plain extract into its lead and its「== heading ==」sections.
    static func sections(_ text: String) -> [(heading: String, body: String)] {
        var result: [(String, String)] = [("", "")]
        for line in text.components(separatedBy: "\n") {
            if let match = line.range(of: #"^=+\s*(.*?)\s*=+\s*$"#, options: .regularExpression) {
                result.append((String(line[match]).trimmingCharacters(in: CharacterSet(charactersIn: "= ")), ""))
            } else {
                result[result.count - 1].1 += line + "\n"
            }
        }
        return result.map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    /// A song article without its charts, awards, track lists and references; at most 6,000 characters.
    static func songText(_ text: String, limit: Int = 6000) -> String {
        var parts: [String] = []
        for (heading, body) in sections(text) where !body.isEmpty {
            if !heading.isEmpty, heading.range(of: junk, options: .regularExpression) != nil { continue }
            parts.append(heading.isEmpty ? body : "【" + heading + "】\n" + body)
        }
        return String(parts.joined(separator: "\n\n").prefix(limit))
    }
    /// A work article's opening and its music sections only; at most 4,000 characters.
    static func workText(_ text: String, limit: Int = 4000) -> String {
        let all = sections(text)
        let musical = all.filter { !$0.heading.isEmpty && $0.heading.range(of: music, options: .regularExpression) != nil && !$0.body.isEmpty }
        guard !musical.isEmpty else { return "" }
        let lead = String((all.first?.body ?? "").prefix(500))
        let body = musical.map { "【" + $0.heading + "】\n" + $0.body }.joined(separator: "\n\n")
        return String((lead + "\n\n" + body).prefix(limit))
    }

    // MARK: Wikipedia and Wikidata calls

    private static func api(_ language: String, _ params: [String: String]) -> URL {
        PublicDatabaseHTTP.endpoint("\(language).wikipedia.org", "/w/api.php", params.merging(["format": "json", "formatversion": "2"]) { a, _ in a })
    }
    /// One request: up to four articles found for the words, in search order, with their opening paragraph.
    static func candidates(_ language: String, _ query: String) async -> [(title: String, intro: String)]? {
        guard let data = await fetch(api(language, ["action": "query", "generator": "search", "gsrsearch": query, "gsrlimit": "4", "gsrnamespace": "0",
                                                      "prop": "extracts", "exintro": "1", "explaintext": "1", "exlimit": "4", "redirects": "1"])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let pages = (object["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return object["batchcomplete"] != nil ? [] : nil }
        return pages.sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
            .compactMap { page in (page["title"] as? String).map { (title: $0, intro: page["extract"] as? String ?? "") } }
    }
    /// One request: the whole plain text of an article and its language links.
    static func read(_ language: String, _ title: String) async -> (title: String, text: String, links: [String: String])? {
        guard let data = await fetch(api(language, ["action": "query", "prop": "extracts|langlinks", "explaintext": "1", "exsectionformat": "wiki",
                                                      "lllimit": "max", "titles": title, "redirects": "1"])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = ((object["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              let text = page["extract"] as? String, text.count >= 200 else { return nil }
        var links: [String: String] = [:]
        for link in page["langlinks"] as? [[String: Any]] ?? [] {
            if let lang = link["lang"] as? String, let name = link["title"] as? String { links[lang] = name }
        }
        return (page["title"] as? String ?? title, String(text.prefix(120_000)), links)
    }
    static func sitelinks(_ qid: String) async -> [String: String]? {
        guard WikiSourceIdentity.validQID(qid),
              let data = await fetch(PublicDatabaseHTTP.endpoint("www.wikidata.org", "/w/api.php", ["action": "wbgetentities", "ids": qid, "props": "sitelinks",
                                                                                                         "sitefilter": "jawiki|zhwiki|enwiki", "format": "json"])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (object["entities"] as? [String: Any])?[qid] as? [String: Any],
              let links = entity["sitelinks"] as? [String: [String: Any]] else { return nil }
        var result: [String: String] = [:]
        for (site, link) in links { if let title = link["title"] as? String { result[String(site.dropLast(4))] = title } }
        return result
    }
}
