import Foundation

struct NetworkPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}
struct NetworkNode: Codable, Equatable, Identifiable, Sendable {
    var id: WorkID
    var position: NetworkPoint
    var depth: Int
    /// The verified edge that first brought this object into the map. Optional
    /// so maps saved before parent tracking still decode without inventing a path.
    var parent: WorkID? = nil
}
/// Persisted exploration, not a paged list. Existing positions never change on expansion.
struct RelationNetworkState: Codable, Equatable, Sendable {
    var root: WorkID
    var focus: WorkID
    var nodes: [NetworkNode]
    var linkIDs: [String] = []
    var expanded: [WorkID] = []
    var trail: [WorkID]
    var camera = NetworkPoint(x: 0, y: 0)
    var scale: Double = 0.9

    init(root: WorkID) {
        self.root = root; focus = root; trail = [root]
        nodes = [NetworkNode(id: root, position: NetworkPoint(x: 0, y: 0), depth: 0)]
    }
    @discardableResult mutating func expand(_ id: WorkID, edges: [RelationEdge]) -> Int {
        guard let origin = nodes.first(where: { $0.id == id }) else { return 0 }
        focusNode(id, edges: edges)
        if !expanded.contains(id) { expanded.append(id) }
        let oldIDs = Set(nodes.map(\.id))
        let unique = edges.filter { $0.from == id || $0.to == id }
        let newIDs = unique.map { $0.other(than: id) }.reduce(into: [WorkID]()) { result, item in
            if !oldIDs.contains(item), !result.contains(item) { result.append(item) }
        }
        let outward = atan2(origin.position.y, origin.position.x)
        for (index, target) in newIDs.enumerated() {
            let initialAngles = [-2.3, -0.84, 2.3, 0.84]
            let angle = id == root && index < 4 ? initialAngles[index]
                : outward + (Double(index) - Double(newIDs.count - 1) / 2) * min(0.68, 2.5 / Double(max(1, newIDs.count - 1)))
            var point = origin.position
            // Search deterministic outer rings. Every card reserves a full label rectangle.
            search: for ring in 0..<80 {
                for step in 0..<32 {
                    let delta = Double((step + 1) / 2) * 0.19 * (step.isMultiple(of: 2) ? 1 : -1)
                    let radius = (id == root ? 206.0 : 225.0) + Double(ring) * 46
                    point = NetworkPoint(x: origin.position.x + cos(angle + delta) * radius,
                                         y: origin.position.y + sin(angle + delta) * radius)
                    if nodes.allSatisfy({ abs($0.position.x - point.x) >= 146 || abs($0.position.y - point.y) >= 152 }) { break search }
                }
            }
            nodes.append(NetworkNode(id: target, position: point, depth: origin.depth + 1, parent: id))
        }
        var shared = 0
        for edge in unique where !linkIDs.contains(edge.id) {
            if oldIDs.contains(edge.other(than: id)) && edge.other(than: id) != root { shared += 1 }
            linkIDs.append(edge.id)
        }
        return shared
    }

    /// Focus is independent of expansion and camera movement. Breadcrumbs call
    /// this without edges; expansion supplies verified edges from that branch.
    @discardableResult mutating func focusNode(_ id: WorkID, edges: [RelationEdge] = []) -> Bool {
        guard nodes.contains(where: { $0.id == id }) else { return false }
        if let prior = trail.firstIndex(of: id) {
            trail = Array(trail.prefix(prior + 1))
        } else if let previous = trail.last, edges.contains(where: {
            ($0.from == previous && $0.to == id) || ($0.to == previous && $0.from == id)
        }) {
            trail.append(id)
        } else {
            trail = firstDiscoveryPath(to: id)
        }
        focus = id
        return true
    }

    private func firstDiscoveryPath(to id: WorkID) -> [WorkID] {
        var reversed: [WorkID] = []
        var visited = Set<WorkID>()
        var current = id
        while visited.insert(current).inserted, let node = nodes.first(where: { $0.id == current }) {
            reversed.append(current)
            if current == root { return Array(reversed.reversed()) }
            guard let parent = node.parent else { break }
            current = parent
        }
        // A historical or damaged map may not carry a provable path. One label
        // is honest; inserting a chevron from the root would assert a false edge.
        return [id]
    }

    mutating func fit(width: Double, height: Double) {
        guard let minX = nodes.map(\.position.x).min(), let maxX = nodes.map(\.position.x).max(),
              let minY = nodes.map(\.position.y).min(), let maxY = nodes.map(\.position.y).max() else { return }
        camera = NetworkPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        scale = min(1.12, max(0.08, min((width - 32) / (maxX - minX + 150), (height - 36) / (maxY - minY + 160))))
    }
}
