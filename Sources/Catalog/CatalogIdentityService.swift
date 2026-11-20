import Foundation

actor CatalogRequestBudget {
    private let limit: Int
    private(set) var used = 0
    init(limit: Int) { self.limit = limit }
    func charge() throws { guard used < limit else { throw CatalogError.throttled }; used += 1 }
}
struct CatalogWikidataIdentity: Sendable {
    struct Link: Sendable { let property: String; let qid: String; let sourceURL: String }
    let qid: String
    let name: String
    let matchedProperty: String
    let matchedValue: String
    let sourceURL: String
    let relations: [Link]
}
struct CatalogMusicBrainzRecording: Codable, Sendable {
    struct Credit: Codable, Sendable {
        let role: String
        let artistID: String
        let name: String
        let workID: String?
        let sourceURL: String
    }
    let id: String
    let title: String
    let credits: [Credit]
    let creditsComplete: Bool
}

/// Exact ID joins only. No title/artist-name search fallback is permitted.
actor CatalogIdentityService {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let load: Loader
    private let responseCache: SourceResponseCache?
    private var cache: [URL: (Data, Date)] = [:]
    private static let musicBrainzPacer = CatalogMusicBrainzPacer()
    init(loader: @escaping Loader = { request in
        let (data, response) = try await SourceHTTP.noRedirectSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.server }
        return (data, http)
    }, responseCache: SourceResponseCache? = SourceHTTP.responseCache) { load = loader; self.responseCache = responseCache }
    nonisolated static func validISRC(_ value: String) -> String? {
        let code = value.uppercased().replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return code.range(of: "^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$", options: .regularExpression) != nil ? code : nil
    }
    private func fetch(_ url: URL, budget: CatalogRequestBudget) async throws -> Data {
        try Task.checkCancellation()
        if let hit = cache[url], hit.1 > Date() { return hit.0 }
        if let hit = await responseCache?.value(url) { return hit.data }
        try await budget.charge()
        try await SourceHTTP.wikidataPacer.wait(for: url)
        if url.host == "musicbrainz.org" { try await Self.musicBrainzPacer.wait() }
        let (data, response) = try await load(SourceHTTP.request(url))
        try Task.checkCancellation()
        guard data.count < 4_000_000 else { throw CatalogError.invalidData }
        if response.statusCode == 404 { throw CatalogError.notFound }
        if response.statusCode == 429 || response.statusCode == 503 { throw CatalogError.throttled }
        guard response.statusCode == 200 else { throw CatalogError.server }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw CatalogError.invalidData }
        if cache.count >= 128 { cache.removeAll() }
        cache[url] = (data, Date().addingTimeInterval(3600))
        await responseCache?.remember(data, response: response)
        return data
    }
    func wikidata(property: String, value: String, budget: CatalogRequestBudget) async throws -> [CatalogWikidataIdentity] {
        guard property == "P1243" && Self.validISRC(value) == value || property == "P2850" && !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CatalogError.invalidLink }
        let searchURL = try SourceHTTP.endpoint(host: "www.wikidata.org", parameters: ["action":"query", "list":"search", "srsearch":"haswbstatement:" + property + "=" + value, "srnamespace":"0", "srlimit":"10"])
        struct Search: Decodable { struct Query: Decodable { struct Hit: Decodable { let title: String }; let search: [Hit] }; let query: Query }
        let hits = try JSONDecoder().decode(Search.self, from: await fetch(searchURL, budget: budget))
        let ids = Array(Set(hits.query.search.map(\.title).filter(WikiSourceIdentity.validQID))).sorted()
        guard !ids.isEmpty else { return [] }
        let entitiesURL = try SourceHTTP.endpoint(host: "www.wikidata.org", parameters: ["action":"wbgetentities", "ids":ids.joined(separator: "|"), "props":"claims|labels", "languages":"ja|zh-hans|zh|en"])
        let response = try JSONDecoder().decode(WikidataSourceResponse.self, from: await fetch(entitiesURL, budget: budget))
        guard let entities = response.entities else { throw CatalogError.invalidData }
        let relationships = ["P86", "P676", "P50", "P57", "P144", "P1441", "P361", "P175", "P162", "P272", "P921", "P4969", "P658", "P2550"]
        return ids.compactMap { qid in
            guard let entity = entities[qid], entity.id == qid, entity.type == "item", entity.missing == nil,
                  entity.strings(property).contains(value) else { return nil }
            let links: [CatalogWikidataIdentity.Link] = relationships.flatMap { property in
                entity.eligibleClaims(property).compactMap { claim in
                    guard let target = claim.mainsnak.datavalue?.entityID, WikiSourceIdentity.validQID(target), let statement = claim.id else { return nil }
                    return .init(property: property, qid: target, sourceURL: "https://www.wikidata.org/wiki/" + qid + "#" + statement.replacingOccurrences(of: "$", with: "-"))
                }
            }
            return .init(qid: qid, name: entity.title, matchedProperty: property, matchedValue: value, sourceURL: "https://www.wikidata.org/wiki/" + qid, relations: links)
        }
    }
    func musicBrainz(isrc: String, budget: CatalogRequestBudget) async throws -> [CatalogMusicBrainzRecording] {
        guard Self.validISRC(isrc) == isrc else { throw CatalogError.invalidLink }
        struct Response: Decodable { let isrc: String; let recordings: [MBRecording] }
        let url = URL(string: "https://musicbrainz.org/ws/2/isrc/" + isrc + "?fmt=json")!
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: await fetch(url, budget: budget)) }
        catch CatalogError.notFound { return [] }
        guard response.isrc == isrc else { throw CatalogError.invalidData }
        var result: [CatalogMusicBrainzRecording] = [], seen = Set<String>()
        for (index, item) in response.recordings.enumerated() where UUID(uuidString: item.id) != nil && seen.insert(item.id).inserted {
            var recording = item, complete = false
            if index < 2 {
                let detail = URL(string: "https://musicbrainz.org/ws/2/recording/" + item.id + "?fmt=json&inc=isrcs+artist-rels+work-rels+work-level-rels")!
                do {
                    let fetched = try JSONDecoder().decode(MBRecording.self, from: await fetch(detail, budget: budget))
                    guard fetched.id == item.id, fetched.isrcs?.contains(isrc) == true else { continue }
                    recording = fetched; complete = true
                } catch is CancellationError { throw CancellationError() }
                catch { } // Preserve the ISRC endpoint's identity; credits remain explicitly unknown.
            }
            result.append(.init(id: recording.id, title: recording.title, credits: recording.credits, creditsComplete: complete))
        }
        return result
    }
}
private struct MBRecording: Decodable {
    let id: String
    let title: String
    var isrcs: [String]?
    var relations: [MBRelation]?
    var credits: [CatalogMusicBrainzRecording.Credit] {
        func extract(_ relations: [MBRelation], work: String?) -> [CatalogMusicBrainzRecording.Credit] {
            relations.compactMap { relation in
                guard ["composer", "lyricist", "arranger", "instrument arranger", "vocal arranger", "orchestrator"].contains(relation.type),
                      let artist = relation.artist, UUID(uuidString: artist.id) != nil else { return nil }
                return .init(role: relation.type, artistID: artist.id, name: artist.name, workID: work,
                             sourceURL: "https://musicbrainz.org/" + (work.map { "work/" + $0 } ?? "recording/" + id))
            }
        }
        let direct = extract(relations ?? [], work: nil)
        return direct + (relations ?? []).flatMap { relation in
            guard relation.type == "performance", let work = relation.work, UUID(uuidString: work.id) != nil else { return [CatalogMusicBrainzRecording.Credit]() }
            return extract(work.relations ?? [], work: work.id)
        }
    }
}
private struct MBRelation: Decodable {
    struct Artist: Decodable { let id: String; let name: String }
    struct Work: Decodable { let id: String; var relations: [MBRelation]? }
    let type: String
    var artist: Artist?
    var work: Work?
}
private actor CatalogMusicBrainzPacer {
    private var last: ContinuousClock.Instant?
    func wait() async throws {
        while let last {
            let earliest = last.advanced(by: .seconds(1))
            guard ContinuousClock.now < earliest else { break }
            try await ContinuousClock().sleep(until: earliest, tolerance: .zero)
        }
        try Task.checkCancellation(); last = .now
    }
}
