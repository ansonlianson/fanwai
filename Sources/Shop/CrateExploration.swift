import Foundation
import Observation

struct CrateItem: Identifiable {
    let entity: SeedGraph.Entity
    let relation: String
    let path: [String]
    var hasStory = false
    /// One sentence: why this is worth pulling out. Shown on the crate's index card.
    var note = ""
    var id: String { entity.id }
}

enum CrateInventory {
    static func items(for id: String) -> [CrateItem] {
        if let fixture = CrateWindowFixture.items(for: id) { return fixture }
        // Crate order is the authored association order, not the next-song
        // recommendation ranking. The source film belongs in the front slot.
        let connections: [(entity: SeedGraph.Entity, label: String)]
        if id == "pool" {
            connections = zip(["film", "manga", "ushio", "jane", "animenzv"],
                              ["配乐出自", "电影原作", "作曲", "同片片尾曲", "钢琴改编"])
                .compactMap { key, label in SeedNowContent.entity(key).map { ($0, label) } }
        } else { connections = SeedNowContent.connections(id) }
        let ranking = NextStationSequence.make(graph: SeedNowContent.connectionGraph, root: id)
        return connections.map { connection in
            CrateItem(entity: connection.entity, relation: connection.label,
                      path: ranking.first { $0.id == connection.entity.id }?.path ?? [id, connection.entity.id])
        }
    }
}

struct InterestEvent: Codable, Equatable {
    let entityID: String
    let fromEntityID: String
    let relation: String
    let at: Date
}

@MainActor @Observable final class CrateExploration {
    private let trails: RelationTrailStore
    // Runtime exploration leaves the retained story pipeline dormant. Tests
    // and the isolated evaluation harness may inject an explicit store.
    let stories: OnDemandStories?
    private(set) var revision = 0
    init(defaults: UserDefaults? = nil, stories: OnDemandStories? = nil) {
        trails = RelationTrailStore(defaults: defaults)
        self.stories = stories
    }
    @ObservationIgnored private var retainedInterests: [InterestEvent]?
    var interests: [InterestEvent] {
        _ = revision
        if let retainedInterests { return retainedInterests }
        let events = trails.defaults.data(forKey: "redesign.interests")
            .flatMap { try? JSONDecoder().decode([InterestEvent].self, from: $0) } ?? []
        let recent = Array(events.suffix(500))
        retainedInterests = recent
        return recent
    }
    /// The shop records an explicit open without changing the evidence graph.
    func record(_ item: CrateItem, from: String, at: Date = Date()) {
        var events = interests
        events.append(InterestEvent(entityID: item.id, fromEntityID: from, relation: item.relation, at: at))
        events = Array(events.suffix(500))
        retainedInterests = events
        if let data = try? JSONEncoder().encode(events) { trails.defaults.set(data, forKey: "redesign.interests") }
        revision += 1
    }
    func pull(_ item: CrateItem, from: String, root: String, at: Date = Date()) {
        stories?.load(item.id)
        record(item, from: from, at: at)
        var map = trails.load(root: root) ?? RelationMapModel(root: root)
        let graph = SeedNowContent.connectionGraph
        _ = map.expand(root, graph: graph)
        // Materialize the authored route for candidates one hop beyond a film.
        if map.nodes[from] == nil {
            let route = NextStationSequence.make(graph: graph, root: root).first { $0.id == from }?.path ?? []
            for id in route where map.nodes[id] != nil { _ = map.expand(id, graph: graph) }
        }
        for id in item.path where map.nodes[id] != nil { _ = map.expand(id, graph: graph) }
        map.setFocus(item.id)
        map.pendingFocusFit = true
        trails.save(map)
    }
}
