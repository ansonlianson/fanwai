import Foundation

/// Decode only fields used for catalog identity / presentation. previewUrl is
/// deliberately absent, so it cannot reach the metadata cache or saved works.
struct ITunesCatalogPayload: Decodable, Sendable {
    let resultCount: Int
    let results: [Item]
    struct Item: Decodable, Sendable {
        let wrapperType: String?
        let kind: String?
        let trackId: Int64?
        let trackName: String?
        let trackViewUrl: String?
        let trackTimeMillis: Int?
        let discNumber: Int?
        let trackNumber: Int?
        let trackCount: Int?
        let artistId: Int64?
        let artistName: String?
        let artistViewUrl: String?
        let artistLinkUrl: String?
        let collectionId: Int64?
        let collectionName: String?
        let collectionViewUrl: String?
        let artworkUrl100: String?
        let releaseDate: String?

        var trackIdentity: CatalogTrackIdentity? {
            guard kind == "song", let album = collectionId, let artist = artistId, let disc = discNumber, let track = trackNumber, let count = trackCount, let milliseconds = trackTimeMillis, album > 0, artist > 0, disc > 0, track > 0, count >= track, milliseconds > 0 else { return nil }
            return .init(albumID: String(album), artistID: String(artist), disc: disc, track: track, trackCount: count, milliseconds: milliseconds)
        }
        var identity: WorkID? {
            let type: String; let number: Int64?
            if wrapperType == "artist" { type = "artist"; number = artistId }
            else if wrapperType == "collection" { type = "album"; number = collectionId }
            else if kind == "song" || kind == "music-video" { type = kind!; number = trackId }
            else { return nil }
            guard let number, number > 0 else { return nil }
            return WorkID(rawValue: "apple:\(type):\(number)")
        }
        var title: String? { wrapperType == "artist" ? artistName : wrapperType == "collection" ? collectionName : trackName }
        var storeURL: String? { wrapperType == "artist" ? artistLinkUrl ?? artistViewUrl : wrapperType == "collection" ? collectionViewUrl : trackViewUrl }
    }

    func validate(country: String? = nil) throws {
        guard resultCount == results.count, results.count <= 200 else { throw CatalogError.invalidData }
        for row in results {
            guard row.identity != nil, let title = row.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count < 4_000, let url = Self.validStoreURL(row.storeURL) else { throw CatalogError.invalidData }
            let number = row.wrapperType == "artist" ? row.artistId : row.wrapperType == "collection" ? row.collectionId : row.trackId
            let linkedID: String?
            if row.wrapperType == "artist" || row.wrapperType == "collection" {
                let last = url.lastPathComponent
                linkedID = last.hasPrefix("id") ? String(last.dropFirst(2)) : last
            } else { linkedID = try? CatalogLink.parse(url.absoluteString).id }
            guard linkedID == number.map(String.init) else { throw CatalogError.invalidData }
            if let country {
                for raw in [row.storeURL, row.collectionViewUrl, row.artistViewUrl] {
                    if let link = Self.validStoreURL(raw), let region = link.pathComponents.dropFirst().first,
                       region.count == 2, region.lowercased() != country { throw CatalogError.invalidData }
                }
            }
        }
    }

    static func validStoreURL(_ raw: String?) -> URL? {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme == "https",
              ["music.apple.com", "itunes.apple.com"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        return parts.url
    }

    func materialize(country: String, artists: [Item] = []) throws -> CatalogResponse {
        try validate(country: country)
        var works: [WorkID: Work] = [:]
        var edges: [RelationEdge] = []
        func id(_ type: String, _ number: Int64?) -> WorkID? {
            guard let number, number > 0 else { return nil }
            return WorkID(rawValue: "apple:\(type):\(number)")
        }
        func source(_ raw: String?, field: String) throws -> Source? {
            guard let url = Self.validStoreURL(raw) else { return nil }
            if let first = url.pathComponents.dropFirst().first, first.count == 2, first.lowercased() != country {
                throw CatalogError.invalidData
            }
            return Source(title: "iTunes", detail: field, url: url.absoluteString)
        }
        func albumURL(_ raw: String?) -> String? {
            guard let raw, Self.validStoreURL(raw) != nil, var parts = URLComponents(string: raw) else { return nil }
            // Search often supplies a collectionViewUrl selecting this track.
            // Removing only i keeps an album action addressed to the album.
            parts.queryItems = parts.queryItems?.filter { $0.name != "i" }
            return parts.url?.absoluteString
        }
        for row in results + artists where row.wrapperType == "artist" {
            guard let identifier = row.identity, let number = row.artistId, let name = row.artistName,
                  let provenance = try source(row.storeURL, field: "artistId · \(country)") else { continue }
            works[identifier] = Work(id: identifier, title: name, creator: "音乐人", kind: "创作者", art: "", detail: "",
                                     url: row.storeURL, linkedCreatorIDs: [], catalogID: String(number), storeCountry: country,
                                     catalogSource: provenance, catalogFetchedAt: Date())
        }
        // Dedicated album rows own album credits and dates regardless of order.
        for row in results.sorted(by: { $0.wrapperType == "collection" && $1.wrapperType != "collection" }) {
            guard row.wrapperType != "artist" else { continue }
            let artistID = id("artist", row.artistId).flatMap { works[$0] != nil ? $0 : nil }
            let albumID = id("album", row.collectionId)
            let artwork = ArtworkLocation.remoteURL(row.artworkUrl100.flatMap(URL.init(string:)))?.absoluteString
                .replacingOccurrences(of: "100x100bb", with: "600x600bb") ?? ""
            let isAlbum = row.wrapperType == "collection"
            if let albumID, let number = row.collectionId, let name = row.collectionName, !name.isEmpty,
               works[albumID] == nil {
                let provenance = try source(row.collectionViewUrl, field: "collectionId · \(country)")
                works[albumID] = Work(id: albumID, title: name, creator: isAlbum ? row.artistName ?? "" : "", kind: "专辑",
                                     art: artwork, detail: isAlbum ? String(row.releaseDate?.prefix(4) ?? "") : "",
                                     url: albumURL(row.collectionViewUrl), linkedCreatorIDs: isAlbum ? artistID.map { [$0] } ?? [] : [],
                                     catalogID: String(number), storeCountry: country, releaseDate: isAlbum ? row.releaseDate : nil,
                                     catalogSource: provenance, catalogFetchedAt: Date(), catalogTrackCount: row.trackCount)
                if isAlbum, let artistID, let provenance {
                    edges.append(RelationEdge(from: albumID, to: artistID, predicate: .performedBy,
                                              label: "发行艺人", inverseLabel: "发行作品", source: provenance))
                }
            }
            guard !isAlbum, let identifier = row.identity, let number = row.trackId, let title = row.trackName else { continue }
            let provenance = try source(row.trackViewUrl, field: "trackId · \(country)")
            var detail: [String] = []
            if let time = row.trackTimeMillis, time > 0 { detail.append("\(time / 60000):\(String(format: "%02d", time / 1000 % 60))") }
            if let date = row.releaseDate { detail.append(String(date.prefix(4))) }
            let actualAlbum = albumID.flatMap { works[$0] != nil ? $0 : nil }
            works[identifier] = Work(id: identifier, title: title, creator: row.artistName ?? "", kind: row.kind == "song" ? "歌曲" : "音乐视频",
                                     art: artwork, detail: detail.joined(separator: " · "), url: row.trackViewUrl,
                                     linkedAlbumID: actualAlbum, linkedCreatorIDs: artistID.map { [$0] } ?? [], catalogID: String(number),
                                     storeCountry: country, releaseDate: row.releaseDate, catalogSource: provenance, catalogFetchedAt: Date(), catalogTrack: row.trackIdentity)
            if let provenance {
                if let artistID { edges.append(RelationEdge(from: identifier, to: artistID, predicate: .performedBy, label: "艺人", inverseLabel: "作品", source: provenance)) }
                if let actualAlbum { edges.append(RelationEdge(from: identifier, to: actualAlbum, predicate: .inAlbum, label: "收录于", inverseLabel: "收录歌曲", source: provenance)) }
            }
        }
        var seen = Set<WorkID>()
        let ids = results.compactMap(\.identity).filter { works[$0] != nil && seen.insert($0).inserted }
        guard results.isEmpty || !ids.isEmpty else { throw CatalogError.invalidData }
        return CatalogResponse(results: ids, snapshot: CatalogSnapshot(works: Array(works.values), relations: edges))
    }
}
