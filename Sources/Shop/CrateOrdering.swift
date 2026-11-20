import Foundation

/// Orders an already accepted inventory. It never adds candidates or facts.
@MainActor enum CrateOrdering {
    static func ordered(_ items: [CrateItem], from entityID: String, library: Library) -> [CrateItem] {
        let catalog = library.catalog
        let root = catalog.canonicalID(for: SeedLibraryBridge.workID(entityID))
        let saved = Set(catalog.canonicalIDs(library.saved + library.listenLater + library.later
            + library.listenedIDs + library.watchedIDs))
        var shared = Set<WorkID>()
        for edge in catalog.edges {
            guard let owner = edge.researchRoot, catalog.canonicalID(for: owner) != root else { continue }
            shared.insert(catalog.canonicalID(for: edge.from))
            shared.insert(catalog.canonicalID(for: edge.to))
        }
        let events = Dictionary(grouping: library.crateExploration.interests) {
            catalog.canonicalID(for: SeedLibraryBridge.workID($0.entityID))
        }
        func history(_ item: CrateItem) -> [InterestEvent] {
            events[catalog.canonicalID(for: SeedLibraryBridge.workID(item.id))] ?? []
        }
        func tier(_ item: CrateItem) -> Int {
            let id = catalog.canonicalID(for: SeedLibraryBridge.workID(item.id))
            return saved.contains(id) ? 0 : shared.contains(id) ? 1 : 2
        }
        return items.enumerated().sorted {
            let a = tier($0.element), b = tier($1.element)
            if a != b { return a < b }
            let ah = history($0.element), bh = history($1.element)
            if ah.count != bh.count { return ah.count > bh.count }
            let al = ah.map(\.at).max() ?? .distantPast, bl = bh.map(\.at).max() ?? .distantPast
            return al != bl ? al > bl : $0.offset < $1.offset
        }.map(\.element)
    }
}
