import Foundation
import SwiftSoup

struct WorkArtwork: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let fileTitle: String
    let thumbnailURL: String
    let sourcePageURL: String
    let articleURL: String
    let artist: String?
    let credit: String?
    let licenseName: String?
    let licenseURL: String?
    let isNonFree: Bool?
    let width: Int
    let height: Int
    var nonFreeValue: String? = nil
    var rawMetadata: [String: String]? = nil
}

struct WorkArtworkResponse: Codable, Sendable {
    let qid: String
    let artwork: WorkArtwork?
}

protocol WorkArtworkFetching: Sendable {
    func fetch(qid: String) async throws -> WorkArtworkResponse
    /// The Apple Music artist header photo for an exact iTunes artist ID.
    func appleArtistPhoto(artistID: String) async throws -> String?
}
extension WorkArtworkFetching {
    func appleArtistPhoto(artistID: String) async throws -> String? { nil }
}

enum WorkArtworkError: Error, LocalizedError {
    case invalidIdentity, identityMismatch, invalidResponse, httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidIdentity, .identityMismatch: "图片的作品身份尚未确认。"
        case .invalidResponse: "图片来源资料暂未完整载入。"
        case .httpStatus: "暂时无法连接图片资料。"
        }
    }
}

/// Fetches JSON metadata only. A Wikipedia representative image belongs to the
/// verified entity; it is not proof of a particular edition or reuse right.
/// Identity comes from an exact QID/sitelink/P18 chain, never a name search.
actor WorkArtworkService: WorkArtworkFetching {
    private let session: URLSession
    private let metadata: MetadataTransport
    init(session: URLSession = PianwaiRuntime.session) {
        self.session = session
        metadata = session === PianwaiRuntime.session ? .shared : MetadataTransport(directory: nil, loader: { try await session.data(for: $0) })
    }

    func fetch(qid: String) async throws -> WorkArtworkResponse {
        guard WorkContextService.validQID(qid) else { throw WorkArtworkError.invalidIdentity }
        let response: EntityResponse = try await load(host: "www.wikidata.org", params: [
            "action": "wbgetentities", "ids": qid, "props": "sitelinks|claims", "sitefilter": "zhwiki|enwiki|jawiki|frwiki|kowiki|dewiki"
        ], version: "1")
        guard response.success == 1, let entity = response.entities?[qid],
              entity.id == qid, entity.type == "item", entity.missing == nil else { throw WorkArtworkError.identityMismatch }
        var sourceError: Error?
        for language in ["zh", "en", "ja", "fr", "ko", "de"] {
            guard let link = entity.sitelinks?[language + "wiki"] else { continue }
            guard link.site == language + "wiki", let title = Self.validTitle(link.title) else { throw WorkArtworkError.identityMismatch }
            do {
                if let artwork = try await artwork(qid: qid, title: title, language: language) {
                    try Task.checkCancellation()
                    return WorkArtworkResponse(qid: qid, artwork: artwork)
                }
            } catch is CancellationError { throw CancellationError() }
            catch WorkArtworkError.identityMismatch { throw WorkArtworkError.identityMismatch }
            catch { sourceError = error }
        }
        // P18 is a file statement on this exact item, useful for creators with
        // no illustrated article. Do not substitute a search result or a
        // related person's image. Preferred statements outrank normal ones.
        for filename in entity.imageFiles.prefix(3) {
            let source = "https://www.wikidata.org/wiki/" + qid
            do {
                if let artwork = try await fileArtwork(filename: filename, host: "commons.wikimedia.org",
                                                       articleURL: source, idPrefix: "commons", pageThumbnail: nil) {
                    try Task.checkCancellation()
                    return WorkArtworkResponse(qid: qid, artwork: artwork)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { sourceError = error }
        }
        for artistID in entity.appleArtistIDs.prefix(2) {
            do {
                if let artwork = try await appleArtistArtwork(qid: qid, artistID: artistID) {
                    try Task.checkCancellation()
                    return WorkArtworkResponse(qid: qid, artwork: artwork)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { sourceError = error }
        }
        try Task.checkCancellation()
        if let sourceError { throw sourceError }
        return WorkArtworkResponse(qid: qid, artwork: nil)
    }

    private func artwork(qid: String, title: String, language: String) async throws -> WorkArtwork? {
        let host = language + ".wikipedia.org"
        let response: WikiResponse = try await load(host: host, params: [
            "action": "query", "titles": title, "prop": "pageprops|pageimages",
            "ppprop": "wikibase_item|disambiguation", "piprop": "name|thumbnail", "pithumbsize": "320", "pilicense": "any", "redirects": "1"
        ])
        guard let query = response.query, let pages = query.pages, pages.count == 1,
              let page = pages.first, page.ns == 0, let pageID = page.pageid, pageID > 0,
              page.missing != true, page.invalid != true, page.pageprops?.disambiguation == nil,
              page.pageprops?.wikibaseItem == qid, let resolvedTitle = page.title.flatMap(Self.validTitle),
              Self.reaches(resolvedTitle, from: title, through: query) else { throw WorkArtworkError.identityMismatch }
        guard let filename = page.pageimage else {
            guard page.thumbnail == nil else { throw WorkArtworkError.invalidResponse }
            return nil
        }
        var articleURL = URLComponents()
        articleURL.scheme = "https"; articleURL.host = host; articleURL.path = "/wiki/" + resolvedTitle.replacingOccurrences(of: " ", with: "_")
        guard let article = articleURL.url else { throw WorkArtworkError.invalidResponse }
        return try await fileArtwork(filename: filename, host: host, articleURL: article.absoluteString,
                                     idPrefix: language, pageThumbnail: page.thumbnail)
    }

    private func fileArtwork(filename: String, host: String, articleURL: String,
                             idPrefix: String, pageThumbnail: WikiResponse.Thumbnail?) async throws -> WorkArtwork? {
        guard let file = Self.validTitle(filename), !file.contains(":"), !file.hasPrefix("/") else { throw WorkArtworkError.invalidResponse }
        let requestedFile = "File:" + file
        let fileResponse: WikiResponse = try await load(host: host, params: [
            "action": "query", "titles": requestedFile, "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
            "iiurlwidth": "320", "iiextmetadatalanguage": "en", "redirects": "1"
        ])
        guard let fileQuery = fileResponse.query, let files = fileQuery.pages, files.count == 1,
              let filePage = files.first, filePage.ns == 6, filePage.invalid != true,
              filePage.missing != true || filePage.imagerepository == "shared",
              let fileTitle = filePage.title.flatMap(Self.validTitle), Self.reaches(fileTitle, from: requestedFile, through: fileQuery),
              let info = filePage.imageinfo?.first,
              let original = info.url.flatMap(Self.uploadURL), let originalWidth = info.width, let originalHeight = info.height,
              originalWidth > 0, originalHeight > 0,
              let description = info.descriptionurl.flatMap({ Self.descriptionURL($0, host: host, repository: filePage.imagerepository, fileTitle: fileTitle) }) else {
            throw WorkArtworkError.invalidResponse
        }
        if let mime = info.mime, !mime.hasPrefix("image/") { throw WorkArtworkError.invalidResponse }
        if let raw = info.thumburl, Self.uploadURL(raw) == nil { throw WorkArtworkError.invalidResponse }
        let thumbnail: (url: URL, width: Int, height: Int)
        if let candidate = pageThumbnail {
            guard let url = Self.uploadURL(candidate.source), Self.validDimensions(candidate.width, candidate.height),
                  candidate.width <= originalWidth, candidate.height <= originalHeight,
                  Self.sameAsset(url, original) || info.thumburl.flatMap(Self.uploadURL).map({ Self.sameAsset(url, $0) }) == true else {
                throw WorkArtworkError.invalidResponse
            }
            if Self.sameAsset(url, original), candidate.width != originalWidth || candidate.height != originalHeight {
                throw WorkArtworkError.invalidResponse
            }
            thumbnail = (url, candidate.width, candidate.height)
        } else if let raw = info.thumburl, let url = Self.uploadURL(raw) {
            // MediaWiki may return the original small image but report the
            // requested 320px in thumbwidth. Its original size is authoritative.
            let unscaled = Self.sameAsset(url, original)
            guard let width = unscaled ? originalWidth : info.thumbwidth,
                  let height = unscaled ? originalHeight : info.thumbheight,
                  Self.validDimensions(width, height), width <= originalWidth, height <= originalHeight else { throw WorkArtworkError.invalidResponse }
            thumbnail = (url, width, height)
        } else {
            guard Self.validDimensions(originalWidth, originalHeight) else { throw WorkArtworkError.invalidResponse }
            thumbnail = (original, originalWidth, originalHeight)
        }
        let metadata = info.extmetadata?.compactMapValues(\.value) ?? [:]
        let rawNonFree = metadata["NonFree"]
        let nonFree: Bool?
        switch rawNonFree?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": nonFree = true
        case "false", "0", "no": nonFree = false
        default: nonFree = nil
        }
        return WorkArtwork(id: idPrefix + ":" + fileTitle, fileTitle: fileTitle, thumbnailURL: thumbnail.url.absoluteString,
                           sourcePageURL: description.absoluteString, articleURL: articleURL,
                           artist: Self.plain(metadata["Artist"]), credit: Self.plain(metadata["Credit"]),
                           licenseName: Self.plain(metadata["LicenseShortName"]), licenseURL: metadata["LicenseUrl"],
                           isNonFree: nonFree, width: thumbnail.width, height: thumbnail.height,
                           nonFreeValue: rawNonFree, rawMetadata: metadata.isEmpty ? nil : metadata)
    }

    /// An iTunes artist ID is already an exact identity: no Wikidata needed.
    func appleArtistPhoto(artistID: String) async throws -> String? {
        guard !artistID.isEmpty, artistID.allSatisfy(\.isNumber) else { throw WorkArtworkError.invalidIdentity }
        return try await appleArtistArtwork(qid: "", artistID: artistID)?.thumbnailURL
    }
    /// P2850 identifies an Apple artist, not an album, song, or a name query.
    /// Only the exact artist-detail header may supply an image; album artwork,
    /// social cards and recommendation images are never substituted for a face.
    private func appleArtistArtwork(qid: String, artistID: String) async throws -> WorkArtwork? {
        guard let url = URL(string: "https://music.apple.com/jp/artist/" + artistID) else { throw WorkArtworkError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("Pianwai/0.1 (exact entity artwork metadata)", forHTTPHeaderField: "User-Agent")
        try Task.checkCancellation()
        let (data, response) = try await measuredData(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WorkArtworkError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw WorkArtworkError.httpStatus(http.statusCode) }
        guard data.count < 2_000_000, let finalURL = response.url,
              Self.appleArtistURL(finalURL.absoluteString, artistID: artistID),
              let html = String(data: data, encoding: .utf8) else { throw WorkArtworkError.identityMismatch }
        let document = try SwiftSoup.parse(html)
        guard let script = try document.select("script#serialized-server-data[type=application/json]").first(),
              let json = try script.html().data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw WorkArtworkError.invalidResponse }
        // Bounded traversal, restricted to the shipped artist header schema.
        var queue: [(Any, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count, cursor < 20_000 {
            let (value, depth) = queue[cursor]; cursor += 1
            guard depth < 32 else { continue }
            if let object = value as? [String: Any] {
                if object["itemKind"] as? String == "artistDetailHeader" {
                    guard let items = object["items"] as? [[String: Any]],
                          let item = items.first(where: { $0["id"] as? String == artistID }),
                          let descriptor = item["contentDescriptor"] as? [String: Any],
                          descriptor["kind"] as? String == "artist",
                          let identifiers = descriptor["identifiers"] as? [String: Any],
                          identifiers["storeAdamID"] as? String == artistID,
                          let pageURL = descriptor["url"] as? String, Self.appleArtistURL(pageURL, artistID: artistID) else {
                        throw WorkArtworkError.identityMismatch
                    }
                    guard let circle = item["circleArtwork"] as? [String: Any],
                          let dictionary = circle["dictionary"] as? [String: Any],
                          let template = dictionary["url"] as? String,
                          let width = dictionary["width"] as? Int, let height = dictionary["height"] as? Int,
                          width > 0, height > 0 else { return nil }
                    let side = min(320, width, height)
                    let raw = template.replacingOccurrences(of: "{w}", with: String(side))
                        .replacingOccurrences(of: "{h}", with: String(side)).replacingOccurrences(of: "{c}", with: "bb")
                        .replacingOccurrences(of: "{f}", with: "jpg")
                    guard let parts = URLComponents(string: raw), parts.scheme == "https",
                          let host = parts.host, host.range(of: "^is[1-5]-ssl\\.mzstatic\\.com$", options: .regularExpression) != nil,
                          parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                          parts.path.hasPrefix("/image/thumb/"), !raw.contains("{") else { throw WorkArtworkError.invalidResponse }
                    return WorkArtwork(id: "apple-artist:" + artistID, fileTitle: "Apple Music artist " + artistID,
                                       thumbnailURL: raw, sourcePageURL: pageURL, articleURL: "https://www.wikidata.org/wiki/" + qid,
                                       artist: nil, credit: "Apple Music", licenseName: nil, licenseURL: nil,
                                       isNonFree: nil, width: side, height: side,
                                       rawMetadata: ["Provider": "Apple Music", "IdentityProperty": "P2850", "ArtistID": artistID])
                }
                queue.append(contentsOf: object.values.map { ($0, depth + 1) })
            } else if let list = value as? [Any] { queue.append(contentsOf: list.map { ($0, depth + 1) }) }
        }
        throw WorkArtworkError.invalidResponse
    }

    private static func appleArtistURL(_ raw: String, artistID: String) -> Bool {
        guard let p = URLComponents(string: raw), p.scheme == "https",
              ["music.apple.com", "classical.music.apple.com"].contains(p.host ?? ""),
              p.user == nil, p.password == nil, p.port == nil, p.fragment == nil else { return false }
        let segments = p.path.split(separator: "/").map(String.init)
        return segments.count >= 3 && segments[1] == "artist" && segments.last == artistID
    }

    private static func validDimensions(_ width: Int, _ height: Int) -> Bool { (1...320).contains(width) && (1...10_000).contains(height) }
    private static func sameAsset(_ lhs: URL, _ rhs: URL) -> Bool { lhs.host == rhs.host && lhs.path == rhs.path }
    private static func uploadURL(_ raw: String) -> URL? {
        guard let p = URLComponents(string: raw), p.scheme == "https", ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(p.host ?? ""),
              p.user == nil, p.password == nil, p.port == nil, p.fragment == nil, p.path.hasPrefix("/wikipedia/") else { return nil }
        return p.url
    }
    private static func descriptionURL(_ raw: String, host: String, repository: String?, fileTitle: String) -> URL? {
        guard let p = URLComponents(string: raw), p.scheme == "https", p.user == nil, p.password == nil, p.port == nil,
              p.host == host || (repository == "shared" && p.host == "commons.wikimedia.org"),
              p.query == nil, p.fragment == nil, p.path.hasPrefix("/wiki/"),
              validTitle(String(p.path.dropFirst(6))) == fileTitle else { return nil }
        return p.url
    }
    private static func plain(_ raw: String?) -> String? {
        guard let raw, let text = try? SwiftSoup.parseBodyFragment(raw).text(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private static func validTitle(_ raw: String) -> String? {
        guard raw.utf8.count <= 1_024, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              raw.rangeOfCharacter(from: CharacterSet(charactersIn: "|#[]{}<>")) == nil, !raw.contains("://") else { return nil }
        let title = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return !title.isEmpty && title.utf8.count <= 255 ? title : nil
    }
    private static func reaches(_ resolved: String, from requested: String, through query: WikiResponse.Query) -> Bool {
        if requested == resolved { return true }
        let rewrites = (query.normalized ?? []) + (query.converted ?? []) + (query.redirects ?? [])
        guard rewrites.count <= 16 else { return false }
        var links: [String: Set<String>] = [:]
        for rewrite in rewrites {
            guard let from = validTitle(rewrite.from), let to = validTitle(rewrite.to) else { return false }
            if from != to { links[from, default: []].insert(to) }
        }
        var current = requested
        var seen = Set<String>()
        for _ in 0..<16 {
            guard seen.insert(current).inserted, let next = links[current], next.count == 1, let target = next.first else { return false }
            if target == resolved { return true }
            current = target
        }
        return false
    }
    private func load<T: Decodable>(host: String, params: [String: String], version: String = "2") async throws -> T {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = "/w/api.php"
        let values = params.merging(["format": "json", "formatversion": version]) { _, new in new }
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw WorkArtworkError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue("Pianwai/0.1 (exact entity artwork metadata)", forHTTPHeaderField: "User-Agent")
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await measuredData(for: request) }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WorkArtworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WorkArtworkError.httpStatus(http.statusCode) }
        guard data.count < 2_000_000 else { throw WorkArtworkError.invalidResponse }
        do {
            if try JSONDecoder().decode(APIEnvelope.self, from: data).error != nil { throw WorkArtworkError.invalidResponse }
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw WorkArtworkError.invalidResponse }
    }

    private func measuredData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if WikidataRequestPacer.isWikimedia(url) {
            guard let result = await metadata.response(url, timeout: min(8, request.timeoutInterval)) else { throw WorkArtworkError.invalidResponse }
            return (result.data, result.http)
        }
            let queued = Date()
            let started = Date()
            let result: (Data, URLResponse)
            do { result = try await session.data(for: request) }
            catch {
                await P17Metrics.shared.request(host: url.host ?? "", queued: queued, started: started, status: "failed")
                throw error
            }
            let http = result.1 as? HTTPURLResponse
            await P17Metrics.shared.request(host: url.host ?? "", queued: queued, started: started, status: String(http?.statusCode ?? 0))
            return result
    }

    private struct APIEnvelope: Decodable { let error: APIError?; struct APIError: Decodable { let code: String? } }
    private struct EntityResponse: Decodable {
        let success: Int?; let entities: [String: Entity]?
        struct Entity: Decodable {
            let id: String?; let type: String?; let missing: String?
            let sitelinks: [String: SiteLink]?; let claims: TypeClaims?
            var appleArtistIDs: [String] {
                var seen = Set<String>()
                return (claims?.appleArtists ?? []).filter {
                    ["normal", "preferred"].contains($0.rank ?? "")
                        && ($0.qualifiers ?? [:]).allSatisfy { property, values in
                            property == "P1810" && !values.isEmpty && values.allSatisfy {
                                $0.property == "P1810" && $0.snaktype == "value" && $0.datatype == "string"
                                    && !($0.datavalue?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                            }
                        }
                        && $0.mainsnak?.property == "P2850" && $0.mainsnak?.snaktype == "value"
                        && $0.mainsnak?.datatype == "external-id"
                }.compactMap { $0.mainsnak?.datavalue?.text }
                    .filter { $0.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil && seen.insert($0).inserted }
            }
            var imageFiles: [String] {
                let statements = (claims?.images ?? []).filter {
                    ["normal", "preferred"].contains($0.rank ?? "")
                        && ($0.qualifiers?.isEmpty ?? true)
                        && $0.mainsnak?.property == "P18" && $0.mainsnak?.snaktype == "value"
                        && $0.mainsnak?.datatype == "commonsMedia"
                }
                let preferred = statements.filter { $0.rank == "preferred" }
                var seen = Set<String>()
                return (preferred.isEmpty ? statements : preferred).compactMap { $0.mainsnak?.datavalue?.text }
                    .filter { seen.insert($0).inserted }
            }
        }
        struct SiteLink: Decodable { let site: String; let title: String }
        struct TypeClaims: Decodable { let images: [Claim]?; let appleArtists: [Claim]?; enum CodingKeys: String, CodingKey { case images = "P18"; case appleArtists = "P2850" } }
        struct Claim: Decodable { let rank: String?; let qualifiers: [String: [Snak]]?; let mainsnak: Snak? }
        struct Snak: Decodable { let property: String?; let snaktype: String?; let datatype: String?; let datavalue: Value? }
        struct Value: Decodable {
            let text: String?
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws { text = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value) }
        }
        struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
    }
    private struct WikiResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [Page]?; let normalized: [Rewrite]?; let converted: [Rewrite]?; let redirects: [Rewrite]? }
        struct Rewrite: Decodable { let from: String; let to: String }
        struct Page: Decodable {
            let ns: Int?; let pageid: Int?; let title: String?; let missing: Bool?; let invalid: Bool?
            let pageprops: Props?; let pageimage: String?; let thumbnail: Thumbnail?; let imageinfo: [ImageInfo]?; let imagerepository: String?
        }
        struct Props: Decodable { let wikibaseItem: String?; let disambiguation: String?; enum CodingKeys: String, CodingKey { case wikibaseItem = "wikibase_item"; case disambiguation } }
        struct Thumbnail: Decodable { let source: String; let width: Int; let height: Int }
        struct ImageInfo: Decodable {
            let url: String?; let width: Int?; let height: Int?; let mime: String?
            let thumburl: String?; let thumbwidth: Int?; let thumbheight: Int?; let descriptionurl: String?; let extmetadata: [String: Metadata]?
        }
        struct Metadata: Decodable {
            let value: String?
            enum CodingKeys: String, CodingKey { case value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // MediaWiki extmetadata includes numeric extension versions and
                // may use booleans. Optional objects/null are not display text;
                // they must not discard otherwise verified image provenance.
                if let text = try? container.decode(String.self, forKey: .value) { value = text }
                else if let flag = try? container.decode(Bool.self, forKey: .value) { value = flag ? "true" : "false" }
                else if let number = try? container.decode(Decimal.self, forKey: .value) { value = NSDecimalNumber(decimal: number).stringValue }
                else { value = nil }
            }
        }
    }
}
