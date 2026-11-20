import Foundation
import SwiftSoup

enum WorkBackgroundError: Error, LocalizedError {
    case invalidIdentity, invalidResponse, httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "这份创作资料暂不可用。"
        case .invalidResponse: "创作资料暂未完整载入。"
        case .httpStatus: "暂时无法连接创作资料。"
        }
    }
}

/// Extracts attributed Wikipedia prose, not independently verified interviews.
/// Exact article identity must already have been established by WorkContext.
actor WorkBackgroundService: WorkBackgroundFetching {
    private let session: URLSession
    init(session: URLSession = PianwaiRuntime.session) { self.session = session }

    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse {
        guard article.isValid else {
            throw WorkBackgroundError.invalidIdentity
        }
        let index = try await load(article: article, section: nil)
        guard let sections = index.sections else { throw WorkBackgroundError.invalidResponse }
        let candidates = try Self.candidates(sections)
        var excerpts: [WorkBackgroundExcerpt] = []
        var focusedByID: [String: WorkBackgroundExcerpt] = [:]
        var seenParagraphs = Set<String>()
        for candidate in candidates.prefix(4) {
            try Task.checkCancellation()
            let section = candidate.section
            let response = try await load(article: article, section: section.index)
            guard let html = response.text else { throw WorkBackgroundError.invalidResponse }
            let material = candidate.isMusicTheme
                ? try Self.musicThemeExcerpts(html: html, section: section, article: article)
                : try Self.excerpts(html: html, section: section, article: article, focusedByID: &focusedByID)
            for item in material {
                if seenParagraphs.insert(item.sourceParagraph).inserted { excerpts.append(item) }
            }
        }
        try Task.checkCancellation()
        // A lead is a bounded fallback, never an extra source competing with
        // usable creative sections. It uses the same pinned article identity.
        if excerpts.isEmpty {
            let lead = try await load(article: article, section: "0")
            guard let html = lead.text else { throw WorkBackgroundError.invalidResponse }
            excerpts = try Self.leadExcerpts(html: html, article: article)
        }
        try Task.checkCancellation()
        let ranked = Self.ranked(excerpts)
        let selected = Array(ranked.prefix(2))
        let selectedIDs = Set(selected.map(\.id))
        let originalContinuation = Array(ranked.filter {
            !selectedIDs.contains($0.id) && Self.readingPriority($0) >= 2
                && !($0.references?.isEmpty ?? true)
        }.prefix(4))
        let continuation = originalContinuation.map { focusedByID[$0.id] ?? $0 }
        let retained = originalContinuation.filter { focusedByID[$0.id] != nil }
        return WorkBackgroundResponse(article: article, excerpts: selected,
                                      continuationCandidates: continuation.isEmpty ? nil : continuation,
                                      retainedContinuationCandidates: retained.isEmpty ? nil : retained)
    }

    private func load(article: WikiArticleIdentity, section: String?) async throws -> Parsed {
        var parts = URLComponents(string: "https://\(article.language).wikipedia.org/w/api.php")!
        var params = ["action": "parse", "oldid": String(article.revision), "prop": section == nil ? "sections" : "text",
                      "format": "json", "formatversion": "2", "disablelimitreport": "1", "disableeditsection": "1"]
        if let section { params["section"] = section }
        parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw WorkBackgroundError.invalidIdentity }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pianwai/0.1 (personal reading app)", forHTTPHeaderField: "User-Agent")
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WorkBackgroundError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WorkBackgroundError.httpStatus(http.statusCode) }
        guard data.count < 3_000_000 else { throw WorkBackgroundError.invalidResponse }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw WorkBackgroundError.invalidResponse }
        guard let parsed = payload.parse, payload.error == nil,
              parsed.pageid == article.pageID, parsed.revid == article.revision else {
            throw WorkBackgroundError.invalidResponse
        }
        return parsed
    }

    private static func candidates(_ sections: [Section]) throws -> [CandidateSection] {
        var result: [CandidateSection] = []
        var musicThemes: [CandidateSection] = []
        var ancestors: [(level: Int, heading: String)] = []
        var seen = Set<String>()
        for (offset, section) in sections.enumerated() {
            guard let level = Int(section.level), (1...6).contains(level) else { throw WorkBackgroundError.invalidResponse }
            while let last = ancestors.last, last.level >= level { ancestors.removeLast() }
            let heading = try SwiftSoup.parseBodyFragment(section.line).text()
            let path = ancestors.map(\.heading) + [heading]
            let nextLevel = offset + 1 < sections.count ? Int(sections[offset + 1].level) : nil
            let leaf = nextLevel.map { $0 <= level } ?? true
            if leaf, section.index.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
               !section.anchor.isEmpty, !path.contains(where: excluded), seen.insert(section.index).inserted {
                let source = Section(index: section.index, line: heading, level: section.level, anchor: section.anchor)
                if musicThemeHeading(heading) {
                    musicThemes.append(CandidateSection(section: source, isMusicTheme: true))
                } else if path.contains(where: creative) {
                    result.append(CandidateSection(section: source, isMusicTheme: false))
                }
            }
            ancestors.append((level, heading))
        }
        // The narrow thematic mode only uses capacity left by established
        // creative sections. It never increases the four-section request cap.
        return result + musicThemes
    }

    private static func musicThemeHeading(_ heading: String) -> Bool {
        ["themes", "major themes", "主题", "主題", "主要主题", "主要主題"].contains(plainText(heading).lowercased())
    }

    private static func excluded(_ heading: String) -> Bool {
        let chinese = ["剧情", "劇情", "情节", "情節", "故事", "作品设定", "作品設定", "人物", "角色", "名单", "名單", "人员", "人員", "曲目", "评价", "評價", "发行", "發行", "发布", "發布", "反响", "反響", "商业", "商業", "相关产品", "相關產品", "现场表演", "現場表演", "票房", "奖项", "獎項", "榜单", "榜單", "注释", "註釋", "参考", "參考", "资料来源", "資料來源", "外部"]
        if chinese.contains(where: heading.contains) { return true }
        return heading.range(of: #"\b(plot|story|setting|synopsis|characters|cast|personnel|credits|tracklist|track listing|reception|release|awards|charts|references|notes|external links)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func creative(_ heading: String) -> Bool {
        let chinese = ["创作", "創作", "制作", "製作", "录制", "錄製", "录音", "錄音", "作曲", "编曲", "編曲", "词曲", "詞曲", "配乐", "配樂", "音乐", "音樂", "拍摄", "拍攝", "摄影", "攝影", "剧本", "劇本", "写作", "寫作", "选角", "選角", "背景與概念", "背景与概念", "書名", "书名", "命名"]
        if chinese.contains(where: heading.contains) { return true }
        return heading.range(of: #"\b(production|development|writing|recording|composition|music|soundtrack|filming|cinematography|screenplay|set design|casting|naming|title)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func excerpts(html: String, section: Section, article: WikiArticleIdentity,
                                 focusedByID: inout [String: WorkBackgroundExcerpt]) throws -> [WorkBackgroundExcerpt] {
        let document = try SwiftSoup.parse(html)
        // Remove containers before selecting paragraphs, so footnotes, tables,
        // navigation, captions and error messages can never become prose.
        try document.select("table, figure, figcaption, .thumb, .gallery, .navbox, .infobox, .hatnote, .metadata, .ambox, .references, .reflist, .mw-references-wrap, script, style").remove()
        var result: [WorkBackgroundExcerpt] = []
        for (offset, paragraph) in try document.select("p").array().prefix(50).enumerated() {
            guard try paragraph.select(".error, .mw-ext-cite-error").isEmpty(),
                  try hasInlineCitation(paragraph) else { continue }
            let projection = try leadProjection(paragraph)
            try paragraph.select(".reference, .error, .mw-ext-cite-error, .noprint, .mw-editsection").remove()
            let full = try paragraph.text().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard full.count <= 20_000, projection.text == full,
                  let body = shortExcerpt(projection, limit: article.language == "zh" ? 140 : 320) else { continue }
            var url = URLComponents(string: "https://\(article.language).wikipedia.org/w/index.php")!
            url.queryItems = [URLQueryItem(name: "oldid", value: String(article.revision))]
            url.fragment = section.anchor
            guard let sourceURL = url.url?.absoluteString else { throw WorkBackgroundError.invalidResponse }
            let references = try articleReferences(in: paragraph, body: body, article: article)
            let excerpt = WorkBackgroundExcerpt(
                id: "\(article.language):\(article.pageID):\(article.revision):\(section.index):\(offset)",
                heading: section.line, body: body, sourceParagraph: full,
                source: Source(title: "维基百科 · \(article.title)", detail: "章节摘录 · CC BY-SA 4.0 · 原始引文未独立核验", url: sourceURL),
                language: article.language, references: references.isEmpty ? nil : references
            )
            result.append(excerpt)
            if let focused = try focusedContinuation(excerpt, projection: projection, article: article) {
                focusedByID[excerpt.id] = focused
            }
        }
        return result
    }

    /// A continuation may start at its useful sentence instead of at a staff
    /// list. It stays inside the already eligible prefix and never changes the
    /// baseline pair or source prose. Preparation checks the retained original
    /// before choosing a sentence that might omit another creative destination.
    private static func focusedContinuation(_ excerpt: WorkBackgroundExcerpt, projection: LeadProjection,
                                            article: WikiArticleIdentity) throws -> WorkBackgroundExcerpt? {
        guard let originalReferences = excerpt.references, !originalReferences.isEmpty else { return nil }
        var candidates: [WorkBackgroundExcerpt] = []
        for range in completeLeadSentences(projection) {
            guard NSMaxRange(range) <= excerpt.body.utf16.count else { break }
            let body = (projection.text as NSString).substring(with: range)
            guard body.count >= 20, body.count < excerpt.body.count,
                  independentSentenceOpening(body) else { continue }
            var references: [WikiArticleReference] = []
            var seen = Set<String>()
            for anchor in projection.anchors {
                guard anchor.range.location >= range.location, NSMaxRange(anchor.range) <= NSMaxRange(range),
                      let reference = try articleReference(anchor.element, article: article),
                      seen.insert(reference.id).inserted else { continue }
                references.append(reference)
                if references.count == 8 { break }
            }
            // Never borrow an identically named anchor from outside this span.
            guard !references.isEmpty else { continue }
            let focused = WorkBackgroundExcerpt(
                id: excerpt.id + ":focus:\(range.location):\(range.length)",
                heading: excerpt.heading, body: body, sourceParagraph: excerpt.sourceParagraph,
                source: Source(title: excerpt.source.title,
                               detail: "章节单句摘录 · CC BY-SA 4.0 · 原始引文未独立核验", url: excerpt.source.url),
                language: excerpt.language, references: references, derivedFromExcerptID: excerpt.id
            )
            if readingPriority(focused) >= 2 { candidates.append(focused) }
        }
        return ranked(candidates).first
    }

    private static func independentSentenceOpening(_ body: String) -> Bool {
        // Conservative exclusion of references whose subject lives in a prior
        // sentence. These lexical checks do not claim general comprehension.
        let dependent = #"^(?:he|she|they|it|his|her|their|its|this|that|these|those|also|however|therefore|the former|the latter)\b"#
        guard body.range(of: dependent, options: [.regularExpression, .caseInsensitive]) == nil,
              !["他", "她", "它", "其", "这", "這", "该", "該", "上述", "此外", "因此"].contains(where: body.hasPrefix),
              let first = body.first, !"\"'“‘「『".contains(first) else { return false }
        return true
    }

    /// A lead often puts a concrete creative account after the release summary.
    /// Retain complete cited sentences at their actual DOM text positions, not
    /// a name-matched slice of the plaintext introduction. No prose is generated.
    private static func leadExcerpts(html: String, article: WikiArticleIdentity) throws -> [WorkBackgroundExcerpt] {
        let document = try SwiftSoup.parse(html)
        try document.select("table, figure, figcaption, .thumb, .gallery, .navbox, .infobox, .hatnote, .metadata, .ambox, .references, .reflist, .mw-references-wrap, script, style").remove()
        var result: [WorkBackgroundExcerpt] = []
        var seenBodies = Set<String>()
        var url = URLComponents(string: "https://\(article.language).wikipedia.org/w/index.php")!
        url.queryItems = [URLQueryItem(name: "oldid", value: String(article.revision))]
        guard let sourceURL = url.url?.absoluteString else { throw WorkBackgroundError.invalidResponse }
        for (paragraphIndex, paragraph) in try document.select("p").array().prefix(50).enumerated() {
            guard try paragraph.select(".error, .mw-ext-cite-error").isEmpty(),
                  try hasInlineCitation(paragraph) else { continue }
            let projection = try leadProjection(paragraph)
            try paragraph.select(".reference, .error, .mw-ext-cite-error, .noprint, .mw-editsection").remove()
            guard projection.text.count <= 20_000,
                  projection.text == plainText(try paragraph.text()) else { continue }
            for (sentenceIndex, range) in completeLeadSentences(projection).enumerated() {
                let body = (projection.text as NSString).substring(with: range)
                let limit = article.language == "zh" ? 140 : 320
                // Exactly one original sentence; the established 25% first-
                // sentence allowance never licenses joining over-budget prose.
                guard body.count >= 20, body.count <= limit + limit / 4,
                      creativeLeadSentence(body),
                      projection.citations.contains(where: { $0 > range.location && $0 <= NSMaxRange(range) }),
                      seenBodies.insert(body).inserted else { continue }
                var references: [WikiArticleReference] = []
                var seenTitles = Set<String>()
                for anchor in projection.anchors {
                    guard anchor.range.location >= range.location, NSMaxRange(anchor.range) <= NSMaxRange(range),
                          let reference = try articleReference(anchor.element, article: article),
                          seenTitles.insert(reference.title).inserted else { continue }
                    references.append(reference)
                    if references.count == 8 { break }
                }
                result.append(WorkBackgroundExcerpt(
                    id: "\(article.language):\(article.pageID):\(article.revision):0:\(paragraphIndex):\(sentenceIndex)",
                    heading: "创作资料", body: body, sourceParagraph: projection.text,
                    source: Source(title: "维基百科 · \(article.title)", detail: "导语摘录 · CC BY-SA 4.0 · 原始引文未独立核验", url: sourceURL),
                    language: article.language, references: references.isEmpty ? nil : references
                ))
            }
        }
        return result
    }

    /// This is a separate, deliberately narrow mode. A Themes heading does not
    /// make its paragraphs creative material. Only a cited musical prefix can
    /// be displayed; later metaphysics, character discussion or plot stays out.
    private static func musicThemeExcerpts(html: String, section: Section, article: WikiArticleIdentity) throws -> [WorkBackgroundExcerpt] {
        let document = try SwiftSoup.parse(html)
        try document.select("table, figure, figcaption, .thumb, .gallery, .navbox, .infobox, .hatnote, .metadata, .ambox, .references, .reflist, .mw-references-wrap, script, style").remove()
        var result: [WorkBackgroundExcerpt] = []
        for (paragraphIndex, paragraph) in try document.select("p").array().prefix(50).enumerated() {
            guard try paragraph.select(".error, .mw-ext-cite-error").isEmpty(),
                  try hasInlineCitation(paragraph) else { continue }
            let projection = try leadProjection(paragraph)
            try paragraph.select(".reference, .error, .mw-ext-cite-error, .noprint, .mw-editsection").remove()
            guard projection.text.count <= 20_000,
                  projection.text == plainText(try paragraph.text()) else { continue }
            let limit = article.language == "zh" ? 140 : 320
            var end = 0
            for range in completeLeadSentences(projection).prefix(2) {
                let sentence = (projection.text as NSString).substring(with: range)
                guard thematicMusicSentence(sentence),
                      projection.citations.contains(where: { $0 > range.location && $0 <= NSMaxRange(range) }) else { break }
                let prefix = (projection.text as NSString).substring(to: NSMaxRange(range))
                guard prefix.count <= limit || (end == 0 && prefix.count <= limit + limit / 4) else { break }
                end = NSMaxRange(range)
            }
            guard end > 0 else { continue }
            let body = (projection.text as NSString).substring(to: end)
            guard body.count >= 20 else { continue }
            var references: [WikiArticleReference] = []
            var seenTitles = Set<String>()
            for anchor in projection.anchors {
                guard NSMaxRange(anchor.range) <= end,
                      let reference = try articleReference(anchor.element, article: article),
                      seenTitles.insert(reference.title).inserted else { continue }
                references.append(reference)
                if references.count == 8 { break }
            }
            // The resolver will still verify every exact target's creative
            // identity. A lexical mention without an actual anchor is not an
            // entry point, and this extraction creates no relationship edge.
            guard !references.isEmpty else { continue }
            var url = URLComponents(string: "https://\(article.language).wikipedia.org/w/index.php")!
            url.queryItems = [URLQueryItem(name: "oldid", value: String(article.revision))]
            url.fragment = section.anchor
            guard let sourceURL = url.url?.absoluteString else { throw WorkBackgroundError.invalidResponse }
            result.append(WorkBackgroundExcerpt(
                id: "\(article.language):\(article.pageID):\(article.revision):\(section.index):music:\(paragraphIndex)",
                heading: section.line, body: body, sourceParagraph: projection.text,
                source: Source(title: "维基百科 · \(article.title)", detail: "音乐主题短摘 · CC BY-SA 4.0 · 原始引文未独立核验", url: sourceURL),
                language: article.language, references: references
            ))
        }
        return result
    }

    private static func thematicMusicSentence(_ text: String) -> Bool {
        let lower = text.lowercased()
        let musicalSubject = #"^(?:(?:the|a|an)\s+)?(?:music\b|(?:power|beauty|role|use|importance)(?:\s+and\s+(?:power|beauty|role|use|importance))?\s+of\s+music\b)"#
        let musicalContext = #"\b(themes?|title|metaphor|motifs?|central ideas?|communicative medium)\b"#
        if lower.range(of: musicalSubject, options: .regularExpression) != nil,
           lower.range(of: musicalContext, options: .regularExpression) != nil { return true }
        return text.range(of: #"^(?:音乐|音樂)(?!家)"#, options: .regularExpression) != nil
            && ["主题", "主題", "书名", "書名", "象征", "象徵", "隐喻", "隱喻", "意象"].contains(where: text.contains)
    }

    private struct LeadProjection {
        let text: String
        let anchors: [LeadAnchor]
        let citations: [Int]
    }
    private struct LeadAnchor {
        let element: Element
        let range: NSRange
    }

    /// Text, anchor spans and citation positions are projected together in one
    /// DOM traversal. Repeated names in another sentence cannot borrow links.
    /// Only whitespace is normalized, as with the existing paragraph extractor.
    private static func leadProjection(_ paragraph: Element) throws -> LeadProjection {
        var text = ""
        var pendingSpace = false
        var anchors: [LeadAnchor] = []
        var citations: [Int] = []
        func append(_ value: String) {
            for character in value {
                if character.isWhitespace { pendingSpace = !text.isEmpty }
                else {
                    if pendingSpace { text.append(" "); pendingSpace = false }
                    text.append(character)
                }
            }
        }
        func walk(_ node: Node) throws {
            if let value = node as? TextNode { append(value.getWholeText()); return }
            guard let element = node as? Element else {
                for child in node.getChildNodes() { try walk(child) }
                return
            }
            if element.hasClass("reference") {
                if ["sup", "span"].contains(element.tagName()), try hasInlineCitation(element) {
                    citations.append(text.utf16.count)
                }
                return
            }
            if ["noprint", "mw-editsection", "error", "mw-ext-cite-error"].contains(where: element.hasClass) { return }
            if element.tagName() == "br" { append(" "); return }
            let start = text.utf16.count
            for child in element.getChildNodes() { try walk(child) }
            if element.tagName() == "a", element.hasAttr("href") {
                let end = text.utf16.count
                let rendered = (text as NSString).substring(with: NSRange(location: start, length: end - start))
                let label = plainText(rendered)
                if !label.isEmpty {
                    anchors.append(LeadAnchor(element: element,
                        range: NSRange(location: end - label.utf16.count, length: label.utf16.count)))
                }
            }
        }
        try walk(paragraph)
        return LeadProjection(text: text, anchors: anchors, citations: citations)
    }

    /// Foundation handles ordinary abbreviations; protected anchor spans and
    /// paired punctuation prevent a band/title's period or exclamation mark
    /// from turning half a source sentence into a new account.
    private static func completeLeadSentences(_ projection: LeadProjection) -> [NSRange] {
        let text = projection.text
        var result: [NSRange] = []
        var start = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let raw = String(text[start..<range.upperBound])
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var unquoted = body
            while let last = unquoted.last, "\"'”’」』）》〉)]} ".contains(last) { unquoted.removeLast() }
            guard let last = unquoted.last, "。！？.!?".contains(last), balancedPunctuation(body) else { return }
            let leading = raw.prefix(while: \.isWhitespace).utf16.count
            let bodyStart = NSRange(start..<start, in: text).location + leading
            let punctuation = bodyStart + unquoted.utf16.count - String(last).utf16.count
            // A tokenizer may stop after a closed parenthetical or book title
            // even when the source continues outside it. The punctuation's
            // position, not merely the final balanced delimiters, determines
            // whether it can terminate the surrounding source sentence.
            guard !insideGrouping(before: String(unquoted.dropLast())) else { return }
            if let anchor = projection.anchors.first(where: { NSLocationInRange(punctuation, $0.range) }) {
                // A name ending in a full stop can also end the sentence.
                // Require the actual DOM citation at that exact sentence end,
                // not any earlier citation in the sentence, to honor that break.
                guard NSMaxRange(anchor.range) == punctuation + String(last).utf16.count,
                      projection.citations.contains(bodyStart + body.utf16.count) else { return }
            }
            result.append(NSRange(location: bodyStart, length: body.utf16.count))
            start = range.upperBound
        }
        return result
    }

    private static func insideGrouping(before text: String) -> Bool {
        let pairs: [Character: Character] = ["(": ")", "（": "）", "[": "]", "【": "】", "{": "}", "《": "》", "〈": "〉"]
        let closers = Set(pairs.values)
        var stack: [Character] = []
        for character in text {
            if let closer = pairs[character] { stack.append(closer) }
            else if closers.contains(character), stack.last == character { stack.removeLast() }
        }
        return !stack.isEmpty
    }

    private static func balancedPunctuation(_ value: String) -> Bool {
        let pairs: [Character: Character] = ["(": ")", "（": "）", "[": "]", "【": "】", "《": "》", "〈": "〉", "「": "」", "『": "』", "“": "”"]
        let closers = Set(pairs.values)
        var stack: [Character] = []
        for character in value {
            if character == "\"" {
                if stack.last == character { stack.removeLast() } else { stack.append(character) }
            } else if let closer = pairs[character] {
                stack.append(closer)
            } else if closers.contains(character), stack.last == character {
                stack.removeLast()
            }
        }
        return stack.isEmpty
    }

    private static func creativeLeadSentence(_ text: String) -> Bool {
        let chineseAction = #"作[詞词](?!家|者)|作曲(?!家|者)|[編编]曲(?!家|者)|(?:[錄录]製|[录錄]制|[錄录]音|混音)(?![專专][輯辑]|室|[師师])|改[編编](?:自|了)|重新[設设][計计]"#
        if text.range(of: chineseAction, options: .regularExpression) != nil || reusesCreativeMaterial(text) { return true }
        let englishAction = #"\b(written by|composed by|arranged by|adapted from|redesigned)\b|\bmixed\s+(?:by|at|in|with)\b|\brecorded\s+(?:(?:by|at|with|in|on|for|during)\b|(?:the|a|an)\s+(?:piano|guitar|music|vocals?|song|track|soundtrack)\b)"#
        return text.range(of: englishAction, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func reusesCreativeMaterial(_ text: String) -> Bool {
        let reuse = ["采用", "採用", "引用", "借用", "取自", "取樣", "取样", "采样", "採樣"]
        let material = ["歌词", "歌詞", "旋律", "乐句", "樂句", "曲调", "曲調", "录音", "錄音"]
        if reuse.contains(where: text.contains) && material.contains(where: text.contains) { return true }
        return text.range(of: #"\b(sampled|samples|interpolat(?:es|ed|ion))\b|\b(reuses|quotes|borrows)\b.{0,80}\b(lyrics|melody|recording)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Compare the bounded section pool before taking the two visible accounts.
    /// Signals rank unchanged source sentences; they neither establish a fact
    /// nor certify a linked article's creative identity. There are no title,
    /// author or item-ID exceptions, and original order resolves equal choices.
    private static func ranked(_ excerpts: [WorkBackgroundExcerpt]) -> [WorkBackgroundExcerpt] {
        excerpts.enumerated().sorted { lhs, rhs in
            let leftPriority = readingPriority(lhs.element)
            let rightPriority = readingPriority(rhs.element)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            let leftComplete = lhs.element.body == lhs.element.sourceParagraph
            let rightComplete = rhs.element.body == rhs.element.sourceParagraph
            if leftComplete != rightComplete { return leftComplete }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func readingPriority(_ excerpt: WorkBackgroundExcerpt) -> Int {
        let text = excerpt.body.lowercased()
        func contains(_ words: [String]) -> Bool { words.contains(where: text.contains) }
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        // A recording action plus something the listener can actually hear.
        // A bare "composed by" credit does not meet both conditions.
        let soundAction = contains(["录音", "錄音", "录下", "錄下", "录制", "錄製", "混音", "编曲", "編曲", "演奏", "采集", "採集"])
            || matches(#"\b(record(?:ed|ing)?|tapping|mix(?:ed|ing)|arrang(?:ed|ing)|synchroni[sz](?:ed|ing))\b"#)
        let soundDetail = contains(["钢琴", "鋼琴", "脚步", "腳步", "敲", "声部", "聲部", "音轨", "音軌", "节奏", "節奏", "物件", "物体", "物體", "乐器", "樂器"])
            || matches(#"\b(piano|footsteps|tapping|objects|instruments|tempo|microphones?|tracks|breath)\b"#)
        if soundAction && soundDetail { return 4 }

        // A source-described use of existing musical material is a concrete
        // creative choice. Ranking this sentence does not assert a graph edge.
        if reusesCreativeMaterial(text) { return 3 }

        // Concrete choices in image-making or performance, not staff lists.
        let makingAction = contains(["改成", "修改", "改车色", "改車色", "试镜", "試鏡", "考取", "亲自", "親自", "重新设计", "重新設計"])
            || matches(#"\b(drew|redesigned|re-designed|auditioned|chose|changed|replaced)\b"#)
        let makingDetail = contains(["镜头", "鏡頭", "剧本", "劇本", "取景", "风景", "風景", "车色", "車色", "驾驶", "駕駛", "分镜", "分鏡"])
            || matches(#"\b(storyboards?|lens|lenses|color|colour|costumes?|locations?|lighting)\b"#)
        if makingAction && makingDetail { return 3 }

        if thematicMusicSentence(excerpt.body), !(excerpt.references?.isEmpty ?? true) { return 2 }

        // These are source-anchor candidates, not yet verified graph edges.
        let musicConnection = contains(["主题曲", "主題曲", "片头", "片頭", "片尾", "演唱", "采样", "採樣", "取样", "取樣"])
            || matches(#"\b(theme song|opening theme|ending theme|end credits|sampled|samples)\b"#)
        if musicConnection, !(excerpt.references?.isEmpty ?? true) { return 2 }

        let chronology = contains(["公布", "宣布", "发表", "發表", "发行", "發行", "发布", "發布", "上映"])
            || matches(#"\b(announced|announcement|released|release date|premiered)\b"#)
        return chronology ? 0 : 1
    }

    private static func articleReferences(in paragraph: Element, body: String, article: WikiArticleIdentity) throws -> [WikiArticleReference] {
        var result: [WikiArticleReference] = []
        var seenTitles = Set<String>()
        for link in try paragraph.select("a[href]").array() {
            let label = plainText(try link.text())
            guard !label.isEmpty, body.contains(label),
                  let prefix = textBefore(link, in: paragraph),
                  body.hasPrefix(plainText(prefix + label)),
                  let reference = try articleReference(link, article: article),
                  seenTitles.insert(reference.title).inserted else { continue }
            // These are exact article-link candidates only. Their work/creator
            // type and final QID must still be verified by the UI resolver.
            result.append(reference)
            // Keep a bounded candidate pool. The presentation resolver chooses
            // its visible links after unsupported identities are filtered out.
            if result.count == 8 { break }
        }
        return result
    }

    private static func articleReference(_ link: Element, article: WikiArticleIdentity) throws -> WikiArticleReference? {
        guard !link.hasClass("new"), !link.hasClass("mw-disambig") else { return nil }
        let label = plainText(try link.text())
        guard !label.isEmpty else { return nil }
        let href = try link.attr("href")
        guard let url = URLComponents(string: href), url.user == nil, url.password == nil, url.port == nil,
              url.scheme == nil || url.scheme?.lowercased() == "https",
              url.host == nil || url.host?.lowercased() == "\(article.language).wikipedia.org",
              url.query == nil else { return nil }
        let path = url.percentEncodedPath
        let encodedTitle: String
        if path.hasPrefix("/wiki/") { encodedTitle = String(path.dropFirst(6)) }
        else if url.host == nil && path.hasPrefix("./") { encodedTitle = String(path.dropFirst(2)) }
        else { return nil }
        guard let decoded = encodedTitle.removingPercentEncoding else { return nil }
        // The exact href title is identity. A tooltip/converted label is only
        // presentation, never a fuzzy replacement for the original link target.
        let title = articleTitle(decoded)
        guard !title.isEmpty, !hasNamespace(title),
              title.caseInsensitiveCompare(articleTitle(article.title)) != .orderedSame else { return nil }
        return WikiArticleReference(label: label, title: title, language: article.language)
    }

    private static func plainText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func articleTitle(_ value: String) -> String {
        plainText(value.replacingOccurrences(of: "_", with: " ")).precomposedStringWithCanonicalMapping
    }

    private static func hasNamespace(_ title: String) -> Bool {
        guard let colon = title.firstIndex(of: ":") else { return false }
        let prefix = plainText(String(title[..<colon])).lowercased()
        if prefix.isEmpty { return true }
        let namespaces: Set<String> = [
            "media", "special", "talk", "user", "user talk", "wikipedia", "wikipedia talk", "project", "project talk",
            "file", "file talk", "image", "image talk", "mediawiki", "mediawiki talk", "template", "template talk",
            "help", "help talk", "category", "category talk", "portal", "portal talk", "draft", "draft talk",
            "book", "book talk", "module", "module talk", "timedtext", "timedtext talk", "topic",
            "媒体", "媒體", "特殊", "讨论", "討論", "用户", "用戶", "使用者", "用户讨论", "用戶討論", "使用者討論",
            "维基百科", "維基百科", "维基百科讨论", "維基百科討論", "文件", "檔案", "文件讨论", "檔案討論", "图像", "圖像",
            "模板", "样板", "樣板", "模板讨论", "模板討論", "样板讨论", "樣板討論", "帮助", "幫助", "帮助讨论", "幫助討論",
            "分类", "分類", "分类讨论", "分類討論", "主题", "主題", "主题讨论", "主題討論", "草稿", "草稿讨论", "草稿討論",
            "模块", "模組", "模块讨论", "模組討論", "wp", "wt", "cat", "h", "p", "t", "mos",
            "en", "zh", "ja", "commons", "wikt", "wiktionary", "wikidata"
        ]
        return namespaces.contains(prefix)
    }

    /// Locate the actual anchor, rather than matching another occurrence of the
    /// same name in an earlier sentence when this anchor lies after the cutoff.
    private static func textBefore(_ target: Element, in paragraph: Element) -> String? {
        var text = ""
        func walk(_ node: Node) -> Bool {
            if node === target { return true }
            if let value = node as? TextNode { text += value.getWholeText(); return false }
            if let element = node as? Element, element.tagName() == "br" { text += " " }
            for child in node.getChildNodes() { if walk(child) { return true } }
            return false
        }
        return walk(paragraph) ? text : nil
    }

    private static func hasInlineCitation(_ paragraph: Element) throws -> Bool {
        for link in try paragraph.select("sup.reference a[href], span.reference a[href]").array() {
            let href = try link.attr("href")
            if (href.removingPercentEncoding ?? href).hasPrefix("#cite_note") { return true }
        }
        return false
    }

    private static func shortExcerpt(_ projection: LeadProjection, limit: Int) -> String? {
        let paragraph = projection.text as NSString
        var value: String?
        // Reuse the DOM-aware boundaries so a candidate cannot stop in the
        // middle of a linked title or leave a quoted statement unfinished.
        for range in completeLeadSentences(projection) {
            let candidate = paragraph.substring(to: NSMaxRange(range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count > limit {
                // One complete first sentence can exceed the reading budget
                // by at most 25%. Do not discard a 322-character sentence at
                // an English 320 boundary, or extend a short prefix with more
                // sentences. The source paragraph remains available in full.
                if value == nil, candidate.count <= limit + limit / 4 { value = candidate }
                break
            }
            value = candidate
        }
        guard let value else { return nil }
        return value.count >= 20 ? value : nil
    }

    private struct Payload: Decodable { let parse: Parsed?; let error: APIError? }
    private struct APIError: Decodable { let code: String? }
    private struct Parsed: Decodable { let pageid: Int; let revid: Int; let sections: [Section]?; let text: String? }
    private struct Section: Decodable { let index: String; let line: String; let level: String; let anchor: String }
    private struct CandidateSection { let section: Section; let isMusicTheme: Bool }
}
