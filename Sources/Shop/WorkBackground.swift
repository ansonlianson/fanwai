import Foundation

struct WikiArticleIdentity: Codable, Hashable, Sendable {
    let qid: String
    let title: String
    let language: String
    let pageID: Int
    let revision: Int
    var cacheKey: String { "\(qid).\(language).\(revision)" }
    var isValid: Bool {
        WorkContextService.validQID(qid) && ["zh", "en"].contains(language)
            && pageID > 0 && revision > 0 && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WorkBackgroundExcerpt: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let heading: String
    let body: String
    let sourceParagraph: String
    let source: Source
    let language: String
    var references: [WikiArticleReference]? = nil
    /// A shorter original sentence retains its exact paragraph-prefix identity
    /// so preparation can preserve other verified destinations when needed.
    var derivedFromExcerptID: String? = nil
}

struct WikiArticleReference: Codable, Hashable, Identifiable, Sendable {
    let label: String
    let title: String
    let language: String
    var id: String { language + ":" + title }
}

struct WorkBackgroundResponse: Codable, Sendable {
    let article: WikiArticleIdentity
    let excerpts: [WorkBackgroundExcerpt]
    var supplementalArticle: WikiArticleIdentity? = nil
    var continuationCandidates: [WorkBackgroundExcerpt]? = nil
    // Original paragraph prefixes remain available to an already-read choice.
    // They belong to the same candidate families, not an additional pool.
    var retainedContinuationCandidates: [WorkBackgroundExcerpt]? = nil
}

protocol WorkBackgroundFetching: Sendable {
    func fetch(article: WikiArticleIdentity) async throws -> WorkBackgroundResponse
}
