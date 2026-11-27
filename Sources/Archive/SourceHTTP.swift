import Foundation

/// Shared request construction for existing work context, exact article resolution,
/// and story sources. API requests are read-only; failures are never retried here.
enum SourceHTTP {
    static let responseCache = SourceResponseCache()
    static let wikidataPacer = WikidataRequestPacer()
    /// Wikimedia's 2026 rate limits count a client as identified only when its User-Agent carries a
    /// web address (checked 11-18: an e-mail alone is treated like no identity: 10 requests a minute
    /// per IP across Wikipedia and Wikidata; with an address, 200). Set this to the app's public page
    /// (its repository or App Store page) once there is one.
    /// 2026-11-18: fanwai.xyz is up. Measured the same evening from this Mac: 45 Wikidata requests in 34 s
    /// with this header, all answered (the unidentified header was cut off after 10 a minute).
    static let homepage: String? = "https://fanwai.xyz"
    /// 2026-11-20 (anson, spam after the repository went public): no personal e-mail here; the web
    /// address is the contact Wikimedia and MusicBrainz ask for.
    static let userAgent = homepage.map { "Pianwai/0.5 (\($0))" } ?? "Pianwai/0.5"
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }
    static func endpoint(host: String, parameters: [String: String], version: String = "1") throws -> URL {
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = "/w/api.php"
        let values = ["format": "json", "formatversion": version].merging(parameters) { _, new in new }
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = url.url else { throw URLError(.badURL) }; return url
    }
    /// Public page redirects are followed explicitly so every HTTP attempt is
    /// charged to the entity budget and the destination's robots rules are read.
    static let noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil
        PianwaiRuntime.configureReviewTransport(config)
        return URLSession(configuration: config, delegate: NoSourceRedirects(), delegateQueue: nil)
    }()
}

/// Shared across discovery, context and story collection, rather than one
/// independent timer per entity. Recheck after every suspension: a delayed
/// wake-up must not shorten the interval before the next request is released.
actor WikidataRequestPacer {
    private var lastRelease: ContinuousClock.Instant?
    nonisolated static func isWikimedia(_ url:URL) -> Bool {
        guard let host=url.host?.lowercased() else { return false }
        return ["wikidata.org","wikipedia.org","wikimedia.org"].contains { host == $0 || host.hasSuffix("."+$0) }
    }
    func wait(for url: URL) async throws {
        guard Self.isWikimedia(url) else { return }
        while let lastRelease {
            let earliest = lastRelease.advanced(by: .seconds(1))
            guard ContinuousClock.now < earliest else { break }
            try await ContinuousClock().sleep(until: earliest, tolerance: .zero)
        }
        try Task.checkCancellation()
        lastRelease = .now
    }
}

/// One public Wikimedia response cache shared by context, identity resolution,
/// and story material collection. A failed refresh never erases a usable hit.
actor SourceResponseCache {
    struct Entry: Sendable { let data: Data; let response: HTTPURLResponse; let expires: Date }
    private var entries: [URL: Entry] = [:]
    func value(_ url: URL) -> Entry? {
        guard let entry = entries[url], entry.expires > Date() else { entries[url] = nil; return nil }
        return entry
    }
    func remember(_ data: Data, response: HTTPURLResponse) {
        guard response.statusCode == 200, data.count < 4_000_000, let url = response.url,
              url.host == "www.wikidata.org" || url.host?.hasSuffix(".wikipedia.org") == true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { return }
        if entries.count >= 128 { entries.removeAll() }
        entries[url] = .init(data: data, response: response, expires: Date().addingTimeInterval(3_600))
    }
}
private final class NoSourceRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Exact syntax/redirect checks shared with WikipediaWorkResolver. A similar
/// label is never proof that two work/article identities are the same.
enum WikiSourceIdentity {
    static func validQID(_ value: String) -> Bool {
        value.hasPrefix("Q") && value.count > 1 && value.count < 24 && value.dropFirst().first != "0"
            && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
    static func title(_ raw: String) -> String? {
        guard raw.utf8.count <= 1_024,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw.rangeOfCharacter(from: CharacterSet(charactersIn: "|#[]{}<>")) == nil,
              !raw.contains("://") else { return nil }
        let title = raw.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return !title.isEmpty && title.utf8.count <= 255 ? title : nil
    }
    static func reaches(_ resolved: String, from requested: String, rewrites: [(String, String)]) -> Bool {
        if requested == resolved { return true }
        guard rewrites.count <= 16 else { return false }
        var links: [String: Set<String>] = [:]
        for (rawFrom, rawTo) in rewrites {
            guard let from = title(rawFrom), let to = title(rawTo) else { return false }
            if from != to { links[from, default: []].insert(to) }
        }
        var current = requested, visited = Set<String>()
        for _ in 0..<16 {
            guard visited.insert(current).inserted, let next = links[current], next.count == 1,
                  let target = next.first else { return false }
            if target == resolved { return true }; current = target
        }
        return false
    }
}
