import Foundation

/// Names remain literal. A link is either an exact entity or a user-selected
/// search; it is never a fuzzy identity join.
struct StoryTextLinks {
    struct Target: Hashable, Identifiable {
        let name: String
        let entityID: String?
        var id: String { name }
        var url: URL {
            var url = URLComponents()
            url.scheme = "pianwai-story"; url.host = "name"
            url.queryItems = [.init(name: "text", value: name)]
            return url.url!
        }
    }
    struct Span: Equatable { let range: NSRange; let name: String }
    let targets: [Target]

    private static let bracketed = try! NSRegularExpression(pattern: "[《〈]([^《》〈〉\\n]{1,40})[》〉]")
    private static let latin = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9'’.\-!&+]*(?: [A-Za-z0-9][A-Za-z0-9'’.\-!&+]*)*(?![A-Za-z0-9])"#)
    /// Format, platform and descriptive words that are spelled in Latin letters but are not names.
    private static let plainWords: Set<String> = ["live", "remix", "acoustic", "demo", "version", "ver", "mix", "cover", "solo", "single", "album",
        "intro", "outro", "hook", "riff", "freestyle", "feat", "size", "edit", "extra", "boss", "dlc", "ost", "bgm", "dvd", "blu-ray",
        "pop", "rock", "jazz", "funk", "rap", "hip-hop", "city", "vocaloid", "flash", "the", "and", "for", "from", "with",
        "tiktok", "youtube", "netflix", "line", "spotify", "apple", "music", "itunes", "twitter", "instagram", "billboard", "oricon",
        "genius", "whosampled", "wikipedia", "nhk", "tbs", "mtv", "radio", "japan", "tv", "cd", "mv", "pv", "op", "ed", "ep", "lp", "dj", "cm"]

    /// Names the reader may open even when the writer did not list them (anson 2026-11-18: n-buna,
    /// GOING STEADY, MONGOL800, THE BLUE HEARTS were plain text): whatever stands in 《》 or 〈〉, and
    /// Latin-script names. In Chinese prose a run of Latin words is almost always a proper name;
    /// the few common format and platform words are left alone.
    static func detected(in text: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        func add(_ value: String) { if seen.insert(value).inserted { out.append(value) } }
        let whole = NSRange(text.startIndex..., in: text)
        for match in bracketed.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let name = text[range].trimmingCharacters(in: .whitespaces)
            if name.count >= 2 || name.unicodeScalars.contains(where: { $0.value > 0x2E7F }) { add(name) }
        }
        for match in latin.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let name = text[range].trimmingCharacters(in: CharacterSet(charactersIn: " .-'’&+"))
            let words = name.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!'’")) }
            guard name.filter(\.isLetter).count >= 3, words.count <= 6, !words.allSatisfy({ plainWords.contains($0) || $0.count < 2 }) else { continue }
            // An ordinary English word in the sentence (coupling, studio, session) is written in
            // lower case; a name has a capital, a digit or a hyphen somewhere (n-buna, MONGOL800).
            guard name.contains(where: { $0.isUppercase || $0.isNumber }) || (name.contains("-") && !name.contains(" ")) else { continue }
            add(name)
        }
        return out
    }

    init(story: Story, excludingNames: Set<String> = [], excludingEntities: Set<String> = []) {
        let text = story.title + "\n" + story.body
        let names = Set(story.entityLinks.keys).union(story.mentions ?? []).union(Self.detected(in: story.body))
        targets = names.filter { !$0.isEmpty && text.contains($0) && !excludingNames.contains(LeadMatch.norm($0))
            && !excludingEntities.contains(story.entityLinks[$0]?.rawValue ?? "") }.sorted().map {
            Target(name: $0, entityID: story.entityLinks[$0]?.rawValue)
        }
    }
    var distinctTargets: [Target] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.entityID ?? "name:" + $0.name).inserted }
    }
    func target(for url: URL) -> Target? { targets.first { $0.url == url } }
    func spans(in text: String) -> [Span] {
        var result: [Span] = []
        // Longest wins, including all repeated occurrences. Latin word
        // boundaries protect Actor/actors and Lotus/LOTUS-2.
        for target in targets.sorted(by: { $0.name.count == $1.name.count ? $0.name < $1.name : $0.name.count > $1.name.count }) {
            let name = StoryTextPresentation.clean(target.name)
            let latin = name.unicodeScalars.allSatisfy(\.isASCII)
            let pattern = (latin ? "(?<![A-Za-z0-9])" : "") + NSRegularExpression.escapedPattern(for: name)
                + (latin ? "(?![A-Za-z0-9]|[-–][0-9])" : "")
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard !result.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                result.append(.init(range: match.range, name: target.name))
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static func verifiedLinks(title: String, body: String, names: StoryNameTable) -> [String: WorkID] {
        let text = title + "\n" + body
        return Dictionary(uniqueKeysWithValues: names.payload.compactMap { item in
            guard let name = item["original"], text.contains(name), let raw = item["entity_id"],
                  let id = WorkID(rawValue: raw) else { return nil }
            return (name, id)
        })
    }
}

enum StoryTextPresentation {
    /// Remove accidental CJK/Latin boundary blanks, keeping Latin word spaces.
    /// The saved sourced copy is unchanged; preview, reading and measurement
    /// all use this same display text.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}》〉」』])[\t ]+(?=[\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9《〈「『])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[A-Za-z0-9])[\t ]+(?=[\p{Han}\p{Hiragana}\p{Katakana}《〈「『])"#, with: "", options: .regularExpression)
    }
}

/// Reviewed narrative copy only. A catalog relation/credit is not a story.
enum NowStoryContent {
    private static let approvedSakamoto = "1982 年，大岛渚邀请坂本龙一出演《圣诞快乐，劳伦斯先生》时，坂本心里已想答应，却在开口前提出，希望也由自己作曲。大岛渚立即同意，他随后答应出演。坂本龙一后来回忆，当时自己对演戏和电影配乐都没有经验，大岛渚仍接受了这个提议。"
    // Standalone paragraphs derived only from the existing reviewed copy.
    // Historical fixtures retain their original title/body for auditability.
    private static let paragraphs: [String: String] = [
        "pool-main": "2023 年为《蕾塞篇》做先导 PV 时，牛尾宪辅准备了一个 B 方案，叫作「我们的歌」。这首《in the pool》后来被放进电次和蕾塞在泳池的那场戏。",
        "pool-suite": "为《in the pool》商量配乐时，牛尾宪辅和导演原本考虑把它拆成几段短曲。牛尾宪辅觉得连成组曲更美，便把它写成了连贯的一首。",
        "jane-main": "米津玄师开始写《JANE DOE》时，还没有想好请谁来唱。随着创作推进，他觉得非宇多田光不可，于是向她发出邀请。",
        "actor-main": "写《Actor》时，几田莉拉想起了妈妈。她说，妈妈一直努力演好「母亲」这个角色；想到这里，她觉得扮演也可以是出于爱。"
    ]
    private static let narrativeIDs: Set<String> = [
        "pool-main", "pool-suite", "jane-main", "actor-main",
        "editorial:story-sakamoto-asked-to-score", "editorial:story-lawrence-composer-on-screen",
        "editorial:story-one-last-kiss-next-song", "editorial:story-one-last-kiss-remote-mv",
        "editorial:story-paprika-two-voices", "editorial:story-kon-lotus-reference"
    ]
    @MainActor static func stories(for entity: SeedGraph.Entity, catalog: CatalogStore) -> [Story] {
        let id = catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
        let presets = PresetStoryProvider().stories(for: entity.id)
        let editorial = catalog.stories.filter { catalog.canonicalID(for: $0.workID) == id }
        let candidates = (presets + editorial).filter { narrativeIDs.contains($0.id) }
        guard !candidates.isEmpty else { return [] }
        let text = candidates.map { story in
            ["editorial:story-sakamoto-asked-to-score", "editorial:story-lawrence-composer-on-screen"].contains(story.id)
                ? approvedSakamoto : paragraphs[story.id] ?? story.body
        }.joined(separator: "\n")
        let seedNames = StoryNameTable(nodes: StoryNameGraph.nodes(catalog: catalog, matching: text), verifiedNames: StoryNameGraph.verifiedAliases)
        return candidates.compactMap { story in
            let isSakamoto = ["editorial:story-sakamoto-asked-to-score", "editorial:story-lawrence-composer-on-screen"].contains(story.id)
            let body = isSakamoto ? approvedSakamoto : paragraphs[story.id] ?? story.body
            // These two shortened labels are reviewed in the literal pool copy.
            var links = StoryTextLinks.verifiedLinks(title: "", body: body, names: seedNames)
            if story.id == "pool-main" { links["蕾塞篇"] = .film; links["牛尾宪辅"] = .ushio }
            if story.id == "jane-main" { links["JANE DOE"] = .jane; links["米津玄师"] = .yonezu; links["宇多田光"] = .utada }
            links.merge(story.entityLinks) { _, authored in authored }
            if story.id == "editorial:story-sakamoto-asked-to-score" || story.id == "editorial:story-lawrence-composer-on-screen" {
                links["坂本"] = WorkID(rawValue: "editorial:ryuichi-sakamoto")!
            }
            if story.id == "editorial:story-paprika-two-voices" { links["筒井"] = WorkID(rawValue: "editorial:yasutaka-tsutsui")! }
            if story.id == "editorial:story-one-last-kiss-remote-mv" { links["庵野"] = WorkID(rawValue: "editorial:hideaki-anno")! }
            #if DEBUG && targetEnvironment(simulator)
            var mentions = story.mentions
            let unboundReview = ProcessInfo.processInfo.arguments.contains("--ui-isolate-data")
                && ProcessInfo.processInfo.arguments.contains("--ui-story-unbound") && story.id == "pool-main"
            if unboundReview { links.removeValue(forKey: "蕾塞篇"); mentions = ["蕾塞篇"] }
            #else
            let mentions = story.mentions
            #endif
            let mapped = Story(id: story.id, entityID: entity.id, title: "", body: body,
                relatedEntityIDs: story.relatedEntityIDs, source: story.source, score: story.score,
                entityLinks: links, additionalSources: story.additionalSources, mentions: mentions)
            return StoryValidator().validate(mapped, context: .init(entityID: entity.id, entityName: entity.title),
                                              reviewedLongForm: true).isValid ? mapped : nil
        }
    }
}
