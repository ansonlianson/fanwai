import Foundation

/// BFS discovers each reachable identity once. Scores are recomputed after
/// each selection so story availability and type variety influence the order.
struct NextStationSequence {
    private struct Candidate {
        let entity: SeedGraph.Entity
        let relation: SeedGraph.Relation
        let parent: SeedGraph.Entity
        let path: [String]
        let order: Int
        let priority: Int
    }
    static func make(graph: SeedGraph, root: String, storyIDs: Set<String> = SeedNowContent.rankedStoryIDs, excluding appeared: Set<String> = []) -> [NowStation] {
        guard let origin = graph[root] else { return [] }
        var queue: [(id: String, path: [String])] = [(root, [root])]
        var visited: Set<String> = [root]
        var cursor = 0
        var candidates: [Candidate] = []
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            guard let parent = graph[current.id] else { continue }
            for relation in graph.relations where relation.from == current.id || relation.to == current.id {
                let target = relation.from == current.id ? relation.to : relation.from
                guard visited.insert(target).inserted, let entity = graph[target] else { continue }
                let path = current.path + [target]
                queue.append((target, path))
                guard !appeared.contains(target) else { continue }
                candidates.append(Candidate(entity: entity, relation: relation, parent: parent,
                    path: path, order: candidates.count, priority: priority(entity, parent: parent, edge: relation)))
            }
        }
        var result: [NowStation] = []
        var previous = origin
        while !candidates.isEmpty {
            func score(_ candidate: Candidate) -> Int {
                candidate.priority + (storyIDs.contains(candidate.entity.id) ? 2 : 0)
                    + (candidate.entity.kind.objectKind != previous.kind.objectKind ? 1 : 0)
            }
            let ranked = candidates.indices.sorted {
                let a = score(candidates[$0]), b = score(candidates[$1])
                return a == b ? candidates[$0].order < candidates[$1].order : a > b
            }
            // A third consecutive song is postponed when any different kind is
            // available; this is the explicit diversity requirement in §4.2.
            let lastTwoAreSongs = result.count >= 2 && result.suffix(2).allSatisfy { $0.entity.kind == .song }
            let chosen = lastTwoAreSongs
                ? (ranked.first { candidates[$0].entity.kind != .song } ?? ranked[0]) : ranked[0]
            let candidate = candidates.remove(at: chosen)
            result.append(NowStation(entity: candidate.entity,
                reason: reason(candidate, previous: previous, graph: graph), path: candidate.path))
            previous = candidate.entity
        }
        return result
    }
    private static func priority(_ entity: SeedGraph.Entity, parent: SeedGraph.Entity, edge: SeedGraph.Relation) -> Int {
        if entity.kind.isMusic && [.film, .tv].contains(parent.kind) { return 5 }
        if entity.kind == .person { return edge.label == "合作" ? 1 : 4 }
        if parent.kind == .person || edge.label == "MV" { return 3 }
        if ["原作", "改编为", "改编自", "钢琴改编", "动画化"].contains(edge.label) { return 2 }
        return 1
    }
    private static func reason(_ candidate: Candidate, previous: SeedGraph.Entity, graph: SeedGraph) -> String {
        let edge = candidate.relation
        if candidate.entity.kind.isMusic && [.film, .tv].contains(candidate.parent.kind) {
            return "同一部\(candidate.parent.kind == .film ? "电影" : "剧集")的\(edge.label)"
        }
        let connecting = graph.relations.first {
            ($0.from == previous.id && $0.to == candidate.entity.id) || ($0.to == previous.id && $0.from == candidate.entity.id)
        }
        let label = connecting?.label ?? edge.label
        if candidate.entity.kind == .person {
            if ["演唱", "词曲演唱"].contains(label) { return "同一位歌手" }
            if ["作曲", "配乐"].contains(label) { return "同一位作曲家" }
            if label == "导演" || label == "总导演" { return "同一位导演" }
            if label == "作者" { return "同一位作者" }
            return "同一位创作者"
        }
        if label == "MV" { return "同一首歌的 MV" }
        if candidate.parent.kind == .person {
            return ["配乐", "作曲"].contains(label) ? "同一位作曲家的作品" : "同一位创作者的作品"
        }
        switch label {
        case "配乐出自": return "这首配乐出自的电影"
        case "收录于": return "这首歌收录的专辑"
        case "钢琴改编": return "同一首曲子的钢琴改编"
        case "改编为", "改编自", "动画化": return "同一部原作的改编"
        default: return "\(candidate.parent.title)的\(label)"
        }
    }
}
