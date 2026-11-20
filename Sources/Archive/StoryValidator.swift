import Foundation

/// Names come from identified entities, never from guesses about arbitrary prose.
struct StoryContext: Equatable, Sendable {
    let entityID: String
    let entityName: String
    var people: [String] = []
    var works: [String] = []


}

struct StoryValidation: Equatable, Codable, Sendable {
    enum Rule: String, Codable, Sendable {
        case titleWidth, bodyWidth, sentenceCount, blockedExpression, concreteNoun, source, sourceURL
    }
    struct Issue: Equatable, Codable, Sendable {
        let rule: Rule
        let detail: String
    }
    let issues: [Issue]
    var isValid: Bool { issues.isEmpty }
}

struct StoryValidator: Sendable {
    static let blockedWords = ["背后的故事", "不为人知", "娓娓道来", "交织", "诠释", "承载", "灵魂", "宛如", "仿佛", "值得一提的是", "令人动容", "完美呼应", "极具巧思"]

    func validate(_ story: Story, context: StoryContext, reviewedLongForm: Bool = false) -> StoryValidation {
        var issues: [StoryValidation.Issue] = []
        func reject(_ rule: StoryValidation.Rule, _ detail: String) { issues.append(.init(rule: rule, detail: detail)) }
        let titleWidth = Self.visualWidth(story.title), bodyWidth = Self.visualWidth(story.body)
        // Empty titles identify the new standalone editorial paragraph. Keep
        // the original limits for historical titled fixtures and saved data.
        let editorial = story.title.isEmpty
        let bodyLimit = editorial ? 400 : reviewedLongForm ? 180 : 90
        let sentenceLimit = editorial ? 10 : reviewedLongForm ? 6 : 3
        if titleWidth > 24 { reject(.titleWidth, "标题 \(titleWidth) 字，超过 24 字") }
        if bodyWidth > bodyLimit { reject(.bodyWidth, "正文 \(bodyWidth) 字，超过 \(bodyLimit) 字") }
        let count = Self.sentences(story.body).count
        if count > sentenceLimit { reject(.sentenceCount, "正文 \(count) 句，超过 \(sentenceLimit) 句") }
        let text = story.title + "\n" + story.body
        for word in Self.blockedWords where text.contains(word) { reject(.blockedExpression, word) }
        // Match the sentence construction, including the ellipsis shorthand.
        if Self.matches("不仅[^。！？\\n]*更是", in: text) { reject(.blockedExpression, "不仅……更是") }
        if Self.matches("一场[^。！？\\n]*的旅程", in: text) { reject(.blockedExpression, "一场……的旅程") }
        if Self.matches("[像如][^。！？\\n]+般", in: text) { reject(.blockedExpression, "像……般") }
        if Self.matches("恰恰是[^。！？\\n]*最", in: text) { reject(.blockedExpression, "恰恰是……最……") }
        if Self.matches(".+的\\s*创作背景", in: story.title) { reject(.blockedExpression, "XX 的创作背景式标题") }
        let entityName = context.entityID == story.entityID ? context.entityName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let knownName = (context.people + context.works).contains { !$0.isEmpty && text.contains($0) }
        let concrete = !entityName.isEmpty || knownName || Self.matches("[0-9０-９]|《[^》]+》|「[^」]+」", in: text)
        if !concrete { reject(.concreteNoun, "标题、正文及所挂实体名中没有具体名词、数字或原话") }
        if story.source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(.source, "没有出处") }
        if let url = URLComponents(string: story.source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty { /* The URL exists; no network verification in P5-a. */ }
        else { reject(.sourceURL, "出处缺少有效的 HTTP(S) URL") }
        return StoryValidation(issues: issues)
    }

    /// English/digit runs round up separately; whitespace contributes no width.
    static func visualWidth(_ text: String) -> Int {
        var width = 0, run = 0
        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber) { run += 1 }
            else {
                width += (run + 1) / 2; run = 0
                if !character.isWhitespace { width += 1 }
            }
        }
        return width + (run + 1) / 2
    }

    static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { "。！？".contains($0) }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// SPEC's two-item title requirement is a selection score, never a rejection.
    func titleSpecificity(_ story: Story, context: StoryContext) -> Int {
        let title = story.title
        return [context.people.contains { !$0.isEmpty && title.contains($0) },
                context.works.contains { !$0.isEmpty && title.contains($0) } || Self.matches("《[^》]+》", in: title),
                Self.matches("[12][0-9]{3}\\s*年", in: title),
                Self.matches("「[^」]+」", in: title)].filter { $0 }.count
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
