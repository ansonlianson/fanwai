import Foundation
import CryptoKit

/// One device-wide clock and disk cache for metadata and literal source reads.
/// Only public response bodies are retained, never request headers or credentials.
actor PublicDatabaseHTTP {
    static let shared = PublicDatabaseHTTP()
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Cached: Codable { let data: Data; let status: Int; let fetchedAt: Date }
    private let directory: URL?
    private let loader: Loader
    private let paced: Bool
    private var last: [String: ContinuousClock.Instant] = [:]
    private var pausedUntil: [String: ContinuousClock.Instant] = [:]
    private var flights: [String: Task<Data, Error>] = [:]
    private var expandedLinks: [URL: URL] = [:]
    init(directory: URL? = PianwaiRuntime.applicationDirectory("PublicDatabase-v1"), paced: Bool = true,
         loader: @escaping Loader = { request in
             let (data, response) = try await SourceHTTP.noRedirectSession.data(for: request)
             guard let http = response as? HTTPURLResponse else { throw CatalogError.server }
             return (data, http)
         }) { self.directory = directory; self.paced = paced; self.loader = loader }

    func get(_ url: URL, body: Data? = nil) async throws -> Data {
        guard StoryMaterialTransport.publicURL(url) else { throw CatalogError.invalidLink }
        let key = SHA256.hash(data: Data((url.absoluteString + (body.map { String(decoding: $0, as: UTF8.self) } ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let path = directory?.appendingPathComponent(key + ".json")
        if let path, let bytes = try? Data(contentsOf: path), let cached = try? JSONDecoder().decode(Cached.self, from: bytes),
           Date().timeIntervalSince(cached.fetchedAt) < (cached.status == 200 ? 7 * 86400 : 300) {
            guard cached.status == 200 else { throw CatalogError.notFound }; return cached.data
        }
        if let flight = flights[key] { return try await flight.value }
        let task = Task { try await self.load(url, body: body, path: path) }
        flights[key] = task
        defer { flights[key] = nil }
        return try await task.value
    }
    /// A saved answer for this address, without any request.
    func saved(_ url: URL) -> Data? {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let path = directory?.appendingPathComponent(key + ".json"), let bytes = try? Data(contentsOf: path),
              let cached = try? JSONDecoder().decode(Cached.self, from: bytes), cached.status == 200,
              Date().timeIntervalSince(cached.fetchedAt) < 7 * 86400 else { return nil }
        return cached.data
    }
    /// Wikimedia answered 429 within the last minute (its limits are per minute and shared by all its sites).
    func wikimediaThrottled() -> Bool {
        guard let last = wikimediaThrottledAt else { return false }
        return ContinuousClock.now < last.advanced(by: .seconds(60))
    }
    private var wikimediaThrottledAt: ContinuousClock.Instant?
    /// Expand only recognized music shares; read metadata afterwards by exact ID.
    func expandSongLink(_ original: URL) async throws -> URL {
        if let known = expandedLinks[original] { return known }
        var url = original, visited = Set<URL>()
        for _ in 0..<5 {
            if PlatformSongLink.parse(url) != nil { expandedLinks[original] = url; return url }
            guard PlatformSongLink.isShort(url), visited.insert(url).inserted,
                  StoryMaterialTransport.publicURL(url), let host = url.host else { throw CatalogError.invalidLink }
            try await reserve(host.lowercased())
            var request = SourceHTTP.request(url); request.timeoutInterval = 9
            let (_, response) = try await loader(request)
            if response.statusCode == 429 || response.statusCode == 503 {
                pausedUntil[host] = .now.advanced(by: .seconds(max(2, PublicRelationService.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))))
                throw CatalogError.throttled
            }
            guard (300...399).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw CatalogError.invalidLink }
            url = next
        }
        throw CatalogError.invalidLink
    }
    private func load(_ url: URL, body: Data?, path: URL?) async throws -> Data {
        let host = url.host!.lowercased()
        let maxAttempts = host == "musicbrainz.org" ? 2 : 1
        for attempt in 0...maxAttempts {
            try await reserve(host)
            var request = SourceHTTP.request(url); request.timeoutInterval = 9
            if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (bytes, response) = try await loader(request)
            if paced { last[host] = .now }
            guard bytes.count <= 4_000_000 else { throw CatalogError.invalidData }
            if response.statusCode == 429 || response.statusCode == 503 {
                let delay = max(2, PublicRelationService.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))
                pausedUntil[host] = .now.advanced(by: .seconds(delay))
                if WikidataRequestPacer.isWikimedia(url) { wikimediaThrottledAt = .now }
                guard attempt < maxAttempts else { throw CatalogError.throttled }
                continue
            }
            if response.statusCode == 200 || response.statusCode == 404 {
                if let path {
                    try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? JSONEncoder().encode(Cached(data: bytes, status: response.statusCode, fetchedAt: Date())).write(to: path, options: .atomic)
                }
            }
            guard response.statusCode == 200 else { throw response.statusCode == 404 ? CatalogError.notFound : CatalogError.server }
            return bytes
        }
        throw CatalogError.throttled
    }
    private func reserve(_ host: String) async throws {
        try Task.checkCancellation()
        // Finish cross-actor accounting before checking the host clock. Suspending
        // between that check and its update lets concurrent requests claim one slot.
        try await PublicRequestLedger.shared.reserve(host: host)
        if paced {
            while true {
                let interval = host == "musicbrainz.org" ? 1.05 : 0.55
                let earliest = max(last[host]?.advanced(by: .seconds(interval)) ?? .now, pausedUntil[host] ?? .now)
                guard ContinuousClock.now < earliest else { break }
                try await ContinuousClock().sleep(until: earliest, tolerance: .zero)
            }
        }
        try Task.checkCancellation()
        last[host] = .now
    }
    nonisolated static func endpoint(_ host: String, _ path: String, _ params: [String: String] = [:]) -> URL {
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path
        c.queryItems = params.isEmpty ? nil : params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}

actor PublicRequestLedger {
    static let shared = PublicRequestLedger()
    func reserve(host: String) throws {
        guard let root = ProcessInfo.processInfo.environment["PIANWAI_ARCH2_OUTPUT"], root.hasSuffix("/QA/ARCH2") else { return }
        let file = URL(fileURLWithPath: root).appendingPathComponent("PUBLIC-BUDGET.json")
        var object = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let total = object["total"] as? Int ?? 0
        guard total < 1000 else { throw CatalogError.throttled }
        var hosts = object["hosts"] as? [String: Int] ?? [:]; hosts[host, default: 0] += 1
        object["total"] = total + 1; object["hosts"] = hosts
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
    }
}
