import Foundation
import Observation

protocol BackgroundReferenceResolving: Sendable {
    func resolveCreative(_ reference: WikiArticleReference) async throws -> String?
}

struct ResolvedBackgroundReference: Identifiable, Equatable, Sendable {
    let article: WikiArticleReference
    let qid: String
    var id: String { qid }
}

struct BackgroundReferenceRequest: Hashable, Sendable {
    let sourceID: String
    let candidates: [WikiArticleReference]
    let excludedQIDs: Set<String>
}

/// The source supplies at most eight exact article links. Only verified, new
/// creative identities consume the three visible destinations, in source order.
@MainActor @Observable
final class BackgroundReferenceSelection {
    private(set) var references: [ResolvedBackgroundReference] = []
    private(set) var hasFailures = false
    private(set) var isLoading = false
    private(set) var openingID: String?
    private(set) var openingError: String?
    @ObservationIgnored private let resolver: any BackgroundReferenceResolving
    @ObservationIgnored private var request: BackgroundReferenceRequest?
    @ObservationIgnored private var loadID: UUID?
    @ObservationIgnored private var openID: UUID?

    init(resolver: any BackgroundReferenceResolving = WikipediaWorkResolver.shared) {
        self.resolver = resolver
    }

    func load(_ request: BackgroundReferenceRequest) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        loadID = token
        if self.request != request {
            references = []
            if self.request?.sourceID != request.sourceID { cancelOpening() }
        }
        self.request = request
        hasFailures = false
        isLoading = true
        defer { if loadID == token { isLoading = false } }
        var selected: [ResolvedBackgroundReference] = []
        var seenQIDs = request.excludedQIDs
        var seenArticles = Set<String>()
        for article in request.candidates.prefix(8) {
            guard loadID == token, !Task.isCancelled else { return }
            guard seenArticles.insert(article.id).inserted else { continue }
            do {
                let qid = try await resolver.resolveCreative(article)
                guard loadID == token, !Task.isCancelled else { return }
                guard let qid, seenQIDs.insert(qid).inserted else { continue }
                selected.append(.init(article: article, qid: qid))
                references = selected
                if selected.count == 3 { break }
            } catch is CancellationError { return }
            catch {
                guard loadID == token, !Task.isCancelled else { return }
                hasFailures = true
            }
        }
        guard loadID == token, !Task.isCancelled else { return }
        references = selected
    }

    /// An open request may finish after a pop, a new selection or cancellation.
    /// The caller supplies its exact navigation origin; none may take the page
    /// back unless that origin and this request are both still current.
    func open(_ reference: ResolvedBackgroundReference,
              load: @MainActor (String) async throws -> WorkID,
              isCurrent: @MainActor () -> Bool,
              navigate: @MainActor (WorkID) -> Void) async {
        guard !Task.isCancelled, isCurrent() else { return }
        let token = UUID()
        openID = token
        openingID = reference.id
        openingError = nil
        defer {
            if openID == token { openID = nil; openingID = nil }
        }
        do {
            let work = try await load(reference.qid)
            guard openID == token, !Task.isCancelled, isCurrent() else { return }
            openingID = nil
            openID = nil
            navigate(work)
        } catch is CancellationError {
            if openID == token { cancelOpening() }
        } catch {
            guard openID == token, !Task.isCancelled, isCurrent() else { return }
            openingID = nil
            openID = nil
            openingError = "资料暂时未载入，点条目可重试。"
        }
    }

    func cancel() {
        loadID = nil
        isLoading = false
        cancelOpening()
    }

    private func cancelOpening() {
        openID = nil
        openingID = nil
        openingError = nil
    }
}
