import Foundation

/// Public metadata only. This route never consults MusicKit, account region or tokens.
actor ITunesCatalogService: CatalogFetching {
    private let transport: ITunesCatalogTransport

    init(transport: ITunesCatalogTransport = .shared) { self.transport = transport }

    func search(_ term: String, country: String, kind: CatalogSearchKind,
                recordingContext: RecordingSearchContext? = nil) async throws -> CatalogResponse {
        try await search(term, country: country, kind: kind, recordingContext: recordingContext, includeArtists: true)
    }
    func searchCandidates(_ term: String, country: String, kind: CatalogSearchKind,
                          recordingContext: RecordingSearchContext? = nil) async throws -> CatalogResponse {
        try await search(term, country: country, kind: kind, recordingContext: recordingContext, includeArtists: false)
    }
    private func search(_ term: String, country: String, kind: CatalogSearchKind,
                        recordingContext: RecordingSearchContext?, includeArtists: Bool) async throws -> CatalogResponse {
        try Task.checkCancellation()
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !kind.usesKnowledgeSearch else {
            return .init(results: [], snapshot: .init(works: [], relations: []))
        }
        let region = try Self.region(country)
        let payload = try await request("search", region: region,
                                        params: ["term": String(query.prefix(200)), "entity": kind.rawValue, "limit": "25"])
        let response: CatalogResponse
        if includeArtists { response = try await materialize(payload, region: region) }
        else { response = try payload.materialize(country: region) }
        let filtered = CatalogResponse(results: response.results.filter { id in
            response.snapshot.works.contains { $0.id == id && kind.includes(workKind: $0.kind) }
        }, snapshot: response.snapshot)
        guard let recordingContext, recordingContext.applies(to: query, kind: kind) else { return filtered }
        return recordingContext.ranked(filtered)
    }

    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind? = nil) async throws -> CatalogResponse {
        try Task.checkCancellation()
        guard let number = Int64(id), number > 0, id.utf8.allSatisfy({ (48...57).contains($0) }),
              entity == nil || ["album", "song"].contains(entity!) else { throw CatalogError.invalidLink }
        let region = try Self.region(country)
        var params = ["id": id, "limit": "40"]
        if let entity { params["entity"] = entity }
        let payload = try await request("lookup", region: region, params: params)
        let response = try await materialize(payload, region: region)
        let expected = kind ?? (entity == "album" ? .artists : entity == "song" ? .albums : .songs)
        let type = expected == .artists ? "artist" : expected == .albums ? "album" : expected == .musicVideos ? "music-video" : "song"
        let target = WorkID(rawValue: "apple:\(type):\(id)")!
        guard response.results.contains(target) else { throw CatalogError.notFound }
        return CatalogResponse(results: [target] + response.results.filter { $0 != target }, snapshot: response.snapshot)
    }

    private func materialize(_ payload: ITunesCatalogPayload, region: String) async throws -> CatalogResponse {
        // A track's display credit may contain several performers, while artistId
        // denotes just one artist. Only dedicated artist rows may name that identity.
        let present = Set(payload.results.filter { $0.wrapperType == "artist" }.compactMap(\.artistId))
        let missing = Set(payload.results.compactMap(\.artistId)).subtracting(present).filter { $0 > 0 }.sorted()
        var artists: [ITunesCatalogPayload.Item] = []
        if !missing.isEmpty {
            do {
                let extra = try await request("lookup", region: region,
                                              params: ["id": missing.prefix(100).map(String.init).joined(separator: ",")])
                artists = extra.results.filter { $0.wrapperType == "artist" && missing.contains($0.artistId ?? 0) }
            } catch {
                try Task.checkCancellation()
                // Valid search results and saving remain usable without extra credits.
            }
        }
        try Task.checkCancellation()
        return try payload.materialize(country: region, artists: artists)
    }

    private func request(_ path: String, region: String, params: [String: String]) async throws -> ITunesCatalogPayload {
        var components = URLComponents()
        components.scheme = "https"; components.host = "itunes.apple.com"; components.path = "/" + path
        var params = params; params["country"] = region
        components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw CatalogError.invalidLink }
        return try await transport.request(url)
    }

    private static func region(_ raw: String) throws -> String {
        let value = raw.lowercased()
        guard value.utf8.count == 2, value.utf8.allSatisfy({ (97...122).contains($0) }) else { throw CatalogError.invalidLink }
        return value
    }
}

/// All default public adapters share both this transport and its rolling budget.
/// Cache contains decoded metadata in memory; raw bytes / previews never enter disk cache.
actor ITunesCatalogTransport {
    static let shared = ITunesCatalogTransport()
    typealias Loader = @Sendable (URLRequest) async throws -> Data
    private let load: Loader
    private let limiter: ITunesRequestLimiter
    private var cache: [URL: (expires: Date, payload: ITunesCatalogPayload)] = [:]
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ITunesCatalogPayload, Error>]
    }
    private var flights: [URL: Flight] = [:]

    init(loader: @escaping Loader = ITunesCatalogTransport.loadPublicData,
         limiter: ITunesRequestLimiter = .shared) {
        load = loader; self.limiter = limiter
    }

    func request(_ url: URL) async throws -> ITunesCatalogPayload {
        try Task.checkCancellation()
        if let entry = cache[url], entry.expires > Date() { return entry.payload }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let payload: ITunesCatalogPayload = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flights[url] != nil {
                    flights[url]?.waiters[waiter] = continuation
                    return
                }
                let flightID = UUID()
                let task = Task {
                    do {
                        try Task.checkCancellation()
                        let queued=Date()
                        try await limiter.charge()
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        let started=Date()
                        let data:Data
                        do { data=try await load(request); await P17Metrics.shared.request(host:url.host!,queued:queued,started:started,status:"ok") }
                        catch { await P17Metrics.shared.request(host:url.host!,queued:queued,started:started,status:"failed"); throw error }
                        try Task.checkCancellation()
                        guard data.count <= 5_000_000 else { throw CatalogError.invalidData }
                        let payload: ITunesCatalogPayload
                        do {
                            payload = try JSONDecoder().decode(ITunesCatalogPayload.self, from: data)
                            let country = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "country" }?.value
                            try payload.validate(country: country)
                        }
                        catch { throw CatalogError.invalidData }
                        finish(url, flightID: flightID, result: .success(payload))
                    } catch { finish(url, flightID: flightID, result: .failure(error)) }
                }
                flights[url] = Flight(id: flightID, task: task, waiters: [waiter: continuation])
            }
            try Task.checkCancellation()
            return payload
        } onCancel: {
            Task { await self.cancel(url, waiter: waiter) }
        }
    }

    private func cancel(_ url: URL, waiter: UUID) {
        guard let continuation = flights[url]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flights[url]?.waiters.isEmpty == true { flights.removeValue(forKey: url)?.task.cancel() }
    }

    private func finish(_ url: URL, flightID: UUID, result: Result<ITunesCatalogPayload, Error>) {
        guard let flight = flights[url], flight.id == flightID else { return }
        flights[url] = nil
        if case .success(let payload) = result, !flight.waiters.isEmpty {
            if cache.count >= 100 { cache.removeAll() }
            cache[url] = (Date().addingTimeInterval(600), payload)
        }
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }

    nonisolated static func loadPublicData(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.host == "itunes.apple.com" else { throw CatalogError.invalidLink }
        return try await PublicDatabaseHTTP.shared.get(url)
    }
}

actor ITunesRequestLimiter {
    static let shared = ITunesRequestLimiter()
    private var requests: [Date] = []
    func charge() throws {
        let now = Date()
        requests.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requests.count < 18 else { throw CatalogError.throttled }
        requests.append(now)
    }
}
