import Foundation
import SwiftSoup

struct WorkContext: Codable, Sendable {
    let qid: String
    var contentVersion: Int? = 3
    var article: WikiArticleIdentity?
    var displayTitle: String?
    var displayTitleSource: Source?
    var displayTitleState: WorkDisplayTitleState?
    var displayTitleAttemptedAt: Date?
    var introduction: String?
    var language: String?
    var introductionSource: Source?
    var introductionUnavailable = false
    var facts: [WorkContextFact] = []
    var destinations: [WorkDestination] = []
    var hasEditionCandidates: Bool?
    var editions: [EditionDestination]?
    var editionLookupUnavailable: Bool?
    var fetchedAt = Date()

    /// The first-screen excerpt omits the opening foreign-title gloss only.
    /// The complete source text remains available on expansion and in storage.
    var readingExcerpt: String? {
        guard let introduction else { return nil }
        let chars = Array(introduction)
        guard let start = chars.firstIndex(where: { $0 == "（" || $0 == "(" }), start < 90 else { return introduction }
        let closing: Character = chars[start] == "（" ? "）" : ")"
        let opening = chars[start]
        var depth = 0
        var end: Int?
        for index in start..<chars.count {
            if chars[index] == opening { depth += 1 }
            if chars[index] == closing { depth -= 1; if depth == 0 { end = index; break } }
        }
        guard let end else { return introduction }
        let gloss = String(chars[(start + 1)..<end])
        let markers = ["日语：", "日文：", "英語：", "英语：", "Japanese:", "Hepburn:"]
        guard markers.contains(where: { gloss.hasPrefix($0) }) else { return introduction }
        let before = String(chars[..<start]).trimmingCharacters(in: .whitespaces)
        let after = String(chars[(end + 1)...])
        return before + after
    }
}

enum WorkDisplayTitleState: String, Codable, Sendable {
    case available, absent, failed
}

struct WorkDisplayTitle: Sendable {
    let title: String
    let source: Source
}

protocol WorkContextFetching: Sendable {
    func fetch(qid: String, includeDisplayTitle: Bool) async throws -> WorkContext
    func fetchDisplayTitle(article: WikiArticleIdentity) async throws -> WorkDisplayTitle?
}

struct WorkContextFact: Codable, Identifiable, Sendable {
    let label: String
    let value: String
    let source: Source
    var id: String { label + ":" + value }
}

struct WorkDestination: Codable, Identifiable, Sendable {
    let title: String
    let url: String
    let source: Source
    var id: String { url }
}

enum WorkContextError: Error, LocalizedError {
    case invalidIdentity, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "这份作品资料暂不可用。"
        case .invalidResponse: "作品资料暂未完整载入。"
        case .unavailable: "暂时无法连接作品资料。"
        }
    }
}

/// Identity comes from an exact Wikidata item and its sitelink. Article search
/// and title similarity never assign an introduction to a work. Text is a
/// source excerpt, not an AI-generated story or a claim of spoiler-free content.
actor WorkContextService: WorkContextFetching {
    private let session: URLSession
    init(session: URLSession = PianwaiRuntime.session) { self.session = session }

    func fetch(qid: String, includeDisplayTitle: Bool = true) async throws -> WorkContext {
        guard Self.validQID(qid) else { throw WorkContextError.invalidIdentity }
        let url = try Self.endpoint(host: "www.wikidata.org", parameters: [
            "action": "wbgetentities", "ids": qid, "props": "labels|claims|sitelinks",
            "languages": "zh-hans|zh|en", "sitefilter": "zhwiki|enwiki"
        ])
        let payload: EntityResponse = try await load(url)
        guard payload.success == 1, let entity = payload.entities?[qid],
              entity.id == qid, entity.type == "item", entity.missing == nil else {
            throw WorkContextError.invalidResponse
        }
        var context = WorkContext(qid: qid)
        let title = entity.labels?["zh-hans"]?.value ?? entity.labels?["zh"]?.value ?? entity.labels?["en"]?.value ?? qid

        // A duration is displayed only when the unit is explicit, finite, and
        // every eligible assertion agrees; edition/cut qualifiers stay omitted.
        let durations = Self.claims(entity, "P2047").compactMap { claim -> (Double, Claim)? in
            guard claim.mainsnak.datatype == "quantity", let amount = claim.mainsnak.datavalue?.quantity,
                  let value = Double(amount.amount), value.isFinite, value > 0 else { return nil }
            let minutes: Double
            switch amount.unit {
            case "http://www.wikidata.org/entity/Q7727": minutes = value
            case "http://www.wikidata.org/entity/Q11574": minutes = value / 60
            default: return nil
            }
            guard minutes <= 10_000 else { return nil }
            return (minutes, claim)
        }
        if let duration = durations.first, durations.allSatisfy({ abs($0.0 - duration.0) < 0.01 }) {
            let number = duration.0.formatted(.number.precision(.fractionLength(0...1)))
            context.facts.append(.init(label: "时长", value: number + " 分钟",
                                       source: Self.source(qid, title, property: "P2047", claim: duration.1)))
        }
        // Qualified regional release dates cannot be flattened into a premiere.
        let years = Self.claims(entity, "P577").compactMap { claim -> (String, Claim)? in
            guard claim.mainsnak.datatype == "time", let time = claim.mainsnak.datavalue?.time,
                  time.precision >= 9, time.time.hasPrefix("+"),
                  time.calendar == "http://www.wikidata.org/entity/Q1985727" else { return nil }
            let year = String(time.time.dropFirst().prefix(4))
            guard year.count == 4, let number = Int(year), (1000...2100).contains(number) else { return nil }
            return (year, claim)
        }
        if let year = years.first, years.allSatisfy({ $0.0 == year.0 }) {
            context.facts.append(.init(label: "发行年份", value: year.0,
                                       source: Self.source(qid, title, property: "P577", claim: year.1)))
        }
        let typeIDs = Set(Self.claims(entity, "P31").compactMap { $0.mainsnak.datavalue?.entityID })
        context.hasEditionCandidates = !typeIDs.isDisjoint(with: ["Q571", "Q8261", "Q7725634"])
            && !(entity.claims?["P747"]?.isEmpty ?? true)
        if !typeIDs.isDisjoint(with: ["Q11424", "Q20650540", "Q5398426", "Q63952888"]) {
            for claim in Self.claims(entity, "P4529", allowName: true) {
                guard let id = Self.externalID(claim), Self.digits(id) else { continue }
                context.destinations.append(.init(title: "豆瓣", url: "https://movie.douban.com/subject/\(id)/",
                    source: Self.source(qid, title, property: "P4529", claim: claim)))
            }
            for claim in Self.claims(entity, "P345", allowName: true) {
                guard let id = Self.externalID(claim), id.hasPrefix("tt"), Self.digits(String(id.dropFirst(2))) else { continue }
                context.destinations.append(.init(title: "IMDb", url: "https://www.imdb.com/title/\(id)/",
                    source: Self.source(qid, title, property: "P345", claim: claim)))
            }
        }
        // P6442 refers to a book version/edition. Keep that distinction visible;
        // do not attach edition IDs borrowed from a different item or title.
        for claim in Self.claims(entity, "P6442", allowName: true) {
            guard let id = Self.externalID(claim), Self.digits(id) else { continue }
            context.destinations.append(.init(title: "豆瓣 · 此版本", url: "https://book.douban.com/subject/\(id)/",
                source: Self.source(qid, title, property: "P6442", claim: claim)))
        }
        var links = Set<String>()
        context.destinations = context.destinations.filter { links.insert($0.url).inserted }

        let site: String
        let language: String
        if entity.sitelinks?["zhwiki"] != nil { site = "zhwiki"; language = "zh" }
        else if entity.sitelinks?["enwiki"] != nil { site = "enwiki"; language = "en" }
        else { return context }
        guard let link = entity.sitelinks?[site], link.site == site,
              !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkContextError.invalidResponse
        }
        let articleURL = try Self.endpoint(host: "\(language).wikipedia.org", parameters: [
            "action": "query", "titles": link.title, "prop": "extracts|pageprops|info",
            "exintro": "1", "explaintext": "1", "exlimit": "1", "inprop": "url",
            "ppprop": "wikibase_item|disambiguation", "redirects": "1", "variant": "zh-cn"
        ], version: "2")
        do {
        let article: ArticleResponse = try await load(articleURL)
        guard let pages = article.query?.pages, pages.count == 1, let page = pages.first,
              page.missing != true, page.ns == 0, page.pageprops?.wikibaseItem == qid,
              page.pageprops?.disambiguation == nil else { throw WorkContextError.invalidResponse }
        if let pageID = page.pageid, pageID > 0, let revision = page.lastrevid, revision > 0,
           let pageTitle = page.title {
            context.article = WikiArticleIdentity(qid: qid, title: pageTitle, language: language,
                                                  pageID: pageID, revision: revision)
        }
        if let text = page.extract?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           let revision = page.lastrevid, revision > 0, let pageTitle = page.title {
            context.introduction = String(text.prefix(8_000))
            context.language = language
            context.introductionSource = Source(title: "维基百科 · " + pageTitle, detail: "导语摘录 · CC BY-SA 4.0",
                url: "https://\(language).wikipedia.org/w/index.php?oldid=\(revision)")
        } else {
            context.introductionUnavailable = true
        }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing/mismatched article cannot erase independently verified
            // destinations and facts, nor become an invented empty introduction.
            context.introductionUnavailable = true
        }
        if includeDisplayTitle, let article = context.article, article.language == "zh" {
            context.displayTitleAttemptedAt = Date()
            do {
                if let result = try await fetchDisplayTitle(article: article) {
                    context.displayTitle = result.title
                    context.displayTitleSource = result.source
                    context.displayTitleState = .available
                } else {
                    context.displayTitleState = .absent
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Failure is retryable; it is not evidence of an absent name.
                context.displayTitleState = .failed
            }
        }
        try Task.checkCancellation()
        return context
    }

    func fetchDisplayTitle(article: WikiArticleIdentity) async throws -> WorkDisplayTitle? {
        guard article.isValid, article.language == "zh" else { throw WorkContextError.invalidIdentity }
        let url = try Self.endpoint(host: "zh.wikipedia.org", parameters: [
            "action": "parse", "oldid": String(article.revision),
            "prop": "displaytitle", "variant": "zh-cn"
        ], version: "2")
        let payload: DisplayTitleResponse = try await load(url)
        guard let parsed = payload.parse, parsed.pageid == article.pageID,
              parsed.revid == article.revision, parsed.title == article.title,
              let html = parsed.displaytitle else { throw WorkContextError.invalidResponse }
        let document = try SwiftSoup.parseBodyFragment(html)
        try document.select("script, style, noscript").remove()
        let title = try document.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= 240 else { throw WorkContextError.invalidResponse }
        guard !title.isEmpty, title.range(of: "\\p{Han}", options: .regularExpression) != nil else { return nil }
        return WorkDisplayTitle(title: title, source: Source(title: "维基百科 · " + article.title,
            detail: "中文地区显示名 · CC BY-SA 4.0",
            url: "https://zh.wikipedia.org/w/index.php?oldid=\(article.revision)&variant=zh-cn"))
    }

    private func load<T: Decodable>(_ url: URL) async throws -> T {
        try Task.checkCancellation()
        if session === PianwaiRuntime.session, let hit = await SourceHTTP.responseCache.value(url),
           let decoded = try? JSONDecoder().decode(T.self, from: hit.data) { return decoded }
        let request = SourceHTTP.request(url)
        if session === PianwaiRuntime.session { try await SourceHTTP.wikidataPacer.wait(for: url) }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 3_000_000 else { throw WorkContextError.unavailable }
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data), envelope.error != nil {
            throw WorkContextError.unavailable
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if session === PianwaiRuntime.session { await SourceHTTP.responseCache.remember(data, response: http) }
            return decoded
        }
        catch { throw WorkContextError.invalidResponse }
    }

    private static func endpoint(host: String, parameters: [String: String], version: String = "1") throws -> URL {
        try SourceHTTP.endpoint(host: host, parameters: parameters, version: version)
    }
    static func validQID(_ value: String) -> Bool { WikiSourceIdentity.validQID(value) }

    private static func digits(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 24 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func externalID(_ claim: Claim) -> String? {
        claim.mainsnak.datatype == "external-id" ? claim.mainsnak.datavalue?.stringValue : nil
    }
    private static func claims(_ entity: Entity, _ property: String, allowName: Bool = false) -> [Claim] {
        entity.eligibleClaims(property, allowName: allowName)
    }

    private static func source(_ qid: String, _ title: String, property: String, claim: Claim) -> Source {
        var url = URLComponents(string: "https://www.wikidata.org/wiki/\(qid)")!
        url.fragment = claim.id ?? property
        return Source(title: "Wikidata · " + title, detail: "社区维护的结构化资料", url: url.url!.absoluteString)
    }

    private typealias EntityResponse = WikidataSourceResponse
    private struct DisplayTitleResponse: Decodable {
        let parse: Parsed?
        struct Parsed: Decodable {
            let title: String?; let pageid: Int?; let revid: Int?; let displaytitle: String?
        }
    }
    private struct APIErrorEnvelope: Decodable {
        let error: APIError?
        struct APIError: Decodable { let code: String? }
    }
    private typealias Entity = WikidataSourceEntity
    private typealias Claim = WikidataSourceEntity.Claim
    private struct ArticleResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [Page]? }
        struct Page: Decodable {
            let title: String?; let pageid: Int?; let ns: Int?; let missing: Bool?; let extract: String?; let lastrevid: Int?; let pageprops: Props?
        }
        struct Props: Decodable {
            let wikibaseItem: String?; let disambiguation: String?
            enum CodingKeys: String, CodingKey { case disambiguation; case wikibaseItem = "wikibase_item" }
        }
    }
}
