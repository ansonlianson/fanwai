import Foundation

actor DomesticMusicCatalog {
    static let shared = DomesticMusicCatalog(http: PlatformCatalogFixtures.http() ?? .shared)
    let http: PublicDatabaseHTTP
    init(http: PublicDatabaseHTTP = .shared) { self.http = http }
    func search(_ query: String, platform: PlaybackPlatform) async throws -> [PlatformRecording] {
        guard platform != .apple else { return [] }
        let url = platform == .qq
            ? PublicDatabaseHTTP.endpoint("c.y.qq.com", "/soso/fcgi-bin/client_search_cp", ["w": query, "format": "json", "p": "1", "n": "8"])
            : PublicDatabaseHTTP.endpoint("music.163.com", "/api/search/get", ["s": query, "type": "1", "limit": "8", "offset": "0"])
        let rows = try Self.parse(try await http.get(url), platform: platform, detail: false)
        // 网易云 search rows carry album.picId only; one batched detail read supplies the
        // https picUrl, so song results show their covers. A failed read keeps the rows.
        let bare = rows.filter { $0.platform == .netease && $0.artwork.isEmpty }.map(\.identifier)
        guard !bare.isEmpty else { return rows }
        let detail = PublicDatabaseHTTP.endpoint("music.163.com", "/api/song/detail/",
            ["id": bare[0], "ids": "[" + bare.joined(separator: ",") + "]"])
        guard let data = try? await http.get(detail),
              let found = try? Self.parse(data, platform: .netease, detail: true) else { return rows }
        let art = Dictionary(found.map { ($0.identifier, $0.artwork) }, uniquingKeysWith: { a, _ in a })
        return rows.map { row in
            guard row.artwork.isEmpty, let cover = art[row.identifier], cover.hasPrefix("https://") else { return row }
            return .init(platform: row.platform, identifier: row.identifier, numericID: row.numericID, title: row.title,
                         artists: row.artists, album: row.album, seconds: row.seconds, artwork: cover)
        }
    }
    func importSong(_ url: URL) async throws -> PlatformRecording {
        let resolved = PlatformSongLink.isShort(url) ? try await http.expandSongLink(url) : url
        guard let link = PlatformSongLink.parse(resolved) else { throw CatalogError.invalidLink }
        let endpoint = link.platform == .qq
            ? PublicDatabaseHTTP.endpoint("c.y.qq.com", "/v8/fcg-bin/fcg_play_single_song.fcg", [link.identifier.allSatisfy(\.isNumber) ? "songid" : "songmid": link.identifier, "tpl": "yqq_song_detail", "format": "json"])
            : PublicDatabaseHTTP.endpoint("music.163.com", "/api/song/detail/", ["id": link.identifier, "ids": "[" + link.identifier + "]"])
        let rows = try Self.parse(try await http.get(endpoint), platform: link.platform, detail: true)
        guard let recording = rows.first(where: { $0.matches(link) }) else { throw CatalogError.invalidData }
        return recording
    }
    nonisolated static func parse(_ data: Data, platform: PlaybackPlatform, detail: Bool) throws -> [PlatformRecording] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? Int, [0, 200].contains(code) else { throw CatalogError.server }
        let rows: [[String: Any]]?
        if platform == .qq { rows = detail ? object["data"] as? [[String: Any]] : ((object["data"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] }
        else { rows = detail ? object["songs"] as? [[String: Any]] : (object["result"] as? [String: Any])?["songs"] as? [[String: Any]] }
        // A valid zero-result envelope differs from an empty HTML/API shell.
        let empty = !detail && platform == .netease && (object["result"] as? [String: Any])?["songCount"] as? Int == 0
        guard let rows else { if empty { return [] }; throw CatalogError.invalidData }
        func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
        let result = rows.compactMap { row -> PlatformRecording? in
            let album = (row["album"] ?? row["al"]) as? [String: Any] ?? [:]
            let artists = ((row["singer"] ?? row["artists"] ?? row["ar"]) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let identifier = string(platform == .qq ? row["mid"] ?? row["songmid"] : row["id"])
            let number = string(platform == .qq ? row["id"] ?? row["songid"] : row["id"])
            let title = string(row["name"] ?? row["songname"])
            guard !title.isEmpty, !identifier.isEmpty, identifier.count < 40, !artists.isEmpty,
                  identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  platform == .qq || UInt64(identifier).map({ $0 > 0 }) == true else { return nil }
            let albumMid = string(album["mid"] ?? row["albummid"])
            let art = platform == .qq && !albumMid.isEmpty ? "https://y.gtimg.cn/music/photo_new/T002R300x300M000" + albumMid + ".jpg" : string(album["picUrl"])
            let seconds = platform == .qq ? (row["interval"] as? NSNumber)?.doubleValue ?? 0 : ((row["duration"] ?? row["dt"]) as? NSNumber)?.doubleValue ?? 0
            return .init(platform: platform, identifier: identifier, numericID: number.isEmpty ? nil : number,
                title: title, artists: artists, album: string(album["name"] ?? row["albumname"]),
                seconds: platform == .qq ? seconds : seconds / 1000, artwork: art)
        }
        guard rows.isEmpty || !result.isEmpty else { throw CatalogError.invalidData }
        return result
    }
}
