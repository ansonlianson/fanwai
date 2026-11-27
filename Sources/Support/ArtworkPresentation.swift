import Observation
import UIKit

/// A page pins its first usable cover for one work. The lit/unlit sleeve and
/// vinyl share this owner, so an enriched URL cannot clear or stagger them.
@MainActor @Observable final class ArtworkPresentation {
    enum Result { case shown, failed, ignored }
    private(set) var identity: String?
    private var displayed: UIImage?
    @ObservationIgnored private let cache: ArtworkImageCache
    init(cache: ArtworkImageCache = .shared) { self.cache = cache }

    func image(for identity: String, source: String?) -> UIImage? {
        if self.identity == identity, let displayed { return displayed }
        guard let source else { return nil }
        if let url = ArtworkLocation.remoteURL(URL(string: source)) { return cache.image(url) }
        return ObservedArtwork.image(source)
    }

    @discardableResult func load(_ source: String?, for identity: String) async -> Result {
        guard !Task.isCancelled else { return .ignored }
        if self.identity != identity { self.identity = identity; displayed = nil }
        if displayed != nil { return .shown }
        guard let source else { return .ignored }
        if let image = image(for: identity, source: source) { displayed = image; return .shown }
        let loaded: UIImage?
        if let url = ArtworkLocation.remoteURL(URL(string: source)) { loaded = await cache.load(url) }
        else { loaded = await ObservedArtwork.load(source) }
        guard !Task.isCancelled, self.identity == identity else { return .ignored }
        if displayed == nil { displayed = loaded }
        return displayed == nil ? .failed : .shown
    }
}
