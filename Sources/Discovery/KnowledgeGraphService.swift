import Foundation

struct KnowledgeExpansion: Sendable {
    let snapshot: CatalogSnapshot
    let rootQID: String
    /// True when a cap, an uninterpreted qualifier, or a partial candidate list
    /// prevented this response from containing every eligible relation.
    let limited: Bool
    /// Verified branches remain usable when an independent directory request fails.
    /// A retry must still be allowed because this is not a complete negative result.
    var retryableFailure: String? = nil
    var truncated: Bool { limited }
}

struct KnowledgeCandidate: Identifiable, Sendable {
    let qid: String
    let title: String
    let detail: String
    var id: String { qid }
}

struct KnowledgeIdentityMatch: Sendable {
    let qid: String
    let source: Source
}

enum KnowledgeMoreStatus: Sendable, Equatable {
    case unqueried, more, exhausted, limited
}

/// A continuation belongs to one person and advances only with its committed page.
/// It is deliberately not persisted: a restored catalog starts from the search
/// head and skips already verified neighbors instead of trusting a stale offset.
struct KnowledgeWorksCursor: Sendable, Equatable {
    let rootQID: String
    fileprivate var propertyIndex = 0
    fileprivate var offset = 0
    fileprivate var continuation: String?
    fileprivate var examined = Set<String>()
    fileprivate var knownMore = false
    fileprivate var limited = false
}

struct KnowledgeWorksPage: Sendable {
    let snapshot: CatalogSnapshot
    let nextCursor: KnowledgeWorksCursor?
    let limited: Bool
    var status: KnowledgeMoreStatus {
        guard let nextCursor else { return limited ? .limited : .exhausted }
        return nextCursor.knownMore ? .more : .unqueried
    }
}

enum KnowledgeError: Error, LocalizedError {
    case invalidIdentifier, notFound, invalidResponse, unavailable
    case throttled(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "这条资料链接暂不可用。"
        case .notFound: "暂时没有找到这份资料。"
        case .invalidResponse: "这次返回的资料不完整，请稍后再试。"
        case .unavailable: "暂时连不上资料库。"
        case .throttled: "资料库有些繁忙，稍后再试。"
        }
    }
    static func message(_ error: Error) -> String {
        if let known = error as? KnowledgeError { return known.localizedDescription }
        if let network = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(network.code) {
            return "暂时无法联网，已有资料仍可浏览。"
        }
        return "这份关联资料暂时无法载入，请稍后再试。"
    }
}

/// Exact-identity graph expansion. Search returns candidates only: it never
/// merges a musical work with an Apple Music recording on the basis of a title.
actor KnowledgeGraphService {
    private let session: URLSession
    private let edgeLimit = 12
    private var cache: [URL: (expires: Date, data: Data)] = [:]
    private var requestTimes: [Date] = []
    private var blockedUntil: Date?
    private let properties = ["P57", "P50", "P86", "P144", "P175", "P406", "P942"]
    private let creditProperties = ["P57", "P50", "P86", "P175"]

    init(session: URLSession = PianwaiRuntime.session) { self.session = session }

    /// P2850 is the Apple Music artist identifier, not a song/album identifier.
    /// The search index only discovers candidates; their current exact external
    /// ID claims must prove a unique match before an identity can be returned.
    func resolveAppleArtist(id: String) async throws -> KnowledgeIdentityMatch? {
        try Task.checkCancellation()
        guard Self.validArtistID(id) else { throw KnowledgeError.invalidIdentifier }
        let candidateLimit = 5
        let url = try endpoint([
            "action": "query", "list": "search", "srsearch": "haswbstatement:P2850=\(id)",
            "srnamespace": "0", "srlimit": String(candidateLimit), "srprop": ""
        ])
        let payload: ReversePayload = try await load(url) { payload in
            guard let count = payload.query?.searchinfo?.totalhits, count >= 0,
                  let results = payload.query?.search,
                  results.allSatisfy({ Self.validQID($0.title) }) else { throw KnowledgeError.invalidResponse }
        }
        let count = payload.query?.searchinfo?.totalhits ?? 0
        let ids = payload.query?.search?.map(\.title) ?? []
        // Do not infer uniqueness from a truncated or internally incomplete page.
        guard count > 0, count <= candidateLimit, ids.count == count,
              Set(ids).count == count else { return nil }
        let candidates = try await entities(ids)
        let matches: [(entity: Entity, claim: Claim)] = candidates.values.compactMap { entity in
            guard entity.kind == "创作者", entity.title != nil, let qid = entity.id else { return nil }
            let matchedClaim = (entity.claims?["P2850"] ?? []).first {
                Self.artistID(from: $0, owner: qid) == id
            }
            return matchedClaim.map { (entity, $0) }
        }
        try Task.checkCancellation()
        guard matches.count == 1, let qid = matches[0].entity.id else { return nil }
        return KnowledgeIdentityMatch(qid: qid, source: source(entity: matches[0].entity, property: "P2850", claim: matches[0].claim))
    }

    func searchCandidates(_ query: String) async throws -> [KnowledgeCandidate] {
        try Task.checkCancellation()
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !term.isEmpty else { return [] }
        var terms = [term]
        var seenTerms: Set<String> = [term]
        // These are Unicode script forms of the literal query, not translations
        // or work aliases. Never chain conversions or replace the user's query.
        for transform in [StringTransform("Hans-Hant"), StringTransform("Hant-Hans")] {
            guard let transformed = term.applyingTransform(transform, reverse: false) else { continue }
            let variant = String(transformed.prefix(200))
            if !variant.isEmpty, seenTerms.insert(variant).inserted { terms.append(variant) }
        }
        for term in terms {
            try Task.checkCancellation()
            let url = try endpoint([
                "action": "wbsearchentities", "search": term,
                "language": "zh", "uselang": "zh-hans", "type": "item", "limit": "8"
            ])
            let payload: SearchPayload = try await load(url) { payload in
                // Reject invalid-only results before caching. A partially
                // valid response still keeps its usable exact identities.
                guard payload.success == 1, let items = payload.search,
                      items.isEmpty || items.contains(where: { item in
                          guard let qid = item.id else { return false }
                          return Self.validQID(qid) && Self.nonempty(item.label) != nil
                      }) else { throw KnowledgeError.invalidResponse }
            }
            let items = payload.search ?? []
            // Only a successful, genuinely empty search permits the next form.
            // Filtering a nonempty payload does not turn it into that signal.
            guard !items.isEmpty else { continue }
            var seen = Set<String>()
            let candidates = items.compactMap { item -> KnowledgeCandidate? in
                guard let qid = item.id, Self.validQID(qid),
                      let title = Self.nonempty(item.label), seen.insert(qid).inserted else { return nil }
                return KnowledgeCandidate(qid: qid, title: title, detail: Self.nonempty(item.description) ?? "")
            }
            try Task.checkCancellation()
            return candidates
        }
        try Task.checkCancellation()
        return []
    }

    /// Search for a work itself, with a verified identity that can expand after
    /// selection. Descriptions disambiguate candidates; they never determine type.
    func searchWorks(_ query: String, kind: CatalogSearchKind, anchors: [String: Work] = [:]) async throws -> CatalogResponse {
        guard kind.usesKnowledgeSearch else { throw KnowledgeError.invalidIdentifier }
        let candidates = try await searchCandidates(query)
        guard !candidates.isEmpty else {
            return CatalogResponse(results: [], snapshot: CatalogSnapshot(works: [], relations: []))
        }
        let records = try await entities(candidates.map(\.qid))
        let works = try candidates.compactMap { candidate -> Work? in
            guard let entity = records[candidate.qid], entity.title != nil,
                  kind.includes(workKind: entity.kind) else { return nil }
            return try materialize(entity, anchors: anchors)
        }
        try Task.checkCancellation()
        return CatalogResponse(results: works.map(\.id), snapshot: CatalogSnapshot(works: works, relations: []))
    }

    func expand(qid: String, anchors: [String: Work] = [:]) async throws -> KnowledgeExpansion {
        guard Self.validQID(qid), anchors.keys.allSatisfy(Self.validQID) else { throw KnowledgeError.invalidIdentifier }
        try Task.checkCancellation()
        let initial = try await entities([qid])
        guard let root = initial[qid], root.title != nil else { throw KnowledgeError.notFound }
        var limited = false
        var pending: [PendingEdge] = []
        for property in properties {
            pending += eligible(root, property: property, limited: &limited).map {
                PendingEdge(from: qid, to: $0.target, property: property, claim: $0.claim)
            }
        }

        var reverseCandidates: [String] = []
        if root.kind == "创作者" {
            let notable = eligible(root, property: "P800", limited: &limited).map(\.target)
            if !notable.isEmpty {
                // P800 is only a discovery list. A work-level credit below is
                // still required before it becomes an edge in the application.
                reverseCandidates = notable
                limited = true
            } else {
                for property in creditProperties {
                    let result = try await self.reverseCandidates(qid: qid, property: property)
                    reverseCandidates += result.ids
                    limited = limited || result.more
                    if Set(reverseCandidates).count >= edgeLimit { limited = true; break }
                }
            }
        }

        var seen = Set<String>()
        let allTargets = (pending.map(\.to) + reverseCandidates).filter { $0 != qid && seen.insert($0).inserted }
        if allTargets.count > edgeLimit { limited = true }
        let targets = Array(allTargets.prefix(edgeLimit))
        let fetched = targets.isEmpty ? [:] : try await entities(targets)
        var all = fetched
        all[qid] = root

        for target in reverseCandidates where fetched[target] != nil {
            guard let entity = fetched[target] else { continue }
            for property in creditProperties {
                for item in eligible(entity, property: property, limited: &limited) where item.target == qid {
                    pending.append(PendingEdge(from: target, to: qid, property: property, claim: item.claim))
                }
            }
        }

        var works: [WorkID: Work] = [:]
        var edges: [RelationEdge] = []
        var edgeIDs = Set<String>()
        let rootWork = try materialize(root, anchors: anchors)
        works[rootWork.id] = rootWork
        // Keep catalog profiles separate from the person and prioritize these
        // exits before the capped work list, so a prolific creator is not a dead end.
        let directories = try await artistDirectories(for: root, person: rootWork)
        for profile in directories.works { works[profile.id] = profile }
        for edge in directories.edges where edgeIDs.insert(edge.id).inserted { edges.append(edge) }
        limited = limited || directories.limited
        for item in pending {
            guard item.from != item.to, let fromEntity = all[item.from], let toEntity = all[item.to],
                  fromEntity.title != nil, toEntity.title != nil else { limited = true; continue }
            let from = try materialize(fromEntity, anchors: anchors)
            let to = try materialize(toEntity, anchors: anchors)
            guard from.id != to.id else { limited = true; continue }
            let mapping = Self.mapping(item.property)
            let edge = RelationEdge(from: from.id, to: to.id, predicate: mapping.kind,
                                    label: mapping.label, inverseLabel: mapping.inverse,
                                    source: source(entity: fromEntity, property: item.property, claim: item.claim))
            guard edgeIDs.insert(edge.id).inserted else { continue }
            guard edges.count < edgeLimit else { limited = true; break }
            works[from.id] = from
            works[to.id] = to
            edges.append(edge)
        }
        try Task.checkCancellation()
        return KnowledgeExpansion(snapshot: CatalogSnapshot(works: works.values.sorted { $0.id.rawValue < $1.id.rawValue }, relations: edges), rootQID: qid, limited: limited, retryableFailure: directories.retryableFailure)
    }

    /// Continue beyond P800 and the initial representative slice. Search only
    /// supplies candidates; each relation still needs a current work-level claim.
    /// A call adds at most 12 new neighbors and examines at most eight search
    /// pages, so stale/duplicate index entries cannot cause an unbounded request.
    func moreWorks(qid: String, after cursor: KnowledgeWorksCursor? = nil,
                   excluding: Set<String> = [], anchors: [String: Work] = [:]) async throws -> KnowledgeWorksPage {
        guard Self.validQID(qid), anchors.keys.allSatisfy(Self.validQID), excluding.allSatisfy(Self.validQID),
              cursor == nil || cursor?.rootQID == qid else { throw KnowledgeError.invalidIdentifier }
        try Task.checkCancellation()
        let initial = try await entities([qid])
        guard let root = initial[qid], root.kind == "创作者", root.title != nil else { throw KnowledgeError.notFound }
        let person = try materialize(root, anchors: anchors)
        var next = cursor ?? KnowledgeWorksCursor(rootQID: qid)
        guard creditProperties.indices.contains(next.propertyIndex), next.offset >= 0, next.offset <= Int.max - edgeLimit else { throw KnowledgeError.invalidIdentifier }
        next.examined.formUnion(excluding)
        next.examined.insert(qid)
        var works: [WorkID: Work] = [person.id: person]
        var edges: [RelationEdge] = []
        var edgeIDs = Set<String>()
        var newNeighbors = Set<WorkID>()
        var searches = 0
        while next.propertyIndex < creditProperties.count && newNeighbors.count < edgeLimit && searches < 8 {
            try Task.checkCancellation()
            let result = try await reversePage(qid: qid, property: creditProperties[next.propertyIndex],
                                               offset: next.offset, continuation: next.continuation,
                                               limit: edgeLimit - newNeighbors.count)
            searches += 1
            var candidates: [String] = []
            for id in result.ids where next.examined.insert(id).inserted { candidates.append(id) }
            let fetched = candidates.isEmpty ? [:] : try await entities(candidates)
            for id in candidates {
                guard let entity = fetched[id], entity.title != nil else { next.limited = true; continue }
                let item = try materialize(entity, anchors: anchors)
                guard item.id != person.id else { next.limited = true; continue }
                var verified: [RelationEdge] = []
                for property in creditProperties {
                    for match in eligible(entity, property: property, limited: &next.limited) where match.target == qid {
                        // A statement from another owner or a malformed GUID is
                        // not evidence for this candidate's credit.
                        guard Self.validStatementID(match.claim.id, owner: id) else { next.limited = true; continue }
                        let mapping = Self.mapping(property)
                        verified.append(RelationEdge(from: item.id, to: person.id, predicate: mapping.kind,
                                                     label: mapping.label, inverseLabel: mapping.inverse,
                                                     source: source(entity: entity, property: property, claim: match.claim)))
                    }
                }
                guard !verified.isEmpty else { next.limited = true; continue }
                works[item.id] = item
                newNeighbors.insert(item.id)
                for edge in verified where edgeIDs.insert(edge.id).inserted { edges.append(edge) }
            }
            if let offset = result.nextOffset {
                next.offset = offset
                next.continuation = result.continuation
                next.knownMore = true
            } else {
                next.propertyIndex += 1
                next.offset = 0
                next.continuation = nil
                next.knownMore = false
            }
        }
        try Task.checkCancellation()
        return KnowledgeWorksPage(snapshot: CatalogSnapshot(works: works.values.sorted { $0.id.rawValue < $1.id.rawValue }, relations: edges),
                                  nextCursor: next.propertyIndex < creditProperties.count ? next : nil, limited: next.limited)
    }

    private func artistDirectories(for entity: Entity, person: Work) async throws -> (works: [Work], edges: [RelationEdge], limited: Bool, retryableFailure: String?) {
        guard entity.kind == "创作者", let qid = entity.id else { return ([], [], false, nil) }
        var seen = Set<String>()
        var profiles: [Work] = []
        var edges: [RelationEdge] = []
        var checked = 0
        var limited = false
        var retryableFailure: String?
        for claim in entity.claims?["P2850"] ?? [] {
            guard let number = Self.artistID(from: claim, owner: qid) else {
                if ["normal", "preferred"].contains(claim.rank ?? ""), !(claim.qualifiers?.isEmpty ?? true) { limited = true }
                continue
            }
            guard seen.insert(number).inserted else { continue }
            guard checked < edgeLimit else { limited = true; break }
            checked += 1
            // A valid claim on this person is necessary but not sufficient: the
            // same ID must not also identify another current person/group.
            let match: KnowledgeIdentityMatch?
            do {
                match = try await resolveAppleArtist(id: number)
            } catch {
                try Task.checkCancellation()
                limited = true
                retryableFailure = retryableFailure ?? KnowledgeError.message(error)
                continue
            }
            guard let verified = match, verified.qid == qid else {
                limited = true
                continue
            }
            let id = WorkID(rawValue: "apple:artist:\(number)")!
            let displayName = claim.qualifiers?["P1810"]?.compactMap { Self.nonempty($0.datavalue?.stringValue) }.first
            let profile = Work(id: id, title: displayName ?? person.title, creator: "音乐人", kind: "创作者", art: "",
                               detail: "Apple Music 艺人目录", url: "https://music.apple.com/jp/artist/\(number)",
                               linkedCreatorIDs: [], catalogID: number, storeCountry: "jp", knowledgeID: qid,
                               knowledgeIdentitySource: verified.source)
            profiles.append(profile)
            edges.append(RelationEdge(from: id, to: person.id, predicate: .artistIdentity,
                                      label: "创作者", inverseLabel: "音乐目录", source: verified.source))
        }
        return (profiles, edges, limited, retryableFailure)
    }

    private static func validArtistID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 23 && value.first != "0"
            && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validStatementID(_ statement: String?, owner: String?) -> Bool {
        guard let owner, let statement, let separator = statement.firstIndex(of: "$"),
              statement[..<separator].uppercased() == owner,
              UUID(uuidString: String(statement[statement.index(after: separator)...])) != nil else { return false }
        return true
    }

    /// Shared by both directions. P1810 is only the name used by this database;
    /// temporal/role qualifiers remain uninterpreted and cannot establish identity.
    private static func artistID(from claim: Claim, owner qid: String) -> String? {
        guard ["normal", "preferred"].contains(claim.rank ?? ""),
              claim.mainsnak?.snaktype == "value", claim.mainsnak?.datatype == "external-id",
              let id = claim.mainsnak?.datavalue?.stringValue, validArtistID(id),
              validStatementID(claim.id, owner: qid),
              (claim.qualifiers ?? [:]).allSatisfy({ property, values in
                  property == "P1810" && !values.isEmpty && values.allSatisfy {
                      $0.snaktype == "value" && $0.datatype == "string"
                          && nonempty($0.datavalue?.stringValue) != nil
                  }
              }) else { return nil }
        return id
    }

    private func materialize(_ entity: Entity, anchors: [String: Work]) throws -> Work {
        guard let qid = entity.id, Self.validQID(qid), let title = entity.title else { throw KnowledgeError.invalidResponse }
        if var anchored = anchors[qid] {
            // Caller supplies only previously verified identity mappings. Preserve
            // curated kind, artwork, music ID, names, and links without replacement.
            anchored.knowledgeID = qid
            return anchored
        }
        guard let id = WorkID(rawValue: "wikidata:\(qid)") else { throw KnowledgeError.invalidIdentifier }
        var work = Work(id: id, title: title, creator: "", kind: entity.kind, art: "",
                        detail: entity.descriptionText ?? "", url: "https://www.wikidata.org/wiki/\(qid)",
                        linkedCreatorIDs: [])
        work.knowledgeID = qid
        return work
    }

    private func eligible(_ entity: Entity, property: String, limited: inout Bool) -> [(target: String, claim: Claim)] {
        (entity.claims?[property] ?? []).compactMap { claim in
            guard ["normal", "preferred"].contains(claim.rank ?? ""), claim.mainsnak?.snaktype == "value",
                  claim.mainsnak?.datatype == "wikibase-item", let target = claim.mainsnak?.datavalue?.entityID,
                  Self.validQID(target) else { return nil }
            // A narrowed historical/role-specific assertion must not silently
            // become an unconditional edge. Qualifier interpretation is deferred.
            guard claim.qualifiers?.isEmpty ?? true else { limited = true; return nil }
            guard let statementID = claim.id, !statementID.isEmpty else { limited = true; return nil }
            return (target, claim)
        }
    }

    private func source(entity: Entity, property: String, claim: Claim) -> Source {
        let qid = entity.id ?? ""
        var url = URLComponents(string: "https://www.wikidata.org/wiki/\(qid)")!
        // Live HTML verified: the exact statement GUID (including $ and casing)
        // is the row's DOM id. Fall back to the property anchor for invalid GUIDs.
        if let id = claim.id, let split = id.firstIndex(of: "$"),
           id[..<split].uppercased() == qid, UUID(uuidString: String(id[id.index(after: split)...])) != nil {
            url.fragment = id
        } else { url.fragment = property }
        return Source(title: "Wikidata · \(entity.title ?? qid)", detail: "社区维护的结构化资料", url: url.url!.absoluteString)
    }

    private func entities(_ ids: [String]) async throws -> [String: Entity] {
        let url = try endpoint([
            "action": "wbgetentities", "ids": ids.sorted().joined(separator: "|"),
            "props": "labels|descriptions|claims", "languages": "zh-hans|zh-cn|zh|zh-hant|en|ja|mul"
        ])
        let payload: EntityPayload = try await load(url) { payload in
            guard let entities = payload.entities else { throw KnowledgeError.invalidResponse }
            for id in ids {
                guard let entity = entities[id] else { throw KnowledgeError.invalidResponse }
                if entity.missing { continue }
                guard entity.id == id, entity.type == "item" else { throw KnowledgeError.invalidResponse }
            }
        }
        return (payload.entities ?? [:]).filter { ids.contains($0.key) && !$0.value.missing }
    }

    private func reverseCandidates(qid: String, property: String) async throws -> (ids: [String], more: Bool) {
        let url = try endpoint([
            "action": "query", "list": "search", "srsearch": "haswbstatement:\(property)=\(qid)",
            "srnamespace": "0", "srlimit": String(edgeLimit + 1), "srprop": ""
        ])
        let payload: ReversePayload = try await load(url) { payload in
            guard payload.query?.search != nil else { throw KnowledgeError.invalidResponse }
        }
        let values = payload.query?.search ?? []
        return (values.compactMap { Self.validQID($0.title) ? $0.title : nil },
                (payload.query?.searchinfo?.totalhits ?? values.count) > edgeLimit)
    }

    private func reversePage(qid: String, property: String, offset: Int, continuation: String?, limit: Int) async throws -> ReversePage {
        var parameters = [
            "action": "query", "list": "search", "srsearch": "haswbstatement:\(property)=\(qid)",
            "srnamespace": "0", "srlimit": String(limit), "srprop": "", "srinfo": "totalhits", "sroffset": String(offset)
        ]
        if let continuation { parameters["continue"] = continuation }
        let url = try endpoint(parameters)
        let payload: ReversePayload = try await load(url) { payload in
            guard let items = payload.query?.search, items.count <= limit,
                  items.allSatisfy({ Self.validQID($0.title) }) else { throw KnowledgeError.invalidResponse }
            let count = payload.query?.searchinfo?.totalhits
            guard count == nil || count! >= 0 else { throw KnowledgeError.invalidResponse }
            if let continuation = payload.continuation {
                guard let next = continuation.sroffset, next > offset, next <= Int.max - edgeLimit, !items.isEmpty else { throw KnowledgeError.invalidResponse }
            } else {
                // Missing metadata is an error, never proof that this is the tail.
                guard let count else { throw KnowledgeError.invalidResponse }
                if count > offset + items.count && items.isEmpty { throw KnowledgeError.invalidResponse }
                if !items.isEmpty && count < offset + items.count { throw KnowledgeError.invalidResponse }
            }
        }
        let items = payload.query?.search ?? []
        let nextOffset: Int?
        if let continuation = payload.continuation { nextOffset = continuation.sroffset }
        else if let count = payload.query?.searchinfo?.totalhits, count > offset + items.count { nextOffset = offset + items.count }
        else { nextOffset = nil }
        return ReversePage(ids: items.map(\.title), nextOffset: nextOffset, continuation: payload.continuation?.token)
    }

    private func endpoint(_ parameters: [String: String]) throws -> URL {
        var parts = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        var values = parameters
        values["format"] = "json"
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw KnowledgeError.invalidIdentifier }
        return url
    }

    private func load<Payload: Decodable>(_ url: URL, validate: (Payload) throws -> Void) async throws -> Payload {
        try Task.checkCancellation()
        let now = Date()
        let data: Data
        var fetchedFromNetwork = false
        var apiRetryAfter: TimeInterval?
        if let entry = cache[url], entry.expires > now { data = entry.data }
        else {
            fetchedFromNetwork = true
            if let blockedUntil, blockedUntil > now { throw KnowledgeError.throttled(retryAfter: blockedUntil.timeIntervalSince(now)) }
            requestTimes.removeAll { now.timeIntervalSince($0) >= 60 }
            guard requestTimes.count < 30 else { throw KnowledgeError.throttled(retryAfter: 60) }
            requestTimes.append(now)
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Pianwai/0.1 (personal cultural exploration; read-only Wikidata client)", forHTTPHeaderField: "User-Agent")
            let body: Data
            let response: URLResponse
            do { (body, response) = try await session.data(for: request) }
            catch {
                try Task.checkCancellation()
                // A provider can cancel its own request while this caller is
                // still active. Only Task cancellation abandons the search;
                // provider failures must reach the caller's retry state.
                throw error
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw KnowledgeError.unavailable }
            if http.statusCode == 429 || http.statusCode == 503 {
                let delay = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                blockedUntil = Date().addingTimeInterval(delay)
                throw KnowledgeError.throttled(retryAfter: delay)
            }
            guard (200..<300).contains(http.statusCode) else { throw KnowledgeError.unavailable }
            guard body.count <= 5_000_000 else { throw KnowledgeError.invalidResponse }
            if let header = http.value(forHTTPHeaderField: "Retry-After") {
                apiRetryAfter = Self.retryDelay(header, now: Date())
            }
            data = body
        }
        let payload: Payload
        do {
            let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
            if let error = envelope.error {
                if ["maxlag", "ratelimited", "readonly"].contains(error.code ?? "") {
                    let delay = apiRetryAfter ?? 60
                    blockedUntil = Date().addingTimeInterval(delay)
                    throw KnowledgeError.throttled(retryAfter: delay)
                }
                throw KnowledgeError.invalidResponse
            }
            payload = try JSONDecoder().decode(Payload.self, from: data)
            try validate(payload)
        } catch let error as KnowledgeError {
            cache[url] = nil
            throw error
        } catch {
            cache[url] = nil
            throw KnowledgeError.invalidResponse
        }
        try Task.checkCancellation()
        if fetchedFromNetwork {
            if cache.count >= 100 { cache.removeAll() }
            cache[url] = (Date().addingTimeInterval(3_600), data)
        }
        return payload
    }

    private static func retryDelay(_ raw: String?, now: Date) -> TimeInterval {
        if let raw, let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 { return max(1, seconds) }
        if let raw {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: raw) { return max(1, date.timeIntervalSince(now)) }
        }
        return 60
    }

    private static func validQID(_ value: String) -> Bool {
        guard value.first == "Q", (2...20).contains(value.count), value.dropFirst().first != "0" else { return false }
        return value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func mapping(_ property: String) -> (kind: RelationKind, label: String, inverse: String) {
        switch property {
        case "P57": (.directedBy, "导演", "导演作品")
        case "P50": (.authoredBy, "作者", "创作作品")
        case "P86": (.composedBy, "作曲", "作曲作品")
        case "P144": (.adaptedFrom, "原作", "改编作品")
        case "P406": (.soundtrackRelease, "原声", "原声来自")
        case "P942": (.themeMusic, "主题音乐", "主题音乐来自")
        default: (.performedBy, "表演者", "参与作品")
        }
    }

    private struct PendingEdge { let from: String; let to: String; let property: String; let claim: Claim }
    private struct ReversePage { let ids: [String]; let nextOffset: Int?; let continuation: String? }
    private struct ErrorEnvelope: Decodable { let error: APIError? }
    private struct APIError: Decodable { let code: String? }
    private struct EntityPayload: Decodable { let entities: [String: Entity]? }
    private struct SearchPayload: Decodable {
        let success: Int?
        let search: [Item]?
        struct Item: Decodable { let id: String?; let label: String?; let description: String? }
    }
    private struct ReversePayload: Decodable {
        let query: Query?
        let continuation: Continuation?
        enum CodingKeys: String, CodingKey { case query; case continuation = "continue" }
        struct Query: Decodable { let search: [Item]?; let searchinfo: Info? }
        struct Item: Decodable { let title: String }
        struct Info: Decodable { let totalhits: Int? }
        struct Continuation: Decodable {
            let sroffset: Int?
            let token: String?
            enum CodingKeys: String, CodingKey { case sroffset; case token = "continue" }
        }
    }
    private struct Entity: Decodable {
        let id: String?
        let type: String?
        let labels: [String: LocalizedText]?
        let descriptions: [String: LocalizedText]?
        let claims: [String: [Claim]]?
        private let missingValue: String?
        var missing: Bool { missingValue != nil || id == nil }
        enum CodingKeys: String, CodingKey { case id, type, labels, descriptions, claims; case missingValue = "missing" }
        var title: String? { localized(labels) }
        var descriptionText: String? { localized(descriptions) }
        private func localized(_ items: [String: LocalizedText]?) -> String? {
            ["zh-hans", "zh-cn", "zh", "zh-hant", "en", "ja", "mul"].compactMap { Self.clean(items?[$0]?.value) }.first
        }
        private static func clean(_ value: String?) -> String? {
            guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
            return result
        }
        var typeIDs: Set<String> {
            Set((claims?["P31"] ?? []).filter {
                ["normal", "preferred"].contains($0.rank ?? "") && ($0.qualifiers?.isEmpty ?? true)
                    && $0.mainsnak?.snaktype == "value" && $0.mainsnak?.datatype == "wikibase-item"
            }.compactMap { $0.mainsnak?.datavalue?.entityID })
        }
        var kind: String {
            let ids = typeIDs
            if !ids.isDisjoint(with: ["Q5", "Q215380"]) { return "创作者" }
            if !ids.isDisjoint(with: ["Q11424", "Q20650540"]) { return "电影" }
            if !ids.isDisjoint(with: ["Q5398426", "Q63952888"]) { return "电视剧" }
            if ids.contains("Q21198342") { return "漫画" }
            // Video games and their expansions: the same classes DiscoveryMediaIdentity accepts.
            if !ids.isDisjoint(with: ["Q7889", "Q209163", "Q16070115"]) { return "游戏" }
            let forms = Set((claims?["P7937"] ?? []).filter {
                ["normal", "preferred"].contains($0.rank ?? "") && ($0.qualifiers?.isEmpty ?? true)
                    && $0.mainsnak?.snaktype == "value" && $0.mainsnak?.datatype == "wikibase-item"
                    && KnowledgeGraphService.validStatementID($0.id, owner: id)
            }.compactMap { $0.mainsnak?.datavalue?.entityID })
            if !ids.isDisjoint(with: ["Q571", "Q8261"]) || forms.contains("Q8261") { return "书籍" }
            if !ids.isDisjoint(with: ["Q7725634", "Q104213567"]) { return "文学作品" }
            if ids.contains("Q482994") { return "专辑" }
            if !ids.isDisjoint(with: ["Q7366", "Q55850593"]) { return "歌曲" }
            // A musical work/composition is not a playable recording. Keep its
            // exact knowledge identity and let the reader find a recording.
            if !ids.isDisjoint(with: ["Q134556", "Q105543609"]) { return "音乐作品" }
            // Do not infer a type from a description, title, or composer credit.
            return "作品"
        }
    }
    private struct LocalizedText: Decodable { let value: String }
    private struct Claim: Decodable {
        let id: String?
        let rank: String?
        let mainsnak: Snak?
        let qualifiers: [String: [Snak]]?
    }
    private struct Snak: Decodable { let snaktype: String?; let datatype: String?; let datavalue: DataValue? }
    private struct DataValue: Decodable {
        let entityID: String?
        let stringValue: String?
        private enum Keys: String, CodingKey { case value }
        private struct EntityValue: Decodable { let id: String? }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            entityID = (try? container.decode(EntityValue.self, forKey: .value))?.id
            stringValue = try? container.decode(String.self, forKey: .value)
        }
    }
}
