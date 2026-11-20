import Foundation

struct StoryEvidenceIssue: Codable, Equatable, Sendable {
    enum Rule: String, Codable, Sendable { case number, name, reference }
    let rule: Rule
    let token: String
    let detail: String
}

/// A literal gate, independent of model approval. It never borrows support from
/// another candidate's facts. Semantic claims still require the separate judge.
struct StoryEvidenceGuard: Sendable {
    static func articleIdentity(_ source: Source) -> String {
        guard var url = URLComponents(string: source.url), url.host == "realsound.jp",
              url.path.range(of: #"/post-[0-9]+(?:_[2-3])?\.html$"#, options: .regularExpression) != nil else { return source.url }
        url.path = url.path.replacingOccurrences(of: #"_[2-3](?=\.html$)"#, with: "", options: .regularExpression)
        url.query = nil; url.fragment = nil
        return url.string ?? source.url
    }

    /// Publisher typography may use NBSP or repeated spaces inside a literal
    /// name. Collapse whitespace only; never translate or repair characters.
    static func literalContains(_ text: String, _ name: String) -> Bool {
        let needle = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !needle.isEmpty && text.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(needle)
    }
    func check(_ candidate: StoryCandidate, facts: [StoryFact], entityInfo: [String], names: StoryNameTable) -> [StoryEvidenceIssue] {
        let primary = candidate.story.source
        let citedSources = [primary] + (candidate.story.additionalSources ?? []).filter {
            Self.articleIdentity($0) == Self.articleIdentity(primary)
        }
        let referenced = facts.filter { candidate.factIDs.contains($0.id) && citedSources.contains($0.source) }
        guard !candidate.factIDs.isEmpty, referenced.count == Set(candidate.factIDs).count else {
            return [.init(rule: .reference, token: candidate.factIDs.joined(separator: ","), detail: "引用事实缺失或出处不一致")]
        }
        let evidence = referenced.flatMap { fact -> [String] in
            // Extracted paraphrases cannot authorize their own invented number.
            // Structured IDs are provenance, not quantities in the narrative.
            if fact.structured != nil { return [fact.text] }
            if case .passage(_, _, let quote) = fact.evidence { return [quote] }
            return []
        }
        let text = candidate.story.title + "\n" + candidate.story.body
        let allowedNumbers = Set((evidence + names.names).flatMap(Self.numbers).map(\.normalized))
        var issues: [StoryEvidenceIssue] = []
        let evidencedPeople = Set(names.nodes.filter { node in
            node.kind == .person && ([node.name] + node.aliases).contains { name in
                evidence.contains { $0.contains(name) }
            }
        }.map(\.id))
        // "The two of them" may refer to the two explicitly named speakers.
        // This does not authorize two takes/years/awards or any other quantity.
        let numberedText = evidencedPeople.count == 2
            ? text.replacingOccurrences(of: "两人|兩人|二人|两位(?=创作歌手|创作者|歌手|艺人)", with: "彼此", options: .regularExpression) : text
        for number in Self.numbers(numberedText) where !allowedNumbers.contains(number.normalized) {
            issues.append(.init(rule: .number, token: number.raw, detail: "所引原文、模板句及名称表没有数字 " + number.raw))
        }
        let sourceNames = evidence + names.names
        func supported(_ value: String) -> Bool {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && sourceNames.contains { Self.literalContains($0, name) }
        }
        var suspicious = Self.matches("[「《『]([^」》』]+)[」》』]", in: text, group: 1)
        // This is a translated musical form, not a work/person name. Do not
        // generalize script conversion to proper names or arbitrary quotations.
        if evidence.contains(where: { $0.contains("組曲") }) {
            suspicious.removeAll { $0 == "组曲" && !text.contains("《组曲》") }
        }
        // A supported name may directly touch Chinese narration (for example
        // 浅野いにお还希望亲自作曲). Separate only exact, evidenced names before
        // tokenizing the remaining Kana. A model mention supplies a boundary,
        // never its own evidence; quotations and typo windows still use text.
        let literalNames = Set(names.names + referenced.flatMap { $0.people ?? [] }
            + (candidate.story.mentions ?? []))
            .filter { $0.count >= 2 && supported($0) }
            .sorted { $0.count > $1.count }
        var kanaText = text
        for name in literalNames where name.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil {
            let pattern = "(?<![\\p{Hiragana}\\p{Katakana}ー・])"
                + NSRegularExpression.escapedPattern(for: name)
                + "(?![\\p{Hiragana}\\p{Katakana}ー・])"
            kanaText = kanaText.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Kana identifies unrecognized Japanese spellings without relying on
        // a probabilistic language tagger. Split Chinese connecting words.
        for run in Self.matches("[\\p{Han}\\p{Hiragana}\\p{Katakana}ー・]+", in: kanaText) {
            for part in run.components(separatedBy: CharacterSet(charactersIn: "的和与與为為把被请請说說让讓在是向由跟对對将將给給曾了后後从從"))
            where part.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil {
                // Chinese narration can sit directly beside a literal Japanese
                // name. Trim grammatical context, never the name's spelling.
                let name = part
                    .replacingOccurrences(of: "^(?:这首|这段)?用于", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?:泳池)?场景$", with: "", options: .regularExpression)
                suspicious.append(name)
            }
        }
        // Known graph/source names form exact spelling anchors. Sliding windows
        // catch a single changed character even when a name is not quoted.
        let canonicalParts = names.nodes.flatMap { node in
            [node.name] + node.name.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 3 }
        }
        let anchors = names.names + canonicalParts + referenced.flatMap { $0.people ?? [] }
        let characters = Array(text)
        for anchor in anchors where (3...24).contains(anchor.count) && anchor.contains(where: { !$0.isASCII }) {
            let original = Array(anchor)
            guard characters.count >= original.count else { continue }
            for start in 0...(characters.count - original.count) {
                let window = Array(characters[start..<(start + original.count)])
                guard window.allSatisfy({ $0.isLetter || $0 == " " || $0 == "・" }),
                      zip(window, original).filter({ $0 != $1 }).count == 1 else { continue }
                let token = String(window)
                // A whole, correctly written name can contain a shorter anchor.
                if !names.names.contains(where: { $0.contains(token) && text.contains($0) }) {
                    suspicious.append(token)
                    if canonicalParts.contains(anchor) {
                        // An extractor's own misspelling cannot authorize a new
                        // translation of an already identified graph node.
                        issues.append(.init(rule: .name, token: token, detail: "与图上名称「" + anchor + "」不一致"))
                    }
                }
            }
        }
        // Han-only people in attribution/action positions must also have literal
        // support. Unrecognized fragments are rejected, never auto-translated.
        let surname = "(?:宇多田|欧阳|司马|诸葛|佐藤|鈴木|高桥|高橋|山田|小林|中村|吉田|藤本|川辺|川边|石野|牛尾|米津|庵野|[赵钱孙李周吴郑王陈杨张刘黄徐郭何林罗梁宋郑谢韩唐冯于董萧程曹袁邓许傅沈曾彭吕苏卢蒋蔡贾丁魏薛叶阎余潘杜戴夏钟汪田任姜范方石姚谭廖邹熊金陆郝孔白崔康毛邱秦江史顾侯邵孟龙万段雷武乔汤尹黎易常严])"
        let attributions = Self.matches("(?:^|[。！？\\n，,：:、]|由|请|与|和|让|向|跟)(" + surname + "[\\p{Han}]{0,3}?)(?=与|和|跟|向|原本|后来|当时|说|表示|回忆|认为|写道|告诉|邀请|受邀|担任|创作|演唱|作曲|作词|合作|参与|参加|拍摄|导演)", in: text, group: 1)
        suspicious += attributions.filter { token in
            if token == "于是" { return false } // Clause connector before 向, not surname 于.
            return !literalNames.contains { name in
                guard token.hasPrefix(name) else { return false }
                return ["接下", "接受", "收到", "开始", "的"].contains(String(token.dropFirst(name.count)))
            }
        }
        for name in Set(suspicious).sorted() where !supported(name) {
            issues.append(.init(rule: .name, token: name, detail: "名称或引文未逐字见于名称表及所引事实：" + name))
        }
        var seen = Set<String>()
        return issues.filter { seen.insert($0.rule.rawValue + ":" + $0.token).inserted }
    }

    struct Number: Equatable { let raw: String; let normalized: String }
    static func numbers(_ text: String) -> [Number] {
        let normalized = text.precomposedStringWithCompatibilityMapping
        // These conjunctions/adverbs contain the glyph 一 but express no
        // quantity. Keep ordinal/count uses such as 第一次、一首 and 一个人.
        // This one explicitly approved semantic equivalence is an ordinal,
        // distinct from a bare count of one. Remove it before cardinal parsing.
        let firstPattern = "初の|初めて|首次|第一次|(?i:\\bfirst\\b|\\b1st\\b)"
        let firsts = matches(firstPattern, in: normalized)
        let numericText = normalized.replacingOccurrences(of: firstPattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "一(?=起|并|同|直|致)|零(?=碎)", with: " ", options: .regularExpression)
        let pattern = "[0-9]+(?:[,，][0-9]{3})*(?:\\.[0-9]+)?(?:[万萬亿億])?|[零〇一二两兩三四五六七八九十百千万萬亿億]+"
        var result = matches(pattern, in: numericText).compactMap { raw -> Number? in
            // SPEC §9 excludes bare Chinese 一; retain ordinal first above,
            // compound numbers such as 十一, and Arabic 1 as quantities.
            guard raw != "一" else { return nil }
            return numericValue(raw).map { .init(raw: raw, normalized: $0) }
        }
        result += firsts.map { .init(raw: $0, normalized: "ordinal:1") }
        // Japanese interviews also spell the ordinary cardinal two in kana.
        // Quantity/subject semantics still go through the sentence verifier.
        result += matches("ふたつ|ふたり|二つ|二人", in: normalized).map { .init(raw: $0, normalized: "2") }
        // Component matches alone must not bless a date assembled from unrelated
        // years/months/counts elsewhere in the paragraph.
        let datePattern = "([0-9零〇一二三四五六七八九]{4})\\s*(?:年|[-/])\\s*([0-9一二三四五六七八九十]{1,3})\\s*(?:月|[-/])\\s*([0-9一二三四五六七八九十]{1,3})\\s*日?"
        for match in matches(datePattern, in: normalized) {
            let parts = matches("[0-9零〇一二三四五六七八九十]+", in: match).compactMap(numericValue)
            if parts.count == 3 { result.append(.init(raw: match, normalized: "date:\(parts[0])-\(parts[1])-\(parts[2])")) }
        }
        return result
    }
    private static func numericValue(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        var value: Decimal = 0
        if cleaned.first?.isASCII == true {
            let suffix = cleaned.last!
            let multiplier: Decimal = "万萬".contains(suffix) ? 10_000 : "亿億".contains(suffix) ? 100_000_000 : 1
            guard let number = Decimal(string: multiplier == 1 ? cleaned : String(cleaned.dropLast()), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            value = number * multiplier
        } else {
            let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"兩":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
            let units: [Character: Decimal] = ["十":10,"百":100,"千":1000,"万":10000,"萬":10000,"亿":100000000,"億":100000000]
            if cleaned.allSatisfy({ digits[$0] != nil }) {
                value = cleaned.reduce(0) { $0 * 10 + Decimal(digits[$1]!) }
            } else {
                var total: Decimal = 0, section: Decimal = 0, digit: Decimal = 0
                for c in cleaned {
                    if let d = digits[c] { digit = Decimal(d) }
                    else if let unit = units[c] {
                        if unit < 10_000 { section += (digit == 0 ? 1 : digit) * unit }
                        else if unit == 10_000 { total += (section + digit == 0 ? 1 : section + digit) * unit; section = 0 }
                        else { total = (total + section + digit == 0 ? 1 : total + section + digit) * unit; section = 0 }
                        digit = 0
                    }
                }
                value = total + section + digit
            }
        }
        return NSDecimalNumber(decimal: value).stringValue
    }
    private static func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
