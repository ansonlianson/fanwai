import Foundation

/// Production uses the normal app directories and URLSession. A simulator
/// journey may opt into an isolated data directory and transport failure or a
/// clearly marked invalid-response fixture. It never changes the Mac's
/// connection, user preferences, or any upstream source payload.
enum PianwaiRuntime {
    static func reduceMotion(_ systemValue: Bool) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-isolate-data"), args.contains("--ui-reduce-motion") { return true }
        #endif
        return systemValue
    }
    static let publicCatalogSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 25
        #if DEBUG && targetEnvironment(simulator)
        if isolatedRoot != nil, SimulatorNetworkFailure.mode != nil {
            configuration.protocolClasses = [SimulatorNetworkFailure.self]
        }
        #endif
        return URLSession(configuration: configuration)
    }()
    static func cacheDirectory(_ name: String) -> URL? {
        directory(name, base: .cachesDirectory)
    }

    static func applicationDirectory(_ name: String) -> URL? {
        directory(name, base: .applicationSupportDirectory)
    }

    /// The no-redirect source reader must honor the same offline review mode
    /// as catalogue requests. Keep real responses out of isolated UI fixtures.
    static func configureReviewTransport(_ configuration: URLSessionConfiguration) {
        #if DEBUG && targetEnvironment(simulator)
        if isolatedRoot != nil, SimulatorNetworkFailure.mode != nil {
            configuration.protocolClasses = [SimulatorNetworkFailure.self]
        }
        #endif
    }

    private static func directory(_ name: String, base: FileManager.SearchPathDirectory) -> URL? {
        #if DEBUG && targetEnvironment(simulator)
        if let isolatedRoot { return isolatedRoot.appendingPathComponent(name, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: base, in: .userDomainMask).first?
            .appendingPathComponent(name, isDirectory: true)
    }

    static let session: URLSession = {
        #if DEBUG && targetEnvironment(simulator)
        guard isolatedRoot != nil, SimulatorNetworkFailure.mode != nil else { return .shared }
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [SimulatorNetworkFailure.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
        #else
        return .shared
        #endif
    }()

    #if DEBUG && targetEnvironment(simulator)
    private static let isolatedRoot: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"),
              let raw = args.first(where: { $0.hasPrefix("--ui-state=") }) else { return nil }
        let name = String(raw.dropFirst(11))
        guard !name.isEmpty, name.count <= 80,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = base.appendingPathComponent("PianwaiUIData", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if args.contains("--ui-reset") { try? FileManager.default.removeItem(at: root) }
        return root
    }()
    #endif
}

#if DEBUG && targetEnvironment(simulator)
private final class SimulatorNetworkFailure: URLProtocol, @unchecked Sendable {
    static let mode: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data") else { return nil }
        let raw = args.first { $0.hasPrefix("--ui-network=") }
        guard let raw else { return nil }
        let mode = String(raw.dropFirst("--ui-network=".count))
        return ["offline", "wikipedia-offline", "search-cancelled", "search-invalid", "public-catalog", "catalog-throttled", "real-relations"].contains(mode) ? mode : nil
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { return false }
        if mode == "public-catalog" || mode == "catalog-throttled" || mode == "real-relations" {
            // Allow the recorded artwork URL to load; all metadata traffic is
            // intercepted and logged, including any accidental MusicKit route.
            return request.url?.host?.hasSuffix(".mzstatic.com") != true
        }
        if mode == "offline" { return true }
        if mode == "search-cancelled" || mode == "search-invalid" {
            guard let url = request.url,
                  url.host?.lowercased() == "www.wikidata.org", url.path == "/w/api.php",
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
            return query.contains { $0.name == "action" && $0.value == "wbsearchentities" }
        }
        return mode == "wikipedia-offline" && (request.url?.host?.hasSuffix(".wikipedia.org") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var delayedResponse: DispatchWorkItem?
    override func startLoading() {
        if Self.mode == "offline", FirstTakeFixture.directory != nil,
           request.url?.host == "ja.wikipedia.org", request.url?.path != "/robots.txt" {
            let work = DispatchWorkItem { [weak self] in self?.deliverResponse() }
            delayedResponse = work
            DispatchQueue.global().asyncAfter(deadline: .now()+4, execute: work)
            return
        }
        if Self.mode == "real-relations", request.url?.path == "/search",
           ProcessInfo.processInfo.arguments.contains("--ui-search-delay") {
            let work = DispatchWorkItem { [weak self] in self?.deliverResponse() }
            delayedResponse = work
            DispatchQueue.global().asyncAfter(deadline: .now()+4, execute: work)
        } else { deliverResponse() }
    }
    private func deliverResponse() {
        if Self.mode == "offline" {
            do {
                if let (data, type) = try FirstTakeFixture.response(request) ?? OriginalRecordingFixture.response(request), let url = request.url,
                   let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type]) {
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
            } catch { client?.urlProtocol(self, didFailWithError: error); return }
        }
        if Self.mode == "real-relations" {
            do {
                guard let url = request.url else { throw URLError(.badURL) }
                let (data, status) = try PublicRelationsFixture.response(url)
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"]) else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
            return
        }
        if Self.mode == "public-catalog" || Self.mode == "catalog-throttled" {
            print("PUBLIC_CATALOG_UI_REQUEST " + (request.url?.absoluteString ?? "invalid"))
            guard let url = request.url, url.host == "itunes.apple.com" else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
            let name: String
            if parameter("country") == "us" { name = "us-song" }
            else if url.path == "/search" { name = parameter("entity") == "musicArtist" ? "artist" : parameter("entity") == "album" ? "album" : "song" }
            else { name = parameter("id") == "939561587" ? "artist" : parameter("entity") == "song" ? "album" : "song" }
            let fixture = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "PublicCatalogUIFixtures")
                ?? Bundle.main.url(forResource: name, withExtension: "json")
            guard let fixture, let data = try? Data(contentsOf: fixture),
                  let response = HTTPURLResponse(url: url, statusCode: Self.mode == "catalog-throttled" ? 429 : 200,
                                                 httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if Self.mode == "search-cancelled" {
            // A raw transport cancellation is not cancellation of the UI task.
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        } else if Self.mode == "search-invalid" {
            // Static SIMULATOR TEST FIXTURE, not a real Wikidata response.
            // A successful HTTP response with nonempty but unusable entities
            // must become a retryable failure, never a genuine empty search.
            let fixture = #"{"success":1,"search":[{"id":"TEST_ONLY_NOT_A_QID","label":"SIMULATOR TEST FIXTURE: invalid ID"},{"id":"Q0","label":"SIMULATOR TEST FIXTURE: invalid QID"},{"label":"SIMULATOR TEST FIXTURE: missing ID"}]}"#
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json; charset=utf-8"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(fixture.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() { delayedResponse?.cancel() }
}
#endif
