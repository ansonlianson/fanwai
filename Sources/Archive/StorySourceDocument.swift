import Foundation
import SwiftSoup

extension StoryMaterial {
    static func appleEditorial(text: String?, url: URL?, title: String, location: String) -> [StoryMaterial] {
        guard let text, let url, url.scheme == "https", url.host == "music.apple.com",
              let plain = try? SwiftSoup.parse(text).text(), !plain.isEmpty else { return [] }
        let source = Source(title: title + " · Apple Music", detail: "editorialNotes", url: url.absoluteString)
        return [.init(id: url.absoluteString + "#" + location, source: source, text: plain, location: location)]
    }
}

struct StorySourceDocument {
    struct Paragraph: Equatable {
        let text: String
        let index: Int
        let heading: String
        let mentionsNeighbor: Bool
    }
    let title: String
    let paragraphs: [Paragraph]
    let references: [String]
    let links: [String]
    struct NamedLink { let url: String; let text: String }
    let namedLinks: [NamedLink]
    let plainText: String
    let restricted: Bool

    static func containsName(_ text: String, names: [String]) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return names.contains { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard name.count >= 2 else { return false }
            // Short Latin names must not match inside another word (sis/analysis).
            if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                return haystack.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: name) + "(?![a-z0-9])", options: .regularExpression) != nil
            }
            return haystack.contains(name)
        }
    }

    private static func isInterviewQuestion(_ text: String) -> Bool {
        ["──", "――", "——"].contains { text.hasPrefix($0) }
    }

    static func decode(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(8_192), as: UTF8.self).lowercased()
        if head.range(of: "charset\\s*=\\s*['\"]?(shift[_-]?jis|sjis|windows-31j)", options: .regularExpression) != nil {
            return String(data: data, encoding: .shiftJIS)
        }
        if head.range(of: "charset\\s*=\\s*['\"]?euc-jp", options: .regularExpression) != nil {
            return String(data: data, encoding: .japaneseEUC)
        }
        return String(data: data, encoding: .utf8)
    }

    static func parse(html: String, url: URL, names: [String], neighbors: [String], wikipedia: Bool = false,
                      pageAnchored: Bool = false, contextNames: [String] = [], wholeSubject: Bool = false) throws -> Self {
        let document = try SwiftSoup.parse(html, url.absoluteString)
        let namedLinks = try document.select("a[href]").array().compactMap { node -> NamedLink? in
            let href = try node.absUrl("href"), text = try node.text()
            return href.hasPrefix("https://") && !text.isEmpty ? NamedLink(url: href, text: text) : nil
        }
        let restricted = !(try document.select("input[type=password], .paywall, #paywall, [data-paywall], .subscriber-only").isEmpty())
            || html.range(of: #"\"isAccessibleForFree\"\s*:\s*(false|\"false\")"#, options: .regularExpression) != nil
        try document.select("script, style, nav, header, footer, aside, form, noscript, .advertisement, .ads, .ad, [role=navigation], .noprint, .navbox, .toc, .mw-editsection").remove()
        // Some publishers start with an empty advertisement <article>. Choose
        // the actual prose container, not simply the first matching element.
        var content = document.body() ?? document
        let selectors = wikipedia ? [".mw-parser-output"] : ["[itemprop=articleBody], .article-body, .entry-content, .post-content", "article", "main"]
        for selector in selectors {
            let ranked = try document.select(selector).array().map { node in (node, try node.select("p").text().count) }
            if let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 { content = best.0; break }
        }
        if url.host == "www.cdjournal.com", let body = try document.getElementById("NWrelart:Body") {
            // This legacy publisher has one literal prose block with <br>s,
            // including the comment's signature at the end. Keep it together
            // so the model can attribute the first-person account correctly.
            let prose = try body.text()
            try body.empty().appendElement("p").text(prose)
            content = body
        }
        // This publisher separates the speaker label from each spoken turn.
        // Keep both literal fields together so extraction cannot swap speakers.
        if url.host == "brutus.jp" {
            for turn in try content.select(".wp-block-brutus-conversation").array() {
                let speaker = try turn.select(".wp-block-brutus-conversation__speaker").text()
                let speech = try turn.select(".wp-block-brutus-conversation__content").text()
                if !speaker.isEmpty && !speech.isEmpty {
                    try turn.empty().appendElement("p").text(speaker + "：" + speech)
                }
            }
        }
        let title = try document.title().isEmpty ? (document.select("h1").first()?.text() ?? "") : document.title()
        let plain = try content.text()
        let firstParagraph = try content.select("p").array().first(where: { try !$0.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text() ?? ""
        let wholePage = pageAnchored && !wikipedia && containsName(title + "\n" + firstParagraph, names: names)
        let sourceParagraphs = try content.select("p").array().map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
        let identifiedContext = !contextNames.isEmpty && containsName(title + "\n" + plain, names: contextNames)
        let matchedIndices = sourceParagraphs.indices.filter { containsName(sourceParagraphs[$0], names: names) }
        // A track may appear on page two of an album interview. Retain its
        // question and answer together, without swallowing an unrelated review
        // elsewhere on a multi-artist page. Search results never supply prose.
        var relatedIndices = Set<Int>()
        if identifiedContext {
            for match in matchedIndices {
                relatedIndices.insert(match)
                if match > 0, isInterviewQuestion(sourceParagraphs[match - 1]) { relatedIndices.insert(match - 1) }
                if isInterviewQuestion(sourceParagraphs[match]), match + 1 < sourceParagraphs.count {
                    relatedIndices.insert(match + 1)
                }
                // A follow-up about the same recording often uses pronouns.
                // Keep at most two adjacent Q&A pairs, stopping at a new work,
                // section, or unrelated question. Never ingest the entire page.
                if isInterviewQuestion(sourceParagraphs[match]) {
                    var cursor = match + 2
                    for _ in 0..<2 {
                        while cursor < sourceParagraphs.count && sourceParagraphs[cursor].isEmpty { cursor += 1 }
                        guard cursor + 1 < sourceParagraphs.count else { break }
                        let question = sourceParagraphs[cursor]
                        let followup = containsName(question, names: contextNames)
                            || question.range(of: "レコーディング|楽曲制作|曲を作|作曲|録音|この曲|その曲|制作過程|录音|合作", options: .regularExpression) != nil
                        let regex = try NSRegularExpression(pattern: "[「『]([^」』]+)[」』]")
                        let titles = regex.matches(in: question, range: NSRange(question.startIndex..., in: question)).compactMap { Range($0.range(at: 1), in: question).map { String(question[$0]) } }
                        let differentWork = titles.contains { $0.count > 2 && !containsName($0, names: names + contextNames)
                            && $0.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) }
                        guard isInterviewQuestion(question), followup, !differentWork else { break }
                        relatedIndices.insert(cursor); relatedIndices.insert(cursor + 1)
                        cursor += 2
                    }
                }
            }
        }
        var remaining = 5_000
        var heading = "导语", index = 0, paragraphs: [Paragraph] = [], referenceIDs: [String] = []
        for node in try content.select("h1, h2, h3, h4, p").array() {
            if node.tagName() != "p" { heading = try node.text(); continue }
            index += 1
            var text = try node.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Publisher release blocks and staff lists are not interview prose.
            if text.range(of: "^(＜収録曲＞|【STAFF】|■関連リンク|■リリース情報|[0-9]+[.．]\\s)", options: .regularExpression) != nil { continue }
            if pageAnchored && !wikipedia {
                let matchingSection = !sourceParagraphs.contains(where: isInterviewQuestion)
                    && containsName(heading, names: names) && containsName(heading + "\n" + text, names: contextNames)
                let creatorComments = wholePage && identifiedContext && containsName(heading, names: contextNames)
                    && heading.range(of: "コメント|comments?|寄语", options: [.regularExpression, .caseInsensitive]) != nil
                    && text.count >= 40
                let eligible = contextNames.isEmpty ? wholePage : identifiedContext && ((wholeSubject && wholePage) || relatedIndices.contains(index - 1) || matchingSection || creatorComments)
                // A dedicated song report can carry consecutive named creator
                // comments without repeating the title in each paragraph. Keep
                // its literal opening as context; stop at the next section.
                if creatorComments, !containsName(text, names: names),
                   paragraphs.last?.heading != heading {
                    text = firstParagraph + "\n" + heading + "\n" + text
                }
                if !contextNames.isEmpty, matchingSection, text.count >= 30, !containsName(text, names: names) {
                    text = heading + "\n" + text
                }
                guard eligible, text.count <= remaining else { continue }
                remaining -= text.count
            } else if !containsName(text, names: names + neighbors) { continue }
            paragraphs.append(.init(text: text, index: index, heading: heading,
                                    mentionsNeighbor: containsName(text, names: neighbors)))
            for a in try node.select("sup.reference a[href], a[href^='#cite_note']").array() {
                if let id = try a.attr("href").split(separator: "#").last { referenceIDs.append(String(id)) }
            }
        }
        if wikipedia {
            // Discography and tie-in tables often hold the only citation for
            // a song. Use that exact row/list item to discover its source;
            // catalog cells themselves are never narrative material.
            for node in try content.select("table.wikitable tr, ul > li, ol > li").array() {
                guard try node.select("ul, ol, table").isEmpty(),
                      !node.id().hasPrefix("cite_note"),
                      !node.parents().array().contains(where: { $0.hasClass("references") || $0.hasClass("reflist") }),
                      containsName(try node.text(), names: names) else { continue }
                for a in try node.select("sup.reference a[href], a[href^='#cite_note']").array() {
                    if let id = try a.attr("href").split(separator: "#").last { referenceIDs.append(String(id)) }
                }
            }
        }
        var references: [String] = []
        for id in referenceIDs {
            if let item = try document.getElementById(id) {
                references += try item.select("a[href]").array().compactMap { node in
                    let href = try node.absUrl("href")
                    return ["http", "https"].contains(URL(string: href)?.scheme ?? "") && !(URL(string: href)?.host?.hasSuffix("wikipedia.org") ?? false) ? href : nil
                }
            }
        }
        let links = try content.select("a[href]").array().compactMap { node -> String? in
            let href = try node.absUrl("href")
            return href.hasPrefix("https://") ? href : nil
        }
        if !contextNames.isEmpty {
            var grouped: [Paragraph] = [], lastIndex = -2
            for p in paragraphs {
                if p.index == lastIndex + 1, grouped.last?.heading == p.heading, let prior = grouped.popLast() {
                    grouped.append(.init(text: prior.text + "\n" + p.text, index: prior.index, heading: prior.heading,
                                         mentionsNeighbor: prior.mentionsNeighbor || p.mentionsNeighbor))
                } else { grouped.append(p) }
                lastIndex = p.index
            }
            paragraphs = grouped
        }
        return Self(title: title, paragraphs: paragraphs, references: unique(references), links: unique(links), namedLinks: namedLinks, plainText: plain, restricted: restricted)
    }
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }
}

/// RFC 9309's longest matching rule wins, with Allow winning ties. Only the
/// strongest matching user-agent group is used; matching groups are combined.
struct StoryRobotsRules: Sendable {
    struct Rule: Sendable { let allow: Bool; let path: String }
    let rules: [Rule]
    init(_ text: String, agent: String = "Pianwai") {
        var groups: [(agents: [String], rules: [Rule])] = [], names: [String] = [], current: [Rule] = [], hasRules = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            if key == "user-agent" {
                if hasRules { groups.append((names, current)); names = []; current = []; hasRules = false }
                names.append(value.lowercased())
            } else if ["allow", "disallow"].contains(key), !names.isEmpty {
                hasRules = true
                if !value.isEmpty { current.append(.init(allow: key == "allow", path: value)) }
            }
        }
        if !names.isEmpty { groups.append((names, current)) }
        let ranked = groups.map { group in
            (group, group.agents.map { $0 == "*" ? 0 : agent.lowercased().contains($0) ? $0.count : -1 }.max() ?? -1)
        }
        let best = ranked.map(\.1).max() ?? -1
        rules = best < 0 ? [] : ranked.filter { $0.1 == best }.flatMap { $0.0.rules }
    }
    func allows(_ url: URL) -> Bool {
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        var winner: (score: Int, allow: Bool)?
        for rule in rules {
            let end = rule.path.hasSuffix("$")
            let raw = end ? String(rule.path.dropLast()) : rule.path
            let regex = "^" + raw.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + (end ? "$" : "")
            guard path.range(of: regex, options: .regularExpression) != nil else { continue }
            let score = raw.replacingOccurrences(of: "*", with: "").utf8.count
            if winner == nil || score > winner!.score || (score == winner!.score && rule.allow) { winner = (score, rule.allow) }
        }
        return winner?.allow ?? true
    }
}
