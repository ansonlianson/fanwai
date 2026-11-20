import Foundation
@testable import Pianwai

// Historical decoder retained for pre-MusicKit test contracts. Production public
// metadata now uses the separately validated ITunesCatalogPayload adapter.
struct AppleCatalogPayload: Decodable, Sendable {
    let results: [Item]
    struct Item: Decodable, Sendable {
        let wrapperType: String?
        let kind: String?
        let trackId: Int64?
        let trackName: String?
        let trackViewUrl: String?
        let trackTimeMillis: Int?
        let artistId: Int64?
        let artistName: String?
        let artistViewUrl: String?
        let collectionId: Int64?
        let collectionName: String?
        let collectionViewUrl: String?
        let artworkUrl100: String?
        let releaseDate: String?
    }

    func materialize(country: String) -> CatalogResponse {
        var works: [WorkID: Work] = [:]
        var edges: [RelationEdge] = []
        var ids: [WorkID] = []
        func identifier(_ kind: String, _ value: Int64) -> WorkID { WorkID(rawValue: "apple:\(kind):\(value)")! }
        for item in results {
            let musical = item.kind == "song" || item.kind == "music-video" || item.wrapperType == "artist" || item.wrapperType == "collection"
            let namedArtist = !(item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let namedAlbum = !(item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let artistID = musical && namedArtist ? item.artistId.map { identifier("artist", $0) } : nil
            let albumID = musical && namedAlbum ? item.collectionId.map { identifier("album", $0) } : nil
            let artwork = item.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "600x600bb") ?? ""
            let artist = item.artistName ?? ""
            if let artistID, let number = item.artistId, !artist.isEmpty {
                works[artistID] = Work(id: artistID, title: artist, creator: "音乐人", kind: "创作者", art: "", detail: "", url: item.artistViewUrl ?? "https://music.apple.com/\(country)/artist/\(number)", catalogID: String(number), storeCountry: country)
            }
            if let albumID, let number = item.collectionId, let name = item.collectionName,
               item.wrapperType == "collection" || works[albumID] == nil {
                // A track's performer is not necessarily the album artist. Only
                // the collection row owns album credits, regardless of row order.
                let isCollection = item.wrapperType == "collection"
                works[albumID] = Work(id: albumID, title: name, creator: isCollection ? artist : "", kind: "专辑", art: artwork, detail: String(item.releaseDate?.prefix(4) ?? ""), url: item.collectionViewUrl ?? "https://music.apple.com/\(country)/album/\(number)", linkedCreatorIDs: isCollection ? artistID.map { [$0] } : [], catalogID: String(number), storeCountry: country)
                if isCollection { works[albumID]?.releaseDate = item.releaseDate }
            }
            if item.wrapperType == "artist", let artistID { ids.append(artistID); continue }
            if item.wrapperType == "collection", let albumID {
                ids.append(albumID)
                if let artistID, let url = works[albumID]?.url {
                    edges.append(RelationEdge(from: albumID, to: artistID, predicate: .performedBy, label: "发行艺人", inverseLabel: "发行作品", source: Source(title: "\(works[albumID]!.title) · Apple Music", detail: "发行与艺人信息", url: url)))
                }
                continue
            }
            guard let number = item.trackId, let title = item.trackName, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kind: String
            switch item.kind {
            case "song": kind = "歌曲"
            case "feature-movie": kind = "电影"
            case "ebook": kind = "书籍"
            case "music-video": kind = "演奏视频"
            default: continue
            }
            let id = identifier(item.kind ?? "work", number)
            let isMusic = kind == "歌曲" || kind == "演奏视频"
            var detail: [String] = []
            if let time = item.trackTimeMillis, kind == "歌曲" { detail.append("\(time / 60000):\(String(format: "%02d", time / 1000 % 60))") }
            if let date = item.releaseDate { detail.append(String(date.prefix(4))) }
            works[id] = Work(id: id, title: title, creator: artist, kind: kind, art: artwork, detail: detail.joined(separator: " · "), url: item.trackViewUrl, linkedAlbumID: isMusic ? albumID : nil, linkedCreatorIDs: isMusic ? artistID.map { [$0] } : [], catalogID: String(number), storeCountry: country)
            works[id]?.releaseDate = item.releaseDate
            ids.append(id)
            guard let url = item.trackViewUrl, URL(string: url)?.scheme == "https" else { continue }
            let source = Source(title: "\(title) · \(isMusic ? "Apple Music" : "Apple")", detail: "作品与发行信息", url: url)
            if isMusic, let artistID {
                edges.append(RelationEdge(from: id, to: artistID, predicate: .performedBy, label: "艺人", inverseLabel: "作品", source: source))
            }
            if isMusic, let albumID {
                edges.append(RelationEdge(from: id, to: albumID, predicate: .inAlbum, label: "收录于", inverseLabel: "收录歌曲", source: source))
            }
        }
        var seen = Set<WorkID>()
        return CatalogResponse(results: ids.filter { seen.insert($0).inserted }, snapshot: CatalogSnapshot(works: Array(works.values), relations: edges))
    }
}
