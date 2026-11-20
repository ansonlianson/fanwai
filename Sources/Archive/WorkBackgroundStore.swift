import Foundation
import Observation

@MainActor @Observable
final class WorkBackgroundStore {
    static let shared = WorkBackgroundStore()
    private(set) var values: [String: WorkBackgroundResponse] = [:]
    private(set) var loading = Set<String>()
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored private let service: any WorkBackgroundFetching
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempted = Set<String>()

    init(service: any WorkBackgroundFetching = FallbackWorkBackgroundService(primary: WorkBackgroundService()),
         directory: URL? = PianwaiRuntime.cacheDirectory("PianwaiBackground")) {
        self.service = service; self.directory = directory
    }

    func load(_ article: WikiArticleIdentity, retry: Bool = false) async {
        guard article.isValid else { return }
        let key = article.cacheKey
        if let task = tasks[key] { await task.value; return }
        if !retry, attempted.contains(key) { return }
        let file = directory?.appendingPathComponent(key + ".json")
        if values[key] == nil, let file, let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode(StoredBackground.self, from: data),
            [5, 6, 7].contains(cached.version), cached.response.article == article {
            values[key] = cached.response
            // Previous source excerpts remain readable during migration,
            // including offline, while acquiring the concise continuation pool.
            if !retry, cached.version == 7, Date().timeIntervalSince(cached.fetchedAt) < 86_400 * 7 {
                attempted.insert(key); return
            }
        }
        loading.insert(key); errors[key] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.loading.remove(key); self.tasks[key] = nil }
            do {
                let response = try await self.service.fetch(article: article)
                try Task.checkCancellation()
                guard response.article == article else { throw WorkContextError.invalidResponse }
                self.values[key] = response
                self.attempted.insert(key)
                if let directory = self.directory, let file {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(StoredBackground(response: response)) {
                        try? data.write(to: file, options: .atomic)
                    }
                }
            } catch is CancellationError {
                self.attempted.remove(key)
            } catch {
                self.errors[key] = "创作资料暂未载入"
                self.attempted.insert(key)
            }
        }
        tasks[key] = task
        await task.value
    }

    private struct StoredBackground: Codable {
        var version = 7
        let response: WorkBackgroundResponse
        var fetchedAt = Date()
    }
}
