import Foundation

/// These are observations of a request, never verdicts about a source or claim.
enum SourceAvailabilityOutcome: String, Codable, Equatable, Sendable {
    case responded
    case browserRequired
    case temporarilyUnavailable
    case notFoundThisTime
    case unsupportedURL

    var message: String? {
        switch self {
        case .responded: nil
        case .browserRequired: "请在浏览器查看"
        case .temporarilyUnavailable: "暂时打不开"
        case .notFoundThisTime: "这次未找到原页面"
        case .unsupportedURL: "链接暂时打不开"
        }
    }
}

struct SourceAvailabilityObservation: Codable, Equatable, Sendable {
    /// Preserve the evidence URL, including a pinned revision and fragment.
    let sourceURL: String
    let checkedAt: Date
    let outcome: SourceAvailabilityOutcome
    let httpStatus: Int?
    let responseURL: URL?
}

/// Used only when a reader opens one particular source. The small in-memory
/// cache contains access observations, never source prose or replacement URLs.
actor SourceAvailabilityService {
    static let shared = SourceAvailabilityService()
    static let requestTimeout: TimeInterval = 6
    typealias ResponseLoader = @Sendable (URLRequest) async throws -> URLResponse

    private let ttl: TimeInterval
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let loadResponse: ResponseLoader
    private var cache: [String: SourceAvailabilityObservation] = [:]

    init(ttl: TimeInterval = 300, capacity: Int = 128,
         now: @escaping @Sendable () -> Date = { Date() },
         loadResponse: @escaping ResponseLoader = SourceAvailabilityService.loadHTTPResponse) {
        self.ttl = max(0, ttl)
        self.capacity = max(1, capacity)
        self.now = now
        self.loadResponse = loadResponse
    }

    func observe(_ source: Source, forceRefresh: Bool = false) async throws -> SourceAvailabilityObservation {
        try Task.checkCancellation()
        let startedAt = now()
        if !forceRefresh, let cached = cache[source.url] {
            let age = startedAt.timeIntervalSince(cached.checkedAt)
            if age >= 0, age < ttl { return cached }
        }

        guard let url = Self.openableURL(source.url) else {
            return SourceAvailabilityObservation(sourceURL: source.url, checkedAt: now(),
                                                 outcome: .unsupportedURL, httpStatus: nil, responseURL: nil)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        // A HEAD rejection says little about whether the actual page opens.
        // The live transport stops at response headers without reading its body.
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false

        let observation: SourceAvailabilityObservation
        do {
            let response = try await loadResponse(request)
            try Task.checkCancellation()
            observation = SourceAvailabilityObservation(
                sourceURL: source.url, checkedAt: now(),
                outcome: Self.classify(response, requestedURL: url),
                httpStatus: (response as? HTTPURLResponse)?.statusCode, responseURL: response.url
            )
        } catch {
            // Leaving the source surface is not an unsuccessful access attempt.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            observation = SourceAvailabilityObservation(sourceURL: source.url, checkedAt: now(),
                                                         outcome: .temporarilyUnavailable,
                                                         httpStatus: nil, responseURL: nil)
        }
        try Task.checkCancellation()
        cache[source.url] = observation
        if cache.count > capacity, let oldest = cache.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        return observation
    }

    nonisolated static func openableURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    nonisolated private static func classify(_ response: URLResponse, requestedURL: URL) -> SourceAvailabilityOutcome {
        guard let http = response as? HTTPURLResponse else { return .temporarilyUnavailable }
        // A homepage, sign-in page, or another revision must not count as the
        // original page being available. Legitimate redirects remain openable.
        if let finalURL = http.url, resourceURL(finalURL) != resourceURL(requestedURL) {
            return .browserRequired
        }
        switch http.statusCode {
        case 200..<300: return .responded
        case 404, 410: return .notFoundThisTime
        case 300..<500: return .browserRequired
        default: return .temporarilyUnavailable
        }
    }

    nonisolated private static func resourceURL(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Fragments are not sent in HTTP requests; keep every query parameter.
        components?.fragment = nil
        return components?.url
    }

    nonisolated private static func loadHTTPResponse(_ request: URLRequest) async throws -> URLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // bytes(for:) returns with the headers. No full article, video, or file
        // download is needed; cancellation also stops any unconsumed body.
        let (_, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        return response
    }
}
