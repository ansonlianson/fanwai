import Foundation

/// A deadline releases the caller even when an optional source ignores task
/// cancellation. Late results never publish into the page that already ended.
enum MetadataDeadline {
    /// Optional independent sources compete for the first verified result;
    /// a fast empty source must not cancel the other source.
    static func first<T: Sendable>(seconds: Double, operations: [@Sendable () async -> T?]) async -> T? {
        let race = MetadataFirstResult<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await race.start(continuation, seconds: seconds, operations: operations) }
            }
        } onCancel: { Task { await race.finish(nil) } }
    }
    static func value<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T?) async -> T? {
        let race = MetadataDeadlineRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await race.start(continuation, seconds: seconds, operation: operation) }
            }
        } onCancel: { Task { await race.finish(nil) } }
    }
}

private actor MetadataFirstResult<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    private var workers: [Task<Void, Never>] = []
    private var remaining = 0
    private var finished = false
    func start(_ continuation: CheckedContinuation<T?, Never>, seconds: Double, operations: [@Sendable () async -> T?]) {
        guard !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation; remaining = operations.count
        guard remaining > 0 else { finish(nil); return }
        workers = operations.map { operation in Task { await received(operation()) } }
        workers.append(Task { do { try await Task.sleep(for: .seconds(seconds)) } catch { return }; finish(nil) })
    }
    private func received(_ value: T?) {
        remaining -= 1
        if value != nil || remaining == 0 { finish(value) }
    }
    func finish(_ value: T?) {
        guard !finished else { return }
        finished = true; workers.forEach { $0.cancel() }; workers.removeAll()
        continuation?.resume(returning: value); continuation = nil
    }
}

private actor MetadataDeadlineRace<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false
    func start(_ continuation: CheckedContinuation<T?, Never>, seconds: Double,
               operation: @escaping @Sendable () async -> T?) {
        guard !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        worker = Task { let result = await operation(); finish(result) }
        timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            finish(nil)
        }
    }
    func finish(_ value: T?) {
        guard !finished else { return }
        finished = true; worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
        continuation?.resume(returning: value); continuation = nil
    }
}

/// One bounded, cached metadata lane for discovery, covers and destinations.
/// No retries or site challenges: throttling stops this source for its cooldown.
actor MetadataTransport {
    static let shared = MetadataTransport()
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    struct Response: Sendable { let data: Data; let http: HTTPURLResponse }
    private struct Saved: Codable { let data: Data; let date: Date; let ttl: Double }
    private let loader: Loader
    private let directory: URL?
    private var cache: [URL: Saved] = [:]
    private var flights: [URL: Task<Response?, Never>] = [:]
    private var blocked: [String: Date] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(directory: URL? = PianwaiRuntime.cacheDirectory("DiscoveryMetadata-v1"),
         loader: @escaping Loader = { try await PianwaiRuntime.session.data(for: $0) }) {
        self.directory = directory; self.loader = loader
    }
    func response(_ url: URL, timeout: Double = 6, referer: String? = nil) async -> Response? {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard WikidataRequestPacer.isWikimedia(url) || ["movie.douban.com", "book.douban.com", "www.youtube.com"].contains(host) else { return nil }
        if cache[url] == nil, let file = file(url), let bytes = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: bytes), saved.data.count <= 4_000_000 { cache[url] = saved }
        let saved = cache[url]
        if let saved, Date().timeIntervalSince(saved.date) < saved.ttl { return restored(saved, url: url) }
        let scope = WikidataRequestPacer.isWikimedia(url) ? "wikimedia" : host
        if let until = blocked[scope], until > Date() { return saved.flatMap { Date().timeIntervalSince($0.date) < 604_800 ? restored($0, url: url) : nil } }
        if let task = flights[url] { return await task.value }
        let deadline = Date().addingTimeInterval(timeout)
        let task = Task { await perform(url, deadline: deadline, referer: referer, scope: scope) }
        flights[url] = task
        let result = await task.value
        flights[url] = nil
        if let result { return result }
        return saved.flatMap { Date().timeIntervalSince($0.date) < 604_800 ? restored($0, url: url) : nil }
    }
    private func perform(_ url: URL, deadline: Date, referer: String?, scope: String) async -> Response? {
        let queued = Date()
        var acquired: Date?, released: Date?, status = "deadline-before-slot", bytes = 0
        defer {
            let ended = Date()
            if P17Metrics.enabled {
                let row = ["event": "metadataRequest", "host": url.host ?? "", "queued": String(queued.timeIntervalSince1970),
                    "slotAcquired": acquired.map { String($0.timeIntervalSince1970) } ?? "", "rateReleased": released.map { String($0.timeIntervalSince1970) } ?? "",
                    "ended": String(ended.timeIntervalSince1970), "status": status, "bytes": String(bytes)]
                Task { await P17Metrics.shared.record(row) }
            }
        }
        await acquire()
        acquired = Date()
        defer { release() }
        guard deadline > Date(), blocked[scope].map({ $0 <= Date() }) ?? true else { return nil }
        if WikidataRequestPacer.isWikimedia(url) {
            do { try await SourceHTTP.wikidataPacer.wait(for: url) } catch { status = "pacing-cancelled"; return nil }
        }
        released = Date()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { status = "deadline-after-pacing"; return nil }
        var request = URLRequest(url: url, timeoutInterval: remaining)
        request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let loaded: (Data, URLResponse)
        do { loaded = try await loader(request) }
        catch { status = (error as? URLError).map { "urlerror:" + String($0.code.rawValue) } ?? "transport-error"; return nil }
        let (data, response) = loaded
        guard let http = response as? HTTPURLResponse else { status = "invalid-response"; return nil }
        status = String(http.statusCode); bytes = data.count
        if [429, 503].contains(http.statusCode) {
            blocked[scope] = Date().addingTimeInterval(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            return nil
        }
        guard http.statusCode == 200, data.count < 4_000_000,
              let object = try? JSONSerialization.jsonObject(with: data), (object as? [String: Any])?["error"] == nil else { return nil }
        let empty = (object as? [Any])?.isEmpty == true
        let saved = Saved(data: data, date: Date(), ttl: empty ? 300 : 86_400)
        cache[url] = saved
        if let directory, let file = file(url) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let bytes = try? JSONEncoder().encode(saved) { try? bytes.write(to: file, options: .atomic) }
        }
        return .init(data: data, http: http)
    }
    private func file(_ url: URL) -> URL? {
        directory?.appendingPathComponent(DiscoveryCore.digest([url.absoluteString]) + ".json")
    }
    private func restored(_ saved: Saved, url: URL) -> Response? {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
            .map { .init(data: saved.data, http: $0) }
    }
    private func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
    static func retryDelay(_ value: String?) -> Double {
        if let value, let seconds = Double(value) { return min(86_400, max(5, seconds)) }
        if let value {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: value) { return min(86_400, max(5, date.timeIntervalSinceNow)) }
        }
        return 60
    }
}
