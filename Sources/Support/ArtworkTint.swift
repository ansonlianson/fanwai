import SwiftUI
import UIKit
import CoreImage

/// Each address has its own observable result: a late cover does not invalidate
/// every page. Sampling starts when metadata arrives, before a page is accepted.
@MainActor @Observable
final class ArtworkTint {
    static let shared = ArtworkTint()
    @MainActor @Observable fileprivate final class Entry {
        var palette: ArtworkPalette?
        var backdrop: UIImage?
        @ObservationIgnored var paletteTask: Task<Void, Never>?
        @ObservationIgnored var backdropTask: Task<Void, Never>?
        @ObservationIgnored var failedAt: Date?
    }
    @ObservationIgnored private var entries: [String: Entry] = [:]

    private func entry(_ address: String) -> Entry {
        if let known = entries[address] { return known }
        // Only retain a small working set; already displayed colours are values.
        if entries.count >= 80, let key = entries.first(where: {
            $0.value.paletteTask == nil && $0.value.backdropTask == nil
        })?.key { entries[key] = nil }
        let value = Entry(); entries[address] = value
        return value
    }
    func prewarm(_ address: String?) {
        guard let address, !address.isEmpty else { return }
        load(address, entry: entry(address))
    }
    func palette(_ address: String) -> ArtworkPalette? {
        let value = entry(address)
        load(address, entry: value)
        return value.palette
    }
    func backdrop(_ address: String) -> UIImage? {
        // ArtworkBackdrop has an animation value outside its content branch.
        // A shop/concept page never displays this background image.
        guard RecordStoreConcept.current == nil, RecordShopArtReview.current == nil else { return nil }
        let value = entry(address)
        guard value.backdrop == nil, value.backdropTask == nil else { return value.backdrop }
        // Most pages display a shop plate, so their palette must not pay for an
        // unused Core Image blur. Build it only for an actual backdrop consumer.
        value.backdropTask = Task {
            defer { value.backdropTask = nil }
            guard let image = await source(address) else { return }
            value.backdrop = await Task.detached(priority: .utility) {
                Self.blur(image)
            }.value
        }
        return value.backdrop
    }
    nonisolated private static func blur(_ source: UIImage) -> UIImage? {
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 280)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: 220, height: 280))
        }
        guard let input = CIImage(image: rendered), let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(30, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent) else { return nil }
        let blurred = UIImage(cgImage: cg)
        return UIGraphicsImageRenderer(size: blurred.size).image { context in
            blurred.draw(at: .zero); context.cgContext.setBlendMode(.sourceAtop)
            UIColor.black.withAlphaComponent(0.45).setFill()
            context.fill(CGRect(origin: .zero, size: blurred.size))
        }
    }
    private func source(_ address: String) async -> UIImage? {
        if address.hasPrefix("https://"), let url = URL(string: Self.sample(address)) {
            return await ArtworkImageCache.shared.load(url)
        }
        return await ObservedArtwork.load(address)
    }
    /// A small rendition is enough to read colour from.
    private static func sample(_ address: String) -> String {
        guard address.contains("mzstatic.com") else { return address }
        return address.replacingOccurrences(of: "1200x1200bb", with: "300x300bb")
            .replacingOccurrences(of: "600x600bb", with: "300x300bb")
    }
    private func load(_ address: String, entry: Entry) {
        guard entry.palette == nil, entry.paletteTask == nil,
              entry.failedAt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { return }
        entry.paletteTask = Task {
            defer { entry.paletteTask = nil }
            guard let image = await source(address) else { entry.failedAt = Date(); return }
            entry.palette = await Task.detached(priority: .userInitiated) {
                ArtworkPalette.extract(image)
            }.value
            entry.failedAt = nil
        }
    }
}
