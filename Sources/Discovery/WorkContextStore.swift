import Foundation
import Observation

@MainActor @Observable
final class WorkContextStore {
    static let shared = WorkContextStore()
    private(set) var values: [String: WorkContext] = [:]
    private(set) var loading = Set<String>()
    private(set) var errors: [String: String] = [:]
    private(set) var displayTitleLoading = Set<String>()
    @ObservationIgnored private let service: any WorkContextFetching
    @ObservationIgnored private let editionService: WorkContextEditionService
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempted = Set<String>()
    @ObservationIgnored private var titleTasks: [String: TitleTask] = [:]

    init(service: any WorkContextFetching = WorkContextService(), directory: URL? = PianwaiRuntime.cacheDirectory("PianwaiWorkContext"), editionService: WorkContextEditionService = WorkContextEditionService()) {
        self.service = service; self.directory = directory; self.editionService = editionService
    }

    func load(_ qid: String, retry: Bool = false) async {
        guard WorkContextService.validQID(qid) else { return }
        if let task = tasks[qid] { await task.value; return }
        if !retry && attempted.contains(qid) {
            _ = beginDisplayTitle(qid)
            return
        }
        if values[qid] == nil, let file = directory?.appendingPathComponent(qid + ".json"),
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(WorkContext.self, from: data), cached.qid == qid {
            values[qid] = cached
        }
        if !retry, let cached = values[qid], cached.contentVersion == 3, !cached.introductionUnavailable, cached.editionLookupUnavailable != true,
           Date().timeIntervalSince(cached.fetchedAt) < 86_400 * 7 {
            attempted.insert(qid)
            _ = beginDisplayTitle(qid)
            return
        }
        loading.insert(qid); errors[qid] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.loading.remove(qid); self.tasks[qid] = nil }
            do {
                var value = try await self.service.fetch(qid: qid, includeDisplayTitle: false)
                try Task.checkCancellation()
                guard value.qid == qid else { throw WorkContextError.invalidIdentity }
                var retainedArticle = false
                // A previous display name is reusable only for this exact
                // article revision. A new revision must earn its own title.
                if let previous = self.values[qid], let article = value.article,
                   previous.article == article {
                    value.displayTitle = previous.displayTitle
                    value.displayTitleSource = previous.displayTitleSource
                    value.displayTitleState = previous.displayTitleState
                    value.displayTitleAttemptedAt = previous.displayTitleAttemptedAt
                }
                if value.introductionUnavailable {
                    self.errors[qid] = "简介暂未载入"
                    // An unavailable article is not evidence that its last
                    // verified revision disappeared. Keep that revision as the
                    // cache key for the already-read background and artwork.
                    // Never attach an old display name to a new revision.
                    if value.article == nil, let previous = self.values[qid],
                       previous.qid == qid, let article = previous.article,
                       article.qid == qid, article.isValid {
                        value.article = article
                        value.displayTitle = previous.displayTitle
                        value.displayTitleSource = previous.displayTitleSource
                        value.displayTitleState = previous.displayTitleState
                        value.displayTitleAttemptedAt = previous.displayTitleAttemptedAt
                        retainedArticle = true
                    }
                    if let previous = self.values[qid], previous.introduction != nil {
                        value.introduction = previous.introduction
                        value.introductionSource = previous.introductionSource
                        value.language = previous.language
                    }
                }
                let previousEditions = self.values[qid]?.editions
                self.values[qid] = value
                self.persist(value)
                // This task is deliberately not awaited: the article and its
                // facts can render and start background reading immediately.
                _ = self.beginDisplayTitle(qid, retry: retry && !retainedArticle)
                if value.hasEditionCandidates == true {
                    // Publish the introduction immediately; finding a particular
                    // edition must not delay reading already-verified material.
                    do {
                        let editions = try await self.editionService.fetch(qid: qid)
                        // Merge into the current value so a completed title
                        // request cannot be erased by a slower edition lookup.
                        self.values[qid]?.editions = editions
                        self.values[qid]?.editionLookupUnavailable = false
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        self.values[qid]?.editions = previousEditions
                        self.values[qid]?.editionLookupUnavailable = true
                        self.errors[qid] = "版本资料暂未载入"
                    }
                }
                self.attempted.insert(qid)
                // This is a redownloadable cache, separate from saved works and
                // reading history. A disk failure never discards fetched content.
                if let current = self.values[qid] { self.persist(current) }
            } catch is CancellationError {
                // A stopped optional request is not presented as an empty result.
                self.attempted.remove(qid)
            } catch {
                self.errors[qid] = "作品资料暂未载入"
                self.attempted.insert(qid)
            }
        }
        tasks[qid] = task
        await task.value
    }

    /// Optional callers may wait for or explicitly retry just the display name.
    /// Normal page loading always schedules it independently of the article.
    func loadDisplayTitle(_ qid: String, retry: Bool = false) async {
        if let task = beginDisplayTitle(qid, retry: retry) { await task.value }
    }

    private func beginDisplayTitle(_ qid: String, retry: Bool = false) -> Task<Void, Never>? {
        guard WorkContextService.validQID(qid) else { return nil }
        let context = values[qid]
        if let current = titleTasks[qid] {
            if current.article == context?.article { return current.task }
            current.task.cancel()
            titleTasks[qid] = nil
            displayTitleLoading.remove(qid)
        }
        guard let context, context.qid == qid, let article = context.article,
              article.isValid, article.qid == qid, article.language == "zh" else { return nil }
        if !retry {
            if context.displayTitleState == .absent { return nil }
            if context.displayTitleState == .available,
               context.displayTitle != nil, context.displayTitleSource != nil { return nil }
            if context.displayTitleState == .failed, let attemptedAt = context.displayTitleAttemptedAt {
                let age = Date().timeIntervalSince(attemptedAt)
                if age >= 0, age < 30 { return nil }
            }
        }
        let requestID = UUID()
        displayTitleLoading.insert(qid)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.titleTasks[qid]?.id == requestID {
                    self.titleTasks[qid] = nil
                    self.displayTitleLoading.remove(qid)
                }
            }
            do {
                let result = try await self.service.fetchDisplayTitle(article: article)
                try Task.checkCancellation()
                guard self.titleTasks[qid]?.id == requestID,
                      self.values[qid]?.article == article else { return }
                self.values[qid]?.displayTitle = result?.title
                self.values[qid]?.displayTitleSource = result?.source
                self.values[qid]?.displayTitleState = result == nil ? .absent : .available
                self.values[qid]?.displayTitleAttemptedAt = Date()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.titleTasks[qid]?.id == requestID,
                      self.values[qid]?.article == article else { return }
                // Keep a successful title/source from this same revision.
                // Failed is retryable independently of the seven-day body cache.
                self.values[qid]?.displayTitleState = .failed
                self.values[qid]?.displayTitleAttemptedAt = Date()
            }
            if let current = self.values[qid] { self.persist(current) }
        }
        titleTasks[qid] = TitleTask(id: requestID, article: article, task: task)
        return task
    }

    private func persist(_ value: WorkContext) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: directory.appendingPathComponent(value.qid + ".json"), options: .atomic)
        }
    }

    private struct TitleTask {
        let id: UUID
        let article: WikiArticleIdentity
        let task: Task<Void, Never>
    }
}
