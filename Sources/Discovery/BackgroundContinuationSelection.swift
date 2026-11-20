import Foundation
import Observation

struct BackgroundContinuationRequest: Hashable, Sendable {
    let first: WorkBackgroundExcerpt
    let second: WorkBackgroundExcerpt
    let candidates: [WorkBackgroundExcerpt]
    let excludedQIDs: Set<String>
    var originalCandidates: [WorkBackgroundExcerpt] = []
}

/// Prepares an optional second account without changing either displayed one.
/// A source anchor is only a lookup candidate: a replacement requires a new,
/// exactly verified creative identity. The caller owns when to freeze/display it.
@MainActor @Observable
final class BackgroundContinuationSelection {
    private(set) var preparedSecondID: String?
    private(set) var isLoading = false
    private(set) var hasPrepared = false
    private(set) var hasFailures = false
    @ObservationIgnored private let resolver: any BackgroundReferenceResolving
    @ObservationIgnored private var preparationID: UUID?

    private enum Resolution {
        case value(String?)
        case failed
        case budgetReached
        case abandoned
    }

    init(resolver: any BackgroundReferenceResolving = WikipediaWorkResolver.shared) {
        self.resolver = resolver
    }

    func prepare(_ request: BackgroundContinuationRequest) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        preparationID = token
        preparedSecondID = nil
        hasPrepared = false
        hasFailures = false
        isLoading = true
        defer { if preparationID == token { isLoading = false } }

        var attemptedArticles = Set<String>()
        var resolutions: [String: Resolution] = [:]
        var seenExcerpts: Set<String> = [request.first.id, request.second.id]
        var seenFamilies = seenExcerpts
        let alternatives = request.candidates.prefix(4).filter {
            seenExcerpts.insert($0.id).inserted
                && seenFamilies.insert($0.derivedFromExcerptID ?? $0.id).inserted
        }
        guard !alternatives.isEmpty else {
            hasPrepared = true
            return
        }

        // Keep exact successes, known noncreative results and failures for this
        // attempt. A shared anchor must not disappear from a later comparison
        // merely because it has already consumed its one transport request.
        func resolve(_ article: WikiArticleReference) async -> Resolution {
            guard preparationID == token, !Task.isCancelled else { return .abandoned }
            if let result = resolutions[article.id] { return result }
            guard attemptedArticles.count < 16 else { return .budgetReached }
            attemptedArticles.insert(article.id)
            let result: Resolution
            do {
                let qid = try await resolver.resolveCreative(article)
                guard preparationID == token, !Task.isCancelled else { return .abandoned }
                result = .value(qid)
            } catch {
                guard preparationID == token, !Task.isCancelled else { return .abandoned }
                // Provider cancellation is a failed lookup while this caller
                // remains active. True cancellation never publishes a result.
                hasFailures = true
                result = .failed
            }
            resolutions[article.id] = result
            return result
        }

        for excerpt in [request.first, request.second] {
            for article in (excerpt.references ?? []).prefix(8) {
                switch await resolve(article) {
                case .value(let qid):
                    guard let qid, !request.excludedQIDs.contains(qid) else { continue }
                    // Any existing new route preserves the original pair.
                    hasPrepared = true
                    return
                case .abandoned: return
                case .failed, .budgetReached: continue
                }
            }
        }

        for excerpt in alternatives {
            guard preparationID == token, !Task.isCancelled else { return }
            guard let originalID = excerpt.derivedFromExcerptID else {
                for article in (excerpt.references ?? []).prefix(8) {
                    switch await resolve(article) {
                    case .value(let qid):
                        guard let qid, !request.excludedQIDs.contains(qid) else { continue }
                        preparedSecondID = excerpt.id
                        hasPrepared = true
                        return
                    case .abandoned: return
                    case .failed, .budgetReached: continue
                    }
                }
                continue
            }

            // A retained original is context for this one candidate family,
            // never a fifth alternative. A missing or mismatched parent cannot
            // establish what the focused sentence omitted.
            let originals = request.originalCandidates.prefix(4).filter { $0.id == originalID }
            guard let original = originals.first, original.id != excerpt.id,
                  originals.allSatisfy({ $0 == original }),
                  original.derivedFromExcerptID == nil,
                  original.sourceParagraph == excerpt.sourceParagraph,
                  original.language == excerpt.language,
                  original.source.url == excerpt.source.url,
                  original.body.contains(excerpt.body) else { continue }

            let focusedReferences = Array((excerpt.references ?? []).prefix(8))
            let focusedArticleIDs = Set(focusedReferences.map(\.id))
            var focusedQIDs = Set<String>()
            for article in focusedReferences {
                switch await resolve(article) {
                case .value(let qid):
                    if let qid, !request.excludedQIDs.contains(qid) { focusedQIDs.insert(qid) }
                case .abandoned: return
                case .failed, .budgetReached: continue
                }
            }

            // Resolve every bounded omitted anchor before choosing shorter
            // prose. Different article titles can resolve to the same QID as
            // an included destination and must not force the longer account.
            let originalReferences = original.references ?? []
            var omittedIdentityUnknown = originalReferences.count > 8
            for article in originalReferences.prefix(8) where !focusedArticleIDs.contains(article.id) {
                switch await resolve(article) {
                case .value(let qid):
                    guard let qid, !request.excludedQIDs.contains(qid),
                          !focusedQIDs.contains(qid) else { continue }
                    preparedSecondID = original.id
                    hasPrepared = true
                    return
                case .failed, .budgetReached: omittedIdentityUnknown = true
                case .abandoned: return
                }
            }
            if !focusedQIDs.isEmpty {
                preparedSecondID = omittedIdentityUnknown ? original.id : excerpt.id
                hasPrepared = true
                return
            }
        }
        guard preparationID == token, !Task.isCancelled else { return }
        // Completion means this bounded attempt ended, not that every possible
        // source is empty. nil always leaves the original second account usable.
        hasPrepared = true
    }

    func cancel() {
        preparationID = nil
        isLoading = false
    }
}
