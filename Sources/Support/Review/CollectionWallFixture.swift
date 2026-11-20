#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Visual review only. Requires an isolated app preferences suite and explicit
/// flags; these records and graph visits are never installed for a real user.
@MainActor enum CollectionWallFixture {
    static var requested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-isolate-data") && args.contains(where: { $0.hasPrefix("--ui-state=") })
            && args.contains(where: { ["--wallState=full", "--wallState=empty"].contains($0) })
    }
    static func install(in library: Library) {
        guard requested, ProcessInfo.processInfo.arguments.contains("--ui-reset") else { return }
        library.listenLater = []; library.later = []; library.saved = []
        let store = RelationTrailStore()
        for root in store.roots() { store.remove(root: root) }
        guard ProcessInfo.processInfo.arguments.contains("--wallState=full") else { library.persist(); return }
        for id in ["jane", "olk", "pool"] {
            if let entity = SeedNowContent.entity(id) { _ = try? SeedLibraryBridge.install(entity, into: library) }
        }
        // 11-20: music is 收藏 (starred), not a 稍后听 queue.
        library.saved = [SeedLibraryBridge.workID("jane"), SeedLibraryBridge.workID("olk"), .distance, .pool].map { library.catalog.canonicalID(for: $0) }
        let wishes = ["film", "manga", "koe", "janemv", "devil"]
        for id in wishes { if let entity = SeedNowContent.entity(id) { try? SeedLibraryBridge.save(entity, into: library) } }
        library.later = wishes.map { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0)) }
        for (id, origin) in zip(wishes, ["pool", "film", "ushio", "jane", "ushio"]) {
            library.recordCollectionOrigin(SeedLibraryBridge.workID(id), from: origin)
        }
        var map = RelationMapModel(root: "pool")
        for id in ["pool", "film", "jane", "utada", "olk", "olkmv"] { _ = map.expand(id, graph: .bundled); map.setFocus(id) }
        map.setFocus("olkmv")
        map.camera = map.fittedCamera(ids: map.focusNeighborhood, viewport: CGSize(width: 402, height: 874))
        store.save(map)
        library.persist()
    }
}
#endif
