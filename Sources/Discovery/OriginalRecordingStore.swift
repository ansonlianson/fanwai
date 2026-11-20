import Foundation

/// Opens only the viewed recording. Successful and empty lookups are cached;
/// no library-wide scan, recursive prefetch or automatic paid request exists here.
@MainActor final class OriginalRecordingStore {
    static let shared = OriginalRecordingStore()
    struct Receipt: Codable, Sendable {
        let seconds: Double
        let catalogRequests: Int
        let sourceRequests: Int
        let found: Bool
        let transientFailure: Bool
    }
    private struct Saved: Codable, Sendable {
        let key: String
        let signature: String
        let date: Date
        let snapshot: CatalogSnapshot
        let receipt: Receipt
    }
    private var saved: [String: Saved] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let directory: URL?
    private let lookup: OriginalRecordingLookup
    private(set) var receipts: [String: Receipt] = [:]
    init(directory: URL? = PianwaiRuntime.cacheDirectory("OriginalRecordings-v1"),
         lookup: OriginalRecordingLookup = .init(catalog: ITunesCatalogService())) {
        self.directory = directory; self.lookup = lookup
    }

    func schedule(_ subject: LeadSubject, library: Library, sourceURL: String?,
                  installed: @escaping @MainActor (CatalogSnapshot) -> Void) {
        guard subject.kind == .song, RecordingVersion.isFirstTake(subject.title),
              tasks[subject.id] == nil, tasks.count < 2 else { return }
        let root = library.catalog.canonicalID(for: SeedLibraryBridge.workID(subject.id))
        if library.catalog.relations(touching: root).contains(where: {
            $0.from == root && [.coverOf].contains($0.predicate)
                && library.catalog.work($0.to).catalogRecordingID != nil
                && !RecordingVersion.isDerivative(library.catalog.work($0.to).title)
        }) { return }
        let topic = ResearchTopic(id: subject.id, title: subject.title, creator: subject.creator,
            album: subject.album.isEmpty ? subject.identity?.releaseTitle ?? subject.identity?.edition ?? "" : subject.album,
            layer: subject.identity?.layer.rawValue ?? "recording", canonicalTitle: subject.identity?.canonicalTitle,
            catalogue: subject.identity?.catalogue, movement: subject.identity?.movement)
        let country = library.country
        let key = DiscoveryCore.digest(["first-take-v1", topic.key, country])
        let file = directory?.appendingPathComponent(key + ".json")
        let materials = ResearchMaterialStore(directory: PianwaiRuntime.cacheDirectory("FirstTakeMaterials-v1"))
        tasks[subject.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[subject.id] = nil }
            let existing = self.saved[key]
            let input = await Task.detached(priority: .utility) {
                let sources = materials.read(topic)?.packet.sources ?? []
                let cached = existing ?? file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
                let signature = DiscoveryCore.digest([sourceURL ?? ""] + sources.map { $0.url + $0.text })
                return (sources, cached, signature)
            }.value
            let signature = input.2
            if let cached = input.1, cached.key == key, cached.signature == signature,
               Date().timeIntervalSince(cached.date) >= 0,
               Date().timeIntervalSince(cached.date) < (cached.receipt.transientFailure ? 900 : cached.receipt.found ? 7 * 86400 : 86400) {
                self.saved[key] = cached; self.receipts[subject.id] = cached.receipt
                if cached.receipt.found { installed(cached.snapshot) }
                return
            }
            let start = Date(), lookup = self.lookup
            // A slow optional card is cancelled without holding the main lookup or page open.
            let result = await withTaskGroup(of: OriginalRecordingLookup.Result.self) { group in
                group.addTask { await lookup.resolve(topic: topic, country: country, sources: input.0, sourceURL: sourceURL) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return .init(transientFailure: true)
                }
                var result = await group.next() ?? .init(transientFailure: true)
                group.cancelAll()
                // A timeout still incurred any requests already sent. Keep those
                // counts while discarding a late optional answer.
                for await tail in group {
                    result.catalogRequests = max(result.catalogRequests, tail.catalogRequests)
                    result.sourceRequests = max(result.sourceRequests, tail.sourceRequests)
                }
                return result
            }
            guard !Task.isCancelled else { return }
            let receipt = Receipt(seconds: Date().timeIntervalSince(start), catalogRequests: result.catalogRequests,
                sourceRequests: result.sourceRequests, found: !result.snapshot.relations.isEmpty,
                transientFailure: result.transientFailure)
            self.receipts[subject.id] = receipt
            let entry = Saved(key: key, signature: signature, date: Date(), snapshot: result.snapshot, receipt: receipt)
            self.saved[key] = entry
            if receipt.found { installed(result.snapshot) }
            if let file { await Task.detached(priority: .utility) {
                guard let bytes = try? JSONEncoder().encode(entry) else { return }
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? bytes.write(to: file, options: .atomic)
            }.value }
        }
    }

    func wait(for id: String) async { await tasks[id]?.value }
}
