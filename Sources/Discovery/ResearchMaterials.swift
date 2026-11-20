import Foundation
import CryptoKit

/// Search inputs are catalog observations, never answers or known target names.
/// This Foundation-only layer is shared by the app and the migration harness.
struct ResearchTopic: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let creator: String
    let album: String
    let layer: String
    var canonicalTitle: String? = nil
    var catalogue: String? = nil
    var movement: String? = nil

    var key: String {
        SHA256.hash(data: Data(["materials-v1", id, title, creator, album, layer,
            canonicalTitle ?? "", catalogue ?? "", movement ?? ""].joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct ResearchQuery: Codable, Hashable, Sendable {
    enum Purpose: String, Codable, Sendable { case identity, lineage, story, downstream, context }
    let purpose: Purpose
    let text: String
}

struct ResearchPage: Codable, Sendable {
    let url: String
    let title: String
    let text: String
    let purposes: [ResearchQuery.Purpose]
    var publisher: String? = nil
    var authority: Int? = nil
    var searchRank: Double? = nil
    var publishedAt: String? = nil
    /// Read directly (a Wikipedia article), not returned by a web search.
    var direct: Bool? = nil
}

struct ResearchSource: Codable, Sendable {
    let id: String
    let url: String
    let title: String
    let publisher: String
    let text: String
    let purposes: [ResearchQuery.Purpose]
    var authority: Int? = nil
    var publishedAt: String? = nil
}

/// Readable, bounded material remains reusable when only the writer changes.
/// A search summary is not a page body and never enters `sources`.
struct ResearchMaterialPacket: Codable, Sendable {
    var version = 1
    let topic: ResearchTopic
    let queries: [ResearchQuery]
    let sources: [ResearchSource]
    let fetchedAt: Date
    let searchSeconds: Double
    let fetchSeconds: Double
    let searches: Int
    let fetches: Int
    var selectionSeconds: Double? = nil
}

enum ResearchMaterials {
    /// Variants are for finding catalog names in evidence, never replacement
    /// identities for the recording or its edition.
    static func observedNameVariants(_ topic: ResearchTopic) -> [String] {
        let bare = topic.title.replacingOccurrences(of: #"\s*[(（](?:feat\.?|live|ライブ|201\d|202\d)[^)）]*[)）]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s*[-–—]\s*[^-–—]*(?:Live|ライブ)[^-–—]*[-–—]?\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let song = versionParts(topic.title).bare
        // "Suite bergamasque: III. Clair de lune" → "Clair de lune"; only a numbered movement has this name.
        let last = song.components(separatedBy: ": ").last ?? song
        let movement = last.replacingOccurrences(of: #"^\s*(?:[IVXivx]+|\d+)\.\s+"#, with: "", options: .regularExpression)
        return [topic.title, topic.canonicalTitle ?? "", bare, bare.components(separatedBy: ": ").last ?? bare, song, last, movement == last ? "" : movement]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func normalized(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return String(simplified.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Kana letters; the middle dot (・) also separates the parts of a transliterated Western name.
    static func hasKana(_ text: String) -> Bool {
        text.range(of: #"[\u3041-\u309F\u30A1-\u30FA\u30FC-\u30FF]"#, options: .regularExpression) != nil
    }

    /// For a Latin-script title whose credit is a Chinese transliteration of a Western name
    /// (Han characters joined by a middle dot, no kana): the Latin-script co-credit if there is
    /// one, else an empty credit. Nil when the credit is not of that kind.
    static func westernCredit(title: String, creator: String) -> String? {
        guard title.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) == nil, !hasKana(creator),
              creator.range(of: #"\p{Han}[·‧・•]\p{Han}"#, options: .regularExpression) != nil else { return nil }
        let parts = creator.components(separatedBy: CharacterSet(charactersIn: ",，、&＆/／")).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first { $0.range(of: #"\p{Han}"#, options: .regularExpression) == nil && $0.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil } ?? ""
    }

    /// A piano, orchestral or acoustic version re-arranges the song; a live take, a TV size or a
    /// remaster only replays it. The word must sit in brackets or lead the title ("Piano: …"),
    /// so that "Piano Sonata No. 8" is not taken for a version of anything.
    static func isArrangedVersion(_ title: String) -> Bool {
        let words = #"(?i)\b(?:piano|orchestra(?:l)?|acoustic|instrumental|arrang\w*|strings|jazz|music\s*box|symphon\w*|unplugged)\b|ピアノ|オーケストラ|アコースティック|オルゴール|钢琴|鋼琴|管弦|交响|交響"#
        if title.range(of: #"(?i)^\s*(?:piano|orchestra|orchestral|acoustic|instrumental)\s*[:：]"#, options: .regularExpression) != nil { return true }
        let brackets = try! NSRegularExpression(pattern: #"[(（\[]([^)）\]]*)[)）\]]"#)
        return brackets.matches(in: title, range: NSRange(title.startIndex..., in: title)).contains { match in
            Range(match.range(at: 1), in: title).map { title[$0].range(of: words, options: .regularExpression) != nil } ?? false
        }
    }

    /// A version of a song (piano, orchestral, acoustic, TV size, a "… Version" in brackets)
    /// is searched by the song it performs: the bare title, plus what the brackets say
    /// about where it comes from ("FINAL FANTASY X Piano Collections Version" → FINAL FANTASY X).
    static func versionParts(_ title: String) -> (bare: String, origin: String, isVersion: Bool) {
        let words = #"(?i)\b(?:piano collections?|piano|orchestra(?:l)?|acoustic|instrumental|arrang\w*|remaster\w*|\w*mix|tv\s*size|movie|live|version|ver\.?|edit)\b|ライブ|アコースティック|ピアノ|オーケストラ|バージョン|现场|現場|钢琴|管弦"#
        let take = RecordingVersion.split(title)
        var bare = take?.title ?? title, origin = "", isVersion = take != nil
        if let prefix = bare.range(of: #"(?i)^\s*(?:piano|orchestra|orchestral|acoustic|live|instrumental)\s*[:：]\s*"#, options: .regularExpression) {
            bare.removeSubrange(prefix); isVersion = true
        }
        let brackets = try! NSRegularExpression(pattern: #"\s*[(（\[]([^)）\]]*)[)）\]]"#)
        for match in brackets.matches(in: bare, range: NSRange(bare.startIndex..., in: bare)).reversed() {
            guard let whole = Range(match.range, in: bare), let inner = Range(match.range(at: 1), in: bare) else { continue }
            let content = String(bare[inner])
            guard content.range(of: words, options: .regularExpression) != nil else { continue }
            let rest = content.replacingOccurrences(of: words, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            // Singers named in the brackets are not where the song comes from.
            if rest.count >= 3, !rest.contains("&"), rest.range(of: #"(?i)vocals?|feat"#, options: .regularExpression) == nil, origin.isEmpty { origin = rest }
            bare.removeSubrange(whole); isVersion = true
        }
        return (bare.trimmingCharacters(in: .whitespaces), origin, isVersion)
    }

    static func queryPlan(_ topic: ResearchTopic, storyOnly: Bool = false) -> [ResearchQuery] {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: " ")
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let original = clean(topic.title)
        // Query variants remove presentation decorations only. They never
        // replace recording identity or become an asserted original work.
        let bare = original.replacingOccurrences(of: #"\s*[(（](?:feat\.?|live|ライブ|201\d|202\d)[^)）]*[)）]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        let short = clean(topic.canonicalTitle ?? bare.components(separatedBy: ": ").last ?? bare)
        // A Western artist listed under a Chinese transliteration (克莉丝汀‧肯诺维斯、Idina Menzel) is
        // searched in English, by the name pages actually print; the middle dot is not kana.
        let western = westernCredit(title: topic.title, creator: topic.creator)
        let creator = clean(western ?? topic.creator.components(separatedBy: ",").first ?? topic.creator)
        let combinedText = western == nil ? [topic.title, topic.creator, topic.album].joined() : topic.title
        let hasKana = Self.hasKana(combinedText)
        let asian = hasKana || combinedText.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let name = String(RecordingVersion.searchTitle(short.isEmpty ? original : short).prefix(76))
        let credit = String(creator.prefix(42))
        let album = clean(topic.album).replacingOccurrences(of: #"\s*[（(][^）)]*(?:soundtrack|Netflix|サウンドトラック)[^）)]*[）)]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        let context = album.isEmpty ? creator : String(RecordingVersion.searchTitle(album).prefix(76)) + " " + credit
        let screen = ["game", "film", "tv", "book", "manga"].contains(topic.layer)
        let contextQuery = screen ? name + (asian ? " 原作 漫画 小説 音楽" : " original adaptation soundtrack")
            : [topic.catalogue, topic.movement].compactMap { $0 }.contains(where: { !$0.isEmpty })
                ? name + " " + [topic.catalogue, topic.movement].compactMap { $0 }.joined(separator: " ") : context + (hasKana ? " インタビュー 制作" : asian ? " 采访 创作 幕后 インタビュー" : " interview inspiration")
        // A classical movement ("Suite bergamasque, L. 75: III. Clair de lune") is played by many
        // people; it is searched by the piece and the work it belongs to, not by this performer.
        let classical = original.range(of: #"(?i)\b(?:op\.|bwv|k\.|l\.)\s*\d+|\bno\.\s*\d+\s+in\s+[a-g]\b|[:：]\s*(?:[IVX]+\.|\d+\.)\s"#, options: .regularExpression) != nil
        if classical, !screen {
            let pieces = original.components(separatedBy: ": ")
            let piece = (pieces.last ?? original).replacingOccurrences(of: #"^\s*(?:[IVXivx]+|\d+)\.\s*"#, with: "", options: .regularExpression)
            let parent = pieces.count > 1 ? pieces.dropLast().joined(separator: " ") : ""
            let values: [(ResearchQuery.Purpose, String)] = [
                (.identity, piece + " " + parent),
                (.lineage, piece + " " + parent + " composer history inspired by poem"),
                (.story, piece + " " + parent + " story behind composition"),
                (.downstream, piece + " used in film soundtrack movie scene"),
                (.context, original + " " + credit)
            ]
            var seen: Set<String> = []
            return (storyOnly ? values.filter { [.story, .context].contains($0.0) } : values).compactMap { purpose, text in
                let query = String(text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
                guard query.count > 2, seen.insert(query).inserted else { return nil }
                return ResearchQuery(purpose: purpose, text: query)
            }
        }
        let version = versionParts(original)
        if version.isVersion, !RecordingVersion.isFirstTake(original), !screen, !version.bare.isEmpty {
            // 归位 (AHA-PLAN §3.2): the performer of a piano or orchestral version is not who
            // wrote the song, so the song and its source are searched without the performer.
            let song = String((version.bare.components(separatedBy: ": ").last ?? version.bare).prefix(76))
            let from = version.origin.isEmpty ? album : version.origin
            let values: [(ResearchQuery.Purpose, String)] = [
                (.identity, song + " " + from + (asian ? " 原曲" : " original song")),
                (.lineage, song + " " + from + (hasKana ? " 原曲 作曲 ゲーム アニメ 主題歌" : asian ? " 原曲 作曲 游戏 动画 主题曲" : " original soundtrack composer game anime film theme")),
                (.story, song + " " + from + (hasKana ? " インタビュー 制作秘話" : asian ? " 幕后 故事 采访" : " interview story behind the song")),
                (.downstream, original + " " + credit),
                (.context, contextQuery)
            ]
            var seen: Set<String> = []
            return (storyOnly ? values.filter { [.story, .context].contains($0.0) } : values).compactMap { purpose, text in
                let query = String(text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
                guard query.count > 2, seen.insert(query).inserted else { return nil }
                return ResearchQuery(purpose: purpose, text: query)
            }
        }
        let allValues: [(ResearchQuery.Purpose, String)] = [
            (.identity, name + " " + credit),
            (.lineage, name + " " + credit + (hasKana ? " 原曲 原作 出典" : asian ? " 原曲 改编 原作 主題歌" : " original melody sample adaptation")),
            // Anecdote words find the "it happened because…" stories readers remember (AHA-PLAN §3.2 幕后).
            (.story, name + " " + credit + (hasKana ? " インタビュー 制作秘話 エピソード" : asian ? " 幕后 故事 采访 创作经过" : " interview story behind the song")),
            (.downstream, name + " " + credit + (hasKana ? " サンプリング カバー 使用 アレンジ" : asian ? " 翻唱 采样 改编 カバー" : " sampled by covered adaptation")),
            (.context, contextQuery)
        ]
        let values = storyOnly ? allValues.filter { [.story, .context].contains($0.0) } : allValues
        var seen: Set<String> = []
        return values.compactMap { purpose, text in
            let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard query.count > 2, seen.insert(query).inserted else { return nil }
            return ResearchQuery(purpose: purpose, text: query)
        }
    }

    static func safeURL(_ raw: String) -> String? {
        guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, !["localhost", "127.0.0.1", "::1"].contains(host),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal") else { return nil }
        c.scheme = "https"; c.host = host
        if c.port == 80 { c.port = nil }
        // Hash routes can identify different works. Only ordinary document
        // anchors can be removed without changing the target.
        if let fragment = c.fragment, !fragment.hasPrefix("/"), !fragment.hasPrefix("!/") { c.fragment = nil }
        c.queryItems = c.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased()) }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.string
    }

    /// `maxPages` and `totalCharacters` stay 8 and 20,000 for the everyday lookup (the cost of the
    /// two model calls follows them); 深挖 reads more. Pages read directly (Wikipedia) come first and
    /// share at most `directCharacters` of the total, so web pages still have room.
    static func select(_ pages: [ResearchPage], topic: ResearchTopic, maxPages: Int = 8, totalCharacters: Int = 20_000,
                       directCharacters: Int = 9_000) -> [ResearchSource] {
        let shortTitle = topic.title.replacingOccurrences(of: #"\s*[(（](?:feat\.?|live|ライブ|201\d|202\d)[^)）]*[)）]"#,
            with: "", options: [.regularExpression, .caseInsensitive]).components(separatedBy: ": ").last ?? topic.title
        let titleTerms = ([topic.title, topic.canonicalTitle ?? "", shortTitle] + observedNameVariants(topic))
            .map(normalized).filter { $0.count > 2 }
        let creator = normalized(topic.creator.components(separatedBy: ",").first ?? topic.creator)
        let clues = ["原曲", "出典", "原作", "編曲", "サンプリング", "sample", "arrang", "recompos",
            "interview", "インタビュー", "対談", "访谈", "採訪", "録音", "制作", "inspir"]
        func score(_ text: String) -> Int {
            let normalizedText = normalized(text), lower = text.lowercased()
            return titleTerms.reduce(0) { $0 + (normalizedText.contains($1) ? 12 : 0) }
                + (!creator.isEmpty && normalizedText.contains(creator) ? 3 : 0)
                + clues.filter { lower.contains($0) }.count * 2
        }
        var merged: [String: ResearchPage] = [:]
        for page in pages {
            guard let url = safeURL(page.url), page.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 160 else { continue }
            let address = URL(string: url), host = address?.host?.lowercased() ?? "", path = address?.path ?? ""
            // A search engine's authority describes its index, not authorship
            // of the work. Aggregated search/shopping pages are not evidence.
            let engine = host.range(of: #"(^|\.)(google\.[a-z.]+|bing\.com|duckduckgo\.com|search\.baidu\.com)$"#, options: .regularExpression) != nil
            if engine && (path.hasPrefix("/search") || path.hasPrefix("/shopping")) { continue }
            let old = merged[url], body = old.map { $0.text.count > page.text.count ? $0.text : page.text } ?? page.text
            let purposes = ResearchQuery.Purpose.allCasesInOrder.filter { old?.purposes.contains($0) == true || page.purposes.contains($0) }
            merged[url] = ResearchPage(url: url, title: page.title, text: String(body.prefix(80_000)), purposes: purposes,
                publisher: page.publisher ?? old?.publisher, authority: page.authority ?? old?.authority,
                searchRank: max(page.searchRank ?? 0, old?.searchRank ?? 0), publishedAt: page.publishedAt ?? old?.publishedAt,
                direct: page.direct == true || old?.direct == true ? true : nil)
        }
        var scored: [(page: ResearchPage, score: Int)] = []
        for page in merged.values {
            if page.title.range(of: #"^\(\d+ページ目\)"#, options: .regularExpression) != nil { continue }
            if URL(string: page.url)?.path.hasPrefix("/subcategory/") == true { continue }
            let body = normalized(page.title + " " + page.text), album = normalized(topic.album)
            let credited = creator.count >= 2 && body.contains(creator)
            let inAlbum = album.count >= 2 && body.contains(album)
            let named = titleTerms.contains(where: { $0.count >= 2 && body.contains($0) })
            let musicContext = ["music", "song", "album", "composer", "piano", "violin", "音楽", "原曲", "楽曲", "演奏", "作曲", "歌", "曲", "唱", "词", "編曲", "编曲", "专辑", "單曲", "单曲"].contains { page.text.lowercased().contains($0) }
            guard page.direct == true || credited || inAlbum || (named && (topic.layer != "recording" || musicContext)) else { continue }
            // Long pages mention more generic keywords; their length is not
            // evidence of relevance. Retain the search engine's relevance signal
            // instead of filling each purpose's quota with incidental matches.
            let rank = score(page.title) * 2 + (credited ? 8 : 0) + (inAlbum ? 8 : 0)
                + Int((page.searchRank ?? 0) * 24) + min(6, score(page.text) / 4)
            scored.append((page, rank))
        }
        let ranked = scored.sorted { $0.score == $1.score ? $0.page.url < $1.page.url : $0.score > $1.score }.map(\.page)
        var selected: [ResearchPage] = [], hosts: [String: Int] = [:]
        func eligible(_ page: ResearchPage) -> Bool {
            let host = URL(string: page.url)?.host ?? ""
            return selected.count < maxPages && !selected.contains(where: { $0.url == page.url }) && hosts[host, default: 0] < 2
        }
        func reserve(_ page: ResearchPage) {
            guard eligible(page) else { return }
            let host = URL(string: page.url)?.host ?? ""
            selected.append(page); hosts[host, default: 0] += 1
        }
        // Articles read directly were chosen for this song; they go first, in the order given.
        let directOrder = pages.compactMap { page in page.direct == true ? safeURL(page.url) : nil }
        for url in directOrder { if let page = ranked.first(where: { $0.url == url }) { reserve(page) } }
        // Keep a direct edition/track reference before essays and storefront
        // descriptions consume the packet. These are observed catalog terms.
        let albumKey = normalized(topic.album)
        func editionScore(_ page: ResearchPage) -> Double {
            // A focused track listing is more useful than a long interview
            // that merely quotes the album title in its headline.
            Double(albumKey.count) / Double(max(1, normalized(page.title).count)) * 100
                + Double(min(3, max(0, page.authority ?? 1))) * 5
        }
        let editions = ranked.filter { normalized($0.title).contains(albumKey) }
        let higherQualityEditions = editions.filter { ($0.authority ?? -1) >= 3 }
        if albumKey.count >= 6, let edition = (higherQualityEditions.isEmpty ? editions : higherQualityEditions)
            .max(by: { editionScore($0) < editionScore($1) }) { reserve(edition) }
        // Reserve a local source/origin passage before generic storefronts and
        // several language versions of the same catalogue consume the packet.
        // This selects material only; these cues do not create relationships.
        func lineageScore(_ page: ResearchPage) -> Int {
            guard page.purposes.contains(.lineage) else { return 0 }
            let characters = Array(page.text)
            let shortNames = observedNameVariants(topic).filter { $0.count >= 4 }
            var local = 0
            for name in shortNames {
                guard let range = page.text.range(of: name, options: .caseInsensitive) else { continue }
                let offset = page.text.distance(from: page.text.startIndex, to: range.lowerBound)
                let window = String(characters[max(0, offset - 180)..<min(characters.count, offset + name.count + 240)])
                let direct = #"原曲\s*[:：]|出典\s*[:：]|原作\s*[:：]|サンプリング|\bsampl(?:e|es|ed|ing)\b|based on|arrang(?:ed|ement)\s+(?:of|by)"#
                let derived = "より[「『《\\\"\\s]*" + NSRegularExpression.escapedPattern(for: name)
                if window.range(of: direct, options: [.regularExpression, .caseInsensitive]) != nil { local = max(local, 2) }
                if window.range(of: derived, options: [.regularExpression, .caseInsensitive]) != nil { local = max(local, 2) }
            }
            return local == 0 ? 0 : local * 20 + min(3, max(0, page.authority ?? 1)) * 2
        }
        if let lineage = ranked.filter({ lineageScore($0) > 0 })
            .max(by: { lineageScore($0) < lineageScore($1) }) { reserve(lineage) }
        // Classical catalog numbers can live in a short library credit table.
        // Reserve distinct hosts rather than several copies of the same index.
        let numberPattern = #"\b(?:RV|BWV|KV|Hob\.?|Op\.?)\s*\d+"#
        var referenceHosts: Set<String> = []
        let references = ranked.filter { page in
            let body = normalized(page.title + " " + page.text)
            return titleTerms.contains(where: { $0.count >= 4 && body.contains($0) })
                && page.text.range(of: numberPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.sorted { ($0.searchRank ?? 0) > ($1.searchRank ?? 0) }
        for page in references where referenceHosts.count < 2 {
            let host = URL(string: page.url)?.host ?? ""
            if referenceHosts.insert(host).inserted { reserve(page) }
        }
        // A catalogue reference and a movement description may be on different
        // consulted pages. Keep both, instead of trading precision for the
        // highest-ranking retelling each time the window is rebuilt.
        let movementPattern = #"\b(?:first|second|third|fourth)\s+movement\b|第[一二三四五六七八九十\d]+[乐楽]章|\b(?:erster|zweiter|dritter)\s+satz\b|\b[IVX]{1,4}\.\s*(?:Allegro|Adagio|Andante|Presto)\b"#
        let movementPages = ranked.filter { page in
            guard page.text.range(of: movementPattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
            // Another movement in a general album interview does not establish
            // the movement of the current track. Prefer a track-specific page.
            let title = normalized(page.title)
            return titleTerms.contains { $0.count >= 4 && title.contains($0) }
        }
        if let movement = movementPages
            .max(by: { ($0.searchRank ?? 0) < ($1.searchRank ?? 0) }) { reserve(movement) }
        // Each search purpose can contribute evidence. Dense identity/catalog
        // results cannot consume the whole packet before a lineage or interview.
        for purpose in ResearchQuery.Purpose.allCasesInOrder {
            if let page = ranked.first(where: { $0.purposes.contains(purpose) && eligible($0) }) { reserve(page) }
        }
        for page in ranked { reserve(page) }
        var remaining = totalCharacters, directLeft = directCharacters, sources: [ResearchSource] = []
        for page in selected {
            guard remaining >= 160 else { break }
            let precision = page.text.range(of: movementPattern, options: [.regularExpression, .caseInsensitive]) != nil
            if page.direct == true, directLeft < 400 { continue }
            let base = page.direct == true ? min(5000, directLeft) : precision ? 6000 : 3400
            let limit = min(base, remaining), paragraphs = page.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var chunks: [String] = []
            for paragraph in paragraphs {
                let characters = Array(paragraph)
                for start in stride(from: 0, to: characters.count, by: 700) { chunks.append(String(characters[start..<min(start + 700, characters.count)])) }
            }
            let scores = chunks.map { chunk in
                score(chunk) + (chunk.range(of: movementPattern, options: [.regularExpression, .caseInsensitive]) != nil ? 24 : 0)
            }
            let order = chunks.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
            var choices: [Int: String] = [:], available = limit
            for index in order {
                for neighbor in [index, index - 1, index + 1] where chunks.indices.contains(neighbor) && choices[neighbor] == nil && available > 0 {
                    let part = String(chunks[neighbor].prefix(available)); choices[neighbor] = part; available -= part.count + 2
                }
            }
            let text = choices.keys.sorted().compactMap { choices[$0] }.joined(separator: "\n\n")
            let host = URL(string: page.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            sources.append(ResearchSource(id: "S\(sources.count + 1)", url: page.url, title: page.title,
                publisher: page.publisher ?? host, text: text, purposes: page.purposes, authority: page.authority, publishedAt: page.publishedAt))
            remaining -= text.count
            if page.direct == true { directLeft -= text.count }
        }
        return sources
    }
}

private extension ResearchQuery.Purpose {
    static var allCasesInOrder: [Self] { [.identity, .lineage, .story, .downstream, .context] }
}
