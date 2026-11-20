import Foundation

/// Tries one verified language edition only after the original article was
/// successfully read and contained no usable creative excerpts.
actor FallbackWorkBackgroundService: WorkBackgroundFetching {
    private let primary: any WorkBackgroundFetching
    private let session: URLSession

    init(primary: any WorkBackgroundFetching, session: URLSession = PianwaiRuntime.session) {
        self.primary = primary
        self.session = session
    }

    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse {
        try Task.checkCancellation()
        guard article.isValid else { throw WorkBackgroundError.invalidIdentity }
        let original = try await primary.fetch(article: article)
        try Task.checkCancellation()
        guard original.article == article else { throw WorkBackgroundError.invalidResponse }
        guard original.excerpts.isEmpty, article.language == "zh" else { return original }

        guard let english = try await englishArticle(qid: article.qid) else {
            try Task.checkCancellation()
            return original
        }
        try Task.checkCancellation()
        let supplement = try await primary.fetch(article: english)
        try Task.checkCancellation()
        guard supplement.article == english else { throw WorkBackgroundError.invalidResponse }
        return WorkBackgroundResponse(article: article, excerpts: supplement.excerpts, supplementalArticle: english,
                                      continuationCandidates: supplement.continuationCandidates,
                                      retainedContinuationCandidates: supplement.retainedContinuationCandidates)
    }

    private func englishArticle(qid: String) async throws -> WikiArticleIdentity? {
        let entities: EntityResponse = try await load(host: "www.wikidata.org", parameters: [
            "action": "wbgetentities", "ids": qid, "props": "sitelinks", "sitefilter": "enwiki"
        ])
        guard entities.error == nil, entities.success == 1,
              entities.entities.count == 1, let entity = entities.entities[qid],
              entity.id == qid, entity.type == "item", entity.missing == nil else {
            throw WorkBackgroundError.invalidResponse
        }
        // A valid empty sitelinks object means this exact work has no English
        // article. A missing/malformed object is a retryable response error.
        guard let link = entity.sitelinks["enwiki"] else { return nil }
        guard link.site == "enwiki", !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkBackgroundError.invalidIdentity
        }
        let payload: ArticleResponse = try await load(host: "en.wikipedia.org", parameters: [
            "action": "query", "titles": link.title, "prop": "pageprops|info",
            "ppprop": "wikibase_item|disambiguation", "formatversion": "2"
        ])
        guard payload.error == nil, let pages = payload.query?.pages, pages.count == 1,
              let page = pages.first, page.ns == 0, page.missing != true, page.invalid != true,
              page.title == link.title, page.pagelanguage == "en",
              page.pageprops?.wikibaseItem == qid, page.pageprops?.disambiguation == nil,
              let pageID = page.pageid, pageID > 0, let revision = page.lastrevid, revision > 0 else {
            throw WorkBackgroundError.invalidIdentity
        }
        return WikiArticleIdentity(qid: qid, title: link.title, language: "en", pageID: pageID, revision: revision)
    }

    private func load<T: Decodable>(host: String, parameters: [String: String]) async throws -> T {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host; parts.path = "/w/api.php"
        let values = parameters.merging(["format": "json"]) { old, _ in old }
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw WorkBackgroundError.invalidIdentity }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pianwai/0.1 (personal reading app)", forHTTPHeaderField: "User-Agent")
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == host else {
            throw WorkBackgroundError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw WorkBackgroundError.httpStatus(http.statusCode) }
        guard data.count < 3_000_000 else { throw WorkBackgroundError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WorkBackgroundError.invalidResponse }
    }

    private struct APIError: Decodable { let code: String? }
    private struct EntityResponse: Decodable {
        let success: Int?
        let entities: [String: Entity]
        let error: APIError?
    }
    private struct Entity: Decodable {
        let id: String
        let type: String
        let missing: String?
        let sitelinks: [String: SiteLink]
        private enum CodingKeys: String, CodingKey { case id, type, missing, sitelinks }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            type = try values.decode(String.self, forKey: .type)
            missing = try values.decodeIfPresent(String.self, forKey: .missing)
            do { sitelinks = try values.decode([String: SiteLink].self, forKey: .sitelinks) }
            catch {
                // Older MediaWiki JSON can serialize an empty map as []. Only
                // that empty representation is accepted, never a missing map.
                let array = try values.nestedUnkeyedContainer(forKey: .sitelinks)
                guard array.isAtEnd else { throw error }
                sitelinks = [:]
            }
        }
    }
    private struct SiteLink: Decodable { let site: String; let title: String }
    private struct ArticleResponse: Decodable {
        let query: Query?
        let error: APIError?
        struct Query: Decodable { let pages: [Page]? }
        struct Page: Decodable {
            let title: String?
            let ns: Int?
            let pageid: Int?
            let lastrevid: Int?
            let pagelanguage: String?
            let missing: Bool?
            let invalid: Bool?
            let pageprops: Props?
        }
        struct Props: Decodable {
            let wikibaseItem: String?
            let disambiguation: String?
            enum CodingKeys: String, CodingKey { case disambiguation; case wikibaseItem = "wikibase_item" }
        }
    }
}
