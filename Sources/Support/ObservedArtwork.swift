import CryptoKit
import Observation
import UIKit

/// Artwork already supplied by the authorised system player. Keep that image
/// immediately, while decoded disk images and JPEG writes run away from the UI.
@MainActor enum ObservedArtwork {
    private static let prefix = "observed-cover-"
    private static let memory = NSCache<NSString, UIImage>()
    private static let named = NSCache<NSString, UIImage>()
    @MainActor @Observable fileprivate final class Entry {
        var revision = 0
        @ObservationIgnored var task: Task<UIImage?, Never>?
        @ObservationIgnored var attempted = false
    }
    private static var entries: [String: Entry] = [:]
    private static var directory: URL? { PianwaiRuntime.applicationDirectory("ObservedArtwork") }

    static func key(_ identity: String) -> String {
        prefix + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func valid(_ key: String) -> Bool {
        key.hasPrefix(prefix) && key.count == prefix.count + 64
            && key.dropFirst(prefix.count).allSatisfy { $0.isHexDigit && $0.isASCII }
    }
    private static func entry(_ asset: String) -> Entry {
        if let known = entries[asset] { return known }
        let value = Entry(); entries[asset] = value; return value
    }
    static func image(_ asset: String) -> UIImage? {
        // Bundled layer artwork is requested synchronously by Core Animation.
        // UIImage(named:) shares UIKit's asset cache; palette decoding uses load.
        // Bundled names are looked up once: UIImage(named:) still resolves the asset
        // catalog's rendition on every call, which showed up in each page push (11-17 profile).
        guard valid(asset) else {
            if let image = named.object(forKey: asset as NSString) { return image }
            let image = UIImage(named: asset)
            if let image { named.setObject(image, forKey: asset as NSString) }
            return image
        }
        let value = entry(asset)
        _ = value.revision
        if let image = memory.object(forKey: asset as NSString) { return image }
        if !value.attempted { start(asset, entry: value) }
        return nil
    }
    static func load(_ asset: String) async -> UIImage? {
        if let image = memory.object(forKey: asset as NSString) { return image }
        let value = entry(asset)
        start(asset, entry: value)
        return await value.task?.value
    }
    private static func start(_ asset: String, entry: Entry) {
        guard entry.task == nil else { return }
        entry.attempted = true
        let file = valid(asset) ? directory?.appendingPathComponent(asset + ".jpg") : nil
        let observed = valid(asset)
        entry.task = Task {
            defer { entry.task = nil }
            let image = await Task.detached(priority: .userInitiated) {
                let source = observed ? file.flatMap { UIImage(contentsOfFile: $0.path) } : UIImage(named: asset)
                return source?.preparingForDisplay() ?? source
            }.value
            // A player-supplied image may have arrived while disk was loading.
            if let current = memory.object(forKey: asset as NSString) { return current }
            if let image {
                memory.countLimit = 48; memory.setObject(image, forKey: asset as NSString)
                entry.revision += 1
            }
            return image
        }
    }
    static func remember(identity: String, image makeImage: () -> UIImage?) -> String? {
        let asset = key(identity)
        if memory.object(forKey: asset as NSString) != nil { return asset }
        guard let supplied = makeImage(), supplied.size.width > 0, supplied.size.height > 0 else {
            // A transiently empty system artwork object must not discard an
            // image retained from an earlier observation of the same identity.
            guard let file = directory?.appendingPathComponent(asset + ".jpg"),
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            start(asset, entry: entry(asset)); ArtworkTint.shared.prewarm(asset)
            // Publish this identity only once image(_:) can actually supply it.
            // The next player capture then carries a real metadata change.
            return nil
        }
        memory.countLimit = 48; memory.setObject(supplied, forKey: asset as NSString)
        entry(asset).revision += 1
        ArtworkTint.shared.prewarm(asset)
        let directory = directory
        Task.detached(priority: .utility) {
            if let directory, let data = supplied.jpegData(compressionQuality: 0.9), data.count < 8_000_000 {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(asset + ".jpg"), options: .atomic)
            }
        }
        return asset
    }
}
