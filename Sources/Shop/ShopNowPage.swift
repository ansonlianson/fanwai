import SwiftUI
import UIKit

/// 0.4 此刻／作品页 — scheme A: a used-record shop at night. The work stands on the wall ledge
/// (LP, framed poster, hardcover or framed photo by kind); related works stand in a plywood bin
/// below, one compartment each, with their name and relation on the divider label.
/// Playing: the display spotlight is on and the record is half out of its sleeve; paused: the light
/// is off and the record slides back. Covers, labels and text are live; the shop is rendered.
struct ShopNowPage: View, @MainActor Equatable {
    let entity: SeedGraph.Entity
    let transitionNamespace: Namespace.ID
    var navigationRoot = ""
    static func == (a: Self, b: Self) -> Bool {
        a.entity == b.entity && a.navigationRoot == b.navigationRoot
            && a.isCurrent == b.isCurrent && a.isPlaying == b.isPlaying && a.idle == b.idle
            && a.queuedIDs == b.queuedIDs && a.savedIDs == b.savedIDs
            && a.transitionNamespace == b.transitionNamespace
    }
    var isCurrent = false
    var isPlaying = false
    var idle = false
    var queuedIDs: Set<String> = []
    var savedIDs: Set<String> = []
    var onStoryName: (StoryTextLinks.Target) -> Void = { _ in }
    var onReadingName: ((StoryTextLinks.Target, Source) -> Void)? = nil
    var onGraph: (String) -> Void
    var onOpen: (CrateItem, String) -> Void
    var onPlayback: () -> Void = {}
    var onNext: (SeedGraph.Entity) -> Void
    var onSave: (SeedGraph.Entity) -> Void
    var onWorks: () -> Void
    var onObjectFrame: (String, CGRect) -> Void = { _, _ in }
    var onRetry: () -> Void = {}
    var onCreator: (() -> Void)? = nil

    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PullOutReaders.self) private var readers
    @Environment(\.playbackTop) private var playbackTop
    @State private var visit = ShopBinVisit()

    static let base = Color(red: 0.090, green: 0.074, blue: 0.055)
    fileprivate static let ink = Color(red: 0.93, green: 0.92, blue: 0.89)
    fileprivate static let secondary = Color(red: 0.71, green: 0.68, blue: 0.62)
    fileprivate static let accent = Color(red: 0.86, green: 0.80, blue: 0.65)
    fileprivate static let binTop: CGFloat = 1580
    static func directCreator(_ label: String) -> Bool { DiscoveryNavigation.directCreator(label) }
    static func kindPrefix(_ entity: SeedGraph.Entity, work: Work) -> String {
        if work.isMusicWork { return "" }
        if entity.kind.isMusic || entity.kind == .person || entity.kind == .group { return "" }
        let word = switch work.kind {
        case "电影": "电影"
        case "电视剧": "剧集"
        case "游戏": "游戏"
        case "动画": "动画"
        case "漫画": "漫画"
        case "书籍": "书"
        case "音乐视频": "视频"
        default: switch entity.kind {
            case .film: "电影"
            case .game: "游戏"
            case .tv: "剧集"
            case .video: "视频"
            case .book: "书"
            case .manga: "漫画"
            default: ""
            }
        }
        return word.isEmpty ? "" : word + " · "
    }


    var body: some View {
        let _ = EvalPerformance.event("ShopNowPage.body")
        GeometryReader { geo in
            let W = geo.size.width
            let k = W / ShopPlates.plateWidth
            let r = W / 402
            let reader = readers.reader(for: entity.id)
            let binY = ShopPlates.plateHeight * k - (ShopPlates.plateHeight - Self.binTop) * k * 0.92
            let restTop = 333 * r
            let expandedTop = max(168 * r, geo.safeAreaInsets.top + 88)
            let distance = max(1, restTop - expandedTop)
            ZStack(alignment: .topLeading) {
                Self.base
                PullOutSceneLayer(reader: reader, layer: .hero, travel: distance, cabinetExit: 0, reduceMotion: PianwaiRuntime.reduceMotion(reduceMotion)) {
                    ShopPageHeroRegion(entity: entity, isCurrent: isCurrent, isPlaying: isPlaying, idle: idle, k: k, r: r)
                }
                ShopPageArticleRegion(entity: entity, isCurrent: isCurrent, idle: idle, queuedIDs: queuedIDs, savedIDs: savedIDs,
                    onStoryName: onStoryName, onReadingName: onReadingName, onNext: onNext, onSave: onSave,
                    onWorks: onWorks, onRetry: onRetry, onCreator: onCreator,
                    width: W, height: geo.size.height, restTop: restTop, expandedTop: expandedTop, binY: binY,
                    bottomInset: max(156 * r, playbackTop.isFinite ? geo.frame(in: .global).maxY - playbackTop + 18 : 0))
                PullOutFade(reader: reader, width: W, height: geo.size.height, top: binY - 66 * r, bottom: binY, reduceMotion: PianwaiRuntime.reduceMotion(reduceMotion))
                PullOutSceneLayer(reader: reader, layer: .cabinet, travel: distance,
                    cabinetExit: max(1, geo.size.height - binY + 30), reduceMotion: PianwaiRuntime.reduceMotion(reduceMotion)) {
                    ShopPageBinRegion(entity: entity, transitionNamespace: transitionNamespace, savedIDs: savedIDs,
                        onStoryName: onStoryName, onGraph: onGraph, onOpen: onOpen, onNext: onNext, onSave: onSave,
                        onRetry: onRetry, visit: visit, k: k, W: W, r: r)
                }
                PullOutMore(reader: reader, width: W, y: binY - 38 * r)
                PullOutHeroHitArea(reader: reader) {
                    ShopPageHeroHit(entity: entity, isCurrent: isCurrent, isPlaying: isPlaying, idle: idle,
                                    k: k, onPlayback: onPlayback, onObjectFrame: onObjectFrame)
                }
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(width: W, height: 60 * r).allowsHitTesting(false)
            }
            .frame(width: W, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .ignoresSafeArea()
        .foregroundStyle(Self.ink)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShopPageGraphAction(entity: entity, visit: visit, onGraph: onGraph)
                ShopPageMenuRegion(entity: entity, onNext: onNext, onSave: onSave, onRetry: onRetry)
            }
        }
        .task(id: entity.id) {
            guard !(SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil) else { return }
            let work = library.catalog.work(SeedLibraryBridge.workID(entity.id))
            RecordingVersionsStore.shared.restore(work, library: library)
            if work.isMusicWork { await RecordingVersionsStore.shared.load(work, library: library) }
        }
        .task(id: "introduction:" + entity.id) {
            let work = library.catalog.work(SeedLibraryBridge.workID(entity.id))
            guard !(SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil), !entity.kind.isMusic,
                  !work.isMusicWork, let qid = work.knowledgeID else { return }
            await WorkContextStore.shared.load(qid)
        }
    }
}

/// The page layout remains stable while these independent regions observe only
/// their own catalogue/research state. Lamp frames never recalculate the bin.
private struct ShopPageHeroRegion: View {
    let entity: SeedGraph.Entity
    let isCurrent: Bool
    let isPlaying: Bool
    let idle: Bool
    let k: CGFloat
    let r: CGFloat
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var catalogID: WorkID { library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)) }
    private var heroPart: String {
        switch entity.kind {
        case .song, .album: "lp"
        case .film, .tv, .video, .game: "bd"
        case .book, .manga: "book"
        case .person, .group: "person"
        }
    }
    var body: some View {
        let current = library.catalog.works[catalogID] == nil ? entity : SeedLibraryBridge.entity(for: catalogID, in: library)
        ShopHeroScene(heroPart: heroPart, heroEntity: current, catalogID: catalogID, k: k, r: r,
                      showsPlaying: isCurrent && isPlaying && !idle, reduceMotion: reduceMotion)
    }
}

private struct ShopPageHeroHit: View {
    let entity: SeedGraph.Entity
    let isCurrent: Bool
    let isPlaying: Bool
    let idle: Bool
    let k: CGFloat
    let onPlayback: () -> Void
    let onObjectFrame: (String, CGRect) -> Void
    var body: some View {
        let part: String = switch entity.kind {
        case .song, .album: "lp"
        case .film, .tv, .video, .game: "bd"
        case .book, .manga: "book"
        case .person, .group: "person"
        }
        let m = ShopPlates.shared.main(part)
        let b = (m?.slots["hero"]?.bounds ?? .zero).union(m?.slots["disc"]?.bounds ?? .zero)
        Button { if isCurrent && entity.kind.isMusic { onPlayback() } } label: { Color.clear.contentShape(.rect) }
            .buttonStyle(.plain)
            .frame(width: b.width * k, height: b.height * k)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onObjectFrame(entity.id, $0) }
            .padding(.leading, b.minX * k).padding(.top, b.minY * k)
            .accessibilityLabel(entity.title)
            .accessibilityValue(isCurrent ? (isPlaying && !idle ? "播放中" : "已暂停") : "")
            .accessibilityIdentifier("now-hero-" + entity.id)
    }
}

@MainActor @Observable private final class ShopBinVisit {
    var inventory = CrateVisitInventory()
    func observe(root: String, available: [String]) {
        // Pinning a batch changes neither its visible IDs nor its appearance.
        var next = inventory; next.observe(root: root, available: available)
        if next.root != inventory.root || next.revealed != inventory.revealed { inventory = next }
    }
    func reveal(root: String, available: [String]) {
        var next = inventory; next.reveal(root: root, available: available)
        if next.root != inventory.root || next.revealed != inventory.revealed { inventory = next }
    }
}

private struct ShopPageBinRegion: View {
    let entity: SeedGraph.Entity
    let transitionNamespace: Namespace.ID
    var savedIDs: Set<String>
    let onStoryName: (StoryTextLinks.Target) -> Void
    let onGraph: (String) -> Void
    let onOpen: (CrateItem, String) -> Void
    let onNext: (SeedGraph.Entity) -> Void
    let onSave: (SeedGraph.Entity) -> Void
    let onRetry: () -> Void
    let visit: ShopBinVisit
    let k: CGFloat
    let W: CGFloat
    let r: CGFloat
    @Environment(Library.self) private var library
    @Environment(LeadResearch.self) private var research
    @Environment(OnDemandStories.self) private var stories
    @Environment(\.scenePhase) private var scenePhase
    @Environment(StoryModelSettings.self) private var storySettings
    @State private var confirmingDeep = false
    @State private var annotating: String?
    @State private var prefetch = NextWorkPrefetch.shared
    @State private var derived = ShopPageDerivedCache()
    @State private var selections = ShopSelectionCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 翻到箱底: the blank sleeves that stood in the bin while the clerk looked, sinking out once
    /// the lookup ends with nothing (anson 11-18 17:30).
    @State private var departing: [ShopBinEntry] = []
    @State private var departed = false
    @State private var emptied = 0
    @State private var sawLoading = false
    private var isSeed: Bool { SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil }
    private var storyLoading: Bool { isSeed ? stories.isLoading(entity.id) : research.state(entity.id) == .loading }
    private var catalogID: WorkID { library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)) }
    private var effectiveSavedIDs: Set<String> { savedIDs.union(selections.value(in: library).saved) }
    private func nextWorks(_ inventory: [CrateItem]) -> [WorkID] {
        let ids = inventory.compactMap { WorkID(rawValue: $0.entity.id) }.map { library.catalog.canonicalID(for: $0) }
        let context = DiscoveryNavigation.context(from: entity.id, catalog: library.catalog,
            provider: nil)?.work.id
        return NextWorkPrefetch.targets(ids, context: context, excluding: catalogID)
    }

    private var allLeads: [CrateItem] {
        research.navigationLeads(entity.id, library: library).compactMap { lead in
            guard let raw = WorkID(rawValue: lead.id) else { return nil }
            let id = library.catalog.canonicalID(for: raw)
            guard library.catalog.works[id] != nil else { return nil }
            var item = CrateItem(entity: SeedLibraryBridge.entity(for: id, in: library), relation: lead.label, path: lead.path ?? [entity.id, id.rawValue])
            item.note = lead.why
            return item
        }
    }
    /// The bin is for discovering works: related works first, and at most one person who made
    /// something you can go and see (duet partner, original singer, director, lead actor).
    /// The song's own singer and credit-only roles (lyrics, composition, arrangement, MV crew)
    /// stay on the relation map.
    private var items: [CrateItem] {
        let report = research.reports[entity.id]
        let key = ShopPageDerivedCache.Key(entityID: entity.id, seed: isSeed,
            catalog: library.catalog.revision, fetchedAt: report?.fetchedAt, leads: report?.leads ?? [],
            interests: library.crateExploration.revision,
            collections: library.saved + library.listenLater + library.later + library.listenedIDs + library.watchedIDs)
        let ordered = derived.items(for: key) {
            CrateOrdering.ordered(isSeed ? CrateInventory.items(for: entity.id) : allLeads,
                from: entity.id, library: library)
        }
        // The order is cached; presentation is read from the current work so a
        // prefetched artwork result is not pinned to an obsolete empty URL.
        guard !isSeed else { return ordered }
        return ordered.map { item in
            var current = CrateItem(entity: SeedLibraryBridge.entity(for: SeedLibraryBridge.workID(item.id), in: library),
                                    relation: item.relation, path: item.path, hasStory: item.hasStory)
            current.note = item.note
            return current
        }
    }
    private func visibleItems(_ inventory: [CrateItem]) -> [CrateItem] {
        let values = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return visit.inventory.visible(root: entity.id, available: inventory.map(\.id)).compactMap { values[$0] }
    }
    private func selectionReady(_ inventory: [CrateItem]) -> Bool { isSeed || !inventory.isEmpty || (research.state(entity.id) != nil && research.state(entity.id) != .loading) }
    private static func tileKind(_ kind: SeedGraph.Kind) -> String {
        ShopStyle.objectKind(kind)
    }
    private struct StripTile: Identifiable {
        let id: String
        let kind: String
        var item: CrateItem? = nil
        var placeholder: String? = nil
    }
    private func tiles(_ inventory: [CrateItem], ready: Bool) -> [StripTile] {
        var list = [StripTile(id: "lead-in", kind: "anon")]
        if !ready {
            // While the clerk is still digging the cards stay blank: what the bin will hold is not
            // known yet, and guessing「作曲」「演唱」would promise the credits it no longer shows.
            for i in 0..<3 { list.append(StripTile(id: "loading-\(i)", kind: "cd", placeholder: "")) }
        } else if inventory.isEmpty {
            list.append(StripTile(id: "stock-1", kind: "anon"))
        } else {
            for item in inventory { list.append(StripTile(id: item.id, kind: Self.tileKind(item.entity.kind), item: item)) }
        }
        list.append(StripTile(id: "stock-tail", kind: "anon"))
        list.append(StripTile(id: "end", kind: "end"))
        return list
    }


    var body: some View {
        let available = items
        let availableIDs = available.map(\.id)
        let inventory = visibleItems(available)
        let pendingItems = visit.inventory.pending(root: entity.id, available: availableIDs)
        let next = nextWorks(inventory)
        let prefetchKey = ([entity.id, library.country, String(scenePhase == .active), String(storyLoading)] + next.map(\.rawValue)).joined(separator: "|")
        let empty = nothingFound(inventory)
        strip(k: k, W: W, r: r, inventory: inventory, ready: selectionReady(inventory), availableIDs: availableIDs, pendingItems: pendingItems, empty: empty)
            .modifier(DeepDiveConfirmation(entity: entity, isPresented: $confirmingDeep))
            .onChange(of: [entity.id] + availableIDs, initial: true) { _, _ in visit.observe(root: entity.id, available: availableIDs) }
            .onChange(of: entity.id) { annotating = nil }
            .onChange(of: storyLoading, initial: true) { _, loading in if loading { sawLoading = true } }
            .onChange(of: empty) { old, new in
                guard new, !old, sawLoading, !PianwaiRuntime.reduceMotion(reduceMotion) else { return }
                // The three blank sleeves (and the plain stock peeking in after them) leave the bin.
                departing = (0..<3).map { ShopBinEntry(id: "loading-\($0)", kind: "cd", placeholder: true) }
                    + [ShopBinEntry(id: "__tail", kind: "anon")]
                departed = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    departed = true
                    try? await Task.sleep(for: .milliseconds(820))
                    emptied += 1
                    departing = []
                }
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: emptied)
            .task(id: prefetchKey) {
                guard !isSeed, scenePhase == .active, !storyLoading else { return }
                await prefetch.prepare(next, root: catalogID, library: library, research: research)
            }
    }
    /// The lookup finished and found neither a related work nor a story.
    private func nothingFound(_ inventory: [CrateItem]) -> Bool {
        guard !isSeed, inventory.isEmpty, !storyLoading, let job = research.jobs.values[entity.id], job.phase == .done else { return false }
        return job.storyResult == .notFound || job.storyResult == .rejected
    }
    private func strip(k: CGFloat, W: CGFloat, r: CGFloat, inventory: [CrateItem], ready: Bool,
                       availableIDs: [String], pendingItems: Int, empty: Bool) -> some View {
        // Nothing found: bare compartments, no stock and no tile asking for more (the 深挖 is above).
        var entries: [ShopBinEntry] = empty ? [] : tiles(inventory, ready: ready).filter { $0.kind != "end" && $0.id != "lead-in" && $0.id != "stock-tail" }.map { t in
            if let item = t.item {
                let work = library.catalog.work(SeedLibraryBridge.workID(item.id))
                let name = work.discovery?.layer == .movement ? DiscoveryPathPresentation.coverTitle(work) : SongTitlePresentation(item.entity.title, isSong: item.entity.kind == .song).title
                let type = DiscoveryPathPresentation.typeName(work)
                return ShopBinEntry(id: item.id, kind: t.kind, title: name,
                                    relation: item.relation == type ? type : type + " · " + item.relation,
                                    artwork: item.entity.artworkAsset, coverTitle: work.discovery?.layer == .movement ? name : item.entity.title)
            }
            return ShopBinEntry(id: t.id, kind: t.kind, title: t.placeholder?.isEmpty == false ? t.placeholder : nil, placeholder: t.placeholder != nil)
        }
        // The last tile offers 深挖 when a model is set up (anson 11-18 14:20); 再翻一箱 otherwise.
        // After a 深挖 there is nothing more to offer, and an empty bin asks for nothing.
        let deep = DeepDiveConfirmation.available(entity, hasModel: storySettings.hasKey, library: library, research: research)
        let deepened = research.jobs.values[entity.id]?.deepened == true
        if !isSeed, ready, !empty, !deepened || storyLoading {
            let more = storyLoading ? "店员在翻…" : deep ? "深挖 ›" : "再翻一箱 ›"
            entries.append(.init(id: "__more", kind: "book", title: more, placeholder: true, action: true))
        }
        let scale: CGFloat = 0.92
        return ShopBinStrip(entries: entries, width: W, top: ShopNowPage.binTop, scale: scale,
                            stock: empty ? "empty" : "anon", departing: departing, departed: departed,
                            onPullUp: inventory.isEmpty ? nil : { onGraph(entity.id) }, transitionNamespace: transitionNamespace) { entry, rect in
            if let item = inventory.first(where: { $0.id == entry.id }) {
                ShopNoteHit(id: item.id, title: SongTitlePresentation(item.entity.title, isSong: item.entity.kind == .song).title,
                            caption: item.relation + (item.entity.subtitle.isEmpty ? "" : " · " + item.entity.subtitle),
                            note: item.note, rect: rect, namespace: nil, annotating: $annotating,
                            actions: noteActions(item))
            } else if entry.action {
                Button {
                    if entry.id == "__more" {
                        if deep { confirmingDeep = true } else { onRetry() }
                    }
                } label: { Color.clear.contentShape(.rect) }
                    .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
                    .padding(.leading, rect.minX).padding(.top, rect.minY)
                    .disabled(entry.id == "__more" && storyLoading)
                    .accessibilityLabel(storyLoading ? "店员在翻…" : deep ? "深挖" : "再翻一箱")
                    .accessibilityIdentifier("lead-more")
            }
        }
        // Anchored at the bottom: the bin stands a little further back, so a fourth compartment
        // peeks in. Placed by layout (not offset) so the zoom finds the covers where they are drawn.
        .padding(.top, ShopPlates.plateHeight * k - (ShopPlates.plateHeight - ShopNowPage.binTop) * k * scale)
        .onChange(of: inventory.map(\.id), initial: true) { _, ids in
            guard P17Metrics.enabled else { return }
            Task { await P17Metrics.shared.record(["event": "cardsVisible", "root": entity.id, "count": String(ids.count), "ids": ids.joined(separator: "|")]) }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("shop-bin")
        .accessibilityValue(storyLoading ? "正在查找" : inventory.isEmpty && ready ? "暂无关联作品" : "")
    }

    private func noteActions(_ item: CrateItem) -> [ShopNoteAction] {
        var actions = [ShopNoteAction(title: "打开", symbol: "arrow.up.right") { onOpen(item, item.id) }]
        let saved = effectiveSavedIDs.contains(item.id)
        if item.entity.kind.isMusic {
            let work = library.catalog.work(SeedLibraryBridge.workID(item.id))
            if let id = EntityActions.playbackID(item.entity, library: library) {
                actions.append(ShopNoteAction(title: library.playbackPlatform.listenTitle, symbol: "play.fill") { library.listen(id) })
            } else if library.playbackPlatform == .apple, (work.isSong || work.isMusicWork),
                      let version = RecordingVersionsStore.shared.versions(for: work, library: library).known.first
                        ?? RecordingVersionsStore.shared.versions(for: work, library: library).candidates.first {
                // A version already found for this card plays from here too (anson 11-18 18:16).
                actions.append(ShopNoteAction(title: "播放", symbol: "play.fill") { library.listen(version) })
            }
            if library.playbackPlatform == .apple, work.isSong, work.catalogRecordingID != nil {
                actions.append(ShopNoteAction(title: "下一首", symbol: "text.line.first.and.arrowtriangle.forward") { onNext(item.entity) })
            }
            if work.isSong || work.isAlbum || work.isMusicWork {
                actions.append(ShopNoteAction(title: saved ? "已收藏" : "收藏", symbol: WorkVerb.symbol("收藏", saved: saved)) {
                    if saved { SeedLibraryBridge.unsave(item.entity, in: library) } else { onSave(item.entity) }
                })
            }
        } else if let verb = WorkVerb.save(item.entity.kind) {
            actions.append(ShopNoteAction(title: saved ? WorkVerb.saved(verb) : verb, symbol: WorkVerb.symbol(verb, saved: saved)) { if !saved { onSave(item.entity) } })
        }
        return actions
    }


}

private struct ShopPageGraphAction: View {
    let entity: SeedGraph.Entity
    let visit: ShopBinVisit
    let onGraph: (String) -> Void
    @Environment(Library.self) private var library
    @Environment(LeadResearch.self) private var research
    @Environment(PullOutReaders.self) private var readers
    var body: some View {
        let isSeed = SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil
        let available = isSeed ? CrateInventory.items(for: entity.id).map(\.id) : research.navigationLeads(entity.id, library: library).compactMap { lead -> String? in
            guard let raw = WorkID(rawValue: lead.id) else { return nil }
            let id = library.catalog.canonicalID(for: raw)
            return library.catalog.works[id] == nil ? nil : id.rawValue
        }
        PullOutToolbarAction(reader: readers.reader(for: entity.id), hasGraph: !visit.inventory.visible(root: entity.id, available: available).isEmpty) { onGraph(entity.id) }
    }
}

private struct ShopPageArticleRegion: View {
    let entity: SeedGraph.Entity
    let isCurrent: Bool
    let idle: Bool
    let queuedIDs: Set<String>
    let savedIDs: Set<String>
    let onStoryName: (StoryTextLinks.Target) -> Void
    let onReadingName: ((StoryTextLinks.Target, Source) -> Void)?
    let onNext: (SeedGraph.Entity) -> Void
    let onSave: (SeedGraph.Entity) -> Void
    let onWorks: () -> Void
    let onRetry: () -> Void
    let onCreator: (() -> Void)?
    let width: CGFloat
    let height: CGFloat
    let restTop: CGFloat
    let expandedTop: CGFloat
    let binY: CGFloat
    let bottomInset: CGFloat
    @Environment(OnDemandStories.self) private var stories
    @Environment(LeadResearch.self) private var research
    @Environment(Library.self) private var library
    @Environment(PullOutReaders.self) private var readers
    @Environment(StoryModelSettings.self) private var storySettings
    @ScaledMetric(relativeTo: .body) private var headerSize: CGFloat = 26
    @State private var showingModelSettings = false
    @State private var showingModelSetup = false
    @State private var trial = TrialAccess.shared
    @State private var confirmingDeep = false
    /// The lookup ran while this page was open, so its outcome arrives with a little motion.
    @State private var sawLoading = false
    @State private var contexts = WorkContextStore.shared
    @State private var selections = ShopSelectionCache()
    private var effectiveSavedIDs: Set<String> { savedIDs.union(selections.value(in: library).saved) }
    private var effectiveQueuedIDs: Set<String> { queuedIDs.union(selections.value(in: library).queued) }
    private var isSeed: Bool { SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil }
    private var story: Story? { isSeed ? stories.story(for: entity.id) : research.story(for: entity.id, library: library) }
    private var storyLoading: Bool { isSeed ? stories.isLoading(entity.id) : research.state(entity.id) == .loading }
    private var researchFailed: Bool { !isSeed && research.state(entity.id) == .failed }
    private var arrival: Lead? { isSeed || isCurrent ? nil : research.lead(for: entity.id) }
    private var catalogID: WorkID { library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)) }
    private var kindPrefix: String { ShopNowPage.kindPrefix(entity, work: library.catalog.work(catalogID)) }
    var body: some View {
        PullOutArticle(reader: readers.reader(for: entity.id), current: storySnapshot, width: width, height: height,
            restTitleTop: restTop, expandedTitleTop: expandedTop, fadeStart: binY - 66 * width / 402,
            bottomInset: bottomInset,
            onName: { target, source in if let onReadingName { onReadingName(target, source) } else { onStoryName(target) } },
            photo: storyPhoto) { articleHeader } empty: { emptyStoryArea }
            .id(entity.id)
            .sheet(isPresented: $showingModelSettings) { SettingsView() }
            .onChange(of: storyLoading, initial: true) { _, loading in if loading { sawLoading = true } }
            // No model yet: the first run's model step, in the same look (ONBOARDING §2).
            .fullScreenCover(isPresented: $showingModelSetup) {
                OnboardingFlow(start: .model) { outcome in
                    showingModelSetup = false
                    if outcome != .later { onRetry() }
                }
                .environment(library).environment(storySettings)
            }
    }
    /// The verified cover of a card this story names first (StoryPhoto, P1).
    private var storyPhoto: StoryPhoto? {
        guard let snapshot = storySnapshot, snapshot.scope != "维基百科简介" else { return nil }
        let items: [CrateItem] = isSeed ? CrateInventory.items(for: entity.id) : research.navigationLeads(entity.id, library: library).compactMap { lead in
            guard let raw = WorkID(rawValue: lead.id) else { return nil }
            let id = library.catalog.canonicalID(for: raw)
            guard library.catalog.works[id] != nil else { return nil }
            return CrateItem(entity: SeedLibraryBridge.entity(for: id, in: library), relation: lead.label, path: lead.path ?? [entity.id, id.rawValue])
        }
        return StoryPhoto.pick(story: snapshot.story.body, items: items, library: library)
    }
    private var articleHeader: some View {
        let display = SongTitlePresentation(entity.title, isSong: entity.kind == .song)
        return VStack(alignment: .leading, spacing: 0) {
            if idle && library.playbackPlatform == .apple {
                Text("Apple Music 没在播放，上次停在这里").font(.system(size: 12)).foregroundStyle(ShopNowPage.secondary.opacity(0.8)).padding(.bottom, 6)
            }
            Text(display.title).font(.system(size: min(34, 26 + (headerSize - 26) * 0.4), weight: .semibold)).tracking(-0.4)
                .lineLimit(2).minimumScaleFactor(0.75).accessibilityIdentifier("now-title")
            Text(kindPrefix + display.identity(creator: entity.subtitle)).font(.system(size: 13.5))
                .foregroundStyle(onCreator != nil && entity.kind.isMusic && !isSeed ? ShopNowPage.accent : ShopNowPage.secondary)
                .lineLimit(1).padding(.top, 4).contentShape(.rect).onTapGesture { onCreator?() }
                .accessibilityIdentifier("now-identity")
            if !isSeed { DiscoveryContextRow(entityID: entity.id, onOpen: onStoryName).padding(.top, 4) }
            if !isCurrent {
                HStack(spacing: 8) {
                    ITunesStoreBadge(work: library.catalog.work(SeedLibraryBridge.workID(entity.id)))
                    EntityActionButtons(entity: entity, queued: effectiveQueuedIDs.contains(entity.id), saved: effectiveSavedIDs.contains(entity.id),
                                        excluding: ["豆瓣", "播放视频", "看频道"],
                                        onNext: onNext, onSave: onSave, onWorks: onWorks)
                    ShopLookupLinks(entity: entity, lead: research.lead(for: entity.id) ?? research.lead(for: catalogID.rawValue))
                }.padding(.top, 10)
            }
            // While the Wikipedia opening stands in for the story, the page's one status line or
            // action (在查 / 查幕后和更多关联 / 没连上…) stays above it, never under the bin.
            if story == nil, introductionStory != nil { emptyStoryArea.padding(.top, 14) }
        }
    }

    private var storySnapshot: PullOutStorySnapshot? {
        guard let story else {
            // No behind-the-scenes story (yet): a non-music work reads its own Wikipedia opening in
            // the same place and with the same gestures — tap the dimmed lines or pull up to read it
            // all, pull back down to close — instead of a link that leaves the app.
            guard let intro = introductionStory else { return nil }
            return .init(story: intro, scope: "维基百科简介", subject: nil, allowsRoot: true)
        }
        return .init(story: story,
            scope: isSeed ? stories.scopeCaption(for: entity.id) : research.scope(for: entity.id, library: library),
            subject: isSeed ? nil : research.storyFocus(entity.id, library: library),
            allowsRoot: isSeed || research.storyAllowsRoot(entity.id))
    }

    @ViewBuilder private var emptyStoryArea: some View {
        VStack(alignment: .leading, spacing: 8) {
        if let arrival, !arrival.why.isEmpty {
            Text(arrival.why).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(ShopNowPage.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lead-arrival")
        }
        if !isSeed, !storySettings.hasKey, !trial.usable, !(trial.hasPass && storyLoading) {
            // Nothing to look this song up with: the line says what is missing and opens the model step.
            // A 体验码 pass says why it cannot be used now (run out, switched off, the day's lookups gone).
            HStack(spacing: 4) {
                if !trial.hasPass {
                    Text("接一个大模型就能查幕后 ·").foregroundStyle(ArtworkPalette.tx3)
                    Button("去接") { showingModelSetup = true }.buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
                } else {
                    Text((trial.remaining == 0 ? "体验码的 \(trial.total) 首查完了" : trial.dailyCapReached ? "今天的免费额度用完了，明天再来" : "免费体验暂停了") + " ·")
                        .foregroundStyle(ArtworkPalette.tx3)
                    Button("接自己的大模型") { showingModelSetup = true }.buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
                }
            }
            .font(.system(size: 13)).accessibilityIdentifier("discovery-model-settings")
        } else if storyLoading, let job = research.jobs.values[entity.id] {
            DiscoveryProgressView(job: job)
        } else if storyLoading {
            StoryLoadingView(compact: true).padding(.horizontal, -26).frame(height: 40, alignment: .top)
        } else if !isSeed {
            if let job = research.jobs.values[entity.id] {
                switch job.phase {
                case .interrupted, .stopped:
                    statusAction(job.phase == .stopped ? "已停止" : "查到一半停了", action: "接着查")
                case .failed:
                    if let reason = job.failure, reason != .network {
                        // The reader's own service refused: name it, and where to fix it.
                        let provider = storySettings.preset?.name ?? ""
                        HStack(spacing: 4) {
                            Text(reason.line(provider: provider) + " ·").foregroundStyle(ArtworkPalette.tx3)
                            if reason == .balance {
                                Button("充值后重查", action: onRetry).buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
                            } else {
                                Button("去设置") { showingModelSettings = true }.buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
                            }
                        }.font(.system(size: 13)).accessibilityIdentifier("discovery-provider-failure")
                    } else if job.failures >= 2, Date().timeIntervalSince(job.startedAt) < 1800 {
                        Text("刚才两次都没连上，过会儿再查").font(.system(size: 13)).foregroundStyle(ArtworkPalette.tx3)
                    } else { statusAction("没连上资料", action: "重查") }
                case .done:
                    if job.storyResult == .notAsked {
                        Button("查幕后 ›", action: onRetry).buttonStyle(.plain)
                            .font(.system(size: 13)).foregroundStyle(ShopNowPage.accent).accessibilityIdentifier("discovery-start")
                    } else if introductionStory != nil {
                        // A Wikipedia opening stands in for the story: one quiet line above it.
                        HStack(spacing: 4) {
                            Text(job.storyResult == .rejected ? "写出的幕后没通过出处核对" : "没找到有出处的幕后")
                                .foregroundStyle(ArtworkPalette.tx3).accessibilityIdentifier("discovery-no-story")
                            if DeepDiveConfirmation.available(entity, hasModel: storySettings.hasKey, library: library, research: research) {
                                Text("·").foregroundStyle(ArtworkPalette.tx3)
                                Button("深挖") { confirmingDeep = true }.buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
                                    .accessibilityIdentifier("lead-deep")
                            }
                        }.font(.system(size: 13))
                    } else {
                        // 什么都没查到 (anson 11-18 17:30): one plain sentence where the story stands, how many
                        // pages were looked through, and 深挖 where 更多 sits. Nothing is made up to fill it.
                        NothingFoundNote(sentence: NothingFound.sentence(entity, rejected: job.storyResult == .rejected),
                            pages: research.pagesRead(entity.id, library: library),
                            deep: DeepDiveConfirmation.available(entity, hasModel: storySettings.hasKey, library: library, research: research),
                            animated: sawLoading) { confirmingDeep = true }
                    }
                default: EmptyView()
                }
            } else if research.isContextOnly(entity.id) || research.state(entity.id) == .ready {
                Button("查幕后和更多关联 ›", action: onRetry).buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(ShopNowPage.accent).accessibilityIdentifier("discovery-start")
            } else if researchFailed { statusAction("没连上资料", action: "重查") }
        }
        }
        .modifier(DeepDiveConfirmation(entity: entity, isPresented: $confirmingDeep))
    }
    private func statusAction(_ text: String, action: String) -> some View {
        HStack(spacing: 4) {
            Text(text + " ·").foregroundStyle(ArtworkPalette.tx3)
            Button(action, action: onRetry).buttonStyle(.plain).foregroundStyle(ShopNowPage.accent)
        }.font(.system(size: 13)).accessibilityIdentifier("discovery-recovery")
    }

    /// The opening of a non-music work's own Wikipedia article, read in place while there is no story.
    private var introductionStory: Story? {
        guard !isSeed, !entity.kind.isMusic else { return nil }
        let work = library.catalog.work(catalogID)
        guard !work.isMusicWork, let qid = work.knowledgeID, let context = contexts.values[qid],
              let source = context.introductionSource, let text = context.readingExcerpt ?? context.introduction,
              !text.isEmpty else { return nil }
        return Story(id: "wikipedia-introduction:" + qid, entityID: catalogID.rawValue, title: "", body: text, source: source)
    }


}

/// What the story slot says when a finished lookup found no story and nothing to put in the bin.
enum NothingFound {
    static func sentence(_ entity: SeedGraph.Entity, rejected: Bool) -> String {
        if rejected { return "找到的说法都对不上出处。" }
        let noun: String? = switch entity.kind {
        case .song: "这首歌"
        case .album: "这张专辑"
        case .film: "这部电影"
        case .tv: "这部剧"
        case .game: "这款游戏"
        case .video: "这支视频"
        case .book: "这本书"
        case .manga: "这部漫画"
        case .person, .group: nil
        }
        if let noun { return "还没有人写过" + noun + "的来历。" }
        return "还没有人写过" + entity.title + "的幕后。"
    }
}

/// The story's own place and type, a shade quieter; under a hairline, how many pages were read
/// and 深挖 where 更多 normally stands. After a 深挖 the count grows and the button is gone.
private struct NothingFoundNote: View {
    let sentence: String
    let pages: Int
    let deep: Bool
    let onDeep: () -> Void
    @ScaledMetric(relativeTo: .body) private var preferredBody: CGFloat = 16
    @State private var visible: Bool
    init(sentence: String, pages: Int, deep: Bool, animated: Bool, onDeep: @escaping () -> Void) {
        self.sentence = sentence; self.pages = pages; self.deep = deep; self.onDeep = onDeep
        _visible = State(initialValue: !animated)
    }
    var body: some View {
        let size = min(28, max(14, preferredBody)), small = min(22, max(14, preferredBody - 1))
        VStack(alignment: .leading, spacing: 0) {
            Text(sentence).font(.system(size: size)).lineSpacing(size * 0.5625)
                .foregroundStyle(ShopStyle.ink.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("discovery-no-story")
            if pages > 0 || deep {
                Rectangle().fill(ShopStyle.line).frame(height: 0.5).padding(.top, 20)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if pages > 0 {
                        Text("翻过 \(pages) 个网页").font(.system(size: small)).foregroundStyle(ShopStyle.tertiary)
                            .accessibilityIdentifier("discovery-pages-read")
                    }
                    Spacer(minLength: 0)
                    if deep {
                        Button("深挖", action: onDeep).buttonStyle(.plain)
                            .font(.system(size: small, weight: .semibold)).foregroundStyle(ShopStyle.accent)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing).contentShape(.rect)
                            .accessibilityIdentifier("lead-deep")
                    }
                }
                .frame(minHeight: 44)
            }
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            guard !visible else { return }
            // After the bin has been emptied (翻到箱底), not before.
            withAnimation(.easeOut(duration: 0.35).delay(0.8)) { visible = true }
        }
    }
}

private struct ShopPageMenuRegion: View {
    let entity: SeedGraph.Entity
    let onNext: (SeedGraph.Entity) -> Void
    let onSave: (SeedGraph.Entity) -> Void
    let onRetry: () -> Void
    @Environment(Library.self) private var library
    @Environment(LeadResearch.self) private var research
    private var isSeed: Bool { SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil }
    private var storyLoading: Bool { !isSeed && research.state(entity.id) == .loading }
    private var catalogID: WorkID { library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)) }
    var body: some View {
        ShopPageMenu(isMusic: entity.kind.isMusic, canQueue: library.playbackPlatform == .apple && library.catalog.work(catalogID).isSong && library.catalog.work(catalogID).catalogRecordingID != nil,
                     canSave: false,
                     needsConnection: library.playbackPlatform == .apple && !library.musicConnected,
                     listenTitle: library.playbackPlatform.listenTitle,
                     appleURL: EntityActions.destination("在 Apple Music 打开", entity, library: library),
                     listenID: EntityActions.playbackID(entity, library: library),
                     canRefresh: !isSeed && research.state(entity.id) != .loading,
                     isLoading: !isSeed && storyLoading,
                     hasSources: !library.catalog.relations(touching: catalogID).isEmpty,
                     onConnect: { Task { await library.connectMusic() } },
                     onNext: { onNext(entity) }, onSave: { onSave(entity) }, onRetry: onRetry,
                     onSources: { library.sourceSheet = catalogID }, onStop: { research.stop(entity.id) },
                     usageLine: isSeed ? nil : UsageLedger.shared.latest(for: entity.id).map { "上次查找 " + UsageLedger.amount($0) })
            .equatable()
    }
}

/// The page menu only rebuilds when what it offers changes; playback ticks no longer redraw it while open.
/// Its body reads no observed state at all (anson 11-18 14:20: the menu kept flashing): reading
/// the player's snapshot here made every playback tick rebuild the open menu.
struct ShopPageMenu: View, @MainActor Equatable {
    let isMusic: Bool
    let canQueue: Bool
    var canSave = true
    let needsConnection: Bool
    let listenTitle: String
    let appleURL: URL?
    let listenID: WorkID?
    @Environment(Library.self) private var library
    let canRefresh: Bool
    var isLoading = false
    let hasSources: Bool
    let onConnect: () -> Void
    let onNext: () -> Void
    let onSave: () -> Void
    let onRetry: () -> Void
    let onSources: () -> Void
    var onStop: () -> Void = {}
    var canDeepDive = false
    var onDeepDive: () -> Void = {}
    /// What the last paid lookup of this page cost (设置 › 用量 has them all).
    var usageLine: String? = nil
    @Environment(\.openURL) private var openURL
    static func == (a: Self, b: Self) -> Bool {
        a.isMusic == b.isMusic && a.canQueue == b.canQueue && a.appleURL == b.appleURL && a.listenID == b.listenID
            && a.canRefresh == b.canRefresh && a.isLoading == b.isLoading && a.hasSources == b.hasSources && a.canDeepDive == b.canDeepDive
            && a.usageLine == b.usageLine && a.needsConnection == b.needsConnection && a.listenTitle == b.listenTitle && a.canSave == b.canSave
    }
    var body: some View {
        Menu {
            if needsConnection { item("连接 Apple Music", "link", action: onConnect) }
            if let listenID { item(listenTitle, "play.fill") { library.listen(listenID) } }
            else if let appleURL { item("在 Apple Music 打开", "arrow.up.forward.app") { openURL(appleURL) } }
            if isMusic {
                if canQueue { item("下一首播放", "text.line.first.and.arrowtriangle.forward", action: onNext) }
                if canSave { item("稍后听", "clock", action: onSave).accessibilityIdentifier("now-save") }
            }
            if isLoading { item("停止查找", "stop", action: onStop).accessibilityIdentifier("lead-stop") }
            else if canRefresh { item("重新查找", "arrow.clockwise", action: onRetry).accessibilityIdentifier("lead-refresh") }
            if canDeepDive && !isLoading { item("深挖", "magnifyingglass", action: onDeepDive).accessibilityIdentifier("lead-deep") }
            if hasSources { item("来源", "text.quote", action: onSources) }
            if let usageLine { Section { Button(usageLine) {}.disabled(true).accessibilityIdentifier("lead-usage") } }
        } label: { Image(uiImage: MenuSymbol.image("ellipsis")) }
            .accessibilityLabel("更多").accessibilityIdentifier("now-more")
    }
    /// Menu rows carry pre-resolved symbol images: a named symbol is otherwise looked
    /// up in the asset catalog for every row each time a page builds its toolbar.
    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(uiImage: MenuSymbol.image(symbol)) } }
    }
}

/// SF Symbols resolved once per name and kept (template images, so tinting still applies).
@MainActor enum MenuSymbol {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage {
        if let known = cache[name] { return known }
        let image = (UIImage(systemName: name) ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache[name] = image
        return image
    }
}

/// Where to go from a work page, by what the work is (see WorkDestinations): watch a video,
/// read up on a film or book, find a song that is not in Apple Music.
struct ShopLookupLinks: View {
    let entity: SeedGraph.Entity
    let lead: Lead?
    @Environment(Library.self) private var library
    /// Bumped when the exact pages arrive, so the buttons switch from searches to the pages.
    @State private var resolved = 0
    @State private var showsSearch = false
    @State private var choosingRecording = false
    @State private var versions = RecordingVersionsStore.shared
    /// The store has been asked for this song's versions (found or not).
    @State private var versionsChecked = false
    private var work: Work { library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))) }
    /// A song or piece the store has no direct link for: its versions are looked up.
    private var needsVersion: Bool { (work.isSong || work.isMusicWork) && work.appleMusicURL == nil }
    var body: some View {
        let _ = resolved
        let links = WorkDestinations.links(entity, library: library, lead: lead)
            HStack(spacing: 10) {
                if needsVersion { versionButtons }
                ForEach(Array(links.filter { !$0.search || showsSearch }.prefix(2))) { PageDestinationButton(link: $0) }
            }
        .frame(height: 38, alignment: .leading)
        .sheet(isPresented: $choosingRecording) { RecordingPicker(entityID: entity.id) }
        .task(id: entity.id) {
            async let lookup: Void = resolveLinks()
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { showsSearch = true } }
            await lookup
        }
        .task(id: "versions:" + entity.id) {
            versionsChecked = false
            guard needsVersion, library.playbackPlatform == .apple else { return }
            await RecordingVersionsStore.shared.load(work, library: library)
            withAnimation(.easeOut(duration: 0.2)) { versionsChecked = true }
        }
    }
    /// Found versions: play the first one right here, the others behind 能听的版本 (anson 11-18).
    /// None in the reader's store: copy the name or search elsewhere, at the least.
    @ViewBuilder private var versionButtons: some View {
        let _ = versions.revision
        let found = versions.versions(for: work, library: library)
        let ids = found.known + found.candidates
        if library.playbackPlatform != .apple || EntityActions.playbackID(entity, library: library) != nil {
            // The page already has its own 播放, or the reader listens on another platform.
            versionsButton
        } else if let first = ids.first {
            Button { library.listen(first) } label: {
                Label("播放", systemImage: "play.fill").lineLimit(1)
                    .font(.system(size: 13.5, weight: .medium)).padding(.horizontal, 16).frame(minHeight: 38).fixedSize()
            }
            .buttonStyle(.plain).foregroundStyle(ShopStyle.accent)
            .glassEffect(.regular.tint(ShopStyle.accent.opacity(0.18)).interactive(), in: .capsule)
            .disabled(library.playbackBusy)
            .accessibilityIdentifier("recording-play")
            if ids.count > 1 { versionsButton }
        } else if versionsChecked {
            ElsewhereSearch(title: ElsewhereSearch.title(work), artist: work.creator.isEmpty ? entity.subtitle : work.creator)
        } else {
            versionsButton
        }
    }
    private var versionsButton: some View {
        Button("能听的版本") { choosingRecording = true }
            .font(.system(size: 13.5, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 38)
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier("recording-versions")
    }
    private func resolveLinks() async {
        if await WorkDestinations.resolve(entity, library: library, lead: lead) {
            withAnimation(.easeOut(duration: 0.2)) { resolved += 1 }
        }
    }
}


