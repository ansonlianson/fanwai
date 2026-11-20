import Foundation

/// A reference to a particular book edition, not a promise of availability or
/// an alias for the original work. Keep both directions of the identity proof.
struct EditionDestination: Codable, Identifiable, Sendable {
    let originalQID: String
    let editionQID: String
    let destination: WorkDestination
    let discoverySource: Source
    let correspondenceSource: Source
    let editionTypeSource: Source
    let publicationSource: Source?
    var id: String { editionQID + ":" + destination.id }
}

/// Bounded original-work -> edition lookup. Names are presentation only.
/// A P747 candidate must independently identify itself as an edition and point
/// back to the requested original through P629 before its P6442 is used.
actor WorkContextEditionService {
    private let session: URLSession
    private let candidateLimit = 4

    init(session: URLSession = PianwaiRuntime.session) { self.session = session }

    func fetch(qid: String) async throws -> [EditionDestination] {
        guard Self.validQID(qid) else { throw WorkContextError.invalidIdentity }
        try Task.checkCancellation()
        let roots = try await entities([qid])
        guard let root = roots[qid] else { throw WorkContextError.invalidResponse }

        var seen = Set<String>()
        let candidates = Self.claims(root, property: "P747", qualifiers: .language)
            .compactMap { claim -> (qid: String, claim: Claim)? in
                guard let target = Self.item(claim), target != qid,
                      seen.insert(target).inserted else { return nil }
                return (target, claim)
            }
            .prefix(candidateLimit)
        guard !candidates.isEmpty else { return [] }
        let editions = try await entities(candidates.map(\.qid))
        var results: [EditionDestination] = []
        for candidate in candidates {
            guard let edition = editions[candidate.qid],
                  let editionType = Self.claims(edition, property: "P31").first(where: { Self.item($0) == "Q3331189" }),
                  let correspondence = Self.claims(edition, property: "P629").first(where: { Self.item($0) == qid }) else { continue }

            // A contradictory original-work assertion cannot be resolved by
            // taking whichever matching claim happened to come first.
            let originals = Set(Self.claims(edition, property: "P629").compactMap(Self.item))
            guard originals == [qid] else { continue }
            let year = Self.publicationYear(edition)
            let editionLabel = year.map { $0.value + "版" } ?? edition.title
            var urls = Set<String>()
            for identifier in Self.claims(edition, property: "P6442", qualifiers: .name) {
                guard identifier.mainsnak.datatype == "external-id",
                      let value = identifier.mainsnak.datavalue?.string,
                      Self.digits(value) else { continue }
                let url = "https://book.douban.com/subject/\(value)/"
                guard urls.insert(url).inserted else { continue }
                results.append(EditionDestination(
                    originalQID: qid, editionQID: candidate.qid,
                    destination: WorkDestination(title: "豆瓣 · " + editionLabel, url: url,
                                                 source: Self.source(edition, identifier)),
                    discoverySource: Self.source(root, candidate.claim),
                    correspondenceSource: Self.source(edition, correspondence),
                    editionTypeSource: Self.source(edition, editionType),
                    publicationSource: year.map { Self.source(edition, $0.claim) }
                ))
            }
        }
        try Task.checkCancellation()
        return results
    }

    private func entities(_ ids: [String]) async throws -> [String: Entity] {
        var url = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        let values = [
            "action": "wbgetentities", "ids": ids.sorted().joined(separator: "|"),
            "props": "labels|claims", "languages": "zh-hans|zh|en|ja",
            "format": "json", "formatversion": "1"
        ]
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let endpoint = url.url else { throw WorkContextError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, timeoutInterval: 18)
        request.setValue("Pianwai/0.1 (personal cultural discovery; exact book editions)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count < 3_000_000 else { throw WorkContextError.unavailable }
        let payload: EntityResponse
        do { payload = try JSONDecoder().decode(EntityResponse.self, from: data) }
        catch { throw WorkContextError.invalidResponse }
        // MediaWiki can return a transient API error inside an HTTP 200.
        if payload.error != nil { throw WorkContextError.unavailable }
        guard payload.success == 1, let entities = payload.entities else { throw WorkContextError.invalidResponse }
        var result: [String: Entity] = [:]
        for id in ids {
            guard let entity = entities[id], entity.id == id else { throw WorkContextError.invalidResponse }
            if entity.missing != nil { continue }
            guard entity.type == "item" else { throw WorkContextError.invalidResponse }
            result[id] = entity
        }
        return result
    }

    private enum AllowedQualifiers { case none, language, name }

    private static func claims(_ entity: Entity, property: String, qualifiers: AllowedQualifiers = .none) -> [Claim] {
        (entity.claims?[property] ?? []).filter { claim in
            guard ["normal", "preferred"].contains(claim.rank ?? ""),
                  claim.mainsnak.snaktype == "value",
                  claim.mainsnak.property == property,
                  let statement = claim.id, let separator = statement.firstIndex(of: "$"),
                  statement[..<separator].uppercased() == entity.id,
                  UUID(uuidString: String(statement[statement.index(after: separator)...])) != nil else { return false }
            return (claim.qualifiers ?? [:]).allSatisfy { property, values in
                guard !values.isEmpty else { return false }
                switch qualifiers {
                case .none: return false
                case .language:
                    return property == "P407" && values.allSatisfy {
                        $0.snaktype == "value" && $0.property == "P407" && $0.datatype == "wikibase-item"
                            && validQID($0.datavalue?.entityID ?? "")
                    }
                case .name:
                    return property == "P1810" && values.allSatisfy {
                        $0.snaktype == "value" && $0.property == "P1810" && $0.datatype == "string"
                            && nonempty($0.datavalue?.string) != nil
                    }
                }
            }
        }
    }

    private static func item(_ claim: Claim) -> String? {
        guard claim.mainsnak.datatype == "wikibase-item", let id = claim.mainsnak.datavalue?.entityID,
              validQID(id) else { return nil }
        return id
    }

    private static func publicationYear(_ entity: Entity) -> (value: String, claim: Claim)? {
        let years = claims(entity, property: "P577").compactMap { claim -> (value: String, claim: Claim)? in
            guard claim.mainsnak.datatype == "time", let time = claim.mainsnak.datavalue?.time,
                  time.precision >= 9, time.calendar == "http://www.wikidata.org/entity/Q1985727",
                  (time.before ?? 0) == 0, (time.after ?? 0) == 0,
                  time.time.hasPrefix("+"), time.time.dropFirst(5).first == "-" else { return nil }
            let year = String(time.time.dropFirst().prefix(4))
            guard year.count == 4, year.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(year), (1000...2100).contains(number) else { return nil }
            return (year, claim)
        }
        guard let first = years.first, years.allSatisfy({ $0.value == first.value }) else { return nil }
        return first
    }

    private static func source(_ entity: Entity, _ claim: Claim) -> Source {
        var url = URLComponents(string: "https://www.wikidata.org/wiki/\(entity.id)")!
        url.fragment = claim.id
        return Source(title: "Wikidata · " + entity.title, detail: "社区维护的结构化资料", url: url.url!.absoluteString)
    }
    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
    private static func validQID(_ value: String) -> Bool {
        value.hasPrefix("Q") && value.count > 1 && value.count < 24 && digits(String(value.dropFirst()))
    }
    private static func digits(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 24 && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private struct EntityResponse: Decodable {
        let success: Int?
        let entities: [String: Entity]?
        let error: APIError?
    }
    private struct APIError: Decodable { let code: String? }
    private struct Entity: Decodable {
        let id: String
        let type: String?
        let missing: String?
        let labels: [String: Localized]?
        let claims: [String: [Claim]]?
        var title: String {
            ["zh-hans", "zh", "en", "ja"].compactMap { nonempty(labels?[$0]?.value) }.first ?? "此版本"
        }
    }
    private struct Localized: Decodable { let value: String }
    private struct Claim: Decodable {
        let id: String?
        let rank: String?
        let mainsnak: Snak
        let qualifiers: [String: [Snak]]?
    }
    private struct Snak: Decodable {
        let property: String?
        let snaktype: String
        let datatype: String?
        let datavalue: Value?
    }
    private struct Value: Decodable {
        let entityID: String?
        let string: String?
        let time: WikiTime?
        private enum CodingKeys: String, CodingKey { case value }
        private struct EntityID: Decodable { let id: String? }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entityID = (try? container.decode(EntityID.self, forKey: .value))?.id
            string = try? container.decode(String.self, forKey: .value)
            time = try? container.decode(WikiTime.self, forKey: .value)
        }
    }
    private struct WikiTime: Decodable {
        let time: String
        let precision: Int
        let calendar: String
        let before: Int?
        let after: Int?
        enum CodingKeys: String, CodingKey { case time, precision, before, after; case calendar = "calendarmodel" }
    }
}
