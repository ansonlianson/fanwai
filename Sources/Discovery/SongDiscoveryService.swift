import Foundation
import SwiftSoup

struct SongDiscoveryDestination: Sendable {
    let qid: String
    let source: Source
}

struct SongDiscoveryResult: Sendable {
    var destinations: [SongDiscoveryDestination] = []
    var retryableFailure: String?
}

protocol SongDiscoveryFetching: Sendable {
    func discover(title: String, artistIDs: [String]) async throws -> SongDiscoveryResult
}

/// Catalog recordings keep their identity. A verified artist's theme-song table
/// can supply a sourced connection, but cannot turn a recording into a Wikidata
/// composition or supply an invented story. Unsupported layouts are left alone.
actor SongDiscoveryService: SongDiscoveryFetching {
    private let session: URLSession
    private let knowledge: KnowledgeGraphService
    private let contexts: WorkContextService
    private let resolver: WikipediaWorkResolver
    private var artistArticles: [String: WikiArticleIdentity] = [:]
    private var articleHTML: [String: String] = [:]

    init(session: URLSession = PianwaiRuntime.session) {
        self.session = session
        knowledge = KnowledgeGraphService(session: session)
        contexts = WorkContextService(session: session)
        resolver = WikipediaWorkResolver(session: session)
    }

    func discover(title: String, artistIDs: [String]) async throws -> SongDiscoveryResult {
        var result = SongDiscoveryResult()
        var seen = Set<String>()
        for artistID in Array(Set(artistIDs)).sorted().prefix(3) {
            try Task.checkCancellation()
            do {
                guard let article = try await article(for: artistID) else { continue }
                let html = try await html(for: article)
                for candidate in try Self.candidates(html: html, title: title, article: article).prefix(4) {
                    do {
                        guard let qid = try await resolver.resolveCreative(candidate.reference) else { continue }
                        if seen.insert(qid).inserted {
                            result.destinations.append(.init(qid: qid, source: candidate.source))
                        }
                    } catch {
                        try Task.checkCancellation()
                        result.retryableFailure = "歌曲背景暂未完整载入。"
                    }
                }
            } catch {
                try Task.checkCancellation()
                result.retryableFailure = "歌曲背景暂未完整载入。"
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func article(for artistID: String) async throws -> WikiArticleIdentity? {
        if let cached = artistArticles[artistID] { return cached }
        guard let identity = try await knowledge.resolveAppleArtist(id: artistID) else { return nil }
        let context = try await contexts.fetch(qid: identity.qid, includeDisplayTitle: false)
        guard let article = context.article else {
            if context.introductionUnavailable { throw WorkContextError.unavailable }
            return nil
        }
        guard article.isValid, article.qid == identity.qid else { throw WorkContextError.invalidIdentity }
        if artistArticles.count >= 32 { artistArticles.removeAll(); articleHTML.removeAll() }
        artistArticles[artistID] = article
        return article
    }

    private func html(for article: WikiArticleIdentity) async throws -> String {
        if let cached = articleHTML[article.cacheKey] { return cached }
        var url = URLComponents(string: "https://\(article.language).wikipedia.org/w/api.php")!
        url.queryItems = ["action": "parse", "oldid": String(article.revision), "prop": "text",
                          "format": "json", "formatversion": "2", "disableeditsection": "1"]
            .sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 18
        request.setValue("Pianwai/0.1 (personal reading app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 3_000_000 else { throw WorkContextError.unavailable }
        let payload = try JSONDecoder().decode(ParseResponse.self, from: data)
        guard let parsed = payload.parse, parsed.pageid == article.pageID,
              parsed.revid == article.revision else { throw WorkContextError.invalidResponse }
        articleHTML[article.cacheKey] = parsed.text
        return parsed.text
    }

    struct Candidate: Sendable {
        let reference: WikiArticleReference
        let source: Source
    }

    static func candidates(html: String, title: String, article: WikiArticleIdentity) throws -> [Candidate] {
        guard article.isValid, !normalized(title).isEmpty else { return [] }
        let document = try SwiftSoup.parse(html)
        try document.select("sup.reference, .mw-editsection").remove()
        var heading = ""
        var result: [Candidate] = []
        var seen = Set<String>()
        for element in try document.select("h2, h3, h4, table.wikitable") {
            if element.tagName() != "table" { heading = try element.text(); continue }
            let section = normalized(heading)
            guard ["主题曲", "主題曲", "tie-ins", "theme songs", "soundtracks"].contains(where: section.contains) else { continue }
            // A merged cell can carry a previous row's identity. Until a complete
            // grid is supported, reject such a table rather than borrow its link.
            guard try element.select("[rowspan], [colspan], table").filter({ $0 !== element }).isEmpty else { continue }
            let rows = try element.select("tr").array()
            guard let header = rows.first else { continue }
            let headings = try header.children().array().map { normalized(try $0.text()) }
            let songColumns = headings.indices.filter { ["歌曲名称", "歌曲名稱", "歌曲", "song", "song title"].contains(headings[$0]) }
            let workColumns = headings.indices.filter { ["作品名称", "作品名稱", "作品", "work", "series", "film", "tie-in"].contains(headings[$0]) }
            guard songColumns.count == 1, workColumns.count == 1,
                  let songColumn = songColumns.first, let workColumn = workColumns.first else { continue }
            for row in rows.dropFirst() {
                let cells = row.children().array()
                guard cells.count == headings.count,
                      normalized(try cells[songColumn].text()) == normalized(title) else { continue }
                let links = try cells[workColumn].select("a[href]").array()
                // More than one work link in this cell needs editorial disambiguation.
                guard links.count == 1, let link = links.first,
                      let reference = try reference(link, language: article.language) else { continue }
                if seen.insert(reference.id).inserted {
                    let source = Source(title: "维基百科 · " + article.title,
                        detail: heading + " · " + (try row.text()) + " · CC BY-SA 4.0",
                        url: "https://\(article.language).wikipedia.org/w/index.php?oldid=\(article.revision)")
                    result.append(.init(reference: reference, source: source))
                }
            }
        }
        return result
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」『』"))
        // Literal Han script conversion only, no translation, fuzzy matching,
        // removal of version qualifiers, or substring-based song identities.
        return folded.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? folded
    }

    private static func reference(_ link: Element, language: String) throws -> WikiArticleReference? {
        let href = try link.attr("href")
        guard href.hasPrefix("/wiki/"), !href.contains("#"), !href.contains("?"),
              let title = String(href.dropFirst(6)).removingPercentEncoding?.replacingOccurrences(of: "_", with: " "),
              !title.isEmpty, !title.contains(":"), !title.contains("/"),
              !link.hasClass("new") else { return nil }
        return .init(label: try link.text(), title: title, language: language)
    }

    private struct ParseResponse: Decodable {
        let parse: Parsed?
        struct Parsed: Decodable { let pageid: Int; let revid: Int; let text: String }
    }
}
