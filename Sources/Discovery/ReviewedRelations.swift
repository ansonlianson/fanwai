import Foundation

/// Individually checked primary-source edges, never a publisher-name allowlist.
/// Seed IDs carry their exact catalog identity through CatalogStore aliases.
enum ReviewedRelations {
    struct Entry {
        let from: String
        let to: String
        let predicate: RelationKind
        let label: String
        let inverse: String
        let source: Source
    }
    // Rechecked 2026-11-10: the official release explicitly names this song
    // as the Reze film's ending theme. See P24's source receipt.
    static let entries: [Entry] = [
        .init(from: "jane", to: "film", predicate: .endingOf,
              label: "片尾曲来自", inverse: "片尾曲", source: .jane)
    ]

    @MainActor static func contains(_ edge: RelationEdge, catalog: CatalogStore) -> Bool {
        entries.contains {
            catalog.canonicalID(for: edge.from) == catalog.canonicalID(for: SeedLibraryBridge.workID($0.from))
                && catalog.canonicalID(for: edge.to) == catalog.canonicalID(for: SeedLibraryBridge.workID($0.to))
                && edge.predicate == $0.predicate && edge.source.url == $0.source.url
        }
    }
    static var browsingEdges: [SeedGraph.Relation] {
        entries.flatMap { [
            .init(from: $0.from, to: $0.to, label: $0.label),
            .init(from: $0.to, to: $0.from, label: $0.inverse)
        ] }
    }
}
