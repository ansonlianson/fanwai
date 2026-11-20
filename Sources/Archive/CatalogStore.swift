import Foundation
import Observation

struct CatalogSnapshot: Codable, Sendable {
    var version = 1
    var works: [Work]
    var relations: [RelationEdge]
    var stories: [EditorialStory] = []
    /// Durable redirects for migrated local identities. Older snapshots omit it.
    var identityAliases: [String: String]? = nil
}

@MainActor @Observable
final class CatalogStore {
    static let shared = CatalogStore()
    private(set) var works: [WorkID: Work]
    private(set) var edges: [RelationEdge]
    private(set) var stories: [EditorialStory] = []
    private(set) var entryPoints: [WorkID] = [.pool, .jane, .animenz]
    private(set) var storageError: String?
    /// Changes only when installed catalog content changes, not on empty merges.
    private(set) var revision = 0
    private(set) var publicRelationsLoading = Set<WorkID>()
    private(set) var publicSelectionReady = Set<WorkID>()
    private(set) var publicMapSelectionReady = Set<WorkID>()
    private(set) var publicReports: [WorkID: PublicRelationReport] = [:]
    @ObservationIgnored private var publicTasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var selectionTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var artworkIdentityAttempts = Set<WorkID>()
    @ObservationIgnored private var publicArtistSongsLoaded = Set<WorkID>()
    private(set) var regionAttempts = Set<WorkID>()
    @ObservationIgnored private var regionTasks: [WorkID: Task<Void, Never>] = [:]
    private(set) var loading = Set<WorkID>()
    private(set) var lookupErrors: [WorkID: String] = [:]
    private(set) var knowledgeLoading = Set<WorkID>()
    private(set) var knowledgeErrors: [WorkID: String] = [:]
    private(set) var songDiscoveryLoading = Set<WorkID>()
    private(set) var songDiscoveryErrors: [WorkID: String] = [:]
    private(set) var knowledgePartial = Set<WorkID>()
    private(set) var knowledgeMoreLoading = Set<WorkID>()
    private(set) var knowledgeMoreErrors: [WorkID: String] = [:]
    private var knowledgeMoreStates: [WorkID: KnowledgeMoreStatus] = [:]
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private var loaded = Set<WorkID>()
    @ObservationIgnored private var tasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var aliases: [WorkID: WorkID] = [WorkID(rawValue: "editorial:hikaru-utada")!: .utada]
    @ObservationIgnored private var identityIndex: [CatalogIdentity: WorkID] = [:]
    @ObservationIgnored private var cacheWriteBlocked = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var diskTask: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var persistenceDirty = false
    @ObservationIgnored private let diskWriter = CatalogDiskWriter()
    @ObservationIgnored private var knowledgeLoaded = Set<WorkID>()
    @ObservationIgnored private var knowledgeTasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var knowledgeWorkCursors: [WorkID: KnowledgeWorksCursor] = [:]
    @ObservationIgnored private var knowledgeMoreTasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var songDiscoveryTasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var songDiscoveryLoaded = Set<WorkID>()
    @ObservationIgnored private let songDiscoveryService: any SongDiscoveryFetching
    @ObservationIgnored private var songEditorial: SongEditorialCatalog?
    let service: any CatalogFetching
    let knowledgeService: KnowledgeGraphService

    var cacheBackupURL: URL? { cacheURL?.appendingPathExtension("unreadable-backup") }

    init(cacheURL: URL? = CatalogStore.defaultCacheURL, service: any CatalogFetching = ITunesCatalogService(), bundle: Bundle = .main, knowledgeService: KnowledgeGraphService = KnowledgeGraphService(), songDiscoveryService: any SongDiscoveryFetching = SongDiscoveryService()) {
        self.cacheURL = cacheURL; self.service = service; self.knowledgeService = knowledgeService
        self.songDiscoveryService = songDiscoveryService
        works = Work.seeds; edges = Relations.seeds
        if let url = bundle.url(forResource: "song-editorial", withExtension: "json") {
            songEditorial = try? JSONDecoder().decode(SongEditorialCatalog.self, from: Data(contentsOf: url))
        }
        // Bundled editorial metadata is authoritative over an older local cache.
        if let url = bundle.url(forResource: "editorial-starter", withExtension: "json") {
            do {
                let pack = try JSONDecoder().decode(EditorialPack.self, from: Data(contentsOf: url))
                guard pack.version == 1 else { throw CatalogError.invalidData }
                let items = pack.works.map { item in
                    Work(id: item.id, title: item.title, creator: item.creator, kind: item.kind, art: item.art, detail: item.detail, url: item.url, linkedAlbumID: item.albumID, linkedCreatorIDs: item.creatorIDs, versionSearchQuery: item.versionSearchQuery)
                }
                let available = Set(items.map(\.id)).union(works.keys)
                guard pack.entryPoints.allSatisfy({ available.contains($0) }) else { throw CatalogError.invalidData }
                try merge(CatalogSnapshot(works: items, relations: pack.relations, stories: pack.stories), persist: false)
                entryPoints = canonicalIDs(entryPoints + pack.entryPoints)
            } catch { storageError = "部分精选内容暂时无法载入。" }
        }
        for (id, qid) in KnowledgeAnchors.verified where works[id] != nil { works[id]?.knowledgeID = qid }
        for anchor in PublicIdentityAnchor.bundled {
            for id in works.keys where works[id]?.knowledgeID == anchor.qid {
                works[id]?.bangumiID = anchor.bangumiID
            }
        }
        // Also initialize the identity index when no editorial resource is bundled.
        try? merge(CatalogSnapshot(works: [], relations: []), persist: false)
        let readURL = cacheURL.map(Self.readURL)
        if let readURL, FileManager.default.fileExists(atPath: readURL.path) {
            do {
                let data = try Data(contentsOf: readURL)
                do {
                    try merge(JSONDecoder().decode(CatalogSnapshot.self, from: data), persist: false)
                    // The current file read cleanly: the copy from before the format change
                    // (catalog-v1.json, 5 MB on anson's phone, untouched since 11-14) is not needed.
                    if readURL == cacheURL, cacheURL?.lastPathComponent == "catalog-v2.json",
                       let legacy = cacheURL?.deletingLastPathComponent().appendingPathComponent("catalog-v1.json") {
                        try? FileManager.default.removeItem(at: legacy)
                    }
                }
                catch {
                    try preserveUnreadableCache(data)
                    storageError = "有一部分已保存的资料暂时读不到，原文件已备份。"
                }
            } catch {
                cacheWriteBlocked = true
                storageError = "原资料暂时无法读取或备份，已停止覆盖本机资料。"
            }
        }
        incrementalReady = true
    }

    static var defaultCacheURL: URL? {
        PianwaiRuntime.applicationDirectory("Pianwai")?.appendingPathComponent("catalog-v2.json")
    }
    nonisolated private static func readURL(for target: URL) -> URL {
        guard target.lastPathComponent == "catalog-v2.json", !FileManager.default.fileExists(atPath: target.path) else { return target }
        let legacy = target.deletingLastPathComponent().appendingPathComponent("catalog-v1.json")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : target
    }

    func work(_ id: WorkID) -> Work {
        let canonical = canonicalID(for: id)
        return works[canonical] ?? Work(id: canonical, title: "作品暂不可用", creator: "", kind: "作品", art: "", detail: "", url: nil)
    }

    private struct MergeState: Sendable {
        var works:[WorkID:Work]; var edges:[RelationEdge]; var stories:[EditorialStory]
        var aliases:[WorkID:WorkID]; var index:[CatalogIdentity:WorkID]; var entryPoints:[WorkID]
        /// Identities that more than one record carries (kept apart on purpose), and the ids of
        /// every relation: what an incremental merge needs to know without walking the catalogue.
        var ambiguous:Set<CatalogIdentity> = []
        var edgeIDs:Set<String> = []
        /// Wikidata ids carried by Apple artist profiles and by other person records: a credit
        /// moves from the profile to the person only when both carry the same one.
        var artistQIDs:Set<String> = []
        var personQIDs:Set<String> = []
    }
    /// What one small merge changes. A phone that has been used for weeks carries about ten
    /// thousand records (2026-11-18: 9,854 works, 8,873 relations); rebuilding all of them for
    /// every card, cover or search result held the main thread for a long time on each merge.
    private struct MergeDelta: Sendable {
        var works:[WorkID:Work] = [:]
        var edges:[RelationEdge] = []
        var replacedEdges:[Int:RelationEdge] = [:]
        var stories:[EditorialStory] = []
        var aliases:[WorkID:WorkID] = [:]
        var index:[CatalogIdentity:WorkID] = [:]
        var artistQIDs:Set<String> = []
        var personQIDs:Set<String> = []
        var changesContent:Bool { !works.isEmpty || !edges.isEmpty || !replacedEdges.isEmpty || !stories.isEmpty || !aliases.isEmpty }
    }
    /// Each work's relations, and the subset the crate and the map walk, built once per catalogue
    /// change. Pages used to filter all (about 9,000) relations for every card and every redraw.
    struct RelationIndex {
        var touching: [WorkID: [RelationEdge]] = [:]
        var facts: [RelationEdge] = []
        var adjacent: [WorkID: [(Int, RelationEdge)]] = [:]
    }
    @ObservationIgnored private var relationIndexCache: (revision: Int, count: Int, index: RelationIndex)?
    @ObservationIgnored private var localMatchCache: (needle: String, revision: Int, count: Int, ids: [WorkID])?
    var relationIndex: RelationIndex {
        let current = revision, all = edges
        if let cache = relationIndexCache, cache.revision == current, cache.count == all.count { return cache.index }
        var index = RelationIndex()
        for edge in all {
            index.touching[edge.from, default: []].append(edge)
            index.touching[edge.to, default: []].append(edge)
        }
        index.facts = all.filter { $0.researchRoot != nil || ["iTunes", "MusicBrainz", "Wikidata", "Bangumi", "VocaDB", "TouhouDB"].contains($0.source.title) }
        for (position, edge) in index.facts.enumerated() {
            index.adjacent[edge.from, default: []].append((position, edge))
            index.adjacent[edge.to, default: []].append((position, edge))
        }
        relationIndexCache = (current, all.count, index)
        return index
    }
    /// The relations that start or end at this work, in catalogue order.
    func relations(touching id: WorkID) -> [RelationEdge] { relationIndex.touching[id] ?? [] }
    @ObservationIgnored private var mergeRevision=0
    @ObservationIgnored private var identityAmbiguous:Set<CatalogIdentity> = []
    @ObservationIgnored private var edgeIDSet:Set<String> = []
    @ObservationIgnored private var artistQIDs:Set<String> = []
    @ObservationIgnored private var personQIDs:Set<String> = []
    /// Off: every merge rebuilds the whole catalogue as before 0.5.25.
    @ObservationIgnored var incrementalMergeEnabled = true
    /// The identity index exists only after the complete reconciles of `init`.
    @ObservationIgnored private var incrementalReady = false
    @ObservationIgnored private(set) var incrementalMerges = 0
    @ObservationIgnored private(set) var completeMerges = 0
    private var mergeState:MergeState { .init(works:works,edges:edges,stories:stories,aliases:aliases,index:identityIndex,entryPoints:entryPoints,ambiguous:identityAmbiguous,edgeIDs:edgeIDSet,artistQIDs:artistQIDs,personQIDs:personQIDs) }
    #if DEBUG
    /// Tests compare the two merge paths by everything a merge leaves behind.
    var mergeBookkeeping: (aliases: [String: String], index: [String: String], ambiguous: Set<String>, edgeIDs: Set<String>, qids: Set<String>) {
        (Dictionary(uniqueKeysWithValues: aliases.filter { $0.key != $0.value }.map { ($0.key.rawValue, $0.value.rawValue) }),
         Dictionary(uniqueKeysWithValues: identityIndex.map { ($0.key.kind + "#" + $0.key.number, $0.value.rawValue) }),
         Set(identityAmbiguous.map { $0.kind + "#" + $0.number }), edgeIDSet,
         Set(artistQIDs.map { "artist:" + $0 }).union(personQIDs.map { "person:" + $0 }))
    }
    #endif
    func merge(_ snapshot: CatalogSnapshot, persist: Bool = true) throws {
        // The state passed here is released before the change is applied, so the records are
        // updated in place instead of being copied (10,000 of them) for every merge.
        if incrementalMergeEnabled, incrementalReady, let delta = Self.delta(snapshot, state: mergeState) { applyDelta(delta, persist: persist); return }
        applyMerge(try Self.reconcile(snapshot,state:mergeState),persist:persist)
    }
    /// A processor migration can rename an unverified local recording while
    /// preserving its bookmarks. It cannot undo or rewrite an Apple identity.
    @discardableResult func migrateProvisionalRecording(_ old: WorkID, to requested: WorkID, expected: DiscoveryIdentity) -> Bool {
        let target = canonicalID(for: requested)
        guard old.rawValue.hasPrefix("lead:recording:"), canonicalID(for: old) == old, old != target,
              let prior = works[old], let next = works[target], prior.catalogRecordingID == nil,
              prior.discovery?.layer == .recording, next.isSong,
              let release = expected.releaseTitle, !release.isEmpty,
              let priorRelease = prior.discovery?.releaseTitle,
              RecordingCatalogMatch.albumKey(priorRelease) == RecordingCatalogMatch.albumKey(release),
              let nextRelease = next.discovery?.releaseTitle ?? next.albumID.map({ work($0).title }),
              RecordingCatalogMatch.albumKey(nextRelease) == RecordingCatalogMatch.albumKey(release),
              DiscoveryRecordingIdentity.sameCredits(prior.creator, next.creator),
              prior.discovery?.nameKeys.isDisjoint(with: expected.nameKeys) == false else { return false }
        var state = mergeState
        state.aliases[old] = target
        do {
            applyMerge(try Self.reconcile(.init(works: [], relations: []), state: state), persist: true)
            return true
        } catch { return false }
    }
    /// Old reports classified an OVA series as one performance video. Correct
    /// only unbound local identities with the same consulted page and title.
    @discardableResult func migrateLegacyScreenSeries(_ old: WorkID, to target: WorkID) -> Bool {
        guard old != target, old.rawValue.hasPrefix("lead:video:"), canonicalID(for: old) == old,
              let prior = works[old], prior.knowledgeID == nil, prior.catalogID == nil,
              let a = prior.discovery, a.layer == .video, a.edition.uppercased().contains("OVA"),
              let next = works[canonicalID(for: target)], let b = next.discovery, b.layer == .tv,
              !a.nameKeys.isDisjoint(with: b.nameKeys),
              let source = DiscoveryCore.sourceKey(a.identitySource), source == DiscoveryCore.sourceKey(b.identitySource) else { return false }
        var state = mergeState; state.aliases[old] = next.id
        // These came from the mistaken single-video classification. A series
        // cannot itself be a music video or a performed recording.
        state.edges.removeAll { $0.from == old && [.musicVideoOf, .performanceOf].contains($0.predicate) }
        do { applyMerge(try Self.reconcile(.init(works: [], relations: []), state: state), persist: true); return true }
        catch { return false }
    }
    /// Replace this page's report atomically, keeping other providers and all
    /// catalog works available for collections and a return to the normal app.
    func replaceLeadRelations(from requested: WorkID, with snapshot: CatalogSnapshot) throws {
        try replaceLeadRelations(from: requested, with: snapshot,
            researchProvider: nil)
    }
    func replaceLeadRelations(from requested: WorkID, with snapshot: CatalogSnapshot, researchProvider: String?) throws {
        let root = canonicalID(for: requested)
        func withoutOldRelations() -> (state: MergeState, removed: Bool) {
            var state = mergeState
            var removed: [String] = []
            state.edges.removeAll {
                let gone = ($0.researchRoot.map { canonicalID(for: $0) == root } ?? (canonicalID(for: $0.from) == root && $0.predicate == .publicRelation))
                    && $0.source.title == "线索" && $0.source.researchProvider == researchProvider
                if gone { removed.append($0.id) }
                return gone
            }
            state.edgeIDs.subtract(removed)
            return (state, !removed.isEmpty)
        }
        if incrementalMergeEnabled, incrementalReady {
            let prepared: (delta: MergeDelta, edges: [RelationEdge], ids: Set<String>, removed: Bool)? = {
                let cleared = withoutOldRelations()
                return Self.delta(snapshot, state: cleared.state).map { ($0, cleared.state.edges, cleared.state.edgeIDs, cleared.removed) }
            }()
            if let prepared {
                if prepared.removed { edges = prepared.edges; edgeIDSet = prepared.ids }
                applyDelta(prepared.delta, persist: true, contentAlreadyChanged: prepared.removed)
                return
            }
        }
        applyMerge(try Self.reconcile(snapshot, state: withoutOldRelations().state), persist: true)
    }
    /// Research is a collection of independent candidates. Validate each against
    /// a private state, then commit its accepted subset once. Ordinary catalog
    /// imports retain their stricter all-or-nothing contract.
    func replaceValidLeadRelations(from requested: WorkID, with snapshot: CatalogSnapshot,
                                   researchProvider: String?, preserveExisting: Bool) -> Set<WorkID> {
        // Normal replies are valid. Reconcile the whole accepted batch once;
        // only fall back to per-item isolation when that actually fails. A phone
        // with thousands of cached records must not sort/encode it for every card.
        do {
            var unique: [WorkID: Work] = [:], order: [WorkID] = []
            for item in snapshot.works {
                _ = try Self.identity(of: item)
                guard Self.validKnowledgeIdentity(item) else { throw CatalogError.invalidData }
                if let prior = unique[item.id] {
                    guard prior.kind == item.kind,
                          prior.knowledgeID == nil || item.knowledgeID == nil || prior.knowledgeID == item.knowledgeID else { throw CatalogError.invalidData }
                    if let before = try Self.identity(of: prior), let after = try Self.identity(of: item), before != after {
                        throw CatalogError.invalidData
                    }
                    unique[item.id] = Self.combine(prior, with: item, incomingWasApple: false, identicalCatalog: true)
                } else { unique[item.id] = item; order.append(item.id) }
            }
            let batch = CatalogSnapshot(works: order.compactMap { unique[$0] }, relations: snapshot.relations)
            if preserveExisting && snapshot.relations.isEmpty { try merge(batch) }
            else { try replaceLeadRelations(from: requested, with: batch, researchProvider: researchProvider) }
            return []
        } catch { }
        let root = canonicalID(for: requested)
        var state = mergeState, rejected: Set<WorkID> = []
        for item in snapshot.works {
            do { state = try Self.reconcile(.init(works: [item], relations: []), state: state) }
            catch { rejected.insert(item.id) }
        }
        let withOldEdges = state
        state.edges.removeAll {
            ($0.researchRoot.map { canonicalID(for: $0) == root } ?? ($0.from == root && $0.predicate == .publicRelation))
                && $0.source.title == "线索" && $0.source.researchProvider == researchProvider
        }
        var accepted = 0
        for edge in snapshot.relations where !rejected.contains(edge.from) && !rejected.contains(edge.to) {
            do { state = try Self.reconcile(.init(works: [], relations: [edge]), state: state); accepted += 1 }
            catch { }
        }
        if accepted == 0 && (preserveExisting || !snapshot.relations.isEmpty) { state = withOldEdges }
        applyMerge(state, persist: true)
        return rejected
    }

    /// Optional image arrivals refine an already installed name card. They do
    /// not rebuild the entire catalog, change identity, or write a partial graph.
    func refineLeadPresentation(_ requested: WorkID, artwork: String, page: String?) {
        let id = canonicalID(for: requested)
        guard let current = works[id], !artwork.isEmpty || page != nil else { return }
        let safeArt = ArtworkLocation.stored(artwork)
        let incoming = Work(id: id, title: current.title, creator: current.creator, kind: current.kind,
            art: safeArt, detail: current.detail, url: page)
        let updated = Self.combine(current, with: incoming, incomingWasApple: false, identicalCatalog: true)
        guard updated != current else { return }
        works[id] = updated
        mergeRevision += 1
        revision += 1
        save()
    }
    /// Covers found after the cards went up, applied as one change (one redraw, one save).
    func refineLeadPresentations(_ items: [(WorkID, String)]) {
        var changed = false
        for (requested, artwork) in items where !artwork.isEmpty {
            let id = canonicalID(for: requested)
            guard let current = works[id] else { continue }
            let incoming = Work(id: id, title: current.title, creator: current.creator, kind: current.kind,
                art: ArtworkLocation.stored(artwork), detail: current.detail, url: nil)
            let updated = Self.combine(current, with: incoming, incomingWasApple: false, identicalCatalog: true)
            if updated != current { works[id] = updated; changed = true }
        }
        guard changed else { return }
        mergeRevision += 1
        revision += 1
        save()
    }
    private func mergeAsync(_ snapshot:CatalogSnapshot,persist:Bool=true,verifiedAliases:[WorkID:WorkID]=[:]) async throws {
        while true {
            if incrementalMergeEnabled, incrementalReady, verifiedAliases.isEmpty, let delta = Self.delta(snapshot, state: mergeState) {
                applyDelta(delta, persist: persist); return
            }
            let revision=mergeRevision, state=mergeState
            let result=try await Task.detached(priority:.userInitiated) { try Self.reconcile(snapshot,state:state,verifiedAliases:verifiedAliases) }.value
            try Task.checkCancellation()
            guard revision == mergeRevision else { continue }
            applyMerge(result,persist:persist); return
        }
    }
    private func applyDelta(_ delta:MergeDelta,persist:Bool,contentAlreadyChanged:Bool=false) {
        incrementalMerges += 1
        mergeRevision += 1
        for (identity, id) in delta.index { identityIndex[identity] = id }
        artistQIDs.formUnion(delta.artistQIDs); personQIDs.formUnion(delta.personQIDs)
        guard delta.changesContent || contentAlreadyChanged else { return }
        for (alias, target) in delta.aliases { aliases[alias] = target }
        for (id, work) in delta.works { works[id] = work }
        for (index, edge) in delta.replacedEdges where edges.indices.contains(index) { edges[index] = edge }
        if !delta.edges.isEmpty {
            edges.append(contentsOf: delta.edges)
            for edge in delta.edges { edgeIDSet.insert(edge.id) }
        }
        if !delta.stories.isEmpty { stories.append(contentsOf: delta.stories) }
        revision += 1
        if persist { save() }
    }
    private func applyMerge(_ result:MergeState,persist:Bool) {
        completeMerges += 1
        let changed = works != result.works || edges != result.edges || stories != result.stories
            || aliases != result.aliases || entryPoints != result.entryPoints
        mergeRevision += 1
        identityIndex = result.index
        identityAmbiguous = result.ambiguous; edgeIDSet = result.edgeIDs
        artistQIDs = result.artistQIDs; personQIDs = result.personQIDs
        guard changed else { return }
        works=result.works; edges=result.edges; stories=result.stories
        aliases=result.aliases; identityIndex=result.index; entryPoints=result.entryPoints
        revision += 1
        if persist { save() }
    }
    nonisolated private static func reconcile(_ snapshot:CatalogSnapshot,state:MergeState,verifiedAliases:[WorkID:WorkID]=[:]) throws -> MergeState {
        let measurement = EvalPerformance.begin("Catalog.reconcile", ["works": String(state.works.count), "edges": String(state.edges.count)])
        defer { measurement?.end() }
        let works=state.works, edges=state.edges, stories=state.stories
        var aliases=state.aliases
        let availableIDs = Set(works.keys).union(snapshot.works.map(\.id))
        // Stored redirects are flattened and can only originate in local lead
        // identities. They never rewrite an Apple/catalog identity or form chains.
        let savedAliases = snapshot.identityAliases ?? [:]
        for (rawAlias, rawTarget) in savedAliases {
            guard rawAlias.hasPrefix("lead:"), let alias = WorkID(rawValue: rawAlias),
                  let target = WorkID(rawValue: rawTarget), alias != target,
                  savedAliases[rawTarget] == nil, availableIDs.contains(Self.resolve(target, aliases: aliases))
            else { throw CatalogError.invalidData }
            aliases[alias] = target
        }
        func canonicalID(for id:WorkID) -> WorkID {
            let resolved=Self.resolve(id,aliases:aliases)
            if let identity=Self.identity(fromAppleID:resolved),let known=state.index[identity] { return known }
            if resolved.rawValue.hasPrefix("bangumi:subject:"),let number=resolved.rawValue.split(separator:":").last,
               let known=state.index[CatalogIdentity(kind:"bangumi-subject",number:String(number))] { return known }
            return resolved
        }
        guard snapshot.version == 1, Set(snapshot.works.map(\.id)).count == snapshot.works.count else { throw CatalogError.invalidData }
        for item in snapshot.works {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.invalidData }
            guard Self.validKnowledgeIdentity(item) else { throw CatalogError.invalidData }
            if let existing = works[canonicalID(for: item.id)], existing.kind != item.kind {
                let verifiedRefinement = existing.id.rawValue.hasPrefix("wikidata:")
                    && (["作品", "音乐作品"].contains(existing.kind) || (existing.kind == "文学作品" && item.kind == "书籍"))
                    && existing.knowledgeID != nil && existing.knowledgeID == item.knowledgeID
                guard verifiedRefinement || (existing.bangumiID != nil && existing.bangumiID == item.bangumiID && existing.knowledgeID != nil) else { throw CatalogError.invalidData }
            }
            if let existing = works[canonicalID(for: item.id)]?.knowledgeID, let incoming = item.knowledgeID, existing != incoming { throw CatalogError.invalidData }
            _ = try Self.identity(of: item)
        }
        let allItems = Array(works.values) + snapshot.works
        var nextAliases = aliases
        for (alias,target) in verifiedAliases {
            guard alias.rawValue.hasPrefix("musicbrainz:artist:"),
                  allItems.contains(where: { $0.id == alias && $0.isPerson }),
                  allItems.contains(where: { $0.id == target && $0.isPerson && $0.knowledgeID != nil }) else { throw CatalogError.invalidData }
            nextAliases[alias]=target
        }
        var grouped: [CatalogIdentity: Set<WorkID>] = [:]
        for item in allItems {
            for identity in try Self.identities(of: item) { grouped[identity, default: []].insert(item.id) }
        }
        var knowledgeByID: [WorkID: Set<String>] = [:]
        for item in allItems { if let qid = item.knowledgeID { knowledgeByID[item.id, default: []].insert(qid) } }
        for (key, candidates) in grouped {
            if key.kind.hasPrefix("bangumi"), candidates.reduce(into: Set<String>(), { $0.formUnion(knowledgeByID[$1] ?? []) }).count > 1 { continue }
            let targets = Set(candidates.map { Self.resolve($0, aliases: nextAliases) })
            guard let target = targets.sorted(by: Self.preferredIdentity).first else { continue }
            for id in candidates { nextAliases[id] = target }
        }
        var proposedIndex: [CatalogIdentity: WorkID] = [:]
        for (identity, candidates) in grouped {
            if Set(candidates.map { Self.resolve($0, aliases: nextAliases) }).count == 1, let candidate = candidates.first { proposedIndex[identity] = Self.resolve(candidate, aliases: nextAliases) }
        }
        func canonical(_ id: WorkID) -> WorkID {
            let resolved = Self.resolve(id, aliases: nextAliases)
            return Self.identity(fromAppleID: resolved).flatMap { proposedIndex[$0] } ?? resolved
        }

        // Choose curated records first, independent of API response ordering.
        let existingIDs = Set(works.keys)
        let ordered = allItems.sorted { lhs, rhs in
            if lhs.id != rhs.id { return Self.preferredIdentity(lhs.id, rhs.id) }
            // Existing editorial text wins; incoming API text may refresh API-only records below.
            return false
        }
        var next: [WorkID: Work] = [:]
        for item in ordered {
            let target = canonical(item.id)
            let remapped = Self.remap(item, to: target, canonical: canonical)
            if let current = next[target] {
                if let existingQID = current.knowledgeID, let newQID = remapped.knowledgeID, existingQID != newQID { throw CatalogError.invalidData }
                let knownIdentity = try Self.identity(of: current)
                let incomingIdentity = try Self.identity(of: item)
                let exactMatch = knownIdentity != nil && knownIdentity == incomingIdentity
                next[target] = Self.combine(current, with: remapped, incomingWasApple: item.id.rawValue.hasPrefix("apple:"), identicalCatalog: exactMatch)
            } else { next[target] = remapped }
        }
        // Refresh dynamic records without replacing curated names or credits.
        for item in snapshot.works where (item.id.rawValue.hasPrefix("apple:") || item.id.rawValue.hasPrefix("local:") || item.id.rawValue.hasPrefix("wikidata:")) && existingIDs.contains(item.id) && canonical(item.id) == item.id {
            let remapped = Self.remap(item, to: item.id, canonical: canonical)
            if let current = next[item.id] {
                next[item.id] = Self.combine(remapped, with: current, incomingWasApple: true, identicalCatalog: true)
            }
        }
        for item in next.values {
            guard item.creatorIDs.allSatisfy({ next[$0]?.isPerson == true }),
                  item.albumID.map({ next[$0]?.isAlbum == true }) ?? true else { throw CatalogError.invalidData }
        }
        var peopleByQID: [String: WorkID] = [:]
        for person in next.values.filter({ $0.isPerson && !$0.id.rawValue.hasPrefix("apple:") }).sorted(by: { Self.preferredIdentity($0.id, $1.id) }) {
            if let qid = person.knowledgeID, peopleByQID[qid] == nil { peopleByQID[qid] = person.id }
        }
        let personCredits: Set<RelationKind> = [.composedBy, .directedBy, .authoredBy, .performedBy]
        var nextEdges: [RelationEdge] = []
        var edgeIDs = Set<String>()
        for edge in edges + snapshot.relations {
            guard edge.from != edge.to, !edge.label.isEmpty, !edge.inverseLabel.isEmpty,
                  Self.validSource(edge.source) else { throw CatalogError.invalidData }
            let from = canonical(edge.from)
            var to = canonical(edge.to)
            guard next[from] != nil, next[to] != nil else { throw CatalogError.invalidData }
            // An Apple artist profile identifies a person but is not itself the
            // name credited by a Wikidata work-level statement. This also repairs
            // older caches; Apple release/artist relationships stay untouched.
            if personCredits.contains(edge.predicate),
               URLComponents(string: edge.source.url)?.host?.lowercased() == "www.wikidata.org",
               to.rawValue.hasPrefix("apple:artist:"), let qid = next[to]?.knowledgeID,
               let person = peopleByQID[qid] { to = person }
            // Two aliases may have been connected before canonicalization.
            guard from != to else { continue }
            // Old releases saved these exact memberships under a display title
            // ("song · Apple Music"). Reattach the current, verified catalog
            // receipt so selection does not discard them by their old label.
            let source: Source
            if let owner = next[from], let target = next[to],
               target.catalogID != nil,
               let receipt = owner.catalogSource, receipt.title == "iTunes",
               (edge.predicate == .inAlbum && owner.albumID == to && owner.catalogTrack?.albumID == target.catalogID
                || edge.predicate == .performedBy && owner.creatorIDs.contains(to)
                    && (owner.catalogTrack?.artistID == target.catalogID || owner.isAlbum)) {
                source = receipt
            } else { source = edge.source }
            let mapped = RelationEdge(from: from, to: to, predicate: edge.predicate, label: edge.label, inverseLabel: edge.inverseLabel, source: source, researchRoot: edge.researchRoot.map(canonical))
            if edgeIDs.insert(mapped.id).inserted { nextEdges.append(mapped) }
        }
        var nextStories: [EditorialStory] = []
        var storyIDs = Set<String>()
        for story in stories + snapshot.stories {
            let mapped = EditorialStory(id: story.id, workID: canonical(story.workID), title: story.title, body: story.body, entityLinks: story.entityLinks.mapValues(canonical), source: story.source, additionalSources: story.additionalSources, relatedEntityIDs: story.relatedEntityIDs.compactMap { WorkID(rawValue: $0).map { canonical($0).rawValue } }, score: story.score, mentions: story.mentions)
            guard next[mapped.workID] != nil, Self.validSource(mapped.source),
                  (mapped.additionalSources ?? []).allSatisfy(Self.validSource),
                  mapped.entityLinks.values.allSatisfy({ next[$0] != nil }) else { throw CatalogError.invalidData }
            if storyIDs.insert(mapped.id).inserted { nextStories.append(mapped) }
        }
        var indexed: [CatalogIdentity: Set<WorkID>] = [:]
        for item in next.values {
            for identity in try Self.identities(of: item) { indexed[identity, default: []].insert(item.id) }
        }
        let index = indexed.compactMapValues { $0.count == 1 ? $0.first : nil }
        var seen=Set<WorkID>()
        let entries=state.entryPoints.map(canonical).filter { next[$0] != nil && seen.insert($0).inserted }
        var artistQIDs=Set<String>(), personQIDs=Set<String>()
        for person in next.values where person.isPerson {
            guard let qid=person.knowledgeID else { continue }
            if person.id.rawValue.hasPrefix("apple:") { artistQIDs.insert(qid) } else { personQIDs.insert(qid) }
        }
        return MergeState(works:next,edges:nextEdges,stories:nextStories,aliases:nextAliases,index:index,entryPoints:entries,
                          ambiguous:Set(indexed.filter { $0.value.count > 1 }.keys),edgeIDs:edgeIDs,artistQIDs:artistQIDs,personQIDs:personQIDs)
    }

    /// The same result as `reconcile` for the common small merge, computed from what the merge
    /// brings alone: records that are new or refresh a record already here, and their relations.
    /// Anything that could regroup identities (two records turning out to be one, a preferred id
    /// taking over, a person gaining a Wikidata identity that existing credits should follow)
    /// returns nil and goes through the complete reconcile. `AhaCatalogMergeTests` checks the two
    /// paths against each other on the phone's own catalogue.
    nonisolated private static func delta(_ snapshot:CatalogSnapshot,state:MergeState) -> MergeDelta? {
        guard snapshot.version == 1, (snapshot.identityAliases ?? [:]).isEmpty,
              Set(snapshot.works.map(\.id)).count == snapshot.works.count else { return nil }
        let works=state.works
        var delta=MergeDelta()
        func resolve(_ id:WorkID) -> WorkID {
            var result=id, visited=Set<WorkID>()
            while let next=delta.aliases[result] ?? state.aliases[result], next != result, visited.insert(result).inserted { result=next }
            return result
        }
        func canonical(_ id:WorkID) -> WorkID {
            let resolved=resolve(id)
            return identity(fromAppleID:resolved).flatMap { delta.index[$0] ?? state.index[$0] } ?? resolved
        }
        func record(_ id:WorkID) -> Work? { delta.works[id] ?? works[id] }
        var claimed:[CatalogIdentity:WorkID] = [:]
        var sourceSensitive=Set<WorkID>()
        for item in snapshot.works {
            guard !item.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, validKnowledgeIdentity(item),
                  let identities=try? identities(of:item) else { return nil }
            let incomingIdentity:CatalogIdentity?
            do { incomingIdentity=try identity(of:item) } catch { return nil }
            let target=canonical(item.id)
            // Two records of this same merge meeting in one place is a regrouping.
            guard delta.works[target] == nil else { return nil }
            for identity in identities {
                guard !state.ambiguous.contains(identity) else { return nil }
                if let owner=claimed[identity] ?? state.index[identity], owner != target { return nil }
            }
            if let existing=works[target] {
                guard existing.kind == item.kind else { return nil }
                if let known=existing.knowledgeID, let incoming=item.knowledgeID, known != incoming { return nil }
                // The record already here must stay the one the others point at.
                if item.id != target, resolve(item.id) != target, !preferredIdentity(target,item.id) { return nil }
                let knownIdentity:CatalogIdentity?
                do { knownIdentity=try identity(of:existing) } catch { return nil }
                let remapped=remap(item,to:target,canonical:canonical)
                var combined=combine(existing,with:remapped,incomingWasApple:item.id.rawValue.hasPrefix("apple:"),
                                     identicalCatalog:knownIdentity != nil && knownIdentity == incomingIdentity)
                if item.id.rawValue.hasPrefix("apple:") || item.id.rawValue.hasPrefix("local:") || item.id.rawValue.hasPrefix("wikidata:"),
                   works[item.id] != nil, canonical(item.id) == item.id {
                    combined=combine(remap(item,to:item.id,canonical:canonical),with:combined,incomingWasApple:true,identicalCatalog:true)
                }
                // A Wikidata identity arriving on a person or an artist profile moves existing credits
                // only when the other kind of record already carries the same one.
                if combined.knowledgeID != existing.knowledgeID, combined.isPerson, let qid=combined.knowledgeID {
                    if target.rawValue.hasPrefix("apple:") {
                        guard !state.personQIDs.contains(qid), !delta.personQIDs.contains(qid) else { return nil }
                        delta.artistQIDs.insert(qid)
                    } else {
                        guard !state.artistQIDs.contains(qid), !delta.artistQIDs.contains(qid) else { return nil }
                        delta.personQIDs.insert(qid)
                    }
                }
                guard let after=try? Self.identities(of:combined) else { return nil }
                for identity in after {
                    guard !state.ambiguous.contains(identity) else { return nil }
                    if let owner=claimed[identity] ?? state.index[identity] { guard owner == target else { return nil } }
                    else { delta.index[identity]=target }
                    claimed[identity]=target
                }
                for identity in identities { claimed[identity]=target }
                if !identities.isEmpty {
                    if state.aliases[item.id] != target { delta.aliases[item.id]=target }
                    if state.aliases[target] != target { delta.aliases[target]=target }
                }
                if combined != existing {
                    delta.works[target]=combined
                    if combined.catalogSource != existing.catalogSource || combined.albumID != existing.albumID
                        || combined.creatorIDs != existing.creatorIDs || combined.catalogID != existing.catalogID
                        || combined.catalogTrack != existing.catalogTrack { sourceSensitive.insert(target) }
                }
            } else {
                guard target == item.id else { return nil }
                let created=remap(item,to:item.id,canonical:canonical)
                if created.isPerson, let qid=created.knowledgeID {
                    if item.id.rawValue.hasPrefix("apple:") {
                        guard !state.personQIDs.contains(qid), !delta.personQIDs.contains(qid) else { return nil }
                        delta.artistQIDs.insert(qid)
                    } else {
                        guard !state.artistQIDs.contains(qid), !delta.artistQIDs.contains(qid) else { return nil }
                        delta.personQIDs.insert(qid)
                    }
                }
                guard let after=try? Self.identities(of:created) else { return nil }
                for identity in after {
                    guard !state.ambiguous.contains(identity), state.index[identity] == nil, claimed[identity] == nil else { return nil }
                }
                delta.works[item.id]=created
                for identity in after { delta.index[identity]=item.id; claimed[identity]=item.id }
                for identity in identities { claimed[identity]=item.id }
                if !identities.isEmpty, state.aliases[item.id] != item.id { delta.aliases[item.id]=item.id }
            }
        }
        for item in delta.works.values {
            guard item.creatorIDs.allSatisfy({ record($0)?.isPerson == true }),
                  item.albumID.map({ record($0)?.isAlbum == true }) ?? true else { return nil }
        }
        let personCredits:Set<RelationKind> = [.composedBy,.directedBy,.authoredBy,.performedBy]
        enum Mapped { case edge(RelationEdge), skip, complete }
        func map(_ edge:RelationEdge) -> Mapped {
            guard edge.from != edge.to, !edge.label.isEmpty, !edge.inverseLabel.isEmpty, validSource(edge.source) else { return .complete }
            let from=canonical(edge.from), to=canonical(edge.to)
            guard let owner=record(from), let target=record(to) else { return .complete }
            // A Wikidata credit on an Apple artist profile may belong to the person record instead:
            // that needs every person in the catalogue, so the complete reconcile decides.
            if personCredits.contains(edge.predicate), to.rawValue.hasPrefix("apple:artist:"), let qid=target.knowledgeID,
               state.personQIDs.contains(qid) || delta.personQIDs.contains(qid),
               URLComponents(string:edge.source.url)?.host?.lowercased() == "www.wikidata.org" { return .complete }
            guard from != to else { return .skip }
            let source:Source
            if target.catalogID != nil, let receipt=owner.catalogSource, receipt.title == "iTunes",
               (edge.predicate == .inAlbum && owner.albumID == to && owner.catalogTrack?.albumID == target.catalogID
                || edge.predicate == .performedBy && owner.creatorIDs.contains(to)
                    && (owner.catalogTrack?.artistID == target.catalogID || owner.isAlbum)) {
                source=receipt
            } else { source=edge.source }
            return .edge(RelationEdge(from:from,to:to,predicate:edge.predicate,label:edge.label,inverseLabel:edge.inverseLabel,
                                      source:source,researchRoot:edge.researchRoot.map(canonical)))
        }
        // Relations already here keep their form unless a record they hang on changed its catalogue receipt.
        if !sourceSensitive.isEmpty {
            for (index,edge) in state.edges.enumerated() where sourceSensitive.contains(edge.from) || sourceSensitive.contains(edge.to) {
                switch map(edge) {
                case .edge(let mapped): if mapped != edge { guard mapped.id == edge.id else { return nil }; delta.replacedEdges[index]=mapped }
                case .skip, .complete: return nil
                }
            }
        }
        var added=Set<String>()
        for edge in snapshot.relations {
            switch map(edge) {
            case .complete: return nil
            case .skip: continue
            case .edge(let mapped):
                if !state.edgeIDs.contains(mapped.id), added.insert(mapped.id).inserted { delta.edges.append(mapped) }
            }
        }
        var storyIDs=Set(state.stories.map(\.id))
        for story in snapshot.stories {
            let mapped=EditorialStory(id:story.id,workID:canonical(story.workID),title:story.title,body:story.body,
                entityLinks:story.entityLinks.mapValues(canonical),source:story.source,additionalSources:story.additionalSources,
                relatedEntityIDs:story.relatedEntityIDs.compactMap { WorkID(rawValue:$0).map { canonical($0).rawValue } },
                score:story.score,mentions:story.mentions)
            guard record(mapped.workID) != nil, validSource(mapped.source), (mapped.additionalSources ?? []).allSatisfy(validSource),
                  mapped.entityLinks.values.allSatisfy({ record($0) != nil }) else { return nil }
            if storyIDs.insert(mapped.id).inserted { delta.stories.append(mapped) }
        }
        return delta
    }

    nonisolated static func validSource(_ source: Source) -> Bool {
        guard let url = URLComponents(string: source.url), url.scheme == "https", let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func localMatches(_ query: String) -> [WorkID] {
        let needle = Self.normalized(query)
        guard !needle.isEmpty else { return entryPoints }
        // A results list asks once per group and per redraw: the same words on the same catalogue
        // are answered from the last scan (folding 10,000 titles took tens of milliseconds each time).
        let current = revision
        if let cache = localMatchCache, cache.needle == needle, cache.revision == current, cache.count == works.count { return cache.ids }
        let ids = works.values.filter { Self.normalized($0.title + " " + $0.creator).contains(needle) }
            .sorted { lhs, rhs in
                let a = Self.normalized(lhs.title) == needle; let b = Self.normalized(rhs.title) == needle
                if a != b { return a }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }.map(\.id)
        localMatchCache = (needle, current, works.count, ids)
        return ids
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String, country: String, kind: CatalogSearchKind, recordingContext: RecordingSearchContext? = nil,
                persist: Bool = true, candidateOnly: Bool = false) async throws -> [WorkID] {
        let result: CatalogResponse
        if kind.usesKnowledgeSearch {
            result = try await knowledgeService.searchWorks(query, kind: kind, anchors: knowledgeAnchors)
        } else {
            if candidateOnly, let publicService = service as? ITunesCatalogService {
                result = try await publicService.searchCandidates(query, country: country, kind: kind, recordingContext: recordingContext)
            } else { result = try await service.search(query, country: country, kind: kind, recordingContext: recordingContext) }
        }
        try Task.checkCancellation()
        try await mergeAsync(result.snapshot, persist: persist)
        return canonicalIDs(result.results).filter { works[$0] != nil }
    }

    func importLink(_ text: String, country: String) async throws -> WorkID {
        let link = try CatalogLink.parse(text)
        let response = try await service.lookup(link.id, country: link.country ?? country, entity: nil, kind: link.kind)
        try Task.checkCancellation()
        try merge(response.snapshot)
        guard let id = canonicalIDs(response.results).first, works[id] != nil else { throw CatalogError.notFound }
        return id
    }

    /// Candidate searches do not prefetch every result's artist. Resolve the
    /// dedicated artist row when the user actually opens that credit.
    func mainArtist(for requested: WorkID, country: String) async -> WorkID? {
        let item = work(canonicalID(for: requested))
        if let known = item.creatorIDs.first { return canonicalID(for: known) }
        guard let number = item.catalogTrack?.artistID else { return nil }
        do {
            let response = try await service.lookup(number, country: item.storeCountry ?? country, entity: nil, kind: .artists)
            try Task.checkCancellation(); try await mergeAsync(response.snapshot)
            return response.results.map { canonicalID(for: $0) }.first { work($0).isPerson }
        } catch { return nil }
    }

    func canonicalID(for id: WorkID) -> WorkID {
        let resolved = Self.resolve(id, aliases: aliases)
        if let identity = Self.identity(fromAppleID: resolved), let known = identityIndex[identity] { return known }
        if resolved.rawValue.hasPrefix("bangumi:subject:"), let number = resolved.rawValue.split(separator: ":").last,
           let known = identityIndex[CatalogIdentity(kind: "bangumi-subject", number: String(number))] { return known }
        return resolved
    }

    func canonicalIDs(_ ids: [WorkID]) -> [WorkID] {
        var seen = Set<WorkID>()
        return ids.map { canonicalID(for: $0) }.filter { seen.insert($0).inserted }
    }

    func enrich(_ requestedID: WorkID, retry: Bool = false) async {
        async let catalog: Void = enrichCatalog(requestedID, retry: retry)
        async let knowledge: Void = expandKnowledge(requestedID, retry: retry)
        _ = await (catalog, knowledge)
        await discoverSong(requestedID, retry: retry)
    }

    func discoverSong(_ requestedID: WorkID, retry: Bool = false) async {
        let id = canonicalID(for: requestedID)
        guard !Task.isCancelled, let song = works[id], song.isSong else { return }
        if let task = songDiscoveryTasks[id] { await task.value; return }
        guard retry || !songDiscoveryLoaded.contains(id) else { return }
        let artistIDs = song.creatorIDs.compactMap { artist -> String? in
            guard let person = works[canonicalID(for: artist)], person.isPerson else { return nil }
            return (try? Self.identity(of: person))?.number
        }
        // Missing catalog metadata is not a completed negative background lookup.
        guard !artistIDs.isEmpty else { return }
        let task = Task { @MainActor in
            songDiscoveryLoading.insert(id); songDiscoveryErrors[id] = nil
            defer { songDiscoveryLoading.remove(id); songDiscoveryTasks[id] = nil }
            do {
                if let curated = songEditorial?.snapshot(for: song, artistIDs: artistIDs) {
                    try merge(curated)
                }
                let response = try await songDiscoveryService.discover(title: song.title, artistIDs: artistIDs)
                try Task.checkCancellation()
                var failed = response.retryableFailure
                for destination in response.destinations {
                    do {
                        let target = try await openKnowledgeCandidate(destination.qid)
                        try Task.checkCancellation()
                        let kind = work(target).kind
                        guard ["电影", "电视剧", "漫画", "书籍", "文学作品"].contains(kind) else { continue }
                        let screenWork = ["电影", "电视剧"].contains(kind)
                        // A precise reviewed ED/score connection already covers
                        // this destination; retain its stronger wording/source.
                        let hasCredit = edges.contains {
                            $0.from == id && $0.to == target && [.endingOf, .soundtrackOf, .themeMusic, .songContext].contains($0.predicate)
                        }
                        if !hasCredit {
                            try merge(CatalogSnapshot(works: [], relations: [
                                // Some theme tables link the franchise's original
                                // literature, not its screen adaptation. Preserve
                                // that actual identity and never label it an anime.
                                RelationEdge(from: id, to: target, predicate: screenWork ? .themeMusic : .songContext,
                                    label: screenWork ? "主题曲用于" : "相关作品",
                                    inverseLabel: screenWork ? "主题曲" : "关联歌曲", source: destination.source)
                            ]))
                        }
                    } catch {
                        try Task.checkCancellation()
                        failed = "歌曲背景暂未完整载入。"
                    }
                }
                songDiscoveryErrors[id] = failed
                if failed == nil { songDiscoveryLoaded.insert(id) }
            } catch {
                guard !Task.isCancelled else { return }
                songDiscoveryErrors[id] = "歌曲背景暂未完整载入。"
            }
        }
        songDiscoveryTasks[id] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func enrichCatalog(_ requestedID: WorkID, retry: Bool = false) async {
        let id = canonicalID(for: requestedID)
        if let task = tasks[id] { await task.value; return }
        guard retry || !loaded.contains(id), let item = works[id],
              let identity = try? Self.identity(of: item) else { return }
        let task = Task { @MainActor in
            loading.insert(id); lookupErrors[id] = nil
            defer { loading.remove(id); tasks[id] = nil }
            do {
                let country = item.storeCountry ?? (item.url.flatMap { try? CatalogLink.parse($0).country } ?? nil) ?? "jp"
                let entity = item.isPerson ? "album" : item.isAlbum ? "song" : nil
                let response = try await service.lookup(identity.number, country: country, entity: entity, kind: nil)
                try Task.checkCancellation()
                try await mergeAsync(response.snapshot)
                loaded.insert(id)
            } catch is CancellationError { }
            catch { lookupErrors[id] = CatalogError.message(error) }
        }
        tasks[id] = task
        await task.value
    }

    func resolvePlaybackRegion(_ requested: WorkID, browsingRegion: String, storefront: String?) async {
        let id = canonicalID(for: requested)
        if let task = regionTasks[id] { await task.value; return }
        guard work(id).resolvedRegion == nil, !regionAttempts.contains(id), let number = work(id).catalogRecordingID else { return }
        let task = Task { @MainActor in
            defer { regionTasks[id] = nil }
            if work(id).catalogSource?.title == "iTunes", let region=work(id).storeCountry, work(id).catalogTrack != nil {
                var current=work(id); current.resolvedRegion=region; current.regionOrigin = .known
                try? await mergeAsync(.init(works:[current],relations:[])); loaded.insert(id); return
            }
            regionAttempts.insert(id)
            let current = work(id)
            let result = await PlaybackRegionResolver.resolve(number: number, known: current.storeCountry,
                storefront: storefront, browsing: browsingRegion, service: service)
            guard let result else { publicSelectionReady.insert(id); return }
            do {
                try await mergeAsync(result.response.snapshot)
                loaded.insert(id)
                var updated = work(id); updated.resolvedRegion = result.region; updated.regionOrigin = result.origin
                try await mergeAsync(.init(works: [updated], relations: []))
            } catch { lookupErrors[id] = CatalogError.message(error) }
        }
        regionTasks[id] = task
        await task.value
    }

    /// Independent from legacy name-search and story enrichment. The caller
    /// resolves the playback region before entering this exact-ID path.
    func enrichPublicRelations(_ requested: WorkID, collector: PublicRelationService = .shared) async {
        let id = canonicalID(for: requested)
        // Playback publishes the title before the catalog supplies its exact
        // album/track identity. That intermediate state is not an empty result.
        guard !work(id).isSong || work(id).catalogRecordingID == nil || work(id).catalogTrack != nil else { return }
        if let task = publicTasks[id] { await task.value; return }
        if publicReports[id]?.failures.isEmpty == true { return }
        let task = Task { @MainActor in
            publicRelationsLoading.insert(id)
            defer { publicRelationsLoading.remove(id); publicTasks[id] = nil }
            if work(id).catalogSource?.title == "iTunes" { await enrichCatalog(id) }
            guard !Task.isCancelled else { return }
            do {
                let report = try await collector.resolve(work(id), known: Array(works.values)) { [weak self] partial in
                    await self?.receivePublicBatch(partial, for:id)
                }
                try Task.checkCancellation()
                try await mergeAsync(report.snapshot,verifiedAliases:report.verifiedArtistAliases ?? [:])
                publicReports[id] = report
            } catch is CancellationError { }
            catch { lookupErrors[id] = CatalogError.message(error) }
        }
        publicTasks[id] = task
        await task.value
    }

    private func receivePublicBatch(_ report:PublicRelationReport, for id:WorkID) async {
        guard !Task.isCancelled else { return }
        do { try await mergeAsync(report.snapshot,persist:false,verifiedAliases:report.verifiedArtistAliases ?? [:]) }
        catch { lookupErrors[id]=CatalogError.message(error) }
    }

    /// Prepare only the selected objects. The 139-item creator response does
    /// not trigger 139 identity/image requests. Series exclusions are checked
    /// before a work enters the visible inventory.
    func preparePublicSelection(_ requested: WorkID, expanding: Bool = false,
                                onMap: Set<WorkID> = [], excluding: Set<WorkID> = [], collector: PublicRelationService = .shared,
                                artwork: WorkArtworkStore = .shared) async {
        let id = canonicalID(for: requested)
        guard !work(id).isSong || work(id).catalogRecordingID == nil || work(id).catalogTrack != nil else { return }
        let key = id.rawValue + (expanding ? ":map" : ":crate")
        if expanding ? publicMapSelectionReady.contains(id) : publicSelectionReady.contains(id) { return }
        if let task = selectionTasks[key] { await task.value; return }
        let task = Task { @MainActor in
            publicRelationsLoading.insert(id)
            defer { publicRelationsLoading.remove(id); selectionTasks[key] = nil }
            let hasCreatorWorks = work(id).isPerson && PublicCrateInventory.directEdges(id, catalog: self).contains {
                !work($0.other(than: id)).isPerson
            }
            if !hasCreatorWorks { await enrichPublicRelations(id, collector: collector) }
            publicRelationsLoading.insert(id)
            let creators = work(id).isPerson ? [id] : PublicCrateInventory.directEdges(id, catalog: self)
                .map { $0.other(than: id) }.filter { work($0).isPerson }
            for creator in creators {
                let person = work(creator)
                if !PublicCrateInventory.directEdges(creator, catalog: self).contains(where: { $0.source.title == "Bangumi" }),
                   person.knowledgeID != nil { await enrichPublicRelations(creator, collector: collector) }
                if person.knowledgeID == nil, let number = person.catalogID,
                   !publicArtistSongsLoaded.contains(creator) {
                    publicArtistSongsLoaded.insert(creator)
                    do {
                        let response = try await service.lookup(number, country: person.storeCountry ?? "jp", entity: "song", kind: .artists)
                        try Task.checkCancellation(); try await mergeAsync(response.snapshot)
                    } catch is CancellationError { return }
                    catch { lookupErrors[creator] = CatalogError.message(error) }
                }
            }
            @MainActor func picks(_ requireSeries: Bool) -> [(RelationEdge, WorkID)] {
                if expanding && work(id).isPerson {
                    return PublicCrateInventory.creatorWorks(id, catalog: self, limit: 6, musicLimit: 2,
                        excluding: excluding, onMap: onMap, requireSeries: requireSeries).map { ($0, id) }
                }
                return PublicCrateInventory.selectedEdges(id, catalog: self, requireSeries: requireSeries)
            }
            var attempted = Set<WorkID>()
            // A newly read series may eliminate the next candidate. Recompute
            // after each response, retaining only the final ranked selection.
            for _ in 0..<12 {
                guard !Task.isCancelled, let target = picks(false).map({ work($0.0.other(than: $0.1)) })
                    .first(where: { $0.bangumiID != nil && $0.seriesIDs == nil && !attempted.contains($0.id) }) else { break }
                attempted.insert(target.id)
                do {
                    let series = try await collector.series(for: target.bangumiID!)
                    var updated = work(target.id); updated.seriesIDs = series
                    try Task.checkCancellation(); try await mergeAsync(.init(works: [updated], relations: []))
                } catch is CancellationError { return }
                catch { lookupErrors[target.id] = CatalogError.message(error) }
            }
            let targets = picks(true).map { canonicalID(for: $0.0.other(than: $0.1)) }
            // At most two selected objects resolve images at once. An optional
            // slow poster must not hold every subsequent object behind it.
            for offset in stride(from: 0, to: targets.count, by: 2) {
                let batch = targets[offset..<min(offset + 2, targets.count)]
                await withTaskGroup(of: Void.self) { group in
                    for target in batch {
                        group.addTask { await self.prepareSelectedArtwork(target, collector: collector, artwork: artwork) }
                    }
                }
            }
            if !Task.isCancelled { publicSelectionReady.insert(id); if expanding { publicMapSelectionReady.insert(id) } }
        }
        selectionTasks[key] = task
        await task.value
    }

    private func prepareSelectedArtwork(_ target: WorkID, collector: PublicRelationService, artwork: WorkArtworkStore) async {
        guard !Task.isCancelled else { return }
        if (work(target).knowledgeID == nil && work(target).bangumiID != nil)
            || (target.rawValue.hasPrefix("musicbrainz:artist:") && (work(target).knowledgeID == nil || work(target).catalogID == nil)),
           artworkIdentityAttempts.insert(target).inserted {
            do {
                let updated = try await collector.artworkIdentity(work(target))
                try Task.checkCancellation(); try await mergeAsync(.init(works: [updated], relations: []))
            } catch is CancellationError { return }
            catch { lookupErrors[target] = CatalogError.message(error) }
        }
        await artwork.loadWork(work(target))
    }

    private var knowledgeAnchors: [String: Work] {
        var result: [String: Work] = [:]
        for item in works.values.filter({ !$0.id.rawValue.hasPrefix("wikidata:") && !$0.id.rawValue.hasPrefix("apple:artist:") }).sorted(by: { Self.preferredIdentity($0.id, $1.id) }) {
            if let qid = item.knowledgeID, result[qid] == nil { result[qid] = item }
        }
        return result
    }

    func expandKnowledge(_ requestedID: WorkID, retry: Bool = false) async {
        let id = canonicalID(for: requestedID)
        guard let item = works[id] else { return }
        let appleArtistID = item.isPerson ? (try? Self.identity(of: item))?.number : nil
        guard item.knowledgeID != nil || appleArtistID != nil else { return }
        if let task = knowledgeTasks[id] { await task.value; return }
        guard retry || !knowledgeLoaded.contains(id) else { return }
        let task = Task { @MainActor in
            knowledgeLoading.insert(id); knowledgeErrors[id] = nil
            defer { knowledgeLoading.remove(id); knowledgeTasks[id] = nil }
            do {
                var current = work(id)
                if current.knowledgeID == nil, let appleArtistID {
                    guard let match = try await knowledgeService.resolveAppleArtist(id: appleArtistID) else {
                        knowledgeLoaded.insert(id)
                        return
                    }
                    try Task.checkCancellation()
                    current = work(id)
                    if let existing = current.knowledgeID, existing != match.qid { throw CatalogError.invalidData }
                    current.knowledgeID = match.qid
                    current.knowledgeIdentitySource = match.source
                    try merge(CatalogSnapshot(works: [current], relations: []))
                }
                guard let qid = current.knowledgeID else { return }
                let anchors = knowledgeAnchors
                let response = try await knowledgeService.expand(qid: qid, anchors: anchors)
                try Task.checkCancellation()
                var snapshot = response.snapshot
                if current.id.rawValue.hasPrefix("apple:artist:"), let source = current.knowledgeIdentitySource {
                    let person = anchors[qid]?.id ?? WorkID(rawValue: "wikidata:\(qid)")!
                    if person != current.id {
                        snapshot = CatalogSnapshot(works: snapshot.works, relations: snapshot.relations + [
                            RelationEdge(from: current.id, to: person, predicate: .artistIdentity,
                                         label: "创作者", inverseLabel: "音乐目录", source: source)
                        ], stories: snapshot.stories)
                    }
                }
                try mergeKnowledgeSnapshot(snapshot)
                if response.limited { knowledgePartial.insert(id) } else { knowledgePartial.remove(id) }
                knowledgeErrors[id] = response.retryableFailure
                if response.retryableFailure == nil { knowledgeLoaded.insert(id) } else { knowledgeLoaded.remove(id) }
            } catch is CancellationError { }
            catch { knowledgeErrors[id] = KnowledgeError.message(error) }
        }
        knowledgeTasks[id] = task
        await task.value
    }

    /// Choosing an encyclopedia candidate opens its own identity. In particular,
    /// a song composition is never silently merged with an Apple recording.
    func openKnowledgeCandidate(_ qid: String) async throws -> WorkID {
        try Task.checkCancellation()
        let anchors = knowledgeAnchors
        let proposed = anchors[qid]?.id ?? WorkID(rawValue: "wikidata:\(qid)")
        let existing = proposed.flatMap { candidate -> WorkID? in
            let id = canonicalID(for: candidate)
            return works[id]?.knowledgeID == qid ? id : nil
        }
        let response: KnowledgeExpansion
        do {
            response = try await knowledgeService.expand(qid: qid, anchors: anchors)
        } catch {
            try Task.checkCancellation()
            // Opening an exact work already on disk must not depend on an
            // optional refresh. Identity/decoding failures and cancellation
            // still propagate; a display-name match is never a fallback.
            guard Self.canUseCachedKnowledge(after: error), let existing,
                  works[existing]?.knowledgeID == qid else { throw error }
            knowledgeErrors[existing] = KnowledgeError.message(error)
            knowledgeLoaded.remove(existing)
            return existing
        }
        try Task.checkCancellation()
        try mergeKnowledgeSnapshot(response.snapshot)
        let id = anchors[qid]?.id ?? WorkID(rawValue: "wikidata:\(qid)")!
        guard works[id] != nil else { throw CatalogError.notFound }
        knowledgeErrors[id] = response.retryableFailure
        if response.retryableFailure == nil { knowledgeLoaded.insert(id) } else { knowledgeLoaded.remove(id) }
        if response.limited { knowledgePartial.insert(id) } else { knowledgePartial.remove(id) }
        return id
    }

    private static func canUseCachedKnowledge(after error: Error) -> Bool {
        if let known = error as? KnowledgeError {
            switch known {
            case .unavailable, .throttled: return true
            case .invalidIdentifier, .notFound, .invalidResponse: return false
            }
        }
        guard let network = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(network.code)
    }

    /// Catalog aliases have their own release lookup and an explicit person link.
    /// Only the stable person page expands work-level encyclopedia credits.
    func knowledgeMoreStatus(for requestedID: WorkID) -> KnowledgeMoreStatus? {
        let id = canonicalID(for: requestedID)
        guard let item = works[id], item.isPerson, item.knowledgeID != nil,
              !id.rawValue.hasPrefix("apple:artist:") else { return nil }
        return knowledgeMoreStates[id] ?? .unqueried
    }

    func loadMoreKnowledge(_ requestedID: WorkID) async {
        let id = canonicalID(for: requestedID)
        guard !Task.isCancelled, let status = knowledgeMoreStatus(for: id),
              status != .exhausted, status != .limited, let qid = works[id]?.knowledgeID else { return }
        if let task = knowledgeMoreTasks[id] { await task.value; return }
        let task = Task { @MainActor in
            knowledgeMoreLoading.insert(id)
            knowledgeMoreErrors[id] = nil
            defer { knowledgeMoreLoading.remove(id); knowledgeMoreTasks[id] = nil }
            do {
                try Task.checkCancellation()
                let creditKinds: Set<RelationKind> = [.directedBy, .authoredBy, .composedBy, .performedBy]
                let existing = Set(edges.filter { $0.to == id && creditKinds.contains($0.predicate) }.compactMap { works[$0.from]?.knowledgeID })
                let response = try await knowledgeService.moreWorks(qid: qid, after: knowledgeWorkCursors[id],
                                                                     excluding: existing, anchors: knowledgeAnchors)
                try Task.checkCancellation()
                guard works[id]?.knowledgeID == qid else { throw CatalogError.invalidData }
                try mergeKnowledgeSnapshot(response.snapshot)
                // Commit the cursor only after its exact snapshot passed merge.
                // Neither errors nor cancellation can skip an unpublished page.
                knowledgeWorkCursors[id] = response.nextCursor
                knowledgeMoreStates[id] = response.status
                if response.limited { knowledgePartial.insert(id) }
            } catch is CancellationError { }
            catch { knowledgeMoreErrors[id] = KnowledgeError.message(error) }
        }
        knowledgeMoreTasks[id] = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Wikidata creates a directory placeholder, not fresher Apple catalog text.
    /// Read the latest stored profile after the network await so a concurrent
    /// catalog lookup keeps its name/artwork while exact identity evidence is added.
    private func mergeKnowledgeSnapshot(_ snapshot: CatalogSnapshot) throws {
        var snapshot = snapshot
        snapshot.works = try snapshot.works.map { incoming in
            guard incoming.id.rawValue.hasPrefix("apple:artist:"),
                  var existing = works[incoming.id] else { return incoming }
            if let old = existing.knowledgeID, let new = incoming.knowledgeID, old != new { throw CatalogError.invalidData }
            existing.knowledgeID = incoming.knowledgeID ?? existing.knowledgeID
            existing.knowledgeIdentitySource = incoming.knowledgeIdentitySource ?? existing.knowledgeIdentitySource
            return existing
        }
        try merge(snapshot)
    }

    /// The IDs the app's own lists point at, supplied by Library (CatalogRetention). Without it
    /// (tests, tools) everything in memory is written, as before.
    @ObservationIgnored var retainedIDs: (() -> Set<WorkID>)?
    private func retainedForSave() -> Set<WorkID>? {
        retainedIDs.map { Set($0().flatMap { [$0, canonicalID(for: $0)] }) }
    }

    /// Memory is authoritative during a visit. Coalesce writes in a bounded
    /// 1.5-second window; continuous arrivals cannot defer durable data forever.
    func save() {
        guard cacheURL != nil, !cacheWriteBlocked else { return }
        persistenceDirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) }
            catch { return }
            guard let self else { return }
            self.saveTask = nil
            self.writePendingSnapshot()
        }
    }

    /// Await this at lifecycle boundaries and before reading a newly saved file.
    /// Encoding, sorting and the atomic replacement all execute on the writer queue.
    func flushPendingWrites() async {
        saveTask?.cancel(); saveTask = nil
        repeat {
            writePendingSnapshot()
            let generation = saveGeneration
            await diskTask?.value
            if !persistenceDirty && generation == saveGeneration { return }
            // Leave a failed write dirty for an explicit retry, without spinning.
            if storageError != nil { return }
        } while true
    }

    /// The system's termination notification cannot await a task. This is the
    /// sole synchronous barrier: disk work still runs on the serial writer.
    func flushPendingWritesBeforeTermination() {
        saveTask?.cancel(); saveTask = nil
        guard !cacheWriteBlocked, let cacheURL else { return }
        guard persistenceDirty || diskTask != nil else { diskWriter.waitForWrites(); return }
        persistenceDirty = false
        saveGeneration += 1
        let state = mergeState
        storageError = diskWriter.writeSynchronously(works: state.works, edges: state.edges, stories: state.stories,
            aliases: state.aliases, retained: retainedForSave(), to: cacheURL, generation: saveGeneration)
        if storageError != nil { persistenceDirty = true }
    }

    private func writePendingSnapshot() {
        guard persistenceDirty, !cacheWriteBlocked, let cacheURL else { return }
        persistenceDirty = false
        saveGeneration += 1
        let generation = saveGeneration, state = mergeState, writer = diskWriter, retained = retainedForSave()
        diskTask = Task { [weak self] in
            let error = await writer.write(works: state.works, edges: state.edges, stories: state.stories,
                aliases: state.aliases, retained: retained, to: cacheURL, generation: generation)
            guard let self, self.saveGeneration == generation else { return }
            self.storageError = error
            if error != nil { self.persistenceDirty = true }
        }
    }

    private func preserveUnreadableCache(_ data: Data) throws {
        guard let cacheURL, let backup = cacheBackupURL else { throw PersistenceRecoveryError.backupFailed }
        do {
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: cacheURL, to: backup)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw PersistenceRecoveryError.backupFailed }
            guard try Data(contentsOf: backup) == data else { throw PersistenceRecoveryError.backupFailed }
        } catch { throw PersistenceRecoveryError.backupFailed }
    }

    private struct CatalogIdentity: Hashable, Sendable { let kind: String; let number: String }

    nonisolated private static func number(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count < 24, raw.utf8.allSatisfy({ (48...57).contains($0) }), raw.contains(where: { $0 != "0" }) else { return nil }
        return String(raw.drop(while: { $0 == "0" }))
    }

    nonisolated private static func identity(fromAppleID id: WorkID) -> CatalogIdentity? {
        let parts = id.rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "apple", let n = number(String(parts[2])) else { return nil }
        let kinds = ["song": "歌曲", "album": "专辑", "artist": "创作者", "feature-movie": "电影", "ebook": "书籍", "music-video": "演奏视频"]
        return kinds[String(parts[1])].map { CatalogIdentity(kind: $0, number: n) }
    }

    // Source identity extraction is deliberately separate from user link import.
    // Artist and book URLs may prove identity without becoming supported music imports.
    nonisolated private static func identity(fromURL raw: String?, kind: String) -> CatalogIdentity? {
        guard let raw, let url = URLComponents(string: raw), url.scheme == "https",
              let host = url.host?.lowercased(), ["music.apple.com", "itunes.apple.com", "books.apple.com"].contains(host),
              url.user == nil, url.password == nil else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count >= 3, let last = path.last else { return nil }
        let route = path[1]
        if kind != "专辑", let selected = url.queryItems?.first(where: { $0.name == "i" }) {
            guard route == "album", host != "books.apple.com", let value = selected.value, let n = number(value) else { return nil }
            return CatalogIdentity(kind: "歌曲", number: n)
        }
        let rawNumber = last.hasPrefix("id") ? String(last.dropFirst(2)) : last
        guard let n = number(rawNumber) else { return nil }
        let kinds = ["song": "歌曲", "album": "专辑", "artist": "创作者", "movie": "电影", "book": "书籍", "music-video": "演奏视频"]
        return kinds[route].map { CatalogIdentity(kind: $0, number: n) }
    }

    nonisolated private static func identities(of work: Work) throws -> [CatalogIdentity] {
        var result = try identity(of: work).map { [$0] } ?? []
        if let number = work.bangumiID, Int(number) ?? 0 > 0 {
            result.append(CatalogIdentity(kind: work.isPerson ? "bangumi-person" : "bangumi-subject", number: number))
        }
        if let id = work.publicIdentifiers?.musicBrainz, UUID(uuidString: id) != nil {
            result.append(.init(kind: "musicbrainz-recording", number: id))
        }
        // A typed, consulted database URL joins the same object without a name-only merge.
        for raw in [work.url, work.discovery?.identitySource].compactMap({ $0 }) {
            guard let url = URL(string: raw), url.scheme == "https" else { continue }
            let parts = url.path.split(separator: "/").map(String.init)
            if url.host == "musicbrainz.org", parts.count == 2, UUID(uuidString: parts[1]) != nil,
               (parts[0] == "recording" && work.isSong || parts[0] == "work" && work.isMusicWork || parts[0] == "artist" && work.isPerson) {
                result.append(.init(kind: "musicbrainz-" + parts[0], number: parts[1]))
            }
            if ["vocadb.net", "touhoudb.com"].contains(url.host ?? ""), parts.count == 2, parts[0] == "S", Int(parts[1]) ?? 0 > 0 {
                result.append(.init(kind: (url.host ?? "") + "-" + work.kind, number: parts[1]))
            }
        }
        // A QID taken from a matching, typed encyclopedia page is a hard media
        // identity. Do not alias a recording/Apple artist profile with a work or
        // the stable person page merely because they mention the same QID.
        if let qid = work.knowledgeID, work.knowledgeIdentitySource != nil,
           !work.isSong, !work.isAlbum, !work.id.rawValue.hasPrefix("apple:artist:") {
            result.append(CatalogIdentity(kind: "knowledge-" + work.kind, number: qid))
        }
        return result
    }

    nonisolated private static func identity(of work: Work) throws -> CatalogIdentity? {
        let idIdentity = identity(fromAppleID: work.id)
        if let idIdentity, idIdentity.kind != work.kind { throw CatalogError.invalidData }
        let declared: CatalogIdentity?
        if let raw = work.catalogID {
            guard let n = number(raw) else { throw CatalogError.invalidData }
            declared = CatalogIdentity(kind: work.kind, number: n)
        } else { declared = nil }
        let urlIdentity = identity(fromURL: work.url, kind: work.kind)
        let candidates = [idIdentity, declared, urlIdentity].compactMap { $0 }
        guard candidates.allSatisfy({ $0.kind == work.kind }), Set(candidates).count <= 1 else { throw CatalogError.invalidData }
        return candidates.first
    }

    nonisolated private static func preferredIdentity(_ lhs: WorkID, _ rhs: WorkID) -> Bool {
        func rank(_ id: WorkID) -> Int {
            if Work.seeds[id] != nil { return 0 }
            if id.rawValue.hasPrefix("bangumi:") { return 3 }
            return id.rawValue.hasPrefix("apple:") ? 2 : 1
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs.rawValue < rhs.rawValue
    }

    nonisolated private static func resolve(_ id: WorkID, aliases: [WorkID: WorkID]) -> WorkID {
        var result = id, visited = Set<WorkID>()
        while let next = aliases[result], next != result, visited.insert(result).inserted { result = next }
        return result
    }

    nonisolated private static func remap(_ item: Work, to id: WorkID, canonical: (WorkID) -> WorkID) -> Work {
        var seen = Set<WorkID>()
        return Work(id: id, title: item.title, creator: item.creator, kind: item.kind, art: ArtworkLocation.stored(item.art), detail: item.detail, url: item.url,
                    linkedAlbumID: item.albumID.map(canonical), linkedCreatorIDs: item.creatorIDs.map(canonical).filter { seen.insert($0).inserted },
                    catalogID: item.catalogID, storeCountry: item.storeCountry, knowledgeID: item.knowledgeID,
                    knowledgeIdentitySource: item.knowledgeIdentitySource, versionSearchQuery: item.versionSearchQuery, releaseDate: item.releaseDate, editorialNotes: item.editorialNotes, catalogSource: item.catalogSource, catalogFetchedAt: item.catalogFetchedAt, catalogTrack: item.catalogTrack, resolvedRegion: item.resolvedRegion, regionOrigin: item.regionOrigin, catalogTrackCount: item.catalogTrackCount, bangumiID: item.bangumiID, seriesIDs: item.seriesIDs, discovery: item.discovery, publicIdentifiers: item.publicIdentifiers, platformRecording: item.platformRecording)
    }

    nonisolated private static func combine(_ current: Work, with incoming: Work, incomingWasApple: Bool, identicalCatalog: Bool) -> Work {
        let curated = !current.id.rawValue.hasPrefix("apple:") && !current.id.rawValue.hasPrefix("local:") && !current.id.rawValue.hasPrefix("wikidata:")
        let artistSource = incoming.catalogSource.flatMap { URLComponents(string: $0.url) }
        let creditedArtistIdentity = current.id == incoming.id && current.isPerson
            && current.id.rawValue.hasPrefix("musicbrainz:artist:") && incoming.catalogSource?.title == "MusicBrainz"
            && artistSource?.scheme == "https" && artistSource?.host == "musicbrainz.org"
            && artistSource?.path == "/ws/2/artist/" + String(current.id.rawValue.dropFirst("musicbrainz:artist:".count))
            && artistSource?.queryItems?.contains(where: { $0.name == "inc" && $0.value == "url-rels" }) == true
        // The same QQ/网易云 recording read again may now carry the cover its first read lacked.
        let samePlatformRecording = current.platformRecording.map { $0.id == incoming.platformRecording?.id } ?? false
        let verifiedArtwork = (identicalCatalog || samePlatformRecording) && !incoming.art.isEmpty && URL(string: incoming.art)?.scheme == "https"
        // Non-Apple records own their text, original links, and existing artwork.
        let art = current.art.isEmpty && (!curated || verifiedArtwork) ? incoming.art : current.art
        let rated = current.doubanRating != nil && current.doubanRatingSource != nil ? current : incoming
        return Work(id: current.id, title: current.title, creator: curated || !current.creator.isEmpty ? current.creator : incoming.creator, kind: current.kind, art: art,
                    detail: current.detail, url: current.url ?? (curated && incomingWasApple ? nil : incoming.url),
                    linkedAlbumID: current.albumID ?? incoming.albumID,
                    linkedCreatorIDs: current.creatorIDs.isEmpty ? incoming.creatorIDs : current.creatorIDs,
                    catalogID: current.catalogID ?? (identicalCatalog || creditedArtistIdentity ? incoming.catalogID : nil),
                    storeCountry: current.storeCountry ?? (identicalCatalog ? incoming.storeCountry : nil), knowledgeID: current.knowledgeID ?? incoming.knowledgeID,
                    knowledgeIdentitySource: current.knowledgeIdentitySource ?? incoming.knowledgeIdentitySource,
                    doubanRating: rated.doubanRating, doubanRatingSource: rated.doubanRatingSource,
                    versionSearchQuery: current.versionSearchQuery ?? incoming.versionSearchQuery,
                    releaseDate: current.releaseDate ?? (identicalCatalog ? incoming.releaseDate : nil),
                    editorialNotes: current.editorialNotes ?? (identicalCatalog ? incoming.editorialNotes : nil),
                    catalogSource: current.catalogSource ?? ((!curated && identicalCatalog) || creditedArtistIdentity ? incoming.catalogSource : nil),
                    catalogFetchedAt: current.catalogFetchedAt ?? incoming.catalogFetchedAt,
                    catalogTrack: current.catalogTrack ?? (identicalCatalog ? incoming.catalogTrack : nil),
                    resolvedRegion: incoming.resolvedRegion ?? current.resolvedRegion, regionOrigin: incoming.regionOrigin ?? current.regionOrigin,
                    catalogTrackCount: current.catalogTrackCount ?? incoming.catalogTrackCount,
                    bangumiID: current.bangumiID ?? incoming.bangumiID, seriesIDs: incoming.seriesIDs ?? current.seriesIDs, discovery: DiscoveryCore.mergeMetadata(current.discovery, incoming.discovery), publicIdentifiers: current.publicIdentifiers ?? incoming.publicIdentifiers, platformRecording: current.platformRecording ?? incoming.platformRecording)
    }

    nonisolated private static func validKnowledgeIdentity(_ work: Work) -> Bool {
        if let source = work.knowledgeIdentitySource {
            guard work.knowledgeID != nil, validSource(source) else { return false }
        }
        if let qid = work.knowledgeID {
            guard qid.first == "Q", let number = Int64(qid.dropFirst()), number > 0,
                  qid.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        if work.id.rawValue.hasPrefix("wikidata:") {
            return work.knowledgeID == String(work.id.rawValue.dropFirst(9))
        }
        return true
    }
}

private struct EditorialPack: Decodable {
    struct Item: Decodable {
        let id: WorkID; let title: String; let creator: String; let kind: String
        let art: String; let detail: String; let url: String?
        let creatorIDs: [WorkID]?; let albumID: WorkID?
        let versionSearchQuery: String?
    }
    let version: Int
    let works: [Item]
    let relations: [RelationEdge]
    let stories: [EditorialStory]
    let entryPoints: [WorkID]
}

/// Serial writer prevents an older encode from replacing a newer snapshot. It
/// receives value snapshots and never touches the observable store or UI thread.
private final class CatalogDiskWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pianwai.catalog.persistence", qos: .utility)
    // Confined to queue; even asynchronously enqueued tasks cannot publish stale data.
    private var latestGeneration = 0

    func write(works: [WorkID: Work], edges: [RelationEdge], stories: [EditorialStory],
               aliases: [WorkID: WorkID], retained: Set<WorkID>? = nil, to url: URL, generation: Int) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.writeOnQueue(works: works, edges: edges, stories: stories,
                    aliases: aliases, retained: retained, to: url, generation: generation))
            }
        }
    }

    func writeSynchronously(works: [WorkID: Work], edges: [RelationEdge], stories: [EditorialStory],
                            aliases: [WorkID: WorkID], retained: Set<WorkID>? = nil, to url: URL, generation: Int) -> String? {
        queue.sync { writeOnQueue(works: works, edges: edges, stories: stories, aliases: aliases, retained: retained, to: url, generation: generation) }
    }

    func waitForWrites() { queue.sync {} }

    private func writeOnQueue(works allWorks: [WorkID: Work], edges allEdges: [RelationEdge], stories: [EditorialStory],
                              aliases: [WorkID: WorkID], retained: Set<WorkID>?, to url: URL, generation: Int) -> String? {
        guard generation >= latestGeneration else { return nil }
        latestGeneration = generation
        // Search results nothing points at stay in memory only (CatalogRetention).
        let (works, edges) = retained.map { CatalogRetention.durable(works: allWorks, edges: allEdges, aliases: aliases, retained: $0) }
            ?? (allWorks, allEdges)
        let measurement = EvalPerformance.begin("Catalog.save", ["works": String(works.count), "edges": String(edges.count)])
        defer { measurement?.end() }
        do {
            let durableAliases = aliases.reduce(into: [String: String]()) { result, pair in
                var target = pair.value, visited = Set<WorkID>()
                while let next = aliases[target], next != target, visited.insert(target).inserted { target = next }
                if pair.key.rawValue.hasPrefix("lead:"), pair.key != target, works[target] != nil {
                    result[pair.key.rawValue] = target.rawValue
                }
            }
            let snapshot = CatalogSnapshot(works: works.values.sorted { $0.id.rawValue < $1.id.rawValue },
                relations: edges, stories: stories, identityAliases: durableAliases.isEmpty ? nil : durableAliases)
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            latestGeneration = generation
            return nil
        } catch { return "这次资料暂时没有保存到本机。" }
    }
}
