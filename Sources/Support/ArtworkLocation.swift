import Foundation

/// MusicKit library artwork may return a musicKit:// URL. It is an opaque
/// framework resource, not a URLSession image or an asset-catalog image name.
/// Use a public catalog cover for the exact recording instead of decoding it.
enum ArtworkLocation {
    /// A recording's own verified release can supply its cover immediately.
    /// This never traverses from a soundtrack to a game or film.
    @MainActor static func displayValue(for work: Work, catalog: CatalogStore, excluding: Set<String> = []) -> String? {
        if !work.art.isEmpty, stored(work.art) == work.art, !excluding.contains(work.art) { return work.art }
        if work.isSong, let album = work.albumID, catalog.work(album).isAlbum {
            let art = catalog.work(album).art
            if remoteURL(URL(string: art)) != nil, !excluding.contains(art) { return art }
        }
        guard let art = WorkArtworkStore.shared.metadata(for: work)?.thumbnailURL, !excluding.contains(art) else { return nil }
        return art
    }
    static func remoteURL(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return url
    }

    static func stored(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        if let url = URL(string: value), url.scheme != nil {
            return remoteURL(url)?.absoluteString ?? ""
        }
        // Asset names are local identifiers; paths/opaque resource URLs are not.
        return value.contains("/") || value.contains(":") ? "" : value
    }
}
