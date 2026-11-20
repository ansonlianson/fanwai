import Foundation
import CryptoKit

enum WikipediaWorkResolverError: Error, LocalizedError {
    case invalidReference, notFound, ambiguous, identityMismatch, invalidResponse, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidReference: "这个资料链接暂时无法打开。"
        case .notFound: "暂时没有找到这份作品资料。"
        case .ambiguous: "这个名字对应多个条目，暂时无法直接打开。"
        case .identityMismatch: "这条资料的作品身份尚未确认。"
        case .invalidResponse: "作品资料暂未完整载入，请重试。"
        case .unavailable: "暂时无法连接作品资料，请重试。"
        }
    }
}

/// Resolves an article link without searching its display label. Both Wikipedia
/// and Wikidata must agree on the final page identity before a QID is returned.
actor WikipediaWorkResolver: BackgroundReferenceResolving {
    static let shared = WikipediaWorkResolver()
    static let identityLifetime: TimeInterval = 7 * 86_400
    private let session: URLSession
    private let directory: URL?
    private let now: @Sendable () -> Date
    private var identities: [ReferenceKey: VerifiedIdentity] = [:]
    private var identityOrder: [ReferenceKey] = []

    init(session: URLSession = PianwaiRuntime.session,
         directory: URL? = PianwaiRuntime.cacheDirectory("PianwaiReferenceIdentities"),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session; self.directory = directory; self.now = now
    }

    func resolve(_ reference: WikiArticleReference) async throws -> String {
        try await verifiedIdentity(reference).qid
    }

    /// Optional story links are limited to exact creative-work/person types.
    /// A verified article about an object or an unknown type stays plain text.
    func resolveCreative(_ reference: WikiArticleReference) async throws -> String? {
        let identity = try await verifiedIdentity(reference)
        return identity.isCreative ? identity.qid : nil
    }

    private func verifiedIdentity(_ reference: WikiArticleReference) async throws -> VerifiedIdentity {
        try Task.checkCancellation()
        guard ["zh", "en"].contains(reference.language),
              let requestedTitle = Self.validTitle(reference.title) else {
            throw WikipediaWorkResolverError.invalidReference
        }
        let key = ReferenceKey(title: requestedTitle, language: reference.language)
        if let cached = identities[key], isFresh(cached) { return cached }
        if let cached = restored(key) {
            try Task.checkCancellation()
            remember(cached, for: key)
            return cached
        }
        let identity = try await fetchIdentity(key)
        try Task.checkCancellation()
        remember(identity, for: key)
        persist(identity, for: key)
        return identity
    }

    private func remember(_ identity: VerifiedIdentity, for key: ReferenceKey) {
        if identities[key] == nil {
            if identityOrder.count >= 256 { identities.removeValue(forKey: identityOrder.removeFirst()) }
            identityOrder.append(key)
        }
        identities[key] = identity
    }

    private func isFresh(_ identity: VerifiedIdentity) -> Bool {
        let age = now().timeIntervalSince(identity.checkedAt)
        return age.isFinite && age >= 0 && age < Self.identityLifetime
    }

    private func restored(_ key: ReferenceKey) -> VerifiedIdentity? {
        guard let file = cacheFile(key), let data = try? Data(contentsOf: file), data.count <= 32_768,
              let cached = try? JSONDecoder().decode(VerifiedIdentity.self, from: data),
              cached.isValid(for: key), isFresh(cached) else { return nil }
        return cached
    }

    private func cacheFile(_ key: ReferenceKey) -> URL? {
        let digest = SHA256.hash(data: Data((key.language + "\n" + key.title).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".json")
    }

    private func persist(_ identity: VerifiedIdentity, for key: ReferenceKey) {
        // Unknown classification remains an in-memory identity only. Neither
        // unavailable transport nor incomplete claims can become disk negatives.
        guard identity.isValid(for: key), let directory, let file = cacheFile(key),
              let data = try? JSONEncoder().encode(identity), data.count <= 32_768 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            // This directory stores only disposable identity evidence. Bound
            // it independently from saved works and source/background caches.
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent.range(of: #"^[a-f0-9]{64}\.json$"#, options: .regularExpression) != nil }
            if files.count > 256 {
                let oldest = files.filter { $0 != file }.sorted {
                    let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return first < second
                }
                for stale in oldest.prefix(files.count - 256) { try? FileManager.default.removeItem(at: stale) }
            }
        } catch { /* A cache write failure cannot invalidate a verified response. */ }
    }

    private func fetchIdentity(_ reference: ReferenceKey) async throws -> VerifiedIdentity {
        let articleURL = try Self.endpoint(host: reference.language + ".wikipedia.org", parameters: [
            "action": "query", "titles": reference.title, "prop": "pageprops",
            "ppprop": "wikibase_item|disambiguation", "redirects": "1", "formatversion": "2"
        ])
        let article: ArticleResponse = try await load(articleURL)
        guard let query = article.query, let pages = query.pages, pages.count == 1 else {
            throw WikipediaWorkResolverError.invalidResponse
        }
        let page = pages[0]
        guard page.missing != true, page.invalid != true else { throw WikipediaWorkResolverError.notFound }
        guard page.ns == 0, let pageID = page.pageid, pageID > 0,
              let title = page.title.flatMap(Self.validTitle) else {
            throw WikipediaWorkResolverError.invalidResponse
        }
        guard page.pageprops?.disambiguation == nil else { throw WikipediaWorkResolverError.ambiguous }
        guard Self.reaches(title, from: reference.title, through: query) else {
            throw WikipediaWorkResolverError.identityMismatch
        }
        guard let qid = page.pageprops?.wikibaseItem, Self.validQID(qid) else {
            throw WikipediaWorkResolverError.identityMismatch
        }

        let site = reference.language + "wiki"
        let entityURL = try Self.endpoint(host: "www.wikidata.org", parameters: [
            "action": "wbgetentities", "ids": qid, "props": "sitelinks|claims",
            "sitefilter": site, "formatversion": "1"
        ])
        let result: EntityResponse = try await load(entityURL)
        guard result.success == 1, let entity = result.entities?[qid],
              entity.id == qid, entity.type == "item", entity.missing == nil,
              let link = entity.sitelinks?[site], link.site == site,
              let backTitle = Self.validTitle(link.title), backTitle == title else {
            throw WikipediaWorkResolverError.identityMismatch
        }
        try Task.checkCancellation()
        return VerifiedIdentity(requestedTitle: reference.title, language: reference.language,
                                resolvedTitle: title, pageID: pageID, qid: qid,
                                isCreative: entity.hasCreativeType, checkedAt: now(),
                                rewrites: (query.normalized ?? []) + (query.converted ?? []) + (query.redirects ?? []),
                                typeIDs: entity.typeIDs.sorted(), occupationIDs: entity.occupationIDs.sorted())
    }

    /// Only MediaWiki's explicit normalization/redirect chain may change a
    /// requested title. A response for a different page is not a name match.
    private static func reaches(_ resolved: String, from requested: String, through query: ArticleResponse.Query) -> Bool {
        let rewrites = (query.normalized ?? []) + (query.converted ?? []) + (query.redirects ?? [])
        return reaches(resolved, from: requested, rewrites: rewrites)
    }

    private static func reaches(_ resolved: String, from requested: String, rewrites: [ArticleResponse.Rewrite]) -> Bool {
        WikiSourceIdentity.reaches(resolved, from: requested, rewrites: rewrites.map { ($0.from, $0.to) })
    }
    private static func validTitle(_ raw: String) -> String? { WikiSourceIdentity.title(raw) }
    private static func validQID(_ value: String) -> Bool { WikiSourceIdentity.validQID(value) }
    private static func endpoint(host: String, parameters: [String: String]) throws -> URL {
        try SourceHTTP.endpoint(host: host, parameters: parameters)
    }

    private func load<T: Decodable>(_ url: URL) async throws -> T {
        try Task.checkCancellation()
        if session === PianwaiRuntime.session, let hit = await SourceHTTP.responseCache.value(url),
           let decoded = try? JSONDecoder().decode(T.self, from: hit.data) { return decoded }
        let request = SourceHTTP.request(url)
        if session === PianwaiRuntime.session { try await SourceHTTP.wikidataPacer.wait(for: url) }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw WikipediaWorkResolverError.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 1_000_000 else { throw WikipediaWorkResolverError.unavailable }
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data), envelope.error != nil {
            throw WikipediaWorkResolverError.unavailable
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if session === PianwaiRuntime.session { await SourceHTTP.responseCache.remember(data, response: http) }
            return decoded
        }
        catch { throw WikipediaWorkResolverError.invalidResponse }
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError?
        struct APIError: Decodable { let code: String? }
    }
    private struct ReferenceKey: Hashable, Sendable {
        let title: String
        let language: String
    }
    private struct VerifiedIdentity: Codable, Sendable {
        var version = 1
        let requestedTitle: String
        let language: String
        let resolvedTitle: String
        let pageID: Int
        let qid: String
        let isCreative: Bool
        let checkedAt: Date
        let rewrites: [ArticleResponse.Rewrite]
        let typeIDs: [String]
        let occupationIDs: [String]

        func isValid(for key: ReferenceKey) -> Bool {
            guard version == 1, language == key.language, ["zh", "en"].contains(language),
                  requestedTitle == key.title, Self.validTitle(requestedTitle) == requestedTitle,
                  Self.validTitle(resolvedTitle) == resolvedTitle, pageID > 0, Self.validQID(qid),
                  rewrites.count <= 16,
                  rewrites.allSatisfy({ Self.validTitle($0.from) != nil && Self.validTitle($0.to) != nil }),
                  Self.reaches(resolvedTitle, from: requestedTitle, rewrites: rewrites),
                  typeIDs.count <= 64, occupationIDs.count <= 64,
                  typeIDs.allSatisfy(Self.validQID), occupationIDs.allSatisfy(Self.validQID),
                  Set(typeIDs).count == typeIDs.count, Set(occupationIDs).count == occupationIDs.count,
                  let classification = EntityResponse.Entity.creativeStatus(types: Set(typeIDs), occupations: Set(occupationIDs)),
                  classification == isCreative else { return false }
            return checkedAt.timeIntervalSinceReferenceDate.isFinite
        }

        private static func validTitle(_ title: String) -> String? { WikipediaWorkResolver.validTitle(title) }
        private static func validQID(_ qid: String) -> Bool { WikipediaWorkResolver.validQID(qid) }
        private static func reaches(_ title: String, from requested: String, rewrites: [ArticleResponse.Rewrite]) -> Bool {
            WikipediaWorkResolver.reaches(title, from: requested, rewrites: rewrites)
        }
    }
    private struct ArticleResponse: Decodable {
        let query: Query?
        struct Query: Decodable {
            let pages: [Page]?
            let normalized: [Rewrite]?
            let converted: [Rewrite]?
            let redirects: [Rewrite]?
        }
        struct Rewrite: Codable, Sendable { let from: String; let to: String }
        struct Page: Decodable {
            let pageid: Int?; let ns: Int?; let title: String?
            let missing: Bool?; let invalid: Bool?; let pageprops: Props?
        }
        struct Props: Decodable {
            let wikibaseItem: String?; let disambiguation: String?
            enum CodingKeys: String, CodingKey { case disambiguation; case wikibaseItem = "wikibase_item" }
        }
    }
    private struct EntityResponse: Decodable {
        let success: Int?; let entities: [String: Entity]?
        struct Entity: Decodable {
            let id: String?; let type: String?; let missing: String?
            let sitelinks: [String: SiteLink]?
            let claims: TypeClaims?

            /// The type is established from unqualified, current item claims.
            /// A person needs an explicit creative occupation; Q5 alone does
            /// not turn a politician, executive or other person into a creator.
            var typeIDs: Set<String> { Self.itemIDs(claims?.instanceOf, property: "P31") }
            var occupationIDs: Set<String> { Self.itemIDs(claims?.occupation, property: "P106") }
            var hasCreativeType: Bool { Self.creativeStatus(types: typeIDs, occupations: occupationIDs) == true }

            static func creativeStatus(types: Set<String>, occupations: Set<String>) -> Bool? {
                guard !types.isEmpty else { return nil }
                let workTypes: Set<String> = [
                    "Q215380",                        // musical group
                    "Q11424", "Q20650540",           // film, animated film
                    "Q5398426", "Q63952888",          // television, animated series
                    "Q21198342",                      // manga series
                    "Q571", "Q8261", "Q7725634",      // book, novel, literary work
                    "Q104213567",                     // light novel series
                    "Q482994",                        // album
                    "Q7366", "Q55850593", "Q134556",  // song, music track, music single
                    "Q105543609"                      // musical work/composition, not a recording
                ]
                if !types.isDisjoint(with: workTypes) { return true }
                guard types.contains("Q5") else { return false }
                guard !occupations.isEmpty else { return nil }
                let creativeOccupations: Set<String> = [
                    "Q36834", "Q639669", "Q177220",   // composer, musician, singer
                    "Q753110", "Q488205", "Q183945",  // songwriter, singer-songwriter, record producer
                    "Q2526255", "Q28389", "Q3282637", // film director, screenwriter, film producer
                    "Q33999", "Q2405480",             // actor, voice actor
                    "Q36180", "Q49757", "Q482980",    // writer, poet, author
                    "Q644687", "Q365834", "Q266569",  // illustrator, comics artist, animator
                    "Q1028181", "Q33231", "Q483501"   // painter, photographer, artist
                ]
                return !occupations.isDisjoint(with: creativeOccupations)
            }

            private static func itemIDs(_ claims: [TypeClaim]?, property: String) -> Set<String> {
                Set((claims ?? []).compactMap { claim in
                    guard ["normal", "preferred"].contains(claim.rank ?? ""),
                          claim.qualifiers?.isEmpty ?? true,
                          let snak = claim.mainsnak, snak.property == property,
                          snak.snaktype == "value", snak.datatype == "wikibase-item",
                          let typeID = snak.datavalue?.itemID, WikipediaWorkResolver.validQID(typeID) else { return nil }
                    return typeID
                })
            }
        }
        struct SiteLink: Decodable { let site: String; let title: String }
        // Decode only P31/P106. Other properties have strings, quantities, dates,
        // coordinates and other value shapes unrelated to this decision.
        struct TypeClaims: Decodable {
            let instanceOf: [TypeClaim]?
            let occupation: [TypeClaim]?
            enum CodingKeys: String, CodingKey { case instanceOf = "P31"; case occupation = "P106" }
        }
        struct TypeClaim: Decodable {
            let rank: String?
            let mainsnak: TypeSnak?
            let qualifiers: [String: IgnoredValue]?
        }
        struct TypeSnak: Decodable {
            let property: String?; let snaktype: String?; let datatype: String?
            let datavalue: TypeValue?
        }
        struct TypeValue: Decodable {
            let itemID: String?
            enum CodingKeys: String, CodingKey { case value }
            struct ItemValue: Decodable { let id: String? }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                itemID = (try? container.decode(ItemValue.self, forKey: .value))?.id
            }
        }
        struct IgnoredValue: Decodable { init(from decoder: Decoder) throws {} }
    }
}
