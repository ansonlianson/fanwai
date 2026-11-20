import Foundation

struct MapCamera: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    func project(_ p: CGPoint) -> CGPoint { CGPoint(x: x + p.x * scale, y: y + p.y * scale) }
    mutating func zoom(by factor: CGFloat, at p: CGPoint) {
        let next = min(2.2, max(0.3, scale * factor))
        let ratio = next / scale
        x = p.x - (p.x - x) * ratio
        y = p.y - (p.y - y) * ratio
        scale = next
    }
}

/// A literal port of the authored expand(), pathTo(), setFocus() and fitTo().
/// Rendering interpolates toward these coordinates; committed old nodes never move.
struct RelationMapModel: Codable, Equatable {
    struct Node: Codable, Equatable, Identifiable {
        let id: String
        var position: CGPoint
        let via: String?
        let label: String?
        var expanded = false
    }
    struct Edge: Codable, Equatable, Identifiable {
        let from: String
        let to: String
        let label: String
        let meet: Bool
        var id: String { [from, to].sorted().joined(separator: "|") }
        func connects(_ a: String, _ b: String) -> Bool { (from == a && to == b) || (from == b && to == a) }
    }
    struct Expansion {
        var fresh: [String] = []
        var edges: [Edge] = []
        var meets: [Edge] = []
    }
    let root: String
    var nodes: [String: Node]
    var order: [String]
    var edges: [Edge] = []
    var focus: String
    var camera = MapCamera()
    var visits: [String]
    var pendingFocusFit: Bool?
    var plannedRelations: [String: [SeedGraph.Relation]]?
    var initialDiscoverySeeded: Bool?
    var revealedOwners: Set<String>?
    var userCollapsed: Set<String>?

    init(root: String) {
        self.root = root; focus = root; order = [root]; visits = [root]
        nodes = [root: Node(id: root, position: .zero, via: nil, label: nil)]
    }
    /// Metadata may resolve a provisional sleeve while the map is open. Reuse
    /// its position and camera; aliases must not create a second visible node.
    mutating func canonicalize(_ canonical: (String) -> String) {
        let canonicalRoot = canonical(root)
        func key(_ id: String) -> String { canonical(id) == canonicalRoot ? root : canonical(id) }
        guard order.contains(where: { key($0) != $0 }) else { return }
        var newOrder: [String] = [], chosen: [String: Node] = [:]
        for old in order {
            guard let node = nodes[old] else { continue }
            let id = key(old)
            if chosen[id] == nil { newOrder.append(id) }
            if chosen[id] == nil || old == focus && id != root {
                chosen[id] = Node(id: id, position: node.position, via: nil, label: node.label, expanded: node.expanded)
            }
        }
        var pairs = Set<String>(), remapped: [Edge] = []
        for edge in edges {
            let a = key(edge.from), b = key(edge.to), pair = [a, b].sorted().joined(separator: "|")
            guard a != b, chosen[a] != nil, chosen[b] != nil, pairs.insert(pair).inserted else { continue }
            remapped.append(.init(from: a, to: b, label: edge.label, meet: edge.meet))
        }
        // Restore a real shortest parent path after collapsing equivalent IDs.
        var reached: Set<String> = [root], queue = [root], cursor = 0
        while cursor < queue.count {
            let parent = queue[cursor]; cursor += 1
            for edge in remapped where edge.from == parent || edge.to == parent {
                let child = edge.from == parent ? edge.to : edge.from
                guard reached.insert(child).inserted, let node = chosen[child] else { continue }
                chosen[child] = Node(id: child, position: node.position, via: parent, label: node.label, expanded: node.expanded)
                queue.append(child)
            }
        }
        nodes = chosen; order = newOrder; edges = remapped; focus = key(focus)
        visits = visits.map(key).filter { nodes[$0] != nil }
        if let selection = plannedRelations {
            var plans: [String: [SeedGraph.Relation]] = [:], seen = Set<String>()
            for owner in selection.keys.sorted() {
                for relation in selection[owner] ?? [] {
                    let from = key(relation.from), to = key(relation.to), via = relation.via.map(key)
                    let pair = key(owner) + "|" + (via ?? from) + "|" + to
                    guard from != to, seen.insert(pair).inserted else { continue }
                    plans[key(owner), default: []].append(.init(from: from, to: to, label: relation.label, via: via))
                }
            }
            plannedRelations = plans
        }
        userCollapsed = userCollapsed.map { Set($0.map(key)) }
        revealedOwners = revealedOwners.map { Set($0.map(key)) }
    }
    /// One-time projection of already-known crate paths. A branch frozen by a
    /// previous deliberate fold stays folded, including trails from build20.
    mutating func seedKnownPaths(_ paths: [[String]], graph: SeedGraph) -> Expansion {
        guard initialDiscoverySeeded != true, !paths.isEmpty else { return Expansion() }
        var owners: [String] = [], targets: [String: Set<String>] = [:]
        for path in paths {
            for (owner, target) in zip(path, path.dropFirst()) {
                let legacyFold = nodes[owner]?.expanded == false && plannedRelations?[owner] != nil && revealedOwners?.contains(owner) != true
                if userCollapsed?.contains(owner) == true || legacyFold { break }
                if targets[owner] == nil { owners.append(owner) }
                targets[owner, default: []].insert(target)
            }
        }
        var result = Expansion()
        for owner in owners where nodes[owner] != nil {
            let all = plannedRelations?[owner] ?? graph.outgoing(from: owner)
            let selected = graph.outgoing(from: owner).filter { targets[owner]?.contains($0.to) == true }
            let expanded = nodes[owner]?.expanded == true
            if plannedRelations == nil { plannedRelations = [:] }
            plannedRelations?[owner] = selected; nodes[owner]?.expanded = false
            let next = expand(owner, graph: graph)
            plannedRelations?[owner] = all
            nodes[owner]?.expanded = expanded
            if !expanded {
                if revealedOwners == nil { revealedOwners = [] }
                revealedOwners?.insert(owner)
            }
            result.fresh += next.fresh; result.edges += next.edges; result.meets += next.meets
        }
        initialDiscoverySeeded = true
        return result
    }
    /// Old trails are presentation state, never authority for a deleted claim.
    /// Keep unaffected positions/camera; invalid tree branches can be reseeded
    /// from the corrected evidence graph instead of displaying stale edges.
    mutating func pruneInvalidEdges(keeping valid: Set<String>) {
        let invalid = edges.filter { !valid.contains($0.id) }
        var removed = Set<String>()
        for edge in invalid {
            if nodes[edge.to]?.via == edge.from { removed.insert(edge.to); removed.formUnion(descendants(of: edge.to)) }
            if nodes[edge.from]?.via == edge.to { removed.insert(edge.from); removed.formUnion(descendants(of: edge.from)) }
        }
        removed.remove(root)
        for id in removed { nodes[id] = nil; plannedRelations?[id] = nil }
        revealedOwners?.subtract(removed); userCollapsed?.subtract(removed)
        order.removeAll { removed.contains($0) }; visits.removeAll { removed.contains($0) }
        edges.removeAll { !valid.contains($0.id) || removed.contains($0.from) || removed.contains($0.to) }
        // Reconcile selection against current facts on the next real expansion.
        for id in order where plannedRelations?[id]?.contains(where: { relation in
            !valid.contains([relation.via ?? id, relation.to].sorted().joined(separator: "|"))
        }) == true { plannedRelations?[id] = nil; nodes[id]?.expanded = false }
        if nodes[focus] == nil { focus = root }
    }
    mutating func freezeSelection(_ id: String, graph: SeedGraph) {
        if plannedRelations?[id] == nil {
            if plannedRelations == nil { plannedRelations = [:] }
            plannedRelations?[id] = graph.outgoing(from: id)
        }
    }
    /// New relations arrived for a sleeve that was already opened: let the
    /// next `expand` add them. Everything already on the map stays where it is.
    mutating func reopen(_ id: String) {
        nodes[id]?.expanded = false
        plannedRelations?[id] = nil
    }
    func pendingRelations(_ id: String, graph: SeedGraph) -> [SeedGraph.Relation] {
        guard nodes[id]?.expanded != true else { return [] }
        var seen = Set<String>()
        return (plannedRelations?[id] ?? graph.outgoing(from: id)).filter { edge in
            let owner = edge.via ?? id
            let key = [owner, edge.to].sorted().joined(separator: "|")
            return owner != edge.to && seen.insert(key).inserted && !edges.contains { $0.connects(owner, edge.to) }
        }
    }
    func pending(_ id: String, graph: SeedGraph) -> Int { pendingRelations(id, graph: graph).count }
    func path(to id: String) -> [String] {
        var path: [String] = []; var cursor: String? = id
        while let current = cursor, let node = nodes[current] { path.insert(current, at: 0); cursor = node.via }
        return path
    }
    var focusPath: [String] { path(to: focus) }
    func onPath(_ edge: Edge) -> Bool {
        let path = focusPath
        guard let a = path.firstIndex(of: edge.from), let b = path.firstIndex(of: edge.to) else { return false }
        return abs(a - b) == 1
    }
    func nearFocus(_ id: String) -> Bool { id == focus || nodes[id]?.via == focus || focusPath.contains(id) }
    mutating func setFocus(_ id: String) {
        guard nodes[id] != nil else { return }
        focus = id
        if visits.last != id { visits.append(id) }
    }
    var focusNeighborhood: [String] {
        [focus] + order.filter { nodes[$0]?.via == focus } + (nodes[focus]?.via.map { [$0] } ?? [])
    }
    /// Everything opened from this node, and from those in turn.
    func descendants(of id: String) -> [String] {
        order.filter { other in
            guard other != id else { return false }
            var cursor = nodes[other]?.via
            while let current = cursor {
                if current == id { return true }
                cursor = nodes[current]?.via
            }
            return false
        }
    }
    /// The page's own work stays open: folding it would leave an empty map.
    func canCollapse(_ id: String) -> Bool { id != root && (nodes[id]?.expanded == true || revealedOwners?.contains(id) == true) && order.contains { nodes[$0]?.via == id } }
    /// Folds a node back: what it opened leaves the map, and it can be opened again later with the
    /// same relations in the same places.
    mutating func collapse(_ id: String) {
        guard nodes[id] != nil else { return }
        if userCollapsed == nil { userCollapsed = [] }
        userCollapsed?.insert(id); revealedOwners?.remove(id)
        let gone = Set(descendants(of: id))
        order.removeAll { gone.contains($0) }
        for key in gone { nodes[key] = nil }
        edges.removeAll { gone.contains($0.from) || gone.contains($0.to) || ($0.from == id && $0.meet) }
        nodes[id]?.expanded = false
        visits.removeAll { gone.contains($0) }
        if gone.contains(focus) { focus = id }
    }
    func fittedCamera(ids: [String], viewport: CGSize, available: CGRect? = nil) -> MapCamera {
        let points = ids.compactMap { nodes[$0]?.position }
        guard let first = points.first else { return camera }
        let x0 = points.map(\.x).min() ?? first.x, x1 = points.map(\.x).max() ?? first.x
        let y0 = points.map(\.y).min() ?? first.y, y1 = points.map(\.y).max() ?? first.y
        let area = available ?? CGRect(x: 16, y: 160, width: max(1, viewport.width-32), height: max(1, viewport.height-320))
        // Include the entire physical object and its name, not only its center.
        let k = min(max(1, area.width) / max(x1-x0+148, 1), max(1, area.height) / max(y1-y0+190, 1), 1.15)
        return MapCamera(x: area.midX - (x0+x1)/2*k,
                         y: area.midY - (y0+y1)/2*k - 15*k, scale: k)
    }
    mutating func expand(_ id: String, graph: SeedGraph) -> Expansion {
        guard let node = nodes[id], !node.expanded else { return Expansion() }
        userCollapsed?.remove(id); revealedOwners?.remove(id)
        freezeSelection(id, graph: graph)
        let relations = pendingRelations(id, graph: graph)
        nodes[id]?.expanded = true
        let fresh = relations.filter { nodes[$0.to] == nil }
        let meets = relations.filter { nodes[$0.to] != nil }
        let parent = node.via.flatMap { nodes[$0] }
        let base = parent.map { atan2(node.position.y-$0.position.y, node.position.x-$0.position.x) } ?? -.pi/2
        let count = fresh.count
        let radius: CGFloat = parent == nil ? 185 : count > 3 ? 215 : 195
        let spread = parent == nil ? CGFloat.pi*2 : min(.pi*1.25, 0.9*CGFloat(max(count-1, 0))+0.001)
        var targets: [String: CGPoint] = [:]
        for (i, edge) in fresh.enumerated() {
            let angle = parent == nil ? base + .pi*2*CGFloat(i)/CGFloat(count)+0.3
                : base-spread/2+(count > 1 ? spread*CGFloat(i)/CGFloat(count-1) : spread/2)
            nodes[edge.to] = Node(id: edge.to, position: node.position, via: edge.via ?? id, label: edge.label)
            order.append(edge.to)
            targets[edge.to] = CGPoint(x: node.position.x+cos(angle)*radius, y: node.position.y+sin(angle)*radius)
        }
        for _ in 0..<260 {
            for edge in fresh {
                let aID = edge.to
                for bID in order where bID != aID {
                    var a = targets[aID]!
                    let b = targets[bID] ?? nodes[bID]!.position
                    let dx = a.x-b.x, dy = a.y-b.y
                    let d = max(hypot(dx, dy*1.2), 1e-9)
                    if d < 138 {
                        let f = (138-d)/d * (targets[bID] != nil ? 0.5 : 1)
                        a.x += dx*f*0.5; a.y += dy*f*0.5; targets[aID] = a
                    }
                }
                var a = targets[aID]!
                let dx = a.x-node.position.x, dy = a.y-node.position.y
                let d = max(hypot(dx, dy), 1e-9), f = (radius-d)/d*0.03
                a.x += dx*f; a.y += dy*f; targets[aID] = a
            }
        }
        func crowded(_ id: String, _ p: CGPoint) -> Bool {
            order.contains { other in
                guard other != id else { return false }
                let q = targets[other] ?? nodes[other]!.position
                return hypot(p.x-q.x, (p.y-q.y)*1.2) < 125
            }
        }
        for edge in fresh {
            let key = edge.to
            var a = targets[key]!, k = 0
            let ux = a.x-node.position.x, uy = a.y-node.position.y, length = max(hypot(ux, uy), 1e-9)
            while crowded(key, a), k < 24 {
                a.x += ux/length*18; a.y += uy/length*18; k += 1; targets[key] = a
            }
            if crowded(key, a) {
                let initialAngle = atan2(uy, ux)
                for step in 1..<14 {
                    if !crowded(key, a) { break }
                    let angle = initialAngle + (step % 2 == 1 ? 1 : -1)*ceil(CGFloat(step)/2)*0.22
                    let r = length+CGFloat(k)*18
                    a = CGPoint(x: node.position.x+cos(angle)*r, y: node.position.y+sin(angle)*r)
                    targets[key] = a
                }
            }
            targets[key] = a
        }
        for edge in fresh { nodes[edge.to]?.position = targets[edge.to]! }
        let newEdges = fresh.map { Edge(from: $0.via ?? id, to: $0.to, label: $0.label, meet: false) }
        let meetEdges = meets.map { Edge(from: $0.via ?? id, to: $0.to, label: $0.label, meet: true) }
        edges += newEdges + meetEdges
        return Expansion(fresh: fresh.map(\.to), edges: newEdges, meets: meetEdges)
    }
}

/// Separate from legacy canvas checkpoints; P4 can present these saved trails.
@MainActor final class RelationTrailStore {
    struct Entry: Identifiable {
        let map: RelationMapModel
        let updatedAt: Date
        var id: String { map.root }
    }
    let defaults: UserDefaults
    private let trailKeyPrefix: String
    private let dateKeyPrefix: String
    /// An empty namespace selects established trails; review keys live outside
    /// that prefix so an old binary cannot enumerate them as normal history.
    init(defaults: UserDefaults? = nil, cacheNamespace: String? = nil) {
        let namespace = cacheNamespace ?? ("")
        trailKeyPrefix = namespace.isEmpty ? "redesign.graphTrail." : "redesign.researchGraphTrail." + namespace + "."
        dateKeyPrefix = namespace.isEmpty ? "redesign.graphTrailDate." : "redesign.researchGraphTrailDate." + namespace + "."
        if let defaults { self.defaults = defaults; return }
        let flag = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ui-state=") }
        self.defaults = flag.flatMap { UserDefaults(suiteName: "Pianwai.UIReview." + $0.dropFirst(11)) } ?? .standard
    }
    func load(root: String) -> RelationMapModel? {
        guard let data = defaults.data(forKey: trailKeyPrefix + root) else { return nil }
        return try? JSONDecoder().decode(RelationMapModel.self, from: data)
    }
    func save(_ state: RelationMapModel) {
        guard load(root: state.root) != state else { return }
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: trailKeyPrefix + state.root)
            defaults.set(Date(), forKey: dateKeyPrefix + state.root)
        }
    }
    /// The pages that have a saved trail, without decoding the trails.
    func roots() -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(trailKeyPrefix) }.map { String($0.dropFirst(trailKeyPrefix.count)) }
    }
    func entries() -> [Entry] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(trailKeyPrefix) }
            .compactMap { key in
                let root = String(key.dropFirst(trailKeyPrefix.count))
                guard let map = load(root: root), map.nodes.count > 1 else { return nil }
                return Entry(map: map, updatedAt: defaults.object(forKey: dateKeyPrefix + root) as? Date ?? .distantPast)
            }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func remove(root: String) {
        defaults.removeObject(forKey: trailKeyPrefix + root)
        defaults.removeObject(forKey: dateKeyPrefix + root)
    }
}
