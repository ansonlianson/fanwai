import Foundation

/// What the catalogue keeps on disk (anson 2026-11-18: the catalogue must slim down and stay small).
///
/// Most of a long-used catalogue was search residue: every Apple Music song, album and artist a
/// search ever returned (his phone, 11-18: 8,311 of 10,612 entries). Those stay in memory for the
/// visit, so search and the version picker stay quick, but only what the app still points at is
/// written:
/// - everything that is not an Apple Music listing (cards, database entries, editorial pages);
/// - Apple Music entries a page's research or a database relation links to;
/// - Apple Music entries the user's own lists point at (收藏、稍后听、最近探索、播放记录、搜索记录、关系图);
/// - the album and the artists of any kept song or album.
/// The next launch reads the slim file; nothing the user kept, opened or researched is dropped.
enum CatalogRetention {
    static func isStoreListing(_ id: WorkID) -> Bool { id.rawValue.hasPrefix("apple:") }

    nonisolated static func durable(works: [WorkID: Work], edges: [RelationEdge], aliases: [WorkID: WorkID],
                                    retained: Set<WorkID>) -> (works: [WorkID: Work], edges: [RelationEdge]) {
        func resolve(_ id: WorkID) -> WorkID {
            var current = id, seen = Set<WorkID>()
            while let next = aliases[current], next != current, seen.insert(current).inserted { current = next }
            return current
        }
        var keep = Set<WorkID>()
        for id in works.keys where !isStoreListing(id) { keep.insert(id) }
        for id in retained { keep.insert(resolve(id)) }
        for edge in edges {
            let from = resolve(edge.from), to = resolve(edge.to)
            if let root = edge.researchRoot {
                keep.insert(from); keep.insert(to); keep.insert(resolve(root))
            } else if !(isStoreListing(from) && isStoreListing(to)) {
                keep.insert(from); keep.insert(to)
            }
        }
        // A kept song brings its album and artists; a kept album its artists.
        var frontier = Array(keep)
        for _ in 0..<2 {
            var next: [WorkID] = []
            for id in frontier {
                guard let work = works[id] else { continue }
                let linked = (work.albumID.map { [$0] } ?? []) + work.creatorIDs
                for item in linked.map(resolve) where keep.insert(item).inserted { next.append(item) }
            }
            frontier = next
        }
        let kept = works.filter { keep.contains($0.key) }
        let keptEdges = edges.filter { edge in
            [edge.from, edge.to].allSatisfy { id in
                let target = resolve(id)
                return !isStoreListing(target) || kept[target] != nil
            }
        }
        return (kept, keptEdges)
    }
}
