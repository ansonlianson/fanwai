import Foundation

/// Shared selection. A via path is a browsing route, never a fabricated edge.
@MainActor enum PublicCrateInventory {
    static func isSingle(_ work: Work) -> Bool {
        work.isAlbum && (work.catalogTrackCount == 1 || work.title.hasSuffix(" - Single"))
    }
    static func isMusic(_ work: Work) -> Bool { work.isSong || work.isAlbum || work.isMusicWork }
    /// A display-series key only; never use this to alias catalog identities.
    static func versionSeries(_ work: Work) -> String? {
        guard work.isSong, let artist = work.catalogTrack?.artistID else { return nil }
        return artist + "\u{1f}" + SongTitlePresentation(work.title).title
    }
    static func prefersRecording(_ a: Work, _ b: Work, catalog: CatalogStore) -> Bool {
        let aSingle = a.albumID.map { isSingle(catalog.work($0)) } ?? false
        let bSingle = b.albumID.map { isSingle(catalog.work($0)) } ?? false
        if aSingle != bSingle { return !aSingle }
        let av = SongTitlePresentation(a.title).version, bv = SongTitlePresentation(b.title).version
        if (av == nil) != (bv == nil) { return av == nil }
        if a.catalogTrack?.track != b.catalogTrack?.track { return (a.catalogTrack?.track ?? .max) < (b.catalogTrack?.track ?? .max) }
        return a.id.rawValue < b.id.rawValue
    }
    static func roleRank(_ label: String) -> Int {
        if ["配乐", "作曲", "作词", "原作", "导演"].contains(label) { return 0 }
        if label == "编曲" { return 1 }
        if label == "演唱" { return 2 }
        return 3
    }
    static func known(_ work: Work, onMap: Set<WorkID>) -> Bool {
        Work.seeds[work.id] != nil || onMap.contains(work.id)
            || PublicIdentityAnchor.bundled.contains { $0.qid == work.knowledgeID }
    }
    static func directEdges(_ id: WorkID, catalog: CatalogStore) -> [RelationEdge] {
        directEdges(id, catalog: catalog,
            researchProvider: nil)
    }
    static func directEdges(_ id: WorkID, catalog: CatalogStore, researchProvider: String?) -> [RelationEdge] {
        let edges = catalog.relations(touching: id).filter {
            ($0.from == id || $0.to == id) && (["iTunes", "MusicBrainz", "Wikidata", "Bangumi", "VocaDB", "TouhouDB", "线索"].contains($0.source.title)
                || ReviewedRelations.contains($0, catalog: catalog))

        }
        // One factual target, with its strongest credit (P144 beats 相关书籍).
        return Dictionary(grouping: edges, by: { $0.other(than: id) }).compactMap { _, group in
            group.sorted {
                let a = roleRank($0.label(from: id)), b = roleRank($1.label(from: id))
                if a != b { return a < b }
                return $0.id < $1.id
            }.first
        }.sorted {
            @MainActor func rank(_ edge: RelationEdge) -> Int {
                let target = catalog.work(edge.other(than: id))
                return target.isPerson ? 0 : target.isAlbum ? 1 : target.isSong ? 2 : 3
            }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if roleRank($0.label(from: id)) != roleRank($1.label(from: id)) {
                return roleRank($0.label(from: id)) < roleRank($1.label(from: id))
            }
            let a = catalog.work($0.other(than: id)), b = catalog.work($1.other(than: id))
            if a.catalogTrack?.track != b.catalogTrack?.track { return (a.catalogTrack?.track ?? Int.max) < (b.catalogTrack?.track ?? Int.max) }
            return $0.id < $1.id
        }
    }
    static func creatorWorks(_ id: WorkID, catalog: CatalogStore, limit: Int, musicLimit: Int,
                             excluding: Set<WorkID> = [], onMap: Set<WorkID> = [], requireSeries: Bool = true) -> [RelationEdge] {
        let excludedSeries = Set(excluding.compactMap { versionSeries(catalog.work($0)) })
        let candidates = directEdges(id, catalog: catalog).filter {
            let target = catalog.work($0.other(than: id))
            // A track of the album already in view is part of that album,
            // not "another work" by the same artist.
            if target.isSong, let album = target.albumID, excluding.contains(album) { return false }
            return !target.isPerson && !excluding.contains(target.id) && !isSingle(target)
                && !(versionSeries(target).map { excludedSeries.contains($0) } ?? false)
        }
        let grouped = Dictionary(grouping: candidates, by: { edge in
            let work = catalog.work(edge.other(than: id))
            return versionSeries(work) ?? work.id.rawValue
        }).compactMap { _, group in group.sorted {
            prefersRecording(catalog.work($0.other(than: id)), catalog.work($1.other(than: id)), catalog: catalog)
        }.first }
        let ranked = grouped.sorted {
            let a = catalog.work($0.other(than: id)), b = catalog.work($1.other(than: id))
            if known(a, onMap: onMap) != known(b, onMap: onMap) { return known(a, onMap: onMap) }
            let ar = roleRank($0.label(from: id)), br = roleRank($1.label(from: id))
            if ar != br { return ar < br }
            if isMusic(a) != isMusic(b) { return !isMusic(a) }
            if a.bangumiID != b.bangumiID { return (Int(a.bangumiID ?? "") ?? 0) > (Int(b.bangumiID ?? "") ?? 0) }
            if a.releaseDate != b.releaseDate { return (a.releaseDate ?? "") > (b.releaseDate ?? "") }
            return a.id.rawValue < b.id.rawValue
        }
        var picked: [RelationEdge] = [], deferred: [RelationEdge] = [], series = Set<String>(), selected = Set<String>(), music = 0
        for edge in ranked {
            let target = catalog.work(edge.other(than: id))
            if let bgm = target.bangumiID {
                if series.contains(bgm) || !selected.isDisjoint(with: target.seriesIDs ?? []) { continue }
                if requireSeries && target.seriesIDs == nil { continue }
                selected.insert(bgm); series.formUnion(target.seriesIDs ?? [])
            }
            if isMusic(target) { if music >= musicLimit { deferred.append(edge); continue }; music += 1 }
            picked.append(edge)
            if picked.count == limit { break }
        }
        if picked.count < limit { picked += deferred.prefix(limit-picked.count) }
        return picked
    }
    static func selectedEdges(_ root: WorkID, catalog: CatalogStore, requireSeries: Bool = true) -> [(RelationEdge, WorkID)] {
        let work = catalog.work(root), direct = directEdges(root, catalog: catalog)
        if work.isPerson { return creatorWorks(root, catalog: catalog, limit: 5, musicLimit: 1, requireSeries: requireSeries).map { ($0, root) } }
        var result: [(RelationEdge, WorkID)] = [], seen: Set<WorkID> = [root], tracks = 0
        for edge in direct {
            let target = catalog.work(edge.other(than: root))
            if isSingle(target) { continue }
            if let key = versionSeries(work), versionSeries(target) == key { continue }
            if target.isSong {
                if tracks >= 1 { continue }; tracks += 1
            }
            guard seen.insert(target.id).inserted else { continue }
            result.append((edge, root))
            if result.count == 5 { return result }
        }
        // The album in view: the root itself, or the album the root song is on.
        if let album = work.isAlbum ? work.id : work.albumID { seen.insert(album) }
        for creator in direct.map({ catalog.work($0.other(than: root)) }).filter(\.isPerson) {
            let musicUsed = result.filter { $0.1 != root && isMusic(catalog.work($0.0.other(than: $0.1))) }.count
            for edge in creatorWorks(creator.id, catalog: catalog, limit: 5-result.count, musicLimit: max(0, 1-musicUsed), excluding: seen, requireSeries: requireSeries) {
                let target = edge.other(than: creator.id)
                if seen.insert(target).inserted { result.append((edge, creator.id)) }
                if result.count == 5 { return result }
            }
        }
        return result
    }
    static func browseItems(for entityID: String, library: Library) -> [CrateItem] {
        let catalog = library.catalog
        let root = catalog.canonicalID(for: SeedLibraryBridge.workID(entityID))
        let direct = directEdges(root, catalog: catalog)
        var pairs = direct.map { ($0, root) }
        if !catalog.work(root).isPerson {
            for edge in direct {
                let person = edge.other(than: root)
                guard catalog.work(person).isPerson else { continue }
                pairs += directEdges(person, catalog: catalog).filter { !catalog.work($0.other(than: person)).isPerson }.map { ($0, person) }
            }
        }
        var seen: Set<WorkID> = [root]
        return pairs.compactMap { edge, owner in
            let targetID = catalog.canonicalID(for: edge.other(than: owner))
            guard seen.insert(targetID).inserted else { return nil }
            let target = SeedLibraryBridge.entity(for: targetID, in: library)
            let via = SeedLibraryBridge.entity(for: owner, in: library).id
            var relation = edge.label(from: owner)
            if owner != root && isMusic(catalog.work(targetID)) && ["作品", "发行作品", "演唱"].contains(relation) { relation = "同一艺人" }
            return .init(entity: target, relation: relation, path: owner == root ? [entityID, target.id] : [entityID, via, target.id])
        }
    }
    static func items(for entityID: String, library: Library) -> [CrateItem] {
        let root = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entityID))
        return selectedEdges(root, catalog: library.catalog).map { edge, owner in
            let target = SeedLibraryBridge.entity(for: edge.other(than: owner), in: library)
            let via = SeedLibraryBridge.entity(for: owner, in: library).id
            var relation = edge.label(from: owner)
            if owner != root, library.catalog.work(owner).isPerson, isMusic(library.catalog.work(edge.other(than: owner))),
               ["作品", "发行作品", "演唱"].contains(relation) { relation = "同一艺人" }
            return CrateItem(entity: target, relation: relation, path: owner == root ? [entityID, target.id] : [entityID, via, target.id])
        }
    }
    /// 0.3 map: what is already known, leads first. Nothing here waits on the network.
    static func mapEdges(_ id: WorkID, catalog: CatalogStore) -> [(RelationEdge, WorkID)] {
        let direct = directEdges(id, catalog: catalog)
        let leads = direct.filter { $0.source.title == "线索" }
        let rest = direct.filter { $0.source.title != "线索" && !isSingle(catalog.work($0.other(than: id))) }
        return (leads + rest).prefix(8).map { ($0, id) }
    }
    /// The 0.3 map. `graph` below is the 0.2 selection, kept with the old
    /// pipeline until that is removed.
    static func leadGraph(root: String, expanding: [String], library: Library) -> SeedGraph {
        var entities: [String: SeedGraph.Entity] = [:], relations: [SeedGraph.Relation] = []
        let provider: String? = nil
        var requiredPairs = Set<String>()
        for lead in DiscoveryNavigation.leads(from: root, catalog: library.catalog, known: [:], provider: provider) {
            let path = lead.path ?? []
            for (a, b) in zip(path, path.dropFirst()) { requiredPairs.insert([a, b].sorted().joined(separator: "|")) }
        }
        for key in Set(expanding + [root]) {
            let id = library.catalog.canonicalID(for: SeedLibraryBridge.workID(key))
            let entity = SeedLibraryBridge.entity(for: id, in: library)
            entities[entity.id] = entity
            let direct = directEdges(id, catalog: library.catalog)
            let required = direct.filter { requiredPairs.contains([$0.from.rawValue, $0.to.rawValue].sorted().joined(separator: "|")) }
            let other = direct.filter { !requiredPairs.contains([$0.from.rawValue, $0.to.rawValue].sorted().joined(separator: "|")) }
            for edge in required + other.prefix(max(0, 8 - required.count)) {
                let owner = id
                let target = SeedLibraryBridge.entity(for: edge.other(than: owner), in: library)
                entities[target.id] = target
                relations.append(.init(from: entity.id, to: target.id,
                    label: DiscoveryPathPresentation.directLabel(edge, from: owner, catalog: library.catalog), via: nil))
            }
        }
        return SeedGraph(version: 1, root: root, entities: Array(entities.values), relations: relations)
    }
    static func graph(root: String, expanding: [String], library: Library) -> SeedGraph {
        var entities: [String: SeedGraph.Entity] = [:], relations: [SeedGraph.Relation] = []
        let onMap = Set(expanding.map { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0)) })
        let origin = library.catalog.work(SeedLibraryBridge.workID(root))
        let context: Set<WorkID> = Set([origin.id] + (origin.albumID.map { [$0] } ?? []))
        for key in Set(expanding + [root]) {
            let id = library.catalog.canonicalID(for: SeedLibraryBridge.workID(key))
            let entity = SeedLibraryBridge.entity(for: id, in: library)
            entities[entity.id] = entity
            let picks: [(RelationEdge, WorkID)]
            if library.catalog.work(id).isPerson {
                picks = creatorWorks(id, catalog: library.catalog, limit: 6, musicLimit: 2, excluding: context, onMap: onMap).map { ($0, id) }
            } else { picks = selectedEdges(id, catalog: library.catalog) }
            for (edge, owner) in picks {
                let target = SeedLibraryBridge.entity(for: edge.other(than: owner), in: library)
                let source = SeedLibraryBridge.entity(for: owner, in: library)
                entities[target.id] = target; entities[source.id] = source
                relations.append(.init(from: entity.id, to: target.id, label: edge.label(from: owner), via: owner == id ? nil : source.id))
            }
        }
        return SeedGraph(version: 1, root: root, entities: Array(entities.values), relations: relations)
    }
}

@MainActor enum VerifiedDisplayName {
    private static let aliasesByID = StoryNameTable.bundledAliases()
    static func title(_ work: Work, catalog: CatalogStore) -> String {
        if work.catalogRecordingID != nil || work.isAlbum && work.catalogID != nil { return work.title }
        guard let qid = work.knowledgeID else { return work.title }
        let names = Set(SeedNowContent.connectionGraph.entities.compactMap { entity -> String? in
            let id = catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
            let external = entity.id == "ikuta" ? "Q96711898" : catalog.work(id).knowledgeID ?? KnowledgeAnchors.verified[id]
            return external == qid ? entity.title : nil
        })
        return names.count == 1 ? names.first! : work.title
    }
    static func creator(_ work: Work, catalog: CatalogStore) -> String {
        // The store's recording credits are already presentation text. Do not
        // rewrite them through a story-name table or a translated artist node.
        if work.catalogRecordingID != nil || work.isAlbum && work.catalogID != nil { return work.creator }
        if work.isMusicWork, work.creator.isEmpty {
            return RecordingCatalogMatch.source(work, catalog: catalog).discovery?.composer ?? ""
        }
        var mappings: [String: Set<String>] = [:]
        for id in work.creatorIDs {
            let creator = catalog.work(id)
            guard let qid = creator.knowledgeID else { continue }
            let preferred = title(creator, catalog: catalog)
            let aliases = (aliasesByID[qid] ?? []) + [creator.title]
            // IDs select the person first; replacing that person's credit text
            // does not establish an identity for any other name in the credit.
            for alias in aliases + [preferred] where !alias.isEmpty { mappings[alias, default: []].insert(preferred) }
        }
        let keys = mappings.keys.filter { mappings[$0]?.count == 1 }.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        var output = "", cursor = work.creator.startIndex
        while cursor < work.creator.endIndex {
            let tail = work.creator[cursor...]
            let match = keys.first { key in
                guard tail.hasPrefix(key) else { return false }
                if key.allSatisfy({ $0.isASCII }) {
                    let end = work.creator.index(cursor, offsetBy: key.count)
                    if cursor > work.creator.startIndex, work.creator[work.creator.index(before: cursor)].isLetter { return false }
                    if end < work.creator.endIndex, work.creator[end].isLetter { return false }
                }
                return true
            }
            if let key = match, let name = mappings[key]?.first {
                output += name; cursor = work.creator.index(cursor, offsetBy: key.count)
            } else { output.append(work.creator[cursor]); cursor = work.creator.index(after: cursor) }
        }
        return output
    }
}
