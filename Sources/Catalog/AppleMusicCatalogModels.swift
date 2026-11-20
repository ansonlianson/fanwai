import Foundation

/// Public MusicKit/Apple Music API resource fields. Missing relationships stay
/// unknown; a display name is never promoted into an identified person/work.
struct AppleMusicResource: Codable, Sendable {
    let id: String
    let type: String
    var attributes: Attributes?
    var relationships: [String: Related]?
    var views: [String: Related]?
    struct Related: Codable, Sendable { var data: [AppleMusicResource]; var next: String? }
    struct Notes: Codable, Sendable { var standard: String?; var short: String? }
    struct Artwork: Codable, Sendable { var url: String? }
    struct Attributes: Codable, Sendable {
        var name: String?
        var artistName: String?
        var albumName: String?
        var composerName: String?
        var genreNames: [String]?
        var isrc: String?
        var releaseDate: String?
        var editorialNotes: Notes?
        var workName: String?
        var recordLabel: String?
        var copyright: String?
        var upc: String?
        var url: String?
        var artwork: Artwork?
        var durationInMillis: Int?
    }
    var workID: WorkID? {
        let kind: String
        switch type { case "songs": kind = "song"; case "albums": kind = "album"
        case "artists": kind = "artist"; case "music-videos": kind = "music-video"; default: return nil }
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return WorkID(rawValue: "apple:" + kind + ":" + id)
    }
    func related(_ field: String) -> [AppleMusicResource] { relationships?[field]?.data ?? views?[field]?.data ?? [] }
    func sourceURL(storefront: String) -> String {
        if let raw = attributes?.url, let url = URL(string: raw), url.scheme == "https", url.host == "music.apple.com" { return raw }
        let path = ["songs":"song", "albums":"album", "artists":"artist", "music-videos":"music-video"][type] ?? type
        return "https://music.apple.com/" + storefront + "/" + path + "/" + id
    }
    func storyMaterials(storefront: String) -> [StoryMaterial] {
        let base = "\(type)[\(id)].attributes.editorialNotes"
        let url = URL(string: sourceURL(storefront: storefront))
        return [("standard", attributes?.editorialNotes?.standard), ("short", attributes?.editorialNotes?.short)].flatMap { field, text -> [StoryMaterial] in
            guard let text else { return [] }
            return StoryMaterial.appleEditorial(text: text, url: url, title: attributes?.name ?? id, location: base + "." + field)
        }
    }
}

struct AppleMusicPayload: Decodable, Sendable {
    var data: [AppleMusicResource]?
    var results: [String: AppleMusicResource.Related]?
    var next: String?
    func resources(type: String? = nil) throws -> [AppleMusicResource] {
        guard data != nil || results != nil else { throw CatalogError.invalidData }
        if let data { return data }
        if let type { return results?[type]?.data ?? [] }
        return (results ?? [:]).sorted { $0.key < $1.key }.flatMap { $0.value.data }
    }
}

enum AppleMusicResourceKind: String, Sendable { case songs, albums, artists, musicVideos = "music-videos" }
enum AppleMusicSongReference: Sendable { case catalogID(String), isrc(String) }

struct AppleMusicRelationCandidate: Codable, Sendable {
    let fromID: String
    let fromType: String
    let target: AppleMusicResource
    let sourceField: String
    let sourceURL: String
}
struct AppleMusicDiscovery: Sendable {
    struct Identity: Sendable {
        let catalogID: String
        let isrc: String?
        let artistIDs: [String]
        var wikidata: [CatalogWikidataIdentity] = []
        var artistsWikidata: [String: [CatalogWikidataIdentity]] = [:]
        var musicBrainz: [CatalogMusicBrainzRecording] = []
    }
    let storefront: String
    let song: AppleMusicResource
    var identity: Identity
    var relations: [AppleMusicRelationCandidate] = []
    var materials: [StoryMaterial] = []
    /// A missing page or exhausted budget is not an empty successful lookup.
    var incomplete: [String] = []
}

extension Array where Element == AppleMusicResource {
    func catalogResponse(storefront: String) -> CatalogResponse {
        var resources: [WorkID: AppleMusicResource] = [:]
        func visit(_ item: AppleMusicResource, depth: Int) {
            guard depth <= 3, resources.count < 500, let id = item.workID else { return }
            if item.attributes?.name != nil {
                let richness = (item.relationships?.count ?? 0) + (item.views?.count ?? 0)
                let existing = resources[id]
                if existing == nil || richness > (existing?.relationships?.count ?? 0) + (existing?.views?.count ?? 0) { resources[id] = item }
            }
            for child in (item.relationships ?? [:]).values.flatMap(\.data) { visit(child, depth: depth + 1) }
        }
        for item in self { visit(item, depth: 0) }
        var works: [WorkID: Work] = [:]
        for (id, item) in resources {
            guard let name = item.attributes?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let a = item.attributes
            let kind = ["songs":"歌曲", "albums":"专辑", "artists":"创作者", "music-videos":"音乐视频"][item.type] ?? ""
            let art = a?.artwork?.url?.replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600").replacingOccurrences(of: "{f}", with: "jpg") ?? ""
            var detail: [String] = []
            if let duration = a?.durationInMillis, item.type == "songs" { detail.append("\(duration / 60000):\(String(format: "%02d", duration / 1000 % 60))") }
            if let date = a?.releaseDate { detail.append(String(date.prefix(4))) }
            let artists = item.related("artists").compactMap(\.workID).filter { resources[$0] != nil }
            let album = item.related("albums").compactMap(\.workID).first { resources[$0] != nil }
            var work = Work(id: id, title: name, creator: a?.artistName ?? (item.type == "artists" ? "音乐人" : ""), kind: kind, art: art, detail: detail.joined(separator: " · "), url: item.sourceURL(storefront: storefront), linkedAlbumID: item.type == "songs" ? album : nil, linkedCreatorIDs: artists, catalogID: item.id, storeCountry: storefront)
            work.publicIdentifiers = a?.isrc.flatMap(CatalogIdentityService.validISRC).map { .init(isrc: $0) }
            work.releaseDate = a?.releaseDate; work.editorialNotes = item.storyMaterials(storefront: storefront)
            works[id] = work
        }
        var edges: [String: RelationEdge] = [:]
        func edge(_ from: WorkID, _ to: WorkID, _ predicate: RelationKind, _ label: String, _ inverse: String, _ item: AppleMusicResource, _ field: String) {
            guard works[from] != nil, works[to] != nil, from != to else { return }
            let value = RelationEdge(from: from, to: to, predicate: predicate, label: label, inverseLabel: inverse,
                source: .init(title: "\(item.attributes?.name ?? item.id) · Apple Music", detail: item.type + "." + field, url: item.sourceURL(storefront: storefront)))
            edges[value.id] = value
        }
        for (id, item) in resources {
            for artist in item.related("artists").compactMap(\.workID) { edge(id, artist, .performedBy, "艺人", "作品", item, "artists") }
            for composer in item.related("composers").compactMap(\.workID) { edge(id, composer, .composedBy, "作曲", "创作", item, "composers") }
            if item.type == "songs" {
                for album in item.related("albums").compactMap(\.workID) { edge(id, album, .inAlbum, "收录于", "收录歌曲", item, "albums") }
            }
            if item.type == "albums" {
                for song in item.related("tracks") where song.type == "songs" {
                    if let songID = song.workID { edge(songID, id, .inAlbum, "收录于", "收录歌曲", item, "tracks") }
                }
            }
        }
        var seen = Set<WorkID>()
        return CatalogResponse(results: compactMap(\.workID).filter { works[$0] != nil && seen.insert($0).inserted },
            snapshot: .init(works: works.values.sorted { $0.id.rawValue < $1.id.rawValue }, relations: edges.values.sorted { $0.id < $1.id }))
    }
}
