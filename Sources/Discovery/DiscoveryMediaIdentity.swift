import Foundation

/// Public encyclopedia identity, separate from model assertions and cover art.
enum DiscoveryMediaIdentity {
    struct Match: Sendable { let qid: String; let source: Source; let art: String?; var pages: [Source]? = nil }
    static func match(page: [String: Any], names: [String], layer: DiscoveryIdentity.Layer, language: String) -> Match? {
        guard let title = page["title"] as? String, LeadArtwork.articleTitleMatches(title, names: names),
              let qid = (page["pageprops"] as? [String: Any])?["wikibase_item"] as? String,
              qid.range(of: #"^Q[1-9][0-9]*$"#, options: .regularExpression) != nil,
              let extract = page["extract"] as? String else { return nil }
        let words: [String]
        switch layer {
        case .game: words = ["video game", "computer game", "expansion pack", "ゲーム", "拡張パッケージ", "电子游戏", "電子遊戲"]
        case .film: words = [" film", " movie", "映画", "电影", "電影"]
        case .tv: words = ["television series", "tv series", "テレビアニメ", "テレビドラマ", "电视剧", "電視劇", "动画剧集"]
        case .manga: words = ["manga", "漫画", "漫畫"]
        case .book: words = ["novel", " book", "小説", "小说", "小說", "書籍"]
        default: return nil
        }
        let intro = extract.lowercased()
        guard words.contains(where: { intro.contains($0) }) else { return nil }
        // A film intro can mention its source novel, and a novel can mention its
        // film adaptation. Ambiguous prose is not enough to assign a hard type.
        let otherTypes: [DiscoveryIdentity.Layer: [String]] = [
            .game: ["video game", "computer game", "expansion pack", "ゲーム", "拡張パッケージ", "电子游戏", "電子遊戲"],
            .film: [" film", " movie", "映画", "电影", "電影"],
            .tv: ["television series", "tv series", "テレビアニメ", "テレビドラマ", "电视剧", "電視劇"],
            .manga: ["manga", "漫画", "漫畫"], .book: ["novel", " book", "小説", "小说", "小說"]]
        guard !otherTypes.contains(where: { $0.key != layer && $0.value.contains(where: intro.contains) }) else { return nil }
        var url = URLComponents(string: "https://\(language).wikipedia.org/w/index.php")!
        url.queryItems = [.init(name: "title", value: title)]
        guard let link = url.url?.absoluteString else { return nil }
        let art = (page["thumbnail"] as? [String: Any])?["source"] as? String
        return .init(qid: qid, source: .init(title: "Wikipedia · " + title, url: link),
            art: art.flatMap { DiscoveryCore.sourceKey($0) })
    }
    static func lookup(hint: String?, names: [String], layer: DiscoveryIdentity.Layer, edition: String = "") async -> Match? {
        guard [.game, .film, .tv, .book, .manga].contains(layer) else { return nil }
        if let structured = await structuredLookup(names: names, layer: layer, edition: edition) { return structured }
        var lookups: [(String, [URLQueryItem])] = []
        if let hint, let colon = hint.firstIndex(of: ":") {
            let language = String(hint[..<colon]), title = String(hint[hint.index(after: colon)...])
            if (2...3).contains(language.count), language.allSatisfy(\.isLetter) { lookups.append((language, [.init(name: "titles", value: title)])) }
        }
        for name in names where !name.isEmpty {
            let kana = name.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
            let han = name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let language = kana ? "ja" : han ? "zh" : "en"
            lookups.append((language, [.init(name: "generator", value: "search"), .init(name: "gsrsearch", value: name), .init(name: "gsrlimit", value: "3")]))
        }
        var seen = Set<String>()
        let requests = lookups.filter { item in
            seen.insert(item.0 + ":" + item.1.compactMap(\.value).joined(separator: "|")).inserted
        }.prefix(3)
        return await withTaskGroup(of: Match?.self) { group in
            for (language, query) in requests {
                group.addTask { await fetch(language: language, query: query, names: names, layer: layer) }
            }
            var matches: [Match] = []
            for await value in group { if let value { matches.append(value) } }
            // A multilingual alias must not pick the first of conflicting hard identities.
            guard Set(matches.map(\.qid)).count == 1 else { return nil }
            return matches.first(where: { $0.art != nil }) ?? matches.first
        }
    }

    static func structuredMatch(_ entity: [String: Any], names: [String], layer: DiscoveryIdentity.Layer, edition: String) -> Match? {
        guard let qid = entity["id"] as? String, WikiSourceIdentity.validQID(qid), entity["missing"] == nil,
              let claims = entity["claims"] as? [String: [[String: Any]]] else { return nil }
        let labels = (entity["labels"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["value"] as? String }
        let aliases = (entity["aliases"] as? [String: [[String: Any]]] ?? [:]).values.flatMap { $0 }.compactMap { $0["value"] as? String }
        guard (labels + aliases).contains(where: { value in names.contains { LeadMatch.same(value, $0, loose: false) } }) else { return nil }
        func values(_ property: String) -> [Any] {
            (claims[property] ?? []).filter { ($0["rank"] as? String) != "deprecated" }.compactMap {
                guard let snak = $0["mainsnak"] as? [String: Any], snak["snaktype"] as? String == "value" else { return nil }
                return (snak["datavalue"] as? [String: Any])?["value"]
            }
        }
        let types = Set(values("P31").compactMap { ($0 as? [String: Any])?["id"] as? String })
        let allowed: Set<String>
        switch layer {
        case .game: allowed = ["Q7889", "Q209163", "Q16070115"]
        case .film: allowed = ["Q11424", "Q20650540"]
        case .tv: allowed = ["Q5398426", "Q63952888", "Q113687694"]
        case .manga: allowed = ["Q21198342"]
        case .book: allowed = ["Q571", "Q8261", "Q7725634"]
        default: return nil
        }
        guard !types.isDisjoint(with: allowed) else { return nil }
        let expectedYears = DiscoveryCore.years(edition)
        let releaseYears = Set(values("P577").compactMap { ($0 as? [String: Any])?["time"] as? String }.flatMap { DiscoveryCore.years($0) })
        if !expectedYears.isEmpty { guard !releaseYears.isEmpty, !expectedYears.isDisjoint(with: releaseYears) else { return nil } }
        var pages: [Source] = []
        func external(_ property: String, title: String, base: String) {
            let ids = values(property).compactMap { $0 as? String }.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            if Set(ids).count == 1, let id = ids.first { pages.append(.init(title: title, url: base + id + "/")) }
        }
        if [.film, .tv].contains(layer) { external("P4529", title: "豆瓣", base: "https://movie.douban.com/subject/") }
        if layer == .film { external("P4947", title: "TMDB", base: "https://www.themoviedb.org/movie/") }
        let sitelinks = entity["sitelinks"] as? [String: [String: Any]] ?? [:]
        for language in ["zh", "ja", "en", "fr", "ko", "de"] {
            if let title = sitelinks[language + "wiki"]?["title"] as? String {
                var article = URLComponents(string: "https://\(language).wikipedia.org/w/index.php")!
                article.queryItems = [.init(name: "title", value: title)]
                if let url = article.url { pages.append(.init(title: "维基百科", url: url.absoluteString)); break }
            }
        }
        return .init(qid: qid, source: .init(title: "Wikidata", url: "https://www.wikidata.org/wiki/" + qid), art: nil, pages: pages)
    }
    private static func structuredLookup(names: [String], layer: DiscoveryIdentity.Layer, edition: String) async -> Match? {
        guard let name = names.first(where: { !$0.isEmpty }) else { return nil }
        let kana = name.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
        let han = name.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }
        let language = kana ? "ja" : han ? "zh" : "en"
        let url = try? SourceHTTP.endpoint(host: "www.wikidata.org", parameters: ["action": "wbsearchentities", "search": name, "language": language, "type": "item", "limit": "5"])
        guard let url, let search = await MetadataTransport.shared.response(url, timeout: 5),
              let data = try? JSONSerialization.jsonObject(with: search.data) as? [String: Any],
              let hits = data["search"] as? [[String: Any]] else { return nil }
        let ids = hits.compactMap { $0["id"] as? String }.filter(WikiSourceIdentity.validQID)
        guard !ids.isEmpty,
              let request = try? SourceHTTP.endpoint(host: "www.wikidata.org", parameters: ["action": "wbgetentities", "ids": ids.joined(separator: "|"), "props": "labels|aliases|claims|sitelinks", "languages": "ja|zh|en"]),
              let response = await MetadataTransport.shared.response(request, timeout: 5),
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let entities = object["entities"] as? [String: [String: Any]] else { return nil }
        let matches = entities.values.compactMap { structuredMatch($0, names: names, layer: layer, edition: edition) }
        return matches.count == 1 ? matches.first : nil
    }
    private static func fetch(language: String, query: [URLQueryItem], names: [String], layer: DiscoveryIdentity.Layer) async -> Match? {
        guard !Task.isCancelled else { return nil }
        var parts = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        parts.queryItems = [.init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "redirects", value: "1"), .init(name: "prop", value: "pageprops|extracts|pageimages"),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"), .init(name: "exsentences", value: "3"),
            .init(name: "piprop", value: "thumbnail"), .init(name: "pilicense", value: "any"), .init(name: "pithumbsize", value: "640")] + query
        guard let url = parts.url else { return nil }
        guard let response = await MetadataTransport.shared.response(url, timeout: 5), !Task.isCancelled,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let pages = (object["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        let matches = pages.values.compactMap { ($0 as? [String: Any]).flatMap { match(page: $0, names: names, layer: layer, language: language) } }
        if Set(matches.map(\.qid)).count == 1 { return matches.first(where: { $0.art != nil }) ?? matches.first }

        return nil
    }
}
