import Foundation

/// 深挖 (AHA-PLAN, decided 2026-11-17): the same service and model as everyday research,
/// asked again in up to three rounds. Each round plans new searches for what is still
/// missing, reads them, and passes the results through the same grounding as Call A /
/// Call B / 同门. A service with its own web tool gets one larger native call instead.
enum DeepResearch {
    static let maxRounds = 3
    static let searchesPerRound = 4

    /// Price shown before a dive: per-round token assumptions × official prices.
    /// Unknown prices show counts only; nothing is invented.
    struct Estimate: Equatable {
        let low: Double?
        let high: Double?
        let model: String
        var text: String {
            if let low, let high { return String(format: "约 ¥%.2f–%.2f · 最多 %d 轮 · %@", low, high, rounds, model) }
            return "最多 \(rounds) 轮、\(rounds * toolCallsPerRound) 次搜索 · \(model)"
        }
    }
    /// The rounds and web calls (searches and full reads) of the design in use.
    static var rounds: Int { strategy == .follow ? followRounds : maxRounds }
    static var toolCallsPerRound: Int { strategy == .follow ? followSearches + 1 : searchesPerRound }
    /// With a price (published, or entered by the user for their own service) the dive is
    /// quoted in money; without one it is quoted in rounds and searches.
    static func estimate(model: String, price: ModelPrice?) -> Estimate {
        guard let price else { return .init(low: nil, high: nil, model: model) }
        // One round. First design: plan (3k/0.3k), Call A (15k/0.8k), 同门 (5k/0.3k), Call B (15k/1k), 4–5 searches, 2 reads.
        // Second design, measured 11-18 on 8 songs: ¥0.086 for one round, ¥0.15–0.21 for two (≈ 25k in, 1.8k out,
        // 9 searches and reads per round).
        let round = strategy == .follow ? price.cost(inputTokens: 25_000, outputTokens: 1_800, searches: 9)
            : price.cost(inputTokens: 38_000, outputTokens: 2_400, searches: 7)
        return .init(low: round, high: round * Double(rounds), model: model)
    }
    static func cost(price: ModelPrice?, usage: DiscoveryUsage?) -> Double? {
        guard let price, let usage else { return nil }
        return price.cost(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, searches: usage.webToolCalls)
    }

    static let plannerRules = "你是片外的深挖规划助手。只根据给出的已知信息提出新的网页搜索查询，不回答问题，不编造事实。严格输出唯一JSON对象。"

    static func plannerPrompt(topic: ResearchTopic, known: [String], hasStory: Bool, round: Int) -> String {
        let list = known.isEmpty ? "（还没有）" : known.prefix(24).map { "- " + $0 }.joined(separator: "\n")
        return """
        当前：《\(topic.title)》（\(topic.creator)），发行：\(topic.album)。这是第\(round)轮深挖。
        已经找到：
        \(list)
        已有幕后故事：\(hasStory ? "有" : "没有")。
        请提出最多\(searchesPerRound)条新的网页搜索查询，去找还没找到的东西：旋律或歌词从哪里来（圣歌、古典、民谣、原曲、采样来源）；它被谁采样或翻唱；改编、现场、管弦乐版本对应的原曲和原作；同一部作品的其他主题曲；有具体人物和经过的幕后轶事。
        不要重复已经找到的内容。用最可能找到原始资料的语言写查询（日本作品用日文，欧美作品用英文）。
        仅输出JSON：{"queries":[{"purpose":"lineage|story|context|downstream","text":"查询词"}]}
        """
    }

    static func queries(_ text: String) -> [ResearchQuery] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let items = root["queries"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return items.compactMap { item -> ResearchQuery? in
            guard let raw = item["text"] as? String else { return nil }
            let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard text.count > 2, seen.insert(text).inserted else { return nil }
            let purpose = ResearchQuery.Purpose(rawValue: item["purpose"] as? String ?? "") ?? .context
            return ResearchQuery(purpose: purpose, text: text)
        }.prefix(searchesPerRound).map { $0 }
    }

    // MARK: second design: follow the leads (anson 2026-11-18 17:00)

    enum Strategy: String { case rounds, follow }
    static let strategyKey = "research.deepStrategy"
    /// `follow` unless a test asks for the first design.
    static var strategy: Strategy { Strategy(rawValue: UserDefaults.standard.string(forKey: strategyKey) ?? "") ?? .follow }
    static let followRounds = 2
    static let followSearches = 8

    static func followPrompt(topic: ResearchTopic, cards: [String], facts: [String], hasStory: Bool, round: Int,
                             searched: [String], wikipedia: String?) -> String {
        let shown = (cards + facts.map { fact -> String in
            let parts = fact.components(separatedBy: " | "); return parts.count >= 3 ? parts[1] + "：" + parts[2] : fact
        }).prefix(30).map { "- " + $0 }.joined(separator: "\n")
        return """
        当前：《\(topic.title)》（\(topic.creator)），专辑：\(topic.album.isEmpty ? "未知" : topic.album)。这是深挖第\(round)轮：用户愿意多花钱，换真正新的发现。
        页面上已经有：
        \(shown.isEmpty ? "（还没有）" : shown)
        已有幕后故事：\(hasStory ? "有" : "没有")。
        维基百科关于这首歌的节选：
        \(wikipedia ?? "（没有找到条目）")
        已经搜过的搜索词（不要重复，也不要只换词序或换几个字）：
        \(searched.suffix(24).map { "- " + $0 }.joined(separator: "\n"))

        先想清楚还缺什么，再写搜索词。可能缺的：
        - lineage：旋律、歌词、采样从哪里来；
        - homing：改编、Live、钢琴版对应的原曲和它出自的作品；
        - sibling：同一部动画、电影、剧、游戏的其他主题曲和插曲；
        - downstream：被谁翻唱、采样，用在哪些作品、广告、节目里；
        - story：当事人讲的、有具体人物和经过的幕后\(hasStory ? "（已经有了，只在可能找到另一件更有意思的事时再找）" : "")。
        规则：
        1. 最多写\(followSearches)条。至少一半以「邻居」为对象而不是这首歌本身：所属的作品、专辑、作曲者、编曲者、原曲、翻唱者。例：作品名 主題歌 一覧；专辑名 全曲解説 / セルフライナーノーツ；作曲者 作品名 インタビュー；原曲名 カバー。
        2. 换资料的种类和语言，而不是换词序：日文的インタビュー、楽曲解説、ライナーノーツ、Wiki；英文的 interview、songfacts、whosampled、secondhandsongs、Genius、liner notes；中文的 采访、萌娘百科、乐评、专访。日本的作品主要用日文，欧美的主要用英文，可以各加一条别的语言。
        3. 页面上已有的东西不要再找；同一个缺口最多三条。
        4. 每条搜索词不超过12个词。
        仅输出JSON：{"gaps":["还缺什么，一句话"],"queries":[{"slot":"lineage|homing|sibling|downstream|story","target":"对象","text":"搜索词"}]}
        """
    }

    /// Queries from the plan, new ones only, at most `followSearches`.
    static func followQueries(_ text: String, searched: [String]) -> [ResearchQuery] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let items = root["queries"] as? [[String: Any]] else { return [] }
        var seen = Set(searched.map { LeadMatch.norm($0) })
        var perSlot: [String: Int] = [:], result: [ResearchQuery] = []
        for item in items {
            guard let raw = item["text"] as? String else { continue }
            let text = String(raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            let slot = (item["slot"] as? String ?? "").lowercased()
            guard text.count > 2, seen.insert(LeadMatch.norm(text)).inserted, perSlot[slot, default: 0] < 3 else { continue }
            perSlot[slot, default: 0] += 1
            let purpose: ResearchQuery.Purpose = switch slot {
            case "lineage", "homing": .lineage
            case "downstream": .downstream
            case "story": .story
            default: .context
            }
            result.append(.init(purpose: purpose, text: text))
            if result.count == followSearches { break }
        }
        return result
    }

    /// What the page already shows, by name: its cards (「标签：名字」), the database facts
    /// (「from | label | to | url」) and the song itself.
    static func knownNames(cards: [String], facts: [String], topic: ResearchTopic) -> Set<String> {
        var names = [topic.title, topic.canonicalTitle ?? ""]
        names += cards.map { $0.components(separatedBy: "：").dropFirst().joined(separator: "：") }
        for fact in facts {
            let parts = fact.components(separatedBy: " | ")
            if parts.count >= 3 { names += [parts[0], parts[2]] }
        }
        return Set(names.map(LeadMatch.norm).filter { !$0.isEmpty })
    }
    /// The names a round brought that were not on the page before it. A round that only finds
    /// again what is already there ends the dive (measured 11-18: three songs each paid for all
    /// three rounds, ¥0.15–0.18, while two of them gained nothing).
    static func novelNames(_ leads: [[String: Any]], known: inout Set<String>) -> [String] {
        var novel: [String] = []
        for lead in leads {
            guard let name = lead["name"] as? String else { continue }
            let keys = [name, lead["zh"] as? String ?? "", lead["en"] as? String ?? ""].map(LeadMatch.norm).filter { !$0.isEmpty }
            if !keys.contains(where: known.contains) { novel.append(name) }
            known.formUnion(keys)
        }
        return novel
    }

    /// Refs from different rounds must not collide (n1, sib1, _piece …).
    static func prefixed(_ part: (leads: [[String: Any]], relations: [[String: Any]]), round: Int) -> (leads: [[String: Any]], relations: [[String: Any]]) {
        func ref(_ value: Any?) -> Any? {
            guard let value = value as? String else { return value }
            return value == "current" ? value : "r\(round)_" + value
        }
        let leads = part.leads.map { lead -> [String: Any] in var copy = lead; copy["ref"] = ref(lead["ref"]); return copy }
        let relations = part.relations.map { edge -> [String: Any] in
            var copy = edge; copy["from"] = ref(edge["from"]); copy["to"] = ref(edge["to"]); return copy
        }
        return (leads, relations)
    }
}
