import Foundation

enum StoryNameGraph {
    static let verifiedAliases = StoryNameTable.bundledAliases().mapValues { names in
        let literalTitles = names.compactMap { name -> String? in
            guard let range = name.range(of: "(?<=[「『])[^」』]+(?=[」』])", options: .regularExpression) else { return nil }
            return String(name[range])
        }
        return Array(Set(names + literalTitles))
    }
    private static func mentioned(_ name: String, qid: String?, in text: String?) -> Bool {
        guard let text else { return true }
        return text.contains(name) || (qid.flatMap { verifiedAliases[$0] } ?? []).contains { text.contains($0) }
    }
    @MainActor static func nodes(catalog: CatalogStore, matching text: String? = nil) -> [StoryNameNode] {
        let seeds = SeedNowContent.connectionGraph.entities
        var represented = Set<WorkID>()
        var nodes = seeds.compactMap { seed -> StoryNameNode? in
            let id = catalog.canonicalID(for: SeedLibraryBridge.workID(seed.id))
            represented.insert(id)
            let work = catalog.work(id)
            var qid = work.knowledgeID ?? KnowledgeAnchors.verified[id]
            // These existing graph nodes use identities already verified in #8
            // and the editorial catalog, not a new match by display name.
            if seed.id == "ikuta" { qid = "Q96711898" }
            if seed.id == "anno" { qid = KnowledgeAnchors.verified[WorkID(rawValue: "editorial:hideaki-anno")!] }
            guard mentioned(seed.title, qid: qid, in: text) else { return nil }
            return .init(id: seed.id, name: seed.title, kind: seed.kind == .song ? .song : [.person, .group].contains(seed.kind) ? .person : .work,
                         externalIDs: [qid].compactMap { $0 })
        }
        nodes += catalog.works.values.filter { !represented.contains($0.id) && mentioned($0.title, qid: $0.knowledgeID ?? KnowledgeAnchors.verified[$0.id], in: text) }.map { work in
            .init(id: work.id.rawValue, name: work.title, kind: work.isSong ? .song : work.isPerson ? .person : .work,
                  externalIDs: [work.knowledgeID ?? KnowledgeAnchors.verified[work.id]].compactMap { $0 })
        }
        // A public credit can expose a second catalog card for the same
        // independently verified person. Keep the established graph name/link;
        // duplicate QIDs must not make a known Chinese name ambiguous.
        var people = Set<String>()
        return nodes.filter { node in
            guard node.kind == .person else { return true }
            let ids = Set(node.externalIDs.filter(WikiSourceIdentity.validQID))
            guard ids.isEmpty || people.isDisjoint(with: ids) else { return false }
            people.formUnion(ids); return true
        }.sorted { $0.id < $1.id }
    }
}
