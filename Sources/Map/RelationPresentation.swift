import Foundation

extension Relations {
    /// One object per destination. A precise editorial credit takes precedence
    /// over a generic catalog artist credit; all source edges remain in storage.
    static func displayEdges(for id: WorkID) -> [RelationEdge] {
        var result: [RelationEdge] = []
        var positions: [WorkID: Int] = [:]
        let all = forEntity(id)
        // Let a different music name reveal its creator before a long album list.
        // On a song, show discoveries before basic album/artist metadata.
        // Stable ordering within each group keeps map and list consistent.
        let discoveryKinds: Set<RelationKind> = [.endingOf, .soundtrackOf, .themeMusic, .musicVideoOf, .adaptedFrom, .arrangedBy, .songContext]
        let isSong = id.work.isSong
        let ordered = all.enumerated().sorted { lhs, rhs in
            func priority(_ edge: RelationEdge) -> Int {
                if edge.predicate == .artistIdentity { return 0 }
                if isSong && discoveryKinds.contains(edge.predicate) { return 1 }
                return 2
            }
            let a = priority(lhs.element), b = priority(rhs.element)
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
        for edge in ordered {
            let target = edge.other(than: id)
            if let index = positions[target] {
                if result[index].predicate == .performedBy && edge.predicate != .performedBy {
                    result[index] = edge
                }
            } else {
                positions[target] = result.count
                result.append(edge)
            }
        }
        return result
    }
}
