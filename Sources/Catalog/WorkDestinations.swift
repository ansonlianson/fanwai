import Foundation

/// Where a work page sends you, by what the work is.
///
/// - Watch a video (MV, live, THE FIRST TAKE): Apple Music if the store has it, the video's own
///   page if research found one, otherwise a search on 哔哩哔哩 / YouTube. Never Douban or Wikipedia:
///   they hold no entry for a single video.
/// - Read up on a film, series, anime, book or manga: its Douban page and its Wikipedia article.
/// - A person: Douban (directors, actors) when matched, and Wikipedia.
/// - A song or album that is not in Apple Music: a search there and on 哔哩哔哩.
///
/// The work's own page always comes first; a search is offered only on a site where this kind
/// of thing lives, and the button says it is a search.
struct PageLink: Identifiable, Hashable, Sendable {
    let title: String
    let url: URL
    /// Opens a results page rather than the work's own page.
    let search: Bool
    var id: String { title }
    var symbol: String { search ? "magnifyingglass" : watch ? "play.fill" : "arrow.up.right" }
    var watch: Bool { ["Apple Music", "YouTube", "哔哩哔哩", "niconico"].contains(title) && !search }
}

@MainActor enum WorkDestinations {
    /// Exact pages looked up when a page opens (no model call): a store music video and a
    /// Wikipedia article. Kept for the session.
    struct Found: Codable, Hashable, Sendable {
        var video: URL?; var watch: URL?; var wiki: URL?; var recording: WorkID?
        var isEmpty: Bool { video == nil && watch == nil && wiki == nil && recording == nil }
    }
    private static var found: [String: Found] = [:]
    private static var foundAt: [String: Date] = [:]
    private static var countries: [String: String] = [:]
    private static var signatures: [String: String] = [:]

    static func cached(_ id: String) -> Found? { found[id] }

    /// Two buttons at most, the work's own pages first.
    static func links(_ entity: SeedGraph.Entity, library: Library, lead: Lead?) -> [PageLink] {
        restore(entity, library: library)
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
        let work = library.catalog.works[key]
        let own = (work?.url).flatMap(URL.init(string:))
        let extra = found[key.rawValue]
        let knownArticle = work?.knowledgeIdentitySource.flatMap { source -> URL? in
            guard let url = URL(string: source.url), let host = url.host,
                  host.hasSuffix(".wikipedia.org"), url.scheme == "https" else { return nil }
            return url
        }
        let name = lead?.original ?? entity.title
        let pages = work?.discovery?.pages ?? []
        var out: [PageLink] = []
        func add(_ title: String, _ url: URL?, search: Bool = false) {
            guard let url, !out.contains(where: { $0.title == title }) else { return }
            out.append(.init(title: title, url: url, search: search))
        }
        switch entity.kind {
        case .video:
            // Only addresses checked to be this very video: the store's own (same title, same
            // artist) and a YouTube page whose title names the song. The research's source link
            // is where a fact came from, not necessarily the video; unchecked, it is not offered.
            add("Apple Music", extra?.video)
            if let watch = extra?.watch, let platform = videoPlatform(watch) { add(platform, watch) }
            let query = videoQuery(name, creator: lead?.creator ?? entity.subtitle)
            add("哔哩哔哩", search("https://search.bilibili.com/all", "keyword", query), search: true)
            add("YouTube", search("https://www.youtube.com/results", "search_query", query), search: true)
        case .film, .tv, .book, .manga:
            if let own, isDouban(own) { add("豆瓣", own) }
            for page in pages where page.title != "TMDB" { add(page.title, URL(string: page.url)) }
            if let wiki = knownArticle ?? extra?.wiki { add("维基百科", wiki) }
            else { add("维基百科", wikiSearch(entity, lead: lead), search: true) }
            for page in pages where page.title == "TMDB" { add(page.title, URL(string: page.url)) }
        case .game:
            for page in pages { add(page.title, URL(string: page.url)) }
            if let wiki = knownArticle ?? extra?.wiki { add("维基百科", wiki) }
            else { add("维基百科", wikiSearch(entity, lead: lead), search: true) }
        case .person, .group:
            if let own, isDouban(own) { add("豆瓣", own) }
            if let wiki = knownArticle ?? extra?.wiki { add("维基百科", wiki) }
            else { add("维基百科", wikiSearch(entity, lead: lead), search: true) }
        case .song, .album:
            guard work?.appleMusicURL == nil else { return [] }
            // A recording lookup is an in-app selection (below), never an
            // unreliable Apple Music search universal link or a generic Bili search.
            break
        }
        return Array(out.prefix(2))
    }

    /// Looks up the exact pages once per work; returns whether anything was found. The lookup
    /// runs on its own, so a page torn down mid-flight (a zoom transition does that) neither
    /// cancels it nor leaves an empty answer behind; the next view simply waits for it.
    @discardableResult
    static func resolve(_ entity: SeedGraph.Entity, library: Library, lead: Lead?, prefetch: Bool = false) async -> Bool {
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)).rawValue
        restore(entity, library: library)
        if let done = found[key], countries[key] == library.country,
           Date().timeIntervalSince(foundAt[key] ?? .distantPast) < (done.isEmpty ? 120 : 7 * 86_400) { return !done.isEmpty }
        let joinedPrefetch = running[key] != nil && runningPrefetch[key] == true
        let lookup: Task<Found, Never>
        if let running = running[key] { lookup = running }
        else {
            let name = lead?.original ?? entity.title, creator = lead?.creator ?? entity.subtitle, country = library.country
            let workID = WorkID(rawValue: key) ?? SeedLibraryBridge.workID(entity.id)
            let work = library.catalog.work(workID)
            let own = work.url.flatMap(URL.init(string:))
            let candidates = [own, lead.flatMap { URL(string: $0.url) },
                work.discovery?.identitySource.flatMap(URL.init(string:)), lead?.identity?.identitySource.flatMap(URL.init(string:))]
                .compactMap { $0 }.filter { videoPlatform($0) == "YouTube" }
            var names = [lead?.name, lead?.original, lead?.alias, entity.title].compactMap { $0 }.filter { !$0.isEmpty }
            names = names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            let kind = entity.kind, hint = lead?.wiki
            let videoSong = library.catalog.edges.first { $0.from.rawValue == key && $0.predicate == .musicVideoOf }
                .map { library.catalog.work($0.to).discovery?.canonicalTitle ?? library.catalog.work($0.to).title }
            lookup = Task { @MainActor in
                var result = Found()
                switch kind {
                case .video:
                    async let store = storeVideo(videoSong ?? name, creator: creator, country: country, prefetch: prefetch)
                    for candidate in candidates where result.watch == nil {
                        if await youTubeNames(candidate, song: coreTitle(videoSong ?? name)) { result.watch = candidate }
                    }
                    result.video = await store
                case .film, .tv, .book, .manga, .person, .group, .game:
                    if let page = work.discovery?.pages?.first(where: { $0.title == "维基百科" }) {
                        result.wiki = URL(string: page.url)
                    } else if let source = work.knowledgeIdentitySource, URL(string: source.url)?.host?.hasSuffix(".wikipedia.org") == true {
                        result.wiki = URL(string: source.url)
                    } else { result.wiki = await wikipediaArticle(hint: hint, names: names) }
                case .song, .album:
                    if !prefetch, work.isSong, work.appleMusicURL == nil, lead?.unconfirmed != true {
                        let candidate = lead ?? Lead(id: key, name: work.title, original: work.discovery?.canonicalTitle ?? work.title,
                            kind: .song, label: "", why: "", url: "", creator: work.creator, art: work.art, identity: work.discovery)
                        if let match = await RecordingCatalogMatch.find(candidate, library: library),
                           RecordingCatalogMatch.attach(match, to: workID, identity: candidate.identity, catalog: library.catalog) {
                            result.recording = match
                            library.persist()
                        }
                    }
                }
                running[key] = nil
                runningPrefetch[key] = nil
                if prefetch, kind.isMusic, result.isEmpty { return result }
                found[key] = result; foundAt[key] = Date(); countries[key] = country
                signatures[key] = signature(entity, library: library, country: country)
                if kind == .video, let watch = result.watch { WorkArtworkStore.shared.useVerifiedVideo(watch, for: workID) }
                save(entity, library: library, result: result, country: country)
                return result
            }
            running[key] = lookup
            runningPrefetch[key] = prefetch
        }
        let result = await lookup.value
        if !prefetch, joinedPrefetch, result.isEmpty {
            found[key] = nil
            return await resolve(entity, library: library, lead: lead)
        }
        return !result.isEmpty
    }
    private static var running: [String: Task<Found, Never>] = [:]
    private static var runningPrefetch: [String: Bool] = [:]

    private struct Saved: Codable { let signature: String; let value: Found; let date: Date }
    private static func signature(_ entity: SeedGraph.Entity, library: Library, country: String) -> String {
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        return DiscoveryCore.digest([work.id.rawValue, country, work.title, work.creator, work.url ?? "",
            work.discovery?.identitySource ?? "", work.knowledgeID ?? ""])
    }
    private static func file(_ signature: String) -> URL? {
        PianwaiRuntime.cacheDirectory("WorkDestinations-v1")?.appendingPathComponent(signature + ".json")
    }
    private static func restore(_ entity: SeedGraph.Entity, library: Library) {
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)).rawValue
        let signature = signature(entity, library: library, country: library.country)
        guard found[key] == nil || countries[key] != library.country || signatures[key] != signature else { return }
        found[key] = nil
        guard let file = file(signature), let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.signature == signature,
              !saved.value.isEmpty, (0..<7 * 86_400).contains(Date().timeIntervalSince(saved.date)) else { return }
        found[key] = saved.value; foundAt[key] = saved.date; countries[key] = library.country
        signatures[key] = signature
        if entity.kind == .video, let watch = saved.value.watch, let id = WorkID(rawValue: key) {
            WorkArtworkStore.shared.useVerifiedVideo(watch, for: id)
        }
    }
    private static func save(_ entity: SeedGraph.Entity, library: Library, result: Found, country: String) {
        // A nil optional lookup may be a network/cancellation failure rather
        // than a verified absence. Never turn it into a day-long disk miss.
        guard !result.isEmpty else { return }
        let signature = signature(entity, library: library, country: country)
        guard let file = file(signature), let data = try? JSONEncoder().encode(Saved(signature: signature, value: result, date: Date())) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Whether a YouTube page is this song's video: its own title (oEmbed, no key) names the song.
    static func youTubeNames(_ url: URL, song: String) async -> Bool {
        guard !song.isEmpty, var parts = URLComponents(string: "https://www.youtube.com/oembed") else { return false }
        parts.queryItems = [.init(name: "url", value: url.absoluteString), .init(name: "format", value: "json")]
        guard let request = parts.url, let payload = await json(request) as? [String: Any],
              let title = payload["title"] as? String else { return false }
        return youTubeTitleMatches(title, song: song)
    }
    static func youTubeTitleMatches(_ title: String, song: String) -> Bool {
        let key = LeadMatch.norm(song)
        return !key.isEmpty && LeadMatch.norm(title).contains(key)
    }

    // MARK: pieces

    static func videoPlatform(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("music.apple.com") { return url.path.contains("/music-video/") ? "Apple Music" : nil }
        if on("youtube.com") || host == "youtu.be" { return url.path.contains("/results") ? nil : "YouTube" }
        if on("bilibili.com") || host == "b23.tv" { return host.hasPrefix("search.") ? nil : "哔哩哔哩" }
        if on("nicovideo.jp") { return "niconico" }
        return nil
    }
    private static func isDouban(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "douban.com" || host.hasSuffix(".douban.com")
    }
    private static func search(_ base: String, _ field: String, _ query: String) -> URL? {
        guard !query.isEmpty, var parts = URLComponents(string: base) else { return nil }
        parts.queryItems = [.init(name: field, value: query)]
        return parts.url
    }
    /// 「wacci『恋だろ』Music Video」 → 「wacci 恋だろ MV」: the platforms index the artist and the song.
    static func videoQuery(_ name: String, creator: String) -> String {
        let core = coreTitle(name), artist = mainArtist(creator)
        var parts: [String] = []
        if !artist.isEmpty, !core.localizedCaseInsensitiveContains(artist) { parts.append(artist) }
        parts.append(core)
        let kind = suffix(name)
        if !kind.isEmpty, !core.localizedCaseInsensitiveContains(kind) { parts.append(kind) }
        return parts.joined(separator: " ")
    }
    private static func mainArtist(_ creator: String) -> String {
        creator.components(separatedBy: CharacterSet(charactersIn: ",，、/／&＆")).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    /// The song inside 『』「」《》, or the name without a trailing video marker.
    static func coreTitle(_ name: String) -> String {
        for (open, close) in [("『", "』"), ("「", "」"), ("《", "》")] {
            if let a = name.range(of: open), let b = name.range(of: close, range: a.upperBound..<name.endIndex), a.upperBound < b.lowerBound {
                return String(name[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        let separators = CharacterSet(charactersIn: " -–—/／()（）")
        var value = name.trimmingCharacters(in: separators)
        var changed = true
        while changed {
            changed = false
            for tail in ["THE FIRST TAKE", "Music Video", "Official Video", "Official MV", "MV"]
            where value.lowercased().hasSuffix(tail.lowercased()) && value.count > tail.count {
                value = String(value.dropLast(tail.count)).trimmingCharacters(in: separators)
                changed = true
            }
        }
        return value.isEmpty ? name : value
    }
    /// What kind of video it is, kept in the query: 「THE FIRST TAKE」「Live」「MV」.
    private static func suffix(_ name: String) -> String {
        for marker in ["THE FIRST TAKE", "Live", "ライブ", "MV", "Music Video"] where name.localizedCaseInsensitiveContains(marker) {
            return marker == "Music Video" ? "MV" : marker
        }
        return ""
    }
    private static func wikiLanguage(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh" }
        return "en"
    }
    private static func wikiSearch(_ entity: SeedGraph.Entity, lead: Lead?) -> URL? {
        if let (language, title) = parseHint(lead?.wiki) {
            return search("https://\(language).wikipedia.org/w/index.php", "search", title)
        }
        let name = lead?.original ?? entity.title
        return search("https://\(wikiLanguage(name + entity.subtitle)).wikipedia.org/w/index.php", "search", name)
    }
    private static func parseHint(_ hint: String?) -> (String, String)? {
        guard let hint, let colon = hint.firstIndex(of: ":") else { return nil }
        let language = String(hint[..<colon]).lowercased()
        let title = String(hint[hint.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard (2...3).contains(language.count), language.allSatisfy(\.isLetter), !title.isEmpty else { return nil }
        return (language, title)
    }

    private static func json(_ url: URL) async -> Any? {
        if WikidataRequestPacer.isWikimedia(url) || url.host == "www.youtube.com" {
            guard let result = await MetadataTransport.shared.response(url, timeout: 6) else { return nil }
            return try? JSONSerialization.jsonObject(with: result.data)
        }
        if url.host == "itunes.apple.com" { do { try await ITunesRequestLimiter.shared.charge() } catch { return nil } }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await PianwaiRuntime.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The store's own music video, by the same artist.
    static func storeVideo(_ name: String, creator: String, country: String, prefetch: Bool = false) async -> URL? {
        let core = coreTitle(name), artist = mainArtist(creator)
        var terms = [core]
        if !artist.isEmpty { terms.insert(artist + " " + core, at: 0) }
        for term in terms {
            guard var parts = URLComponents(string: "https://itunes.apple.com/search") else { continue }
            parts.queryItems = [.init(name: "term", value: term), .init(name: "country", value: country),
                                .init(name: "entity", value: "musicVideo"), .init(name: "limit", value: "10")]
            if prefetch, !PrefetchQueryBudget.charge() { return nil }
            guard let url = parts.url, let payload = await json(url) as? [String: Any],
                  let results = payload["results"] as? [[String: Any]] else { continue }
            for result in results {
                guard let title = result["trackName"] as? String, let link = result["trackViewUrl"] as? String,
                      LeadMatch.same(title, core, loose: false) || LeadMatch.same(coreTitle(title), core, loose: false) else { continue }
                if !creator.isEmpty, let artist = result["artistName"] as? String, !LeadMatch.sameCreator(artist, creator) { continue }
                return URL(string: link)
            }
        }
        return nil
    }

    /// The article itself: the named one if it exists, otherwise one whose title is the work's name.
    static func wikipediaArticle(hint: String?, names: [String]) async -> URL? {
        var tries: [(String, String)] = []
        if let parsed = parseHint(hint) { tries.append(parsed) }
        for name in names {
            let language = wikiLanguage(name)
            tries.append((language, name))
            if language == "zh" { tries.append(("ja", name)) }
        }
        var seen = Set<String>()
        for (language, title) in tries.prefix(5) where seen.insert(language + ":" + title).inserted {
            guard var parts = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else { continue }
            parts.queryItems = [.init(name: "action", value: "query"), .init(name: "format", value: "json"),
                                .init(name: "redirects", value: "1"), .init(name: "converttitles", value: "1"), .init(name: "titles", value: title)]
            guard let url = parts.url, let payload = await json(url) as? [String: Any],
                  let pages = (payload["query"] as? [String: Any])?["pages"] as? [String: Any] else { continue }
            for case let page as [String: Any] in pages.values where page["missing"] == nil && page["invalid"] == nil {
                guard let found = page["title"] as? String else { continue }
                // A disambiguation page is not the work.
                if found.contains("曖昧さ回避") || found.contains("消歧义") || found.localizedCaseInsensitiveContains("disambiguation") { continue }
                // An existing hint can still name a soundtrack, artist or franchise instead
                // of this exact work. A redirect is not permission to change the target.
                guard names.contains(where: { LeadMatch.same($0, found, loose: false) }) else { continue }
                let path = found.replacingOccurrences(of: " ", with: "_")
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                return URL(string: "https://\(language).wikipedia.org/wiki/\(path)")
            }
        }
        return nil
    }
}
