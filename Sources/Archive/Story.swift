import Foundation

/// The single story payload used by preset content, the catalog and R4's cache.
/// Legacy link annotations remain metadata; they are not a second story model.
struct Story: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let entityID: String
    let title: String
    let body: String
    let relatedEntityIDs: [String]
    let source: Source
    let score: Double
    let entityLinks: [String: WorkID]
    let additionalSources: [Source]?
    /// Literal person/work names. Unresolved names open an explicit search, never a guessed ID.
    let mentions: [String]?

    var workID: WorkID { WorkID(rawValue: entityID)! } // Validated by both initializers.
    var sourceTitle: String { source.title }
    var sourceURL: URL? { source.url.isEmpty ? nil : URL(string: source.url) }

    init(id: String, entityID: String, title: String, body: String,
         relatedEntityIDs: [String] = [], source: Source, score: Double = 0,
         entityLinks: [String: WorkID] = [:], additionalSources: [Source]? = nil, mentions: [String]? = nil) {
        precondition(WorkID(rawValue: entityID) != nil)
        self.id = id; self.entityID = entityID; self.title = title; self.body = body
        self.relatedEntityIDs = relatedEntityIDs; self.source = source; self.score = score
        self.entityLinks = entityLinks; self.additionalSources = additionalSources; self.mentions = mentions
    }

    /// Existing catalog call sites keep their typed work identity.
    init(id: String, workID: WorkID, title: String, body: String,
         entityLinks: [String: WorkID], source: Source, additionalSources: [Source]? = nil,
         relatedEntityIDs: [String]? = nil, score: Double = 0, mentions: [String]? = nil) {
        self.init(id: id, entityID: workID.rawValue, title: title, body: body,
                  relatedEntityIDs: relatedEntityIDs ?? Array(Set(entityLinks.values.map(\.rawValue))).sorted(),
                  source: source, score: score, entityLinks: entityLinks, additionalSources: additionalSources, mentions: mentions)
    }

    private enum CodingKeys: String, CodingKey {
        case id, entityID, workID, title, body, relatedEntityIDs, source, score, entityLinks, additionalSources, mentions
    }
    init(from decoder: Decoder) throws { try self.init(from: decoder, boundEntityID: nil) }

    /// Song-editorial v1 binds its unbound text to the recording in its parent
    /// entry. Older catalog snapshots store the same identity as `workID`.
    init(from decoder: Decoder, boundEntityID: String?) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entityID = try boundEntityID ?? c.decodeIfPresent(String.self, forKey: .entityID)
            ?? c.decode(String.self, forKey: .workID)
        guard WorkID(rawValue: entityID) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .entityID, in: c, debugDescription: "Invalid story entity")
        }
        let links = try c.decodeIfPresent([String: WorkID].self, forKey: .entityLinks) ?? [:]
        self.init(id: try c.decode(String.self, forKey: .id), entityID: entityID,
                  title: try c.decode(String.self, forKey: .title), body: try c.decode(String.self, forKey: .body),
                  relatedEntityIDs: try c.decodeIfPresent([String].self, forKey: .relatedEntityIDs)
                    ?? Array(Set(links.values.map(\.rawValue))).sorted(),
                  source: try c.decodeIfPresent(Source.self, forKey: .source) ?? Source(title: "", url: ""),
                  score: try c.decodeIfPresent(Double.self, forKey: .score) ?? 0,
                  entityLinks: links, additionalSources: try c.decodeIfPresent([Source].self, forKey: .additionalSources),
                  mentions: try c.decodeIfPresent([String].self, forKey: .mentions))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(entityID, forKey: .entityID)
        try c.encode(title, forKey: .title); try c.encode(body, forKey: .body)
        try c.encode(relatedEntityIDs, forKey: .relatedEntityIDs); try c.encode(source, forKey: .source)
        try c.encode(score, forKey: .score); try c.encode(entityLinks, forKey: .entityLinks)
        try c.encodeIfPresent(additionalSources, forKey: .additionalSources)
        try c.encodeIfPresent(mentions, forKey: .mentions)
    }
}

// Compatibility spelling only. All storage and providers use the same payload.
typealias EditorialStory = Story

