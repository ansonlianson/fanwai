import Foundation

/// Search words written by the model from what is already known (anson 2026-11-18 17:00, item 2).
///
/// The fixed templates misjudge language and context: 「Lemon · 米津玄师」 from the Chinese store
/// was searched in Chinese (采访 创作经过) and found Baidu, sheet music and Douyin, while its
/// story is in Japanese interviews; 「Without You · ハリー・ニルソン」 is searched in Japanese
/// although its sources are English. One small call (≈ ¥0.003) rewrites the draft in the
/// language of the sources, with the show, film or game the free databases found.
/// Any failure falls back to the draft; the lookup never waits on it for long.
enum ResearchQueryPlanner {
    static let enabledKey = "research.queryPlanner"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    struct Plan: Sendable {
        var queries: [ResearchQuery]
        var hints = ResearchHints()
        var usage: StoryModelUsage? = nil
        var planned = false
    }

    static let rules = "你为音乐资料检索写网页搜索词。只写搜索词，不回答问题，不编造事实。严格输出唯一JSON对象。"

    static func prompt(topic: ResearchTopic, knownFacts: [String], draft: [ResearchQuery], storyOnly: Bool) -> String {
        let facts = knownFacts.prefix(14).map { fact -> String in
            let parts = fact.components(separatedBy: " | ")
            return "- " + (parts.count >= 3 ? parts.prefix(3).joined(separator: " | ") : fact)
        }
        let purposes = draft.map(\.purpose.rawValue)
        return """
        当前歌曲：《\(topic.title)》，署名：\(topic.creator)，专辑：\(topic.album.isEmpty ? "未知" : topic.album)。
        免费数据库已确认的事实：
        \(facts.isEmpty ? "（没有）" : facts.joined(separator: "\n"))
        现在的搜索词草稿（按顺序，每条有用途）：
        \(draft.enumerated().map { "\($0.offset + 1). " + $0.element.purpose.rawValue + "：" + $0.element.text }.joined(separator: "\n"))

        请改写草稿，让每条搜索词都能搜到最多原始资料。规则：
        1. 用原始资料最多的语言：日本的歌和作品用日文，华语用中文，欧美用英文。商店把欧美艺人写成片假名（ハリー・ニルソン）或中文译名时，换回原名（Harry Nilsson）用英文搜；简体中文写的日本人名（米津玄师）改回日文写法（米津玄師）。
        2. 已知这首歌属于某部动画、电影、剧或游戏时，把作品名写进相关搜索词。
        3. story 要能搜到当事人讲这首歌创作经过的采访或解说，用资料所在的那一种语言：日本的歌用「インタビュー」「楽曲解説」「セルフライナーノーツ」「制作秘話」，欧美的歌用 interview、"story behind"、songfacts，华语歌用 采访、创作背景、幕后。一条搜索词里不要混用两种语言。
        4. 没有歌词的配乐、原声曲：搜这部作品的音乐和作曲者的采访（作品名 + 作曲者 + サウンドトラック／劇伴／soundtrack + インタビュー／interview）。
        5. 钢琴版、管弦乐版、Live 等改编版本：搜原曲和它出自的作品，不带演奏者的名字。
        6. 不要写商店、歌词、乐谱、视频网站就能回答的词。每条不超过12个词。
        7. q 按草稿顺序一条对应一条（共\(draft.count)条，用途不变）\(storyOnly ? "" : "，可以在最后再加一条 story")。
        t、a 是这首歌和署名在原始资料里的写法（不知道就照抄输入）；w 是它所属的动画、电影、剧或游戏（专辑不算；不确定就留空）。
        仅输出JSON：{"t":"歌名","a":"艺人","w":"作品或空","q":["搜索词1","搜索词2"]}
        用途顺序：\(purposes.joined(separator: "、"))
        """
    }

    /// The model's queries when they keep every purpose of the draft; otherwise nil (the draft is used).
    /// The answer is `{"t","a","w","q":[…]}` with q in the draft's order (an extra last one is a story);
    /// the longer `{"names":{…},"queries":[{"purpose","text"}]}` is read too.
    static func parse(_ text: String, draft: [ResearchQuery]) -> (queries: [ResearchQuery], hints: ResearchHints)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        var items: [(purpose: ResearchQuery.Purpose?, text: String)] = []
        if let list = root["q"] as? [String] {
            items = list.enumerated().map { index, text in (index < draft.count ? draft[index].purpose : .story, text) }
        } else if let list = root["queries"] as? [[String: Any]] {
            items = list.compactMap { item in (item["text"] as? String).map { (ResearchQuery.Purpose(rawValue: item["purpose"] as? String ?? ""), $0) } }
        } else { return nil }
        let allowed = Set(draft.map(\.purpose))
        var seen = Set<String>(), primary: [ResearchQuery] = [], extra: [ResearchQuery] = []
        for item in items {
            guard let purpose = item.purpose, allowed.contains(purpose) || purpose == .story && allowed.contains(.story) else { continue }
            let text = String(item.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard text.count > 2, seen.insert(text.lowercased()).inserted else { continue }
            if primary.contains(where: { $0.purpose == purpose }) { extra.append(.init(purpose: purpose, text: text)) }
            else { primary.append(.init(purpose: purpose, text: text)) }
        }
        guard !primary.isEmpty else { return nil }
        // A purpose the model dropped keeps its draft query; one more query at most (story first).
        for query in draft where !primary.contains(where: { $0.purpose == query.purpose }) {
            if seen.insert(query.text.lowercased()).inserted { primary.append(query) }
        }
        let room = draft.count + (draft.count >= 4 ? 1 : 0) - primary.count
        let queries = primary + extra.sorted { ($0.purpose == .story ? 0 : 1) < ($1.purpose == .story ? 0 : 1) }.prefix(max(0, room))
        var hints = ResearchHints()
        let names = root["names"] as? [String: Any] ?? root
        func value(_ keys: [String]) -> String? {
            for key in keys {
                let text = (names[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty, text.count <= 80 { return text }
            }
            return nil
        }
        hints.title = value(["t", "title"]); hints.artist = value(["a", "artist"])
        if let work = value(["w", "work"]) { hints.works = [.init(name: work)] }
        return (Array(queries), hints)
    }

    /// The draft rewritten, or the draft itself after any failure or 6 seconds.
    static func plan(topic: ResearchTopic, knownFacts: [String], draft: [ResearchQuery], storyOnly: Bool,
                     client: any StoryModelClient, configuration: ResearchModelConfiguration) async -> Plan {
        guard enabled, !draft.isEmpty else { return .init(queries: draft) }
        let user = prompt(topic: topic, knownFacts: knownFacts, draft: draft, storyOnly: storyOnly)
        let reply: StoryModelReply? = await MetadataDeadline.value(seconds: 6) {
            do {
                try await ModelRequestLedger.shared.reserve(configuration, kind: "query-plan")
                return try await client.complete(system: rules, user: user, maxTokens: 360)
            } catch { return nil }
        }
        guard let reply else { return .init(queries: draft) }
        EvalResearchCapture.data(Data(reply.text.utf8), name: "query-plan-raw.txt", secret: configuration.credential.value)
        guard let parsed = parse(reply.text, draft: draft) else { return .init(queries: draft, usage: reply.usage) }
        return .init(queries: parsed.queries, hints: parsed.hints, usage: reply.usage, planned: true)
    }
}
