import Foundation

enum SourcePageAudit {
    struct Request: Codable, Sendable { let url: String; let purpose: String; var status: Int?; var error: String? }
    struct Skipped: Codable, Sendable { let url: String; let reason: String }
}

/// A job owns its complete HTTP budget, including robots, redirects and failures.
/// One explicitly bounded Wikidata 429 retry is charged to this same cap.
actor StoryMaterialTransport {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Archive: Sendable {
        struct Response: Sendable { let data: Data; let response: HTTPURLResponse }
        let requests: [SourcePageAudit.Request]
        let responses: [String: Response]
    }
    private let loader: Loader
    private let startedAt = Date()
    private let limit: Int
    private var requests: [SourcePageAudit.Request] = []
    private var skipped: [SourcePageAudit.Skipped] = []
    private var attempted = Set<String>()
    private var robots: [String: StoryRobotsRules?] = [:]
    private let archive: Archive?
    private let responseCache: SourceResponseCache?
    private var cacheHits: [String] = []
    init(limit: Int = 12, archive: Archive? = nil, responseCache: SourceResponseCache? = nil, loader: @escaping Loader = { request in
        let (data, response) = try await SourceHTTP.noRedirectSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }) {
        self.limit = min(12, max(0, limit)); self.loader = loader; self.archive = archive; self.responseCache = responseCache
        self.requests = Array((archive?.requests ?? []).prefix(self.limit))
        self.attempted = Set(self.requests.map(\.url))
    }
    var remaining: Int { max(0, limit - requests.count) }
    func audit() -> ([SourcePageAudit.Request], [SourcePageAudit.Skipped]) { (requests, skipped) }
    func cachedURLs() -> [String] { StorySourceDocument.unique(cacheHits) }
    func skip(_ url: String, _ reason: String) { skipped.append(.init(url: url, reason: reason)) }

    func api(_ url: URL, purpose: String) async -> Data? {
        guard let result = await raw(url, purpose: purpose), result.1.statusCode == 200 else { return nil }
        return result.0
    }
    func page(_ url: URL, purpose: String, redirects: Int = 0, allowedHosts: Set<String>? = nil, acceptingJSON: Bool = false,
              finishingArticle: Bool = false) async -> (Data, URL)? {
        guard redirects <= 5, Self.publicURL(url) else { skip(url.absoluteString, "不是公开 HTTPS 网页或跳转次数超限"); return nil }
        if let allowedHosts, !allowedHosts.contains(url.host?.lowercased() ?? "") {
            skip(url.absoluteString, "跳转主机不在参考来源白名单"); return nil
        }
        guard await permitted(url, finishingArticle: finishingArticle) else { return nil }
        guard let (data, response) = await raw(url, purpose: purpose, finishingArticle: finishingArticle) else { return nil }
        if (300...399).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
            return await page(next, purpose: purpose, redirects: redirects + 1, allowedHosts: allowedHosts,
                              acceptingJSON: acceptingJSON, finishingArticle: finishingArticle)
        }
        guard response.statusCode == 200 else { return nil }
        let mime = response.mimeType ?? ""
        guard mime.contains("html") || mime == "text/plain" || (acceptingJSON && mime.contains("json")) else { skip(url.absoluteString, "非网页正文：" + mime); return nil }
        return (data, url)
    }
    private func raw(_ url: URL, purpose: String, wikidataRetry: Bool = false, finishingArticle: Bool = false) async -> (Data, HTTPURLResponse)? {
        guard !Task.isCancelled else { skip(url.absoluteString, "任务已取消"); return nil }
        // Stop new discovery after 35 seconds, but reserve bounded time to
        // actually read an article already found, including its redirect.
        // Otherwise a slow index repeatedly consumes the entire search budget.
        let remainingSeconds = (finishingArticle ? 75.0 : 35.0) - Date().timeIntervalSince(startedAt)
        guard remainingSeconds > 0 else { skip(url.absoluteString, "本轮资料时间预算已用完"); return nil }
        guard Self.publicURL(url) else { skip(url.absoluteString, "不是公开 HTTPS 地址"); return nil }
        if let hit = await responseCache?.value(url) { cacheHits.append(url.absoluteString); return (hit.data, hit.response) }
        // A research continuation can reparse recorded responses while retaining
        // every previous HTTP attempt in the budget. Failed URLs are not retried.
        if let cached = archive?.responses[url.absoluteString] { return (cached.data, cached.response) }
        guard requests.count < limit else { skip(url.absoluteString, "每实体 \(limit) 次请求上限"); return nil }
        guard wikidataRetry || attempted.insert(url.absoluteString).inserted else { skip(url.absoluteString, "本轮已尝试，不重试"); return nil }
        let index = requests.count
        requests.append(.init(url: url.absoluteString, purpose: purpose))
        do {
            try await SourceHTTP.wikidataPacer.wait(for: url)
            var request = SourceHTTP.request(url)
            request.timeoutInterval = min(request.timeoutInterval, remainingSeconds)
            let (data, response) = try await loader(request)
            requests[index].status = response.statusCode
            guard response.url == url else { skip(url.absoluteString, "传输层隐式跳转，拒绝绕过预算和 robots"); return nil }
            guard data.count <= 4_000_000 else { skip(url.absoluteString, "响应超过 4MB"); return nil }
            if !wikidataRetry, WikidataRequestPacer.isWikimedia(url), [429, 503].contains(response.statusCode),
               let seconds = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After") ?? "5"), remaining > 0 {
                try await Task.sleep(for: .seconds(seconds))
                return await raw(url, purpose: purpose + " · Wikimedia 限流重试", wikidataRetry: true, finishingArticle: finishingArticle)
            }
            await responseCache?.remember(data, response: response)
            if !(200...399).contains(response.statusCode) { skip(url.absoluteString, "HTTP \(response.statusCode)") }
            return (data, response)
        } catch {
            requests[index].error = String(describing: error)
            skip(url.absoluteString, "请求失败，不重试：\(error)")
            return nil
        }
    }
    static func retryDelay(_ header: String, now: Date = Date()) -> Double? {
        let seconds: Double?
        if let value = Double(header) { seconds = value }
        else {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            seconds = formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 30 else { return nil }
        return seconds
    }
    private func permitted(_ url: URL, finishingArticle: Bool = false) async -> Bool {
        guard let host = url.host else { return false }
        let origin = "https://" + host + (url.port.map { ":\($0)" } ?? "")
        if !robots.keys.contains(origin) {
            guard let endpoint = URL(string: origin + "/robots.txt"),
                  let (data, response) = await raw(endpoint, purpose: "robots.txt", finishingArticle: finishingArticle) else {
                robots[origin] = .some(nil); skip(url.absoluteString, "robots 无法读取，保守跳过"); return false
            }
            if response.statusCode == 404 || response.statusCode == 410 { robots[origin] = StoryRobotsRules("") }
            else if response.statusCode == 200, let text = String(data: data, encoding: .utf8) { robots[origin] = StoryRobotsRules(text) }
            else { robots[origin] = .some(nil) }
        }
        guard let cached = robots[origin], let rules = cached, rules.allows(url) else {
            skip(url.absoluteString, "robots 拒绝或不可验证"); return false
        }
        return true
    }
    static func publicURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", !host.contains(":"), !(url.port.map { $0 != 443 } ?? false) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 { return false } // Extracted sources must use public DNS names.
        return true
    }
}
