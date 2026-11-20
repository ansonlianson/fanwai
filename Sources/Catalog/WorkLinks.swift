import Foundation

extension Work {
    /// Only exact item links are promoted to Music. Keep the storefront and the
    /// selected track; strip Store-routing and affiliate query parameters.
    var appleMusicURL: URL? {
        guard isSong || isAlbum || isPerson, let raw = url,
              var parts = URLComponents(string: raw), parts.scheme == "https",
              ["music.apple.com", "itunes.apple.com"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        var path = parts.path.split(separator: "/").map(String.init)
        if isPerson {
            guard path.contains("artist"), let last = path.last,
                  let number = Int64(last.hasPrefix("id") ? String(last.dropFirst(2)) : last), number > 0 else { return nil }
        } else {
            guard let link = try? CatalogLink.parse(raw),
                  isSong ? link.kind == .songs : link.kind == .albums else { return nil }
            if let stored = validStoredCatalogID, stored != link.id { return nil }
        }
        if let last = path.last, last.hasPrefix("id") { path[path.count-1] = String(last.dropFirst(2)) }
        parts.host = "music.apple.com"; parts.path = "/" + path.joined(separator: "/")
        let selection = (parts.queryItems ?? []).filter { $0.name == "i" }
        parts.queryItems = selection.isEmpty ? nil : selection
        parts.fragment = nil
        return parts.url
    }

    var queueSelection: MusicQueueSelection? {
        if let id = catalogRecordingID { return .init(catalogID: id, kind: .song) }
        guard hasCatalogAlbum, let id = validStoredCatalogID ?? url.flatMap(CatalogLink.musicID) else { return nil }
        return .init(catalogID: id, kind: .album)
    }
    /// Describe the destination, independently of the entity's media type.
    var externalLinkTitle: String {
        guard let raw = url, let link = URLComponents(string: raw),
              link.scheme?.lowercased() == "https", link.user == nil,
              link.password == nil, link.port == nil else { return "作品来源" }
        switch link.host?.lowercased() {
        case "music.apple.com": return "在 Apple Music 中查看"
        case "itunes.apple.com": return "在 iTunes 中查看"
        case "books.apple.com": return "在 Apple Books 中查看"
        case "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be":
            return isVideo ? "在 YouTube 中观看" : "作品来源"
        case "www.bilibili.com", "bilibili.com", "b23.tv":
            return isVideo ? "在哔哩哔哩中观看" : "作品来源"
        default: return "作品来源"
        }
    }

    /// A composition, album, library-only ID or title match cannot stand in for
    /// a playable recording. Catalog IDs follow the playback service's format.
    var catalogRecordingID: String? {
        guard isSong else { return nil }
        if let identifier = validStoredCatalogID { return identifier }
        guard let raw = url, let link = URLComponents(string: raw),
              let identifier = CatalogLink.musicID(from: raw) else { return nil }
        let path = link.path.split(separator: "/")
        let selectedTrack = link.queryItems?.contains { $0.name == "i" && $0.value == identifier } == true
        guard path.contains("song") || (path.contains("album") && selectedTrack) else { return nil }
        return identifier
    }

    var hasCatalogRecording: Bool { catalogRecordingID != nil }

    /// Finding a version is a discovery action, not permission to play this
    /// entity. A musical work and a release retain their own identities.
    var catalogVersionSearchKind: CatalogSearchKind? {
        if kind == "音乐作品" { return .song }
        guard knowledgeID != nil else { return nil }
        if isSong && !hasCatalogRecording { return .song }
        if isAlbum && !hasCatalogAlbum { return .album }
        return nil
    }

    var canFindCatalogVersion: Bool { catalogVersionSearchKind != nil }
    var catalogVersionSearchTitle: String {
        catalogVersionSearchKind == .album ? "查找发行" : "查找录音"
    }

    private var hasCatalogAlbum: Bool {
        guard isAlbum else { return false }
        if validStoredCatalogID != nil { return true }
        guard let raw = url, let link = URLComponents(string: raw),
              CatalogLink.musicID(from: raw) != nil else { return false }
        return link.path.split(separator: "/").contains("album")
            && link.queryItems?.contains(where: { $0.name == "i" }) != true
    }

    private var validStoredCatalogID: String? {
        guard let raw = catalogID else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 30,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              value.contains(where: { $0 != "0" }) else { return nil }
        return value
    }
}
