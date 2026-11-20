import Foundation
import MusicKit

enum CatalogSearchKind: String, CaseIterable, Identifiable, Sendable {
    case song, album, musicArtist, movie, ebook
    /// Every non-music work kind in one knowledge search (films, series, games, books, manga);
    /// the unified search groups them afterwards (0.5.9). Not offered as a segment.
    case works
    static var allCases: [CatalogSearchKind] { [.song, .album, .musicArtist, .movie, .ebook] }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .song: "歌曲"
        case .album: "专辑"
        case .musicArtist: "音乐人"
        case .movie: "影视"
        case .ebook: "书籍"
        case .works: "作品"
        }
    }

    var usesKnowledgeSearch: Bool { self == .movie || self == .ebook || self == .works }

    func includes(workKind: String) -> Bool {
        switch self {
        case .song: ["歌曲", "音乐作品"].contains(workKind)
        case .album: workKind == "专辑"
        case .musicArtist: workKind == "创作者"
        case .movie: ["电影", "电视剧"].contains(workKind)
        case .ebook: ["书籍", "文学作品", "漫画"].contains(workKind)
        case .works: ["电影", "电视剧", "游戏", "书籍", "文学作品", "漫画"].contains(workKind)
        }
    }
}

enum CatalogError: Error, LocalizedError {
    case invalidData, invalidLink, notFound, throttled, server, offline
    var errorDescription: String? {
        switch self {
        case .invalidData: "这次返回的资料不完整，请稍后再试。"
        case .invalidLink: "认不出这个链接里的歌。请粘贴 Apple Music、QQ 音乐或网易云的歌曲分享链接。"
        case .notFound: "这个地区暂时没有找到该作品。"
        case .throttled: "查询有些频繁，稍等片刻再试。"
        case .server: "暂时连不上作品目录，请稍后再试。"
        case .offline: "暂时无法联网，已保存的作品仍可浏览。"
        }
    }
    static func message(_ error: Error) -> String {
        if let value = error as? CatalogError { return value.localizedDescription }
        if let value = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(value.code) { return CatalogError.offline.localizedDescription }
        return CatalogError.server.localizedDescription
    }
}

struct CatalogLink: Equatable, Sendable {
    let id: String
    let country: String?
    var kind: AppleMusicResourceKind = .songs
    static func parse(_ text: String) throws -> Self {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host?.lowercased(),
              ["music.apple.com", "itunes.apple.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw CatalogError.invalidLink }
        let components = parts.path.split(separator: "/").map(String.init)
        guard components.contains("song") || components.contains("album") else { throw CatalogError.invalidLink }
        let song = parts.queryItems?.first(where: { $0.name == "i" })?.value
        let last = components.last.map { $0.hasPrefix("id") ? String($0.dropFirst(2)) : $0 }
        guard let id = song ?? last, let number = Int64(id), number > 0,
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CatalogError.invalidLink }
        let country = components.first.flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0.lowercased() : nil }
        return Self(id: id, country: country, kind: song != nil || components.contains("song") ? .songs : .albums)
    }
    static func musicID(from raw: String?) -> String? {
        raw.flatMap { try? parse($0).id }
    }
}

struct CatalogResponse: Sendable {
    let results: [WorkID]
    let snapshot: CatalogSnapshot
}

protocol CatalogFetching: Sendable {
    func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext?) async throws -> CatalogResponse
    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind?) async throws -> CatalogResponse
}

/// Uses MusicKit's automatic token handling; credentials never enter this layer.
/// Injected URLSession is an offline-test transport, not a production fallback.
actor AppleCatalogService: CatalogFetching {
    typealias Loader = @Sendable (URLRequest) async throws -> Data
    private let load: Loader
    private let countryCode: (@Sendable () async throws -> String)?
    private var cache: [URL: (expires: Date, payload: AppleMusicPayload)] = [:]
    private var requests: [Date] = []
    private let alignment: CatalogIdentityService

    init(loader: @escaping Loader = AppleCatalogService.musicKitData,
         storefront: (@Sendable () async throws -> String)? = { try await MusicDataRequest.currentCountryCode },
         alignment: CatalogIdentityService = CatalogIdentityService()) {
        load = loader; countryCode = storefront; self.alignment = alignment
    }
    init(session: URLSession) {
        load = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CatalogError.server }
            switch http.statusCode { case 200..<300: return data; case 404: throw CatalogError.notFound
            case 429: throw CatalogError.throttled; default: throw CatalogError.server }
        }
        countryCode = nil; alignment = CatalogIdentityService()
    }
    nonisolated static func musicKitData(_ request: URLRequest) async throws -> Data {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"),
           ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-network=") }) {
            let (data, _) = try await PianwaiRuntime.session.data(for: request)
            return data
        }
        #endif
        do { return try await MusicDataRequest(urlRequest: request).response().data }
        catch let error as MusicDataRequest.Error {
            switch error.status { case 404: throw CatalogError.notFound; case 429: throw CatalogError.throttled; default: throw CatalogError.server }
        }
    }
    private func storefront(_ requested: String) async throws -> String {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"),
           ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-network=") }) { return requested.lowercased() }
        #endif
        let value = try await countryCode?() ?? requested
        let normalized = value.lowercased()
        guard normalized.count == 2, normalized.utf8.allSatisfy({ (97...122).contains($0) }) else { throw CatalogError.invalidLink }
        return normalized
    }
    private func request(_ path: String, country: String, params: [String: String] = [:], budget: CatalogRequestBudget? = nil) async throws -> AppleMusicPayload {
        try Task.checkCancellation()
        var parts = URLComponents(); parts.scheme = "https"; parts.host = "api.music.apple.com"
        parts.path = "/v1/catalog/" + country + "/" + path
        parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw CatalogError.invalidLink }
        if let hit = cache[url], hit.expires > Date() { return hit.payload }
        requests.removeAll { Date().timeIntervalSince($0) > 60 }
        guard requests.count < 18 else { throw CatalogError.throttled }
        try await budget?.charge(); requests.append(Date())
        var request = URLRequest(url: url); request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await load(request)
        try Task.checkCancellation()
        guard data.count < 5_000_000 else { throw CatalogError.invalidData }
        let payload: AppleMusicPayload
        do { payload = try JSONDecoder().decode(AppleMusicPayload.self, from: data); _ = try payload.resources() }
        catch { throw CatalogError.invalidData }
        if cache.count >= 100 { cache.removeAll() }
        cache[url] = (Date().addingTimeInterval(600), payload)
        return payload
    }
    func search(_ term: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext? = nil) async throws -> CatalogResponse {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !kind.usesKnowledgeSearch else { return .init(results: [], snapshot: .init(works: [], relations: [])) }
        let region = try await storefront(country)
        let type: AppleMusicResourceKind = kind == .song ? .songs : kind == .album ? .albums : .artists
        let payload = try await request("search", country: region, params: ["term": String(query.prefix(200)), "types": type.rawValue, "limit": "25", "include[\(type.rawValue)]": type == .songs ? "artists,albums,composers" : type == .albums ? "artists,tracks" : "albums"])
        let response = try payload.resources(type: type.rawValue).catalogResponse(storefront: region)
        guard let recordingContext, recordingContext.applies(to: query, kind: kind) else { return response }
        return recordingContext.ranked(response)
    }
    func lookup(_ id: String, country: String, entity: String?, kind: AppleMusicResourceKind? = nil) async throws -> CatalogResponse {
        let region = try await storefront(country)
        let resourceKind = kind ?? (entity == "album" ? .artists : entity == "song" ? .albums : .songs)
        let resources = try await lookupResources(id, kind: resourceKind, country: region)
        return resources.catalogResponse(storefront: region)
    }
    func resource(_ id: String, kind: AppleMusicResourceKind, country: String) async throws -> [AppleMusicResource] {
        try await lookupResources(id, kind: kind, country: storefront(country))
    }
    private func lookupResources(_ id: String, kind: AppleMusicResourceKind, country: String, budget: CatalogRequestBudget? = nil) async throws -> [AppleMusicResource] {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CatalogError.invalidLink }
        let params: [String: String]
        switch kind {
        case .songs: params = ["include": "artists,composers,albums,music-videos"]
        case .albums: params = ["include": "artists,tracks", "views": "other-versions,related-albums,appears-on"]
        case .artists: params = ["include": "albums", "views": "similar-artists,latest-release,top-songs,appears-on-albums", "extend": "editorialNotes"]
        case .musicVideos: params = ["include": "artists,albums"]
        }
        do {
            let data = try await request(kind.rawValue + "/" + id, country: country, params: params, budget: budget).resources()
            if !data.isEmpty { return data }
        } catch CatalogError.notFound { }
        guard kind != .artists else { throw CatalogError.notFound }
        // Apple's equivalency endpoint carries the cross-storefront identity.
        // Never search by title to silently substitute a different recording.
        let equivalents = try await request(kind.rawValue, country: country, params: params.merging(["filter[equivalents]": id]) { _, new in new }, budget: budget).resources()
        guard !equivalents.isEmpty else { throw CatalogError.notFound }; return equivalents
    }

    /// Prepared for #12; this method does not mutate CatalogStore or the seed.
    /// ISRC can map to several releases; every catalog ID remains a separate result.
    func discover(_ reference: AppleMusicSongReference, country: String) async throws -> [AppleMusicDiscovery] {
        let region = try await storefront(country), budget = CatalogRequestBudget(limit: 12)
        let songs: [AppleMusicResource]
        switch reference {
        case .catalogID(let id): songs = try await lookupResources(id, kind: .songs, country: region, budget: budget)
        case .isrc(let value):
            guard let isrc = CatalogIdentityService.validISRC(value) else { throw CatalogError.invalidLink }
            let matches = try await request("songs", country: region, params: ["filter[isrc]": isrc, "include": "artists,composers,albums,music-videos"], budget: budget).resources()
            songs = matches.filter { $0.attributes?.isrc.flatMap(CatalogIdentityService.validISRC) == isrc }
        }
        var output: [AppleMusicDiscovery] = []
        for song in songs.prefix(3) where song.type == "songs" {
            let artists = song.related("artists").filter { $0.type == "artists" }
            var result = AppleMusicDiscovery(storefront: region, song: song, identity: .init(catalogID: song.id, isrc: song.attributes?.isrc.flatMap(CatalogIdentityService.validISRC), artistIDs: artists.map(\.id)))
            if songs.count > 3 { result.incomplete.append("song matches limited to 3") }
            var items = [song]
            for album in song.related("albums").prefix(2) {
                do { items += try await lookupResources(album.id, kind: .albums, country: region, budget: budget) }
                catch is CancellationError { throw CancellationError() }
                catch { result.incomplete.append("albums[\(album.id)]: request failed or budget exhausted") }
            }
            for artist in artists.prefix(2) {
                do { items += try await lookupResources(artist.id, kind: .artists, country: region, budget: budget) }
                catch is CancellationError { throw CancellationError() }
                catch { result.incomplete.append("artists[\(artist.id)]: request failed or budget exhausted") }
            }
            if song.related("albums").count > 2 || artists.count > 2 { result.incomplete.append("album/artist expansion limited to 2 each") }
            for item in items {
                result.materials += item.storyMaterials(storefront: region)
                for (container, fields) in [("relationships", item.relationships ?? [:]), ("views", item.views ?? [:])] {
                    for (field, related) in fields.sorted(by: { $0.key < $1.key }) {
                        result.relations += related.data.map { .init(fromID: item.id, fromType: item.type, target: $0,
                            sourceField: "\(item.type)[\(item.id)].\(container).\(field)", sourceURL: item.sourceURL(storefront: region)) }
                        if related.next != nil { result.incomplete.append("\(item.type)[\(item.id)].\(field): more pages available") }
                    }
                }
            }
            if let isrc = result.identity.isrc {
                do { result.identity.wikidata = try await alignment.wikidata(property: "P1243", value: isrc, budget: budget) }
                catch is CancellationError { throw CancellationError() }
                catch { result.incomplete.append("Wikidata P1243 unavailable") }
                do { result.identity.musicBrainz = try await alignment.musicBrainz(isrc: isrc, budget: budget) }
                catch is CancellationError { throw CancellationError() }
                catch { result.incomplete.append("MusicBrainz ISRC/credits unavailable") }
            }
            for artist in artists.prefix(2) {
                do { result.identity.artistsWikidata[artist.id] = try await alignment.wikidata(property: "P2850", value: artist.id, budget: budget) }
                catch is CancellationError { throw CancellationError() }
                catch { result.incomplete.append("Wikidata P2850[\(artist.id)] unavailable") }
            }
            try Task.checkCancellation(); output.append(result)
        }
        return output
    }
}
