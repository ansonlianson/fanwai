import Foundation

enum CrateWindow {
    struct Page: Identifiable {
        let items: [CrateItem]
        let start: Int
        var id: String { items.first!.id }
    }
    /// Balanced windows keep 3–5 exposed objects when there are more than five,
    /// rather than leaving a final page with a single inaccessible sliver.
    static func pages(_ items: [CrateItem]) -> [Page] {
        guard !items.isEmpty else { return [] }
        let count = (items.count + 4) / 5
        let small = items.count / count, extra = items.count % count
        var start = 0
        return (0..<count).map { index in
            let size = small + (index < extra ? 1 : 0)
            defer { start += size }
            return Page(items: Array(items[start..<start+size]), start: start)
        }
    }
    static func slot(of id: String, items: [CrateItem]) -> Int {
        pages(items).first { $0.items.contains { $0.id == id } }?.items.firstIndex { $0.id == id } ?? 0
    }
}

enum CrateWindowPosition {
    static func read(entityID: String, items: [CrateItem], defaults: UserDefaults) -> String? {
        let saved = defaults.string(forKey: "redesign.crateWindow." + entityID)
        let pages = CrateWindow.pages(items)
        return pages.first { $0.items.contains { $0.id == saved } }?.id ?? pages.first?.id
    }
    static func save(_ anchor: String?, entityID: String, defaults: UserDefaults) {
        defaults.set(anchor, forKey: "redesign.crateWindow." + entityID)
    }
}

enum CrateWindowFixture {
    static func items(for id: String) -> [CrateItem]? {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard id == "pool", args.contains("--ui-isolate-data") else { return nil }
        if args.contains("--ui-crate-prototype") {
            // Authored design content for an exact v3 comparison, isolated from
            // the public catalogue and unavailable on physical devices.
            let album = SeedGraph.Entity(id: "prototype:reze-album", kind: .album,
                title: "REZE ARC 原声带", subtitle: "牛尾宪辅 · 2025", artworkAsset: "pool",
                fallbackGlyph: nil, hook: "", actions: [])
            return [(album, "收录于"), (SeedGraph.bundled["ushio"]!, "作曲"),
                    (SeedGraph.bundled["film"]!, "出自"), (SeedGraph.bundled["manga"]!, "电影原作"),
                    (SeedGraph.bundled["jane"]!, "同一部电影")].map {
                .init(entity: $0.0, relation: $0.1, path: [id, $0.0.id])
            }
        }
        guard args.contains("--ui-crate-many") else { return nil }
        return SeedGraph.bundled.entities.filter { $0.id != id }.prefix(14).map {
            .init(entity: $0, relation: "关联作品", path: [id, $0.id])
        }
        #else
        return nil
        #endif
    }
}
