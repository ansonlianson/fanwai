import SwiftUI

struct RelationMapView: View {
    let root: String
    let initialFocus: String
    var queuedIDs: Set<String> = []
    var savedIDs: Set<String> = []
    var onEntity: (String) -> Void
    var onNext: (SeedGraph.Entity) -> Void
    var onSave: (SeedGraph.Entity) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(Library.self) private var library
    @Environment(LeadResearch.self) private var research
    @Environment(\.playbackTop) private var playbackTop
    @State private var map: RelationMapModel
    /// Per-frame gesture bookkeeping. A reference that SwiftUI does not observe: a pan or
    /// pinch writes it every frame without re-evaluating this view (the card, breadcrumbs,
    /// toolbar). Only `MapCameraCanvas` redraws, and only its transform (0.5.8).
    @State private var interaction = MapInteraction()
    /// The live camera scale, read only by the map's labels (so they resize continuously).
    @State private var zoom = MapZoom()
    /// A restored trail keeps the camera it was left with; the card's layout
    /// (which grows as its sentence and pages arrive) must not re-fit it.
    @State private var keepRestoredCamera = false
    /// When a finger last moved or pinched the map, and when a node was last chosen. A node's
    /// tap that lands with a pinch is not a choice, and once the user has moved the camera
    /// themselves, late arrivals (research, the card's new height) no longer re-fit it.
    @State private var focusedAt = Date.distantPast
    private var userTookCamera: Bool { interaction.touchedAt > focusedAt }
    private var canonicalMapSignature: [String] {
        map.order.map { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0)).rawValue }
    }
    @State private var positions: [String: CGPoint] = [:]
    @State private var born = Set<String>()
    @State private var drawn = Set<String>()
    @State private var hiddenMeetEdges = Set<String>()
    @State private var pings: [String: Int] = [:]
    @State private var meetEdge: RelationMapModel.Edge?
    @State private var cardID: String
    @State private var cardSwap = false
    @State private var lastExpansion: [String: Any] = [:]
    @State private var listMode = false
    @State private var listRoot: String
    @State private var started = false
    @State private var cardHeight: CGFloat = 0
    @State private var bottomInset: CGFloat = 90
    @State private var work: [Task<Void, Never>] = []
    /// Bumped when the card's exact pages arrive, so its third button switches to them.
    @State private var linksRevision = 0
    @State private var versionsFor: String?
    @State private var contexts = WorkContextStore.shared
    /// Why the selected work is on the map: its sentence from the page it was found on.
    @State private var cardLead: Lead?
    @State private var cardLeadFor: String?
    private let store = RelationTrailStore()
    private var isDynamic: Bool { !SeedNowContent.contains(root) || RecordShopArtReview.current != nil }
    private var graph: SeedGraph { isDynamic ? PublicCrateInventory.leadGraph(root: root, expanding: map.order, library: library) : SeedNowContent.connectionGraph }
    private func entity(_ id: String) -> SeedGraph.Entity? { Self.lookup(id, dynamic: isDynamic, library: library) }
    @MainActor static func lookup(_ id: String, dynamic: Bool, library: Library) -> SeedGraph.Entity? {
        if !dynamic { return SeedNowContent.entity(id) }
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(id))
        guard library.catalog.works[key] != nil else { return nil }
        let value = SeedLibraryBridge.entity(for: key, in: library)
        return .init(id: value.id, kind: value.kind, title: value.title, subtitle: value.subtitle,
                     artworkAsset: value.artworkAsset, fallbackGlyph: value.fallbackGlyph, hook: "", actions: value.actions)
    }
    private var palette: ArtworkPalette { .asset(entity(root)?.artworkAsset) }
    private let cameraAnimation = Animation.timingCurve(0.25, 0.85, 0.3, 1, duration: 0.7)

    init(root: String, initialFocus: String, initiallyListing: Bool = false, queuedIDs: Set<String> = [], savedIDs: Set<String> = [],
         onEntity: @escaping (String) -> Void, onNext: @escaping (SeedGraph.Entity) -> Void,
         onSave: @escaping (SeedGraph.Entity) -> Void) {
        self.root = root; self.initialFocus = initialFocus; self.queuedIDs = queuedIDs; self.savedIDs = savedIDs
        self.onEntity = onEntity; self.onNext = onNext; self.onSave = onSave
        let saved = RelationTrailStore().load(root: root)
        let state = saved ?? RelationMapModel(root: root)
        _keepRestoredCamera = State(initialValue: saved?.nodes[root]?.expanded == true && saved?.pendingFocusFit != true)
        _map = State(initialValue: state); _cardID = State(initialValue: state.focus); _listRoot = State(initialValue: initiallyListing ? initialFocus : root)
        _listMode = State(initialValue: initiallyListing)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let art = RecordShopArtReview.current { RecordShopReviewBackdrop(art: art) }
                else if ShopPlates.shared.isAvailable { ShopMapBackdrop() }
                else { FeltBackdrop(palette: palette) }
                canvas(size: geometry.size)
                    .opacity(listMode ? 0 : 1).allowsHitTesting(!listMode)
                if listMode { relationList(size: geometry.size) }
                if !listMode {
                    breadcrumbs(size: geometry.size).padding(.top, 120)
                    if let entity = entity(cardID) {
                        bottomScrim
                        focusCard(entity).padding(.horizontal, 12)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                cardHeight = height
                                // A restored trail keeps its camera until the user chooses a work
                                // or moves the map; the card filling in later must not re-fit it.
                                if keepRestoredCamera { return }
                                if userTookCamera { return }
                                fit(isDynamic ? map.order : map.focusNeighborhood, size: geometry.size)
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, bottomInset)
                    }
                }
            }
            .clipped().ignoresSafeArea()
            .task { await prepare(size: geometry.size) }
            .onGeometryChange(for: CGFloat.self) { proxy in
                playbackTop.isFinite ? max(28, proxy.frame(in: .global).maxY-playbackTop+12)
                    : max(140, proxy.safeAreaInsets.bottom+90)
            } action: { bottomInset = $0 }
            .onChange(of: canonicalMapSignature) { _, _ in canonicalizeMap() }
        }
        .ignoresSafeArea()
        // Keep native navigation and playback occupancy consistent with the
        // record page. Hiding the tab bar here resized the crate during pop.
        // Tabs and the player stay as on every other page (no jump on the way back);
        // the focus card below is content, not a third glass panel.
        .toolbar(.visible, for: .navigationBar).toolbar(.visible, for: .tabBar)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $listMode) {
                    Text("关系图").tag(false)
                    Text("列表").tag(true)
                }.pickerStyle(.segmented).frame(width: 162).accessibilityIdentifier("map-segment")
            }
            // No trailing buttons: 看全图 and ⋯ did nothing he used, and the ☆ lives on each song's card (anson 11-20).
        }
        .foregroundStyle(ArtworkPalette.tx).tint(palette.ac.color)
        .sheet(isPresented: Binding(get: { versionsFor != nil }, set: { if !$0 { versionsFor = nil } })) {
            if let id = versionsFor { RecordingPicker(entityID: id) }
        }
        .onChange(of: map) { _, state in store.save(state) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.save(map) } }
        .onDisappear { store.save(map); work.forEach { $0.cancel() }; work.removeAll() }
    }

    private func canvas(size: CGSize) -> some View {
        MapCameraCanvas(camera: map.camera, size: size, interaction: interaction, zoom: zoom,
                        onBegin: { if keepRestoredCamera { keepRestoredCamera = false } },
                        onCommit: { map.camera = $0 }) {
            RelationMapContent(map: map, root: root, isDynamic: isDynamic, positions: positions, born: born, drawn: drawn,
                               hiddenMeetEdges: hiddenMeetEdges, pings: pings, palette: palette, reduceMotion: reduceMotion,
                               onTap: { tap($0, size: size) }, onMounted: { await mounted($0) })
            .equatable()
        }
        .environment(zoom)
        .accessibilityElement(children: .contain).accessibilityIdentifier("relation-canvas")
        .accessibilityValue(mapAccessibilityValue)
    }
    /// Artists listed or placed on the map get their Apple Music photo.
    private func loadPhoto(_ id: String) {
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(id)))
        if work.art.isEmpty, work.isPerson, work.id.rawValue.hasPrefix("apple:artist:") {
            Task { await WorkArtworkStore.shared.loadAppleArtist(String(work.id.rawValue.dropFirst("apple:artist:".count))) }
        }
    }
    private func mounted(_ id: String) async {
        loadPhoto(id)
        if isDynamic, research.reports[id] != nil { map.freezeSelection(id, graph: graph) }
        // Start only once this node has actually mounted.
        // A model insertion can precede the first drawn frame.
        guard born.contains(id) else { return }
        let index = map.order.filter { born.contains($0) }.firstIndex(of: id) ?? 0
        try? await Task.sleep(for: .milliseconds(30+index*55))
        guard !Task.isCancelled, let destination = map.nodes[id]?.position else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.62, dampingFraction: 0.8)) {
            positions[id] = destination; born.remove(id)
        }
    }

    private var mapAccessibilityValue: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-network=real-relations"),
           let data = try? JSONEncoder().encode(map),
           var value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value["rendering"] = ["born": Array(born), "positions": positions.mapValues { [$0.x, $0.y] },
                                  "cancelledTasks": work.filter(\.isCancelled).count]
            let snapshot = graph
            value["lastExpansion"] = lastExpansion
            value["badges"] = Dictionary(uniqueKeysWithValues: map.order.map { ($0, displayedPending($0, graph: snapshot)) })
            value["outgoing"] = Dictionary(uniqueKeysWithValues: map.order.map { id in
                (id, snapshot.outgoing(from: id).map { ["to": $0.to, "label": $0.label, "via": $0.via ?? ""] })
            })
            value["objects"] = Dictionary(uniqueKeysWithValues: map.order.compactMap { id -> (String, [CGFloat])? in
                guard let entity = entity(id) else { return nil }
                let scale: CGFloat = id == root && entity.kind.isMusic ? 104/64 : 1
                let size = PhysicalObject.baseSize(for: entity.kind)
                return (id, [size.width*scale, size.height*scale])
            })
            return String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? data, as: UTF8.self)
        }
        #endif
        return "\(map.nodes.count) 件，缩放 \(Int(map.camera.scale*100))%"
    }

    private func breadcrumbs(size: CGSize) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(map.focusPath.enumerated()), id: \.element) { index, id in
                        if index > 0 { Text("›").font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx3) }
                        Button(entity(id)?.title ?? "") { focus(id, size: size) }
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: size.width * 0.65)
                            .font(.system(size: 12.5, weight: id == map.focus ? .semibold : .regular)).padding(.horizontal, 6).padding(.vertical, 5)
                            .foregroundStyle(id == map.focus ? ArtworkPalette.paperInk : ArtworkPalette.tx2)
                            .background(id == map.focus ? ArtworkPalette.paper : .clear, in: .rect(cornerRadius: 4))
                            .buttonStyle(.plain).id(id).accessibilityIdentifier("map-crumb-" + id)
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
                .onChange(of: map.focus) { _, id in reader.scrollTo(id, anchor: .trailing) }
        }.frame(height: 32)
    }
    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
    private func fit(_ ids: [String], size: CGSize) {
        let area = CGRect(x: 12, y: 166, width: max(1, size.width-88), height: max(1, size.height-bottomInset-cardHeight-12-166))
        withAnimation(reduceMotion ? nil : cameraAnimation) { map.camera = map.fittedCamera(ids: isDynamic ? map.order : ids, viewport: size, available: area) }
    }
    private func zoom(_ factor: CGFloat, size: CGSize) {
        withAnimation(reduceMotion ? nil : cameraAnimation) { map.camera.zoom(by: factor, at: CGPoint(x: size.width/2, y: size.height*0.45)) }
    }
    private func focus(_ id: String, size: CGSize) {
        keepRestoredCamera = false
        map.setFocus(id)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { cardSwap = true }
        work.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140)); guard !Task.isCancelled else { return }
            cardID = id
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8)) { cardSwap = false }
        })
        work.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80)); guard !Task.isCancelled else { return }
            fit(map.focusNeighborhood, size: size)
        })
    }
    private func displayedPending(_ id: String, graph: SeedGraph) -> Int {
        guard !isDynamic || map.plannedRelations?[id] != nil else { return 0 }
        return map.pending(id, graph: graph)
    }
    private func tap(_ id: String, size: CGSize) {
        // The finger that rested on a sleeve during a pinch or pan lifts as a "tap"; it is not one.
        guard !interaction.pinching, Date().timeIntervalSince(interaction.touchedAt) > 0.35 else { return }
        keepRestoredCamera = false
        // Tapping the open sleeve in focus folds it back; tapping it again opens it.
        if map.focus == id, map.canCollapse(id) { collapse(id, size: size); return }
        focusedAt = Date()
        focus(id, size: size)
        // Open with what is already known; nothing here waits on the network.
        expand(id)
        fit(map.focusNeighborhood, size: size)
        follow(id, size: size)
    }
    /// What the sleeve opened slides back into it and fades; then the map settles on it.
    private func collapse(_ id: String, size: CGSize) {
        focusedAt = Date()
        let origin = map.nodes[id]?.position ?? .zero
        let gone = map.descendants(of: id)
        let lines = map.edges.filter { gone.contains($0.from) || gone.contains($0.to) || ($0.from == id && $0.meet) }.map(\.id)
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.28)) {
            for key in gone { positions[key] = origin; born.insert(key) }
            drawn.subtract(lines)
        }
        work.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 300)); guard !Task.isCancelled else { return }
            map.collapse(id)
            for key in gone { positions[key] = nil; born.remove(key) }
            cardID = map.focus
            fit(map.focusNeighborhood, size: size)
        })
    }
    /// A sleeve not researched yet is looked up in the background. What it
    /// finds joins the map around it; nothing already placed moves.
    private func follow(_ id: String, size: CGSize) {
        guard isDynamic, research.reports[id] == nil, let subject = research.subject(id, library: library) else { return }
        work.append(Task { @MainActor in
            // A sleeve followed on the map is asked for its related works only (anson 2026-11-18):
            // no story is written or paid for here. Its own page offers 查幕后.
            await research.load(subject, library: library, context: id == root ? nil : .init(rootID: root, parentID: map.nodes[id]?.via ?? root),
                                cardsOnly: id != root)
            guard !Task.isCancelled, map.nodes[id] != nil else { return }
            // Folded back by the user meanwhile: leave it folded.
            guard map.nodes[id]?.expanded == true else { return }
            map.reopen(id)
            expand(id)
            let seeded = id == root && seedKnownDiscovery()
            if map.focus == id, !userTookCamera { fit(seeded ? map.order : map.focusNeighborhood, size: size) }
        })
    }
    private func expand(_ id: String) {
        let origin = map.nodes[id]?.position ?? .zero
        let selection = map.pendingRelations(id, graph: graph)
        let result = map.expand(id, graph: graph)
        #if DEBUG
        lastExpansion = ["id": id, "preparedCount": selection.count, "fresh": result.fresh,
                         "meets": result.meets.map(\.to), "selected": selection.map { ["to": $0.to, "label": $0.label, "via": $0.via ?? ""] }]
        #endif
        for key in result.fresh { positions[key] = origin; born.insert(key) }
        work.append(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120)); guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .timingCurve(0.3, 0.8, 0.3, 1, duration: 0.6)) { drawn.formUnion(result.edges.map(\.id) + result.meets.map(\.id)) }
        })
        // Meeting a sleeve already on the map: the new line simply joins it.
    }
    private func prepare(size: CGSize) async {
        canonicalizeMap()
        if isDynamic, map.initialDiscoverySeeded != true {
            let facts = library.catalog.edges
            let canonicalPairs = Set(facts.map { [$0.from.rawValue, $0.to.rawValue].sorted().joined(separator: "|") })
            func isValid(_ from: String, _ to: String) -> Bool {
                let a = library.catalog.canonicalID(for: SeedLibraryBridge.workID(from))
                let b = library.catalog.canonicalID(for: SeedLibraryBridge.workID(to))
                return canonicalPairs.contains([a.rawValue, b.rawValue].sorted().joined(separator: "|"))
            }
            var valid = Set(map.edges.filter { shown in
                isValid(shown.from, shown.to)
            }.map(\.id))
            for (owner, selection) in map.plannedRelations ?? [:] {
                for relation in selection where isValid(relation.via ?? owner, relation.to) {
                    valid.insert([relation.via ?? owner, relation.to].sorted().joined(separator: "|"))
                }
            }
            map.pruneInvalidEdges(keeping: valid)
        }
        positions = map.nodes.mapValues(\.position); drawn = Set(map.edges.map(\.id)); hiddenMeetEdges = []; born = []
        guard !started else { return }
        started = true
        if !map.nodes[root]!.expanded {
            map.camera = MapCamera(x: size.width/2, y: 400, scale: 0.95)
            expand(root)
            seedKnownDiscovery()
            try? await Task.sleep(for: .milliseconds(120))
            fit(map.order, size: size)
        }
        if seedKnownDiscovery(), !userTookCamera, !keepRestoredCamera {
            fit(map.order, size: size)
        }
        follow(root, size: size)
        if map.pendingFocusFit == true {
            fit(map.focusNeighborhood, size: size)
            map.pendingFocusFit = nil
        }
        if initialFocus != root, map.nodes[initialFocus] != nil {
            try? await Task.sleep(for: .milliseconds(700)); tap(initialFocus, size: size)
        }
    }
    private func canonicalizeMap() {
        let before = map.order
        map.canonicalize { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0)).rawValue }
        guard before != map.order else { return }
        positions = map.nodes.mapValues(\.position); drawn = Set(map.edges.map(\.id))
        born = []; hiddenMeetEdges = []
        let canonicalRoot = library.catalog.canonicalID(for: SeedLibraryBridge.workID(root)).rawValue
        let next = library.catalog.canonicalID(for: SeedLibraryBridge.workID(cardID)).rawValue
        cardID = next == canonicalRoot ? root : next
    }
    @discardableResult private func seedKnownDiscovery() -> Bool {
        guard isDynamic, map.initialDiscoverySeeded != true else { return false }
        let paths = DiscoveryNavigation.initialMapPaths(from: root, catalog: library.catalog,
            provider: nil)
        let owners = paths.flatMap { $0.dropLast() }
        let known = PublicCrateInventory.leadGraph(root: root, expanding: map.order + owners, library: library)
        let result = map.seedKnownPaths(paths, graph: known)
        for id in result.fresh { positions[id] = map.nodes[id]?.position }
        drawn.formUnion(result.edges.map(\.id) + result.meets.map(\.id))
        return !result.fresh.isEmpty
    }
}

extension RelationMapView {
    private var scrimBase: Color {
        RecordShopArtReview.current?.base ?? (ShopPlates.shared.isAvailable ? ShopNowPage.base : palette.bg.color)
    }
    /// One ground colour from just above the card down to the screen's bottom edge, under the
    /// player and the tabs too, so nothing below the card shows a seam (MAP-COLLECTION-DESIGN §4.4).
    private var bottomScrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [scrimBase.opacity(0), scrimBase], startPoint: .top, endPoint: .bottom).frame(height: 32)
            scrimBase
        }
        .frame(height: max(0, cardHeight + bottomInset + 24))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private struct CardButton: Identifiable {
        let id: String
        let title: String
        let symbol: String?
        var enabled = true
        var highlighted = false
        let action: () -> Void
    }
    /// 打开, then what this kind of work offers, then its first exact page; three at most.
    private func cardButtons(_ entity: SeedGraph.Entity) -> [CardButton] {
        _ = linksRevision
        var out = [CardButton(id: "open", title: "打开", symbol: "arrow.up.right") { onEntity(entity.id) }]
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        for action in actions(entity) where out.count < 3 {
            switch action {
            case _ where action == library.playbackPlatform.listenTitle:
                if library.playbackPlatform == .apple && playingNow(entity) { out.append(.init(id: action, title: "正在播放", symbol: "waveform", enabled: false) {}) }
                else { out.append(.init(id: action, title: library.playbackPlatform.listenTitle, symbol: "play.fill", enabled: !library.playbackBusy) { perform(action, on: entity) }) }
            case "下一首播放":
                let queued = completed(action, entity)
                out.append(.init(id: action, title: queued ? "已排下一首" : "下一首", symbol: queued ? "checkmark" : "text.line.first.and.arrowtriangle.forward",
                                 enabled: !queued && !library.playbackBusy, highlighted: queued) { perform(action, on: entity) })
            case _ where WorkVerb.isSave(action):
                // Music is kept with the card's ☆, not a button here.
                if entity.kind.isMusic { continue }
                let saved = completed(action, entity)
                out.append(.init(id: action, title: saved ? WorkVerb.saved(action) : action, symbol: WorkVerb.symbol(action, saved: saved),
                                 highlighted: saved) { perform(action, on: entity) })
            case "在 Apple Music 打开":
                out.append(.init(id: action, title: "Apple Music", symbol: "arrow.up.forward.app") { perform(action, on: entity) })
            default: break
            }
        }
        if out.count < 3, work.isMusicWork || (work.isSong && work.appleMusicURL == nil && library.playbackPlatform == .apple) {
            out.append(.init(id: "versions", title: "能听的版本", symbol: "music.note.list") { versionsFor = entity.id })
        }
        if out.count < 3 {
            let links = WorkDestinations.links(entity, library: library, lead: research.lead(for: entity.id))
            let titles = Set(out.map(\.title))
            if let link = links.first(where: { !$0.search && !titles.contains($0.title) }) ?? links.first(where: { !titles.contains($0.title) }) {
                out.append(.init(id: "link", title: link.search ? "搜" + link.title : link.title,
                                 symbol: link.search ? "magnifyingglass" : "arrow.up.right.square") { openURL(link.url) })
            }
        }
        return out
    }
    /// What the work is before who made it, as on its page: 「游戏 · 上海アリス幻樂団」.
    private func identity(_ entity: SeedGraph.Entity) -> String {
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        return ShopNowPage.kindPrefix(entity, work: work) + entity.subtitle
    }
    /// The opening of the work's own Wikipedia article (free, sourced), for a card with no lead sentence.
    private func introduction(_ entity: SeedGraph.Entity) -> String? {
        guard !entity.kind.isMusic else { return nil }
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        guard let qid = work.knowledgeID, let context = contexts.values[qid], context.introductionSource != nil else { return nil }
        return context.readingExcerpt ?? context.introduction
    }
    private func focusCard(_ entity: SeedGraph.Entity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button { onEntity(entity.id) } label: {
                    HStack(spacing: 14) {
                        if ShopStyle.enabled { ShopObject(entity: entity, height: 58).shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 3) }
                        else { PhysicalObject(entity: entity, scale: cardScale(entity), palette: palette, showsDisc: false) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entity.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                .accessibilityIdentifier("map-card-title")
                            Text(identity(entity)).font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx2).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("map-card-open")
                // Every song on the map, the one it starts from included, is starred from its card.
                if entity.kind.isMusic {
                    ShopStarAction(entity: entity, onSave: onSave).font(.system(size: 19)).frame(width: 40, height: 40)
                }
            }
            if isDynamic, let lead = cardLead, cardLeadFor == entity.id, entity.id != root {
                Text(lead.label + " · " + lead.why).font(.system(size: 13.5)).lineSpacing(2.5).lineLimit(2)
                    .foregroundStyle(ArtworkPalette.tx.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12).accessibilityIdentifier("map-card-why")
            } else if cardLeadFor == entity.id, let intro = introduction(entity) {
                Text("\(Text("维基百科　").font(.system(size: 11.5)).foregroundStyle(ArtworkPalette.tx3))\(intro)")
                    .font(.system(size: 13)).lineSpacing(2.5).lineLimit(2).foregroundStyle(ArtworkPalette.tx2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12).accessibilityIdentifier("map-card-intro")
            }
            if isDynamic, research.state(entity.id) == .loading {
                if let job = research.jobs.values[entity.id] { DiscoveryProgressView(job: job, compact: true).padding(.top, 10) }
                else { ProgressView().controlSize(.small).tint(ArtworkPalette.tx3).padding(.top, 10).accessibilityLabel("正在查找") }
            }
            HStack(spacing: 8) {
                ForEach(cardButtons(entity)) { b in
                    Button(action: b.action) {
                        HStack(spacing: 5) {
                            if let symbol = b.symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                            Text(b.title).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity, minHeight: 22)
                    }
                    .font(.system(size: 13.5, weight: .medium)).buttonStyle(.glass)
                    .foregroundStyle(b.highlighted ? scrimAccent : ArtworkPalette.tx)
                    .disabled(!b.enabled)
                    .accessibilityIdentifier("map-action-" + b.id)
                }
            }.padding(.top, 14)
        }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
            .task(id: entity.id) {
                // Looked up once per card, never per frame of a pan or pinch.
                cardLead = relationLead(entity); cardLeadFor = entity.id
                let lead = research.lead(for: entity.id)
                let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
                if !entity.kind.isMusic, let qid = work.knowledgeID { await WorkContextStore.shared.load(qid) }
                if await WorkDestinations.resolve(entity, library: library, lead: lead) { linksRevision += 1 }
            }
            .scaleEffect(cardSwap ? 0.985 : 1).offset(y: cardSwap ? 8 : 0)
            .accessibilityElement(children: .contain).accessibilityIdentifier("map-focus-card")
    }
    private var scrimAccent: Color { ShopStyle.enabled ? ShopStyle.accent : palette.ac.color }
    /// The lead sentence for this work, from the report that found it or from the bin of the page
    /// it hangs from on the map (the same sentence the crate's note shows).
    private func relationLead(_ entity: SeedGraph.Entity) -> Lead? {
        guard isDynamic, entity.id != root else { return nil }
        if let lead = research.lead(for: entity.id), !lead.why.isEmpty { return lead }
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
        for parent in [map.nodes[entity.id]?.via, root].compactMap({ $0 }) {
            if let lead = research.navigationLeads(parent, library: library).first(where: {
                library.catalog.canonicalID(for: SeedLibraryBridge.workID($0.id)) == key }), !lead.why.isEmpty { return lead }
        }
        return nil
    }
    /// The song that is playing needs no play button on its own card.
    private func playingNow(_ entity: SeedGraph.Entity) -> Bool {
        if RecordShopArtReview.current != nil, entity.id == root { return true }
        guard let current = library.currentTrack else { return false }
        return library.catalog.canonicalID(for: current) == library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
    }
    private func cardScale(_ entity: SeedGraph.Entity) -> CGFloat {
        switch entity.kind.objectKind {
        case .film, .game, .book, .manga: 60 / PhysicalObject.baseSize(for: entity.kind).height
        case .person: 54/68
        case .video: 84/86
        default: 56/64
        }
    }
    private var listGroups: [(title: String, rows: [SeedGraph.Relation])] {
        let listID = library.catalog.canonicalID(for: SeedLibraryBridge.workID(listRoot))
        let direct = isDynamic ? PublicCrateInventory.directEdges(listID, catalog: library.catalog,
            researchProvider: nil).map {
            SeedGraph.Relation(from: listRoot, to: SeedLibraryBridge.entity(for: $0.other(than: listID), in: library).id,
                               label: $0.label(from: listID), via: nil)
        } : graph.outgoing(from: listRoot)
        func group(_ edge: SeedGraph.Relation) -> String {
            if isDynamic, listLead(edge.to) != nil { return "关联" }
            if ["钢琴改编", "改编为", "动画化"].contains(edge.label) { return "改编与翻奏" }
            if entity(edge.to)?.kind == .person { return "创作者" }
            if entity(edge.to)?.kind == .video { return "视频" }
            return "出自"
        }
        return ["关联", "出自", "创作者", "改编与翻奏", "视频"].compactMap { title in
            let rows = direct.filter { group($0) == title }
            return rows.isEmpty ? nil : (title, rows)
        }
    }
    /// A lead found for the page the list is about, with its sentence.
    private func listLead(_ id: String) -> Lead? {
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(id)).rawValue
        return research.leads(listRoot).first { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0.id)).rawValue == key }
    }
    private func listCaption(_ entity: SeedGraph.Entity, _ edge: SeedGraph.Relation) -> String {
        if isDynamic, let lead = listLead(entity.id) { return lead.label + " · " + lead.why }
        if entity.kind == .person { return entity.subtitle.isEmpty ? edge.label : entity.subtitle }
        return entity.subtitle.isEmpty ? edge.label : entity.subtitle + "，" + edge.label
    }
    private func relationList(size: CGSize) -> some View {
        List {
            if let entity = graph[listRoot] {
                HStack(spacing: 16) {
                    if ShopStyle.enabled { ShopObject(entity: entity, height: 76, asSleeve: true).shadow(color: .black.opacity(0.5), radius: 5, x: 2, y: 4) }
                    else { PhysicalObject(entity: entity, palette: palette, showsDisc: false) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entity.title).font(.system(size: 20, weight: .bold))
                        Text(entity.subtitle).font(.system(size: 13.5)).foregroundStyle(ArtworkPalette.tx2)
                    }
                }.padding(.vertical, 6).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(listGroups, id: \.title) { group in
                Section {
                    ForEach(group.rows, id: \.to) { edge in
                        if let entity = entity(edge.to) {
                            HStack(spacing: 14) {
                                Button {
                                    if map.nodes[entity.id] != nil {
                                        listMode = false
                                        tap(entity.id, size: size)
                                    } else { onEntity(entity.id) }
                                } label: {
                                    HStack(spacing: 14) {
                                        Group {
                                            if ShopStyle.enabled { ShopObject(entity: entity, height: 52).shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 2) }
                                            else { PhysicalObject(entity: entity, scale: 50 / max(PhysicalObject.baseSize(for: entity.kind).width, PhysicalObject.baseSize(for: entity.kind).height), palette: palette, showsDisc: false) }
                                        }
                                            .frame(width: 56, height: 54)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entity.title).font(.system(size: 15.5)).lineLimit(1)
                                            Text(listCaption(entity, edge))
                                                .font(.system(size: 13)).foregroundStyle(ArtworkPalette.tx2).lineLimit(isDynamic && listLead(entity.id) != nil ? 2 : 1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("map-list-" + entity.id)
                                Menu {
                                    ForEach(actions(entity), id: \.self) { action in
                                        Button(menuTitle(action, entity)) { perform(action, on: entity) }.disabled(!available(action, entity))
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 52).foregroundStyle(ArtworkPalette.tx2)
                                }.accessibilityLabel("更多").accessibilityIdentifier("map-menu-" + entity.id)
                            }.frame(minHeight: 66).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 4))
                                .task(id: entity.id) { loadPhoto(entity.id) }
                                .listRowBackground(Color.clear).listRowSeparatorTint(ArtworkPalette.line)
                        }
                    }
                } header: {
                    Text(group.title).font(.system(size: 20, weight: .bold)).textCase(nil).foregroundStyle(ArtworkPalette.tx)
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(ShopStyle.enabled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(palette.bg.color))
            .contentMargins(.top, 112, for: .scrollContent).contentMargins(.bottom, 40, for: .scrollContent)
            .accessibilityIdentifier("relation-list")
    }
    private func actions(_ entity: SeedGraph.Entity) -> [String] {
        EntityActions.labels(entity, library: library).filter { !isDynamic || $0 != "看全部作品" }
    }
    private func completed(_ action: String, _ entity: SeedGraph.Entity) -> Bool {
        if action == "下一首播放" { return queuedIDs.contains(entity.id) }
        return WorkVerb.isSave(action) && SeedLibraryBridge.saved(entity, in: library)
    }
    private func available(_ action: String, _ entity: SeedGraph.Entity) -> Bool {
        switch action {
        case _ where action == library.playbackPlatform.listenTitle: return !library.playbackBusy
        case "下一首播放": return library.playbackPlatform == .apple && !library.playbackBusy
        case _ where WorkVerb.isSave(action): return entity.kind != .person && entity.kind != .group
        case "看全部作品": return true
        default: return destination(action, entity) != nil
        }
    }
    private func destination(_ action: String, _ entity: SeedGraph.Entity) -> URL? {
        EntityActions.destination(action, entity, library: library)
    }
    private func perform(_ action: String, on entity: SeedGraph.Entity) {
        switch action {
        case _ where action == library.playbackPlatform.listenTitle:
            library.listen(SeedLibraryBridge.workID(entity.id))
        case "下一首播放": onNext(entity)
        case _ where WorkVerb.isSave(action):
            // A second tap takes it back out; the button shows the change.
            if completed(action, entity) { SeedLibraryBridge.unsave(entity, in: library) } else { onSave(entity) }
        case "看全部作品": listRoot = entity.id; listMode = true
        default: if let url = destination(action, entity) { openURL(url) }
        }
    }
    private func menuTitle(_ action: String, _ entity: SeedGraph.Entity) -> String {
        WorkVerb.isSave(action) && completed(action, entity) ? WorkVerb.saved(action) : action
    }
}

/// Nodes and edges. Equatable on its data only, so a camera move (which lives
/// outside this view) re-renders nothing here; the scale/offset transform is
/// applied to the already-rendered layer.
struct RelationMapContent: View, Equatable {
    let map: RelationMapModel
    let root: String
    let isDynamic: Bool
    let positions: [String: CGPoint]
    let born: Set<String>
    let drawn: Set<String>
    let hiddenMeetEdges: Set<String>
    let pings: [String: Int]
    let palette: ArtworkPalette
    let reduceMotion: Bool
    var onTap: (String) -> Void
    var onMounted: (String) async -> Void
    @Environment(Library.self) private var library

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.map == b.map && a.root == b.root && a.isDynamic == b.isDynamic && a.positions == b.positions
            && a.born == b.born && a.drawn == b.drawn && a.hiddenMeetEdges == b.hiddenMeetEdges
            && a.pings == b.pings && a.reduceMotion == b.reduceMotion
    }

    var body: some View {
        let snapshot = isDynamic ? PublicCrateInventory.leadGraph(root: root, expanding: map.order, library: library) : SeedNowContent.connectionGraph
        let captions = isDynamic ? DiscoveryNavigation.mapCaptions(root: root, ids: map.order, catalog: library.catalog) : [:]
        let leads = isDynamic ? DiscoveryNavigation.leads(from: root, catalog: library.catalog, known: [:], provider: nil) : []
        let pathLabels = Dictionary(uniqueKeysWithValues: leads.map { ($0.id, $0.label) })
        let legibleDiscoveries = map.order.count <= 12 ? Set(leads.map(\.id)) : []
        let currentLabels = Dictionary(uniqueKeysWithValues: snapshot.relations.map { ($0.from + "|" + $0.to, $0.label) })
        ZStack(alignment: .topLeading) {
            ForEach(map.edges) { edge in edgeView(edge) }
            ForEach(map.order, id: \.self) { id in
                if let node = map.nodes[id], let entity = RelationMapView.lookup(id, dynamic: isDynamic, library: library) {
                    let point = positions[id] ?? node.position
                    let caption = captions[id]
                    let height = PhysicalObject.baseSize(for: entity.kind).height * (id == root && entity.kind.isMusic ? 104/64 : 1) * (caption?.scale ?? 1)
                    RelationMapObject(entity: entity, root: id == root, focused: id == map.focus,
                        onPath: map.focusPath.contains(id), dimmed: map.focus != root && !map.nearFocus(id) && !map.edges.contains { $0.connects(id, map.focus) }, expanded: node.expanded,
                        pending: pending(id, graph: snapshot), label: pathLabels[id] ?? node.via.flatMap { currentLabels[$0 + "|" + id] } ?? node.label, cameraScale: map.camera.scale,
                        showsRelation: id == map.focus || map.edges.contains { $0.connects(id, map.focus) } || legibleDiscoveries.contains(id),
                        palette: palette, ping: pings[id] ?? 0, collapsible: id == map.focus && map.canCollapse(id),
                        displayTitle: caption?.title, detail: caption?.detail, sizeMultiplier: caption?.scale ?? 1,
                        keepsNameVisible: legibleDiscoveries.contains(id)) { onTap(id) }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: map.focus)
                        .opacity(born.contains(id) ? 0 : 1)
                        .offset(x: point.x-54, y: point.y-height/2)
                        .task { await onMounted(id) }
                }
            }
        }
    }
    private func pending(_ id: String, graph: SeedGraph) -> Int {
        guard !isDynamic || map.plannedRelations?[id] != nil else { return 0 }
        return map.pending(id, graph: graph)
    }
    @ViewBuilder private func edgeView(_ edge: RelationMapModel.Edge) -> some View {
        let from = positions[edge.from] ?? map.nodes[edge.from]!.position
        let to = positions[edge.to] ?? map.nodes[edge.to]!.position
        let curve = MapCurve(from: from, to: to)
        let onPath = map.onPath(edge)
        let touch = edge.from == map.focus || edge.to == map.focus
        curve.trim(from: 0, to: drawn.contains(edge.id) ? 1 : 0)
            .stroke(onPath ? palette.ac.color : Color(red: 233/255, green: 227/255, blue: 214/255).opacity(0.26), lineWidth: onPath ? 1.8 : 1.1)
            .opacity(onPath || touch ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: map.focus)
    }
}

/// The camera scale while the map is pinched; observed only by the labels that size with it.
@MainActor @Observable final class MapZoom {
    var scale: CGFloat? = nil
}

/// Gesture state written every frame of a pan or pinch; deliberately not observed.
final class MapInteraction {
    var pinching = false
    var active = false
    var lastDrag = CGSize.zero
    var lastMagnification: CGFloat = 1
    /// When a finger last moved or pinched the map. A node's tap that lands with a pinch is not a
    /// choice, and once the user has moved the camera, late arrivals no longer re-fit it.
    var touchedAt = Date.distantPast
}

/// The map's camera while a finger is down. Only this view owns the live camera, so a frame of
/// a pan or pinch re-evaluates nothing but this transform; the nodes are an equatable layer that
/// is not redrawn, and the page (card, breadcrumbs, toolbar) is not touched until the commit.
struct MapCameraCanvas<Content: View>: View {
    let camera: MapCamera
    let size: CGSize
    let interaction: MapInteraction
    let zoom: MapZoom
    let onBegin: () -> Void
    let onCommit: (MapCamera) -> Void
    @ViewBuilder let content: () -> Content
    @State private var live: MapCamera?

    var body: some View {
        let c = live ?? camera
        content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(c.scale, anchor: .topLeading).offset(x: c.x, y: c.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(.rect)
            // Simultaneous, so a finger that lands on a sleeve still pans or
            // pinches the map; a moving finger cancels that sleeve's tap.
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    begin()
                    guard !interaction.pinching else { interaction.lastDrag = value.translation; return }
                    let delta = CGSize(width: value.translation.width - interaction.lastDrag.width,
                                       height: value.translation.height - interaction.lastDrag.height)
                    interaction.lastDrag = value.translation
                    var next = live ?? camera
                    next.x += delta.width; next.y += delta.height
                    set(next)
                }
                .onEnded { _ in
                    interaction.touchedAt = Date(); interaction.lastDrag = .zero
                    if !interaction.pinching { commit() }
                })
            .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.005)
                .onChanged { value in
                    begin(); interaction.pinching = true
                    let factor = value.magnification / interaction.lastMagnification
                    interaction.lastMagnification = value.magnification
                    var next = live ?? camera
                    next.zoom(by: factor, at: value.startLocation)
                    set(next)
                }
                .onEnded { _ in
                    interaction.lastMagnification = 1; interaction.pinching = false; interaction.touchedAt = Date()
                    commit()
                })
            .onChange(of: camera) { _, _ in if !interaction.active { live = nil } }
    }
    private func begin() {
        interaction.touchedAt = Date()
        if !interaction.active { interaction.active = true; onBegin() }
    }
    private func set(_ next: MapCamera) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            live = next
            if zoom.scale != next.scale { zoom.scale = next.scale }
        }
    }
    /// Both recognisers can be live at once; commit only when the last one ends.
    private func commit() {
        interaction.active = false
        guard let next = live else { return }
        var t = Transaction(); t.disablesAnimations = true
        // The committed scale now drives the labels' font size; clear the live one in the same
        // transaction so their on-screen size is unchanged at the moment the finger lifts.
        withTransaction(t) { onCommit(next); live = nil; zoom.scale = nil }
    }
}
