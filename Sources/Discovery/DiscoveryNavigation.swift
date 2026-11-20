import Foundation

/// Projects real directed paths into the crate; presentation never manufactures
/// a direct edge between the recording and a multi-step destination.
@MainActor enum DiscoveryNavigation {
    static func directCreator(_ label: String) -> Bool {
        let credit = ["作曲", "作词", "填词", "词曲", "编曲", "制作", "编舞", "MV", "混音", "录音", "监制", "封面", "摄影", "导演关联"]
        if credit.contains(where: { label.contains($0) }) && !label.contains("主演") { return false }
        return ["合唱", "对唱", "合作", "客串", "原唱", "演唱", "主演", "导演", "原作", "作者"].contains(where: { label.contains($0) })
    }

    static func sameTitle(_ a: Work, _ b: Work) -> Bool {
        func names(_ work: Work) -> Set<String> {
            Set(([work.title, work.discovery?.canonicalTitle ?? ""] + (work.discovery?.aliases ?? []))
                .map { LeadMatch.norm(SongTitlePresentation($0).title) }.filter { !$0.isEmpty })
        }
        return !names(a).isDisjoint(with: names(b))
    }
    struct Context {
        let work: Work
        let label: String
        let otherVersions: Int
        let isMembership: Bool
        var canOpen: Bool { isMembership || otherVersions > 0 }
    }
    static func context(from requested: String, catalog: CatalogStore, provider: String?) -> Context? {
        let root = catalog.canonicalID(for: SeedLibraryBridge.workID(requested))
        let source = catalog.work(root), index = catalog.relationIndex
        let facts = (index.adjacent[root] ?? []).map(\.1)
        if source.isSong, let edge = facts.first(where: { $0.from == root && $0.predicate == .performanceOf }) {
            let versions = Set((index.adjacent[edge.to] ?? []).map(\.1).filter { $0.to == edge.to && $0.predicate == .performanceOf && $0.from != root && catalog.work($0.from).isSong }.map(\.from))
            return .init(work: catalog.work(edge.to), label: "演奏作品", otherVersions: versions.count, isMembership: false)
        }
        if source.isMusicWork, let edge = facts.first(where: { $0.from == root && $0.predicate == .partOf && catalog.work($0.to).isMusicWork }) {
            return .init(work: catalog.work(edge.to), label: "属于", otherVersions: 0, isMembership: true)
        }
        return nil
    }
    /// The same split, usable off the main actor (search queries are built there).
    nonisolated static func mainCreatorName(_ line: String) -> String {
        let separator = try! NSRegularExpression(pattern: #"(?i)\s+(?:feat\.?|featuring|with)\s+|[,，、/／&＆;；]"#)
        let range = separator.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)).flatMap { Range($0.range, in: line) }
        return String(line[..<(range?.lowerBound ?? line.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func mainCreator(_ line: String) -> String {
        let separator = try! NSRegularExpression(pattern: #"(?i)\s+(?:feat\.?|featuring|with)\s+|[,，、/／&＆;；]"#)
        let range = separator.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)).flatMap { Range($0.range, in: line) }
        return String(line[..<(range?.lowerBound ?? line.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func edges(_ catalog: CatalogStore, provider: String?) -> [RelationEdge] {
        catalog.relationIndex.facts
    }
    static func leads(from requested: String, catalog: CatalogStore, known: [String: Lead], provider: String?) -> [Lead] {
        let root = catalog.canonicalID(for: SeedLibraryBridge.workID(requested))
        // The catalogue's own index: nothing here walks all of its relations.
        let source = catalog.work(root), relationIndex = catalog.relationIndex
        let facts = relationIndex.facts, adjacent = relationIndex.adjacent
        let own = (adjacent[root] ?? []).map(\.1)
        let structural = Set(own.filter { $0.from == root && ((source.isSong && $0.predicate == .performanceOf) || (source.isMusicWork && $0.predicate == .partOf)) }.map(\.to))
        let anchoredWorks = Set(own.filter { $0.from == root && $0.predicate == .performanceOf }.map(\.to))
        struct Visit { let id: WorkID; let path: [WorkID]; let edge: RelationEdge; let previous: WorkID }
        // 同门 (AHA-PLAN §3.2): root → the show it was made for ← another song made for that show.
        let madeFor: Set<RelationKind> = [.soundtrackOf, .usedIn, .themeMusic, .endingOf]
        func isSibling(_ edge: RelationEdge, at show: WorkID, path: [WorkID], arrived: RelationEdge?) -> Bool {
            guard path.count == 2, let arrived, arrived.from == root, arrived.to == show, madeFor.contains(arrived.predicate),
                  edge.to == show, edge.from != root, madeFor.contains(edge.predicate) else { return false }
            let song = catalog.work(edge.from)
            // The playing song under another ref (the piece it performs, or a same-title node) is not its own sibling.
            guard !anchoredWorks.contains(edge.from), !sameTitle(source, song) else { return false }
            return song.isSong || song.isMusicWork
        }
        var visits: [Visit] = [], reached = Set<WorkID>()
        func rank(_ edge: RelationEdge, at id: WorkID) -> Int {
            if edge.from == id {
                switch edge.predicate {
                case .performanceOf, .adaptedFrom, .coverOf, .remixOf, .samplesFrom: return 0
                case .soundtrackOf, .partOf: return 1
                case .usedIn: return 3
                default: break
                }
            }
            if catalog.work(edge.other(than: id)).isPerson { return 9 }
            return 4
        }
        // Prefer a concrete two-hop origin over a one-hop "inspired by".
        // Positive weights keep a real, acyclic shortest evidence tree; on
        // equal cost the shorter path wins, so long detours do not take over.
        var queue: [(id: WorkID, path: [WorkID], edge: RelationEdge?, cost: Int)] = [(root, [root], nil, 0)]
        while !queue.isEmpty {
            let index = queue.indices.min { a, b in
                if queue[a].cost != queue[b].cost { return queue[a].cost < queue[b].cost }
                if queue[a].path.count != queue[b].path.count { return queue[a].path.count < queue[b].path.count }
                return a < b
            }!
            let (current, path, arrived, cost) = queue.remove(at: index)
            guard reached.insert(current).inserted else { continue }
            if let arrived, let previous = path.dropLast().last { visits.append(.init(id: current, path: path, edge: arrived, previous: previous)) }
            guard path.count <= 3 else { continue }
            // A sibling song is a destination; its own relations are not walked from here.
            if path.count == 3, let arrived, madeFor.contains(arrived.predicate), arrived.to == path[1], arrived.from == current { continue }
            let neighbors = (adjacent[current] ?? []).sorted { a, b in
                let x = rank(a.1, at: current), y = rank(b.1, at: current); return x == y ? a.0 < b.0 : x < y
            }
            for (_, edge) in neighbors {
                let target = edge.other(than: current)
                guard catalog.works[target] != nil, !reached.contains(target) else { continue }
                if path.count > 1 {
                    guard source.isSong || source.isMusicWork else { continue }
                    let previous = path[path.count - 2]
                    let derivative = arrived.map { $0.from == current && $0.to == previous && [.adaptedFrom, .remixOf, .coverOf].contains($0.predicate) } ?? false
                    guard !derivative else { continue }
                    let original = arrived.map { $0.from == previous && $0.to == current && [.adaptedFrom, .remixOf, .coverOf].contains($0.predicate) } ?? false
                    if original && edge.predicate == .partOf { continue }
                    let upstream = edge.from == current && [.performanceOf, .adaptedFrom, .coverOf, .remixOf, .partOf, .soundtrackOf, .usedIn, .samplesFrom].contains(edge.predicate)
                    let derived = edge.to == current && [.adaptedFrom, .remixOf, .musicVideoOf, .samplesFrom].contains(edge.predicate)
                    guard upstream || derived || isSibling(edge, at: current, path: path, arrived: arrived) else { continue }
                }
                let next = path + [target]
                let weak = edge.predicate == .techniqueReference || edge.predicate == .publicRelation
                queue.append((target, next, edge, cost + (weak ? 3 : 1)))
            }
        }
        var people = 0, optionalWorks = 0, siblings = 0
        let children = Dictionary(grouping: visits, by: \.previous)
        var paired: [Visit] = []
        func appendBranch(_ parent: WorkID) {
            for child in children[parent] ?? [] { paired.append(child); appendBranch(child.id) }
        }
        appendBranch(root)
        // Select shortest routes first, then keep an original and its source
        // game together when presenting the crate. Identity and display order
        // are separate decisions.
        let ordered = paired.filter { !catalog.work($0.id).isPerson } + paired.filter { catalog.work($0.id).isPerson }
        // One card per show, film, game or book: a later lookup (深挖) that names 「最终幻想VIII」 again under
        // another identity is the 「最终幻想8」 already in the bin (measured 11-18: 4 of 8 dives re-added one).
        let screens: Set<DiscoveryIdentity.Layer> = [.film, .tv, .game, .book, .manga]
        var shown: [(DiscoveryIdentity.Layer, Set<String>)] = []
        return ordered.compactMap { visit -> Lead? in
            let work = catalog.work(visit.id)
            if structural.contains(visit.id) || work.isAlbum { return nil }
            if let identity = work.discovery, screens.contains(identity.layer) {
                let keys = identity.nameKeys.union([LeadMatch.norm(work.title)]).filter { $0.count >= 2 }
                if shown.contains(where: { $0.0 == identity.layer && !$0.1.isDisjoint(with: keys) }) { return nil }
                shown.append((identity.layer, keys))
            }
            if work.isPerson {
                let label = visit.edge.label(from: visit.previous)
                let role = [.directedBy, .authoredBy].contains(visit.edge.predicate) || directCreator(label)
                guard people == 0, role, !LeadMatch.sameCreator(work.title, mainCreator(source.creator)),
                      ![.composedBy, .arrangedBy].contains(visit.edge.predicate) else { return nil }
                people += 1
            } else if visit.path.count == 3, visit.edge.to == visit.previous, madeFor.contains(visit.edge.predicate), work.isSong || work.isMusicWork {
                // At most two 同作 songs per crate (anson 2026-11-17).
                guard siblings < 2 else { return nil }
                siblings += 1
            } else {
                // Keep original recordings; put other editions behind the version entry.
                if source.isSong, work.isSong, visit.edge.predicate != .coverOf,
                   (adjacent[visit.id] ?? []).contains(where: { $0.1.from == visit.id && $0.1.predicate == .performanceOf && anchoredWorks.contains($0.1.to) }) { return nil }
                let required = [.adaptedFrom, .coverOf, .remixOf, .soundtrackOf, .samplesFrom].contains(visit.edge.predicate)
                    || (source.isMusicWork && visit.edge.predicate == .performanceOf)
                if !required { guard optionalWorks < 5 else { return nil }; optionalWorks += 1 }
            }
            var lead = known[visit.id.rawValue] ?? Lead(id: visit.id.rawValue, name: work.title,
                original: work.discovery?.canonicalTitle ?? work.title, kind: work.discovery.map { DiscoveryCore.kind($0.layer) } ?? kind(work),
                label: "", why: "", url: visit.edge.source.url, creator: work.creator, art: work.art, link: work.url, identity: work.discovery)
            // A cover found after the card went up lives on the catalogue record (LeadResearch.fillCovers).
            if lead.art.isEmpty { lead.art = work.art }
            lead.label = DiscoveryPathPresentation.label(visit.edge, path: visit.path, facts: facts, catalog: catalog)
            let fact = visit.edge.source.detail.components(separatedBy: "\n").first ?? ""
            lead.why = fact.isEmpty ? "" : visit.path.count > 2 ? DiscoveryPathPresentation.quoted(catalog.work(visit.previous).title) + " · " + fact : fact
            lead.path = visit.path.map(\.rawValue)
            lead.url = visit.edge.source.url
            return lead
        }
    }
    /// Owners of the exact paths already offered in the crate. Opening these
    /// known branches costs no research and never turns via paths into spokes.
    static func initialMapOwners(from root: String, catalog: CatalogStore, provider: String?) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for path in initialMapPaths(from: root, catalog: catalog, provider: provider) {
            for owner in path.dropLast() where seen.insert(owner).inserted { result.append(owner) }
        }
        return result
    }
    static func initialMapPaths(from root: String, catalog: CatalogStore, provider: String?) -> [[String]] {
        leads(from: root, catalog: catalog, known: [:], provider: provider).compactMap(\.path)
    }
    struct MapCaption {
        let title: String
        let detail: String?
        var scale: CGFloat = 1
    }
    static func mapCaptions(root requested: String, ids: [String], catalog: CatalogStore) -> [String: MapCaption] {
        let root = catalog.canonicalID(for: SeedLibraryBridge.workID(requested)), source = catalog.work(root)
        let works = ids.map { catalog.work(catalog.canonicalID(for: SeedLibraryBridge.workID($0))) }
        let names = Dictionary(grouping: works, by: { LeadMatch.norm($0.title) })
        var result: [String: MapCaption] = [:]
        for (key, work) in zip(ids, works) {
            if work.id == source.albumID {
                result[key] = .init(title: work.title, detail: "专辑", scale: 0.7)
            } else if source.isSong, work.isMusicWork, catalog.relations(touching: root).contains(where: { $0.from == root && $0.to == work.id && $0.predicate == .performanceOf }) {
                let composer = work.discovery?.composer.isEmpty == false ? work.discovery!.composer : work.creator
                let same = sameTitle(source, work)
                result[key] = .init(title: same ? "乐曲" : work.title, detail: composer.isEmpty ? nil : same ? composer : "乐曲 · " + composer)
            } else if work.isPerson, source.creatorIDs.count == 1, source.creatorIDs.contains(work.id) {
                result[key] = .init(title: DiscoveryRecordingIdentity.creditKeys(source.creator).count == 1 ? source.creator : work.title, detail: "艺人")
            } else if work.discovery?.layer == .movement {
                result[key] = .init(title: DiscoveryPathPresentation.coverTitle(work), detail: work.creator)
            } else if (names[LeadMatch.norm(work.title)]?.count ?? 0) > 1 {
                result[key] = .init(title: work.title, detail: DiscoveryPathPresentation.typeName(work))
            }
        }
        return result
    }
    private static func kind(_ work: Work) -> SeedGraph.Kind {
        if work.isSong || work.isMusicWork { return .song }
        if work.isPerson { return .person }
        if work.isVideo { return .video }
        if work.isAlbum { return .album }
        switch work.kind {
        case "游戏": return .game
        case "电影", "动画": return .film
        case "电视剧": return .tv
        case "漫画": return .manga
        default: return .book
        }
    }
}
