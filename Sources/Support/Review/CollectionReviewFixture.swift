#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Visual review of 收藏 in chosen states (anson 2026-11-20: 「能给我看看他的不同情况的样式吗」).
/// Isolated data only: `--ui-isolate-data --ui-reset --ui-state=<name> --ui-collection-review=<spec.json>`.
/// The spec names works in a copy of a real catalogue file and says which list each one goes in;
/// nothing here reads or writes a reader's own data.
@MainActor enum CollectionReviewFixture {
    struct Spec: Decodable {
        /// A catalogue file (`catalog-v2.json`) to take the named works from.
        var catalog: String?
        /// A folder of observed covers (`ObservedArtwork`); only the covers of the named works are copied.
        var artwork: String?
        var platform: String?
        var listenLater: [String]?
        var wish: [String]?
        var watched: [String]?
        var listened: [String]?
        var origins: [String: String]?
        /// Songs in 收藏 (the starred list).
        var saved: [String]?
        /// A preferences file to take the starred songs' relation maps from.
        var trails: String?
    }
    private struct Lossy: Decodable {
        let work: Work?
        init(from decoder: Decoder) throws { work = try? Work(from: decoder) }
    }
    private struct CatalogFile: Decodable { let works: [Lossy] }

    static var spec: Spec? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains("--ui-reset"),
              let raw = args.first(where: { $0.hasPrefix("--ui-collection-review=") }),
              let data = FileManager.default.contents(atPath: String(raw.dropFirst("--ui-collection-review=".count))) else { return nil }
        return try? JSONDecoder().decode(Spec.self, from: data)
    }
    private static var logURL: URL? {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-collection-review=") })
            .map { URL(fileURLWithPath: String($0.dropFirst("--ui-collection-review=".count)) + ".log") }
    }

    /// Every work on the starred songs' maps, so the maps open with their cards.
    private static func trailNodes(_ spec: Spec) -> [String] {
        guard let path = spec.trails, let prefs = NSDictionary(contentsOfFile: path) else { return [] }
        return (spec.saved ?? []).flatMap { id -> [String] in
            guard let data = prefs["redesign.graphTrail." + id] as? Data,
                  let map = try? JSONDecoder().decode(RelationMapModel.self, from: data) else { return [] }
            return Array(map.nodes.keys)
        }
    }

    static func install(_ spec: Spec, in library: Library) {
        var log: [String] = []
        defer { if let logURL { try? log.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8) } }
        let named = (spec.listenLater ?? []) + (spec.wish ?? []) + (spec.watched ?? []) + (spec.listened ?? []) + (spec.saved ?? [])
            + Array((spec.origins ?? [:]).values) + trailNodes(spec)
        if let path = spec.catalog, let data = FileManager.default.contents(atPath: path) {
            do {
                let file = try JSONDecoder().decode(CatalogFile.self, from: data)
                let all = Dictionary(file.works.compactMap(\.work).map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
                // A song arrives with its album and its artists, as the store gives them.
                var wanted = Set(named)
                for id in named { if let work = all[id] { wanted.formUnion([work.linkedAlbumID?.rawValue].compactMap { $0 } + (work.linkedCreatorIDs ?? []).map(\.rawValue)) } }
                let works = wanted.compactMap { all[$0] }
                log.append("decoded \(file.works.count), readable \(all.count), named \(works.count)/\(wanted.count)")
                do { try library.catalog.merge(.init(works: works, relations: [])) }
                catch {
                    log.append("together: \(error)")
                    for work in works {
                        do { try library.catalog.merge(.init(works: [work], relations: [])) }
                        catch { log.append("merge \(work.id.rawValue): \(error)") }
                    }
                }
                if let source = spec.artwork, let target = PianwaiRuntime.applicationDirectory("ObservedArtwork") {
                    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    for work in works where work.art.hasPrefix("observed-cover-") {
                        let from = URL(fileURLWithPath: source).appendingPathComponent(work.art + ".jpg")
                        try? FileManager.default.copyItem(at: from, to: target.appendingPathComponent(work.art + ".jpg"))
                    }
                }
            } catch { log.append("catalogue: \(error)") }
        }
        library.playbackPlatform = PlaybackPlatform(rawValue: spec.platform ?? "apple") ?? .apple
        func ids(_ raw: [String]?) -> [WorkID] { (raw ?? []).compactMap { WorkID(rawValue: $0) }.map { library.catalog.canonicalID(for: $0) } }
        // Finished songs pass through 稍后听 the way a played queue does; the newest ends up first.
        library.listenLater = Array(ids(spec.listened).reversed()) + ids(spec.listenLater)
        for id in ids(spec.listened).reversed() { library.markListened(id) }
        for id in (ids(spec.wish) + ids(spec.watched)).reversed() { library.toggleLater(id) }
        for id in ids(spec.watched).reversed() {
            if let entry = library.watchLaterEntry(for: id) { library.markWatchLaterEntryWatched(entry.id) }
        }
        for (id, origin) in spec.origins ?? [:] {
            if let work = WorkID(rawValue: id) { library.recordCollectionOrigin(work, from: origin) }
        }
        library.saved = ids(spec.saved)
        if let path = spec.trails, let prefs = NSDictionary(contentsOfFile: path) {
            let store = RelationTrailStore()
            for id in spec.saved ?? [] {
                if let data = prefs["redesign.graphTrail." + id] as? Data { store.defaults.set(data, forKey: "redesign.graphTrail." + id) }
            }
        }
        log.append("listenLater \(library.listenLater.count) wish \(library.watchLaterEntries.count) listened \(library.listenedIDs.count) watched \(library.watchedIDs.count)")
        for id in library.listenLater + library.watchLaterEntries.map(\.workID) {
            log.append("\(id.rawValue) → \(library.catalog.works[id] == nil ? "MISSING" : library.catalog.work(id).kind + " " + library.catalog.work(id).title)")
        }
        library.persist()
    }
}
#endif
