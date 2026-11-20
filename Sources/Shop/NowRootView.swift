import SwiftUI
import UIKit

/// Native Liquid Glass tabs and accessory; live playback is independent of reading.
struct NowRootView: View {
    private enum Selection: Hashable {
        case now, collection, search
        var key: String { switch self { case .now: "now"; case .collection: "collection"; case .search: "search" } }
    }
    private enum Destination: Hashable {
        case graph(root: String, focus: String, list: Bool), entity(String, root: String, source: String?)
        /// Built by hand: String(describing:) reflects on the enum and walked the Swift
        /// runtime's metadata on every root body (seen in the 11-17 crate-open profile).
        var key: String {
            switch self {
            case .graph(let root, let focus, let list): "g:" + root + ">" + focus + (list ? ":l" : "")
            case .entity(let id, let root, let source): "e:" + id + ">" + root + ":" + (source ?? "")
            }
        }
    }
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = NowSession()
    @State private var stories = OnDemandStories()
    @State private var research = LeadResearch.shared
    @State private var readers = PullOutReaders()
    @State private var storySettings = StoryModelSettings.shared
    private struct StoryLookup: Identifiable {
        let name: String
        let source: Source
        let root: String
        var id: String { name }
    }
    @State private var storyLookup: StoryLookup?
    @State private var lookupDestination: Destination?
    private var visibleStoryID: String? {
        let active = selection == .search ? searchPath : selection == .collection ? collectionPath : path
        if case .entity(let id, _, _) = active.last { return id }
        return selection == .now && active.isEmpty ? session.entityID : nil
    }
    private var storyRequest: String {
        pageRequest(visibleStoryID ?? "")
    }
    private var browseContext: LeadResearch.BrowseContext? {
        let active = selection == .search ? searchPath : selection == .collection ? collectionPath : path
        guard case .entity(let id, let root, _) = active.last, id != root else { return nil }
        let parent: String
        switch active.dropLast().last {
        case .entity(let previous, _, _): parent = previous
        case .graph(_, let focus, _): parent = focus
        default: parent = root
        }
        return .init(rootID: root, parentID: parent)
    }
    private func subject(_ id: String) -> LeadSubject? { research.subject(id, library: library) }
    private func refresh(_ id: String) {
        guard let subject = subject(id) else { return }
        Task { await research.load(subject, library: library, force: true) }
    }

    @Namespace private var objectTransition
    @State private var crateLifted = false
    @State private var cratePageTransition = CratePageTransition()
    @State private var selection = Selection.now
    @State private var path: [Destination] = []
    @State private var searchPath: [Destination] = []
    @State private var searchFocusRequest = 0
    @State private var collectionPath: [Destination] = []
    @State private var toast: String?
    // QQ 音乐 / 网易云 (DOMESTIC-STORY-ART/DESIGN.md): clipboard offer and first-run platform question.
    @State private var clipboardOffer = false
    @State private var dismissedClipboardChange = -1
    @State private var askPlatform = false
    @AppStorage("domestic.platformAsked") private var platformAsked = false
    @State private var queueRequest: String?
    @State private var objectFrames: [String: CGRect] = [:]
    @State private var collectionArrival: CollectionArrival?
    @State private var playbackFrame = CGRect.zero
    @State private var motionReceipt = ""
    @State private var savedToast: String?
    @State private var settledStoryRequest = ""
    @State private var appearances = ShopPageAppearanceGeneration()
    @State private var pageActions = ShopPageActionsCache()
    @State private var selections = ShopSelectionCache()
    private var listeningContext: String {
        ([selection.key] + path.map(\.key) + ["/"] + searchPath.map(\.key) + ["/"] + collectionPath.map(\.key) + [session.entityID])
            .joined(separator: "|")
    }
    private var palette: ArtworkPalette { .asset(session.entity.artworkAsset) }
    private var playbackEntity: SeedGraph.Entity? { SeedLibraryBridge.playbackEntity(in: library) }
    private var offeredPlaybackEntity: SeedGraph.Entity? {
        guard selection == .now, let pending = session.pendingEntity else { return nil }
        if let id = visibleStoryID, readers.reader(for: id).isReading { return nil }
        let visibleID: String?
        switch path.last {
        case .entity(let id, _, _): visibleID = id
        case .graph: visibleID = nil
        case nil: visibleID = session.entityID
        }
        if let visibleID,
           library.catalog.canonicalID(for: SeedLibraryBridge.workID(visibleID)) ==
            library.catalog.canonicalID(for: SeedLibraryBridge.workID(pending.id)) { return nil }
        return pending
    }
    private var isPlaying: Bool {
        if NowSession.usesPreviewPlayback && !library.canControlPlayback { return session.previewPlaying }
        return library.isPlaying && playbackEntity?.id == session.entityID
    }
    private var allEntities: [SeedGraph.Entity] {
        var seen = Set<String>()
        return (SeedGraph.bundled.entities + SeedNowContent.extras + library.catalog.works.keys.map {
            SeedLibraryBridge.entity(for: $0, in: library)
        }).filter { seen.insert($0.id).inserted }
    }
    private func resolvedEntity(_ id: String) -> SeedGraph.Entity? {
        if SeedNowContent.contains(id), let seed = SeedNowContent.entity(id) { return seed }
        let workID = SeedLibraryBridge.workID(id)
        guard library.catalog.works[library.catalog.canonicalID(for: workID)] != nil else { return nil }
        return SeedLibraryBridge.entity(for: workID, in: library)
    }
    private var savedIDs: Set<String> { selections.value(in: library).saved }
    private var tabSelection: Binding<Selection> {
        Binding(get: { selection }, set: { next in
            if next == selection, next == .search {
                if searchPath.isEmpty { searchFocusRequest += 1 } else { searchPath.removeAll() }
            }
            selection = next
        })
    }
    private var queuedIDs: Set<String> { selections.value(in: library).queued }

    private var tabContent: some View {
        // Apple Music's search tab: the first tap shows the page (with recent searches); tapping
        // it again while there puts the cursor in the field, or pops back to the page first.
        TabView(selection: tabSelection) {
            Tab("此刻", systemImage: "opticaldisc", value: .now) {
                NavigationStack(path: $path) {
                    nowPage

                        .navigationDestination(for: Destination.self) { destinationView($0) }
                }
            }
            Tab("收藏", systemImage: "books.vertical", value: .collection) {
                NavigationStack(path: $collectionPath) {
                    Group {
                        if ShopStyle.enabled {
                            ShopCollectionView(onOpen: { id in
                                                   let entity = SeedLibraryBridge.entity(for: id, in: library)
                                                   library.visit(id)
                                                   collectionPath.append(.entity(entity.id, root: entity.id, source: nil))
                                               },
                                               onTrail: { collectionPath.append(.graph(root: $0, focus: $0, list: false)) },
                                               onNext: { library.queueCollectedRecordNext($0) })
                        } else {
                            CollectionWall(onTrail: { collectionPath.append(.graph(root: $0, focus: $0, list: false)) }, onNext: { library.queueCollectedRecordNext($0) }, dockHeight: 0)
                        }
                    }

                        .navigationDestination(for: Destination.self) { destinationView($0) }
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: $searchPath) {
                    Group {
                        if ShopStyle.enabled {
                            // 0.5.9: one field across every kind (search/SEARCH-DESIGN.md).
                            ShopSearchView(focusRequest: searchFocusRequest) { id in
                                // A QQ/网易云 user's chosen song goes onto the counter (此刻).
                                if bringsToCounter(id) { bringIn(id); return }
                                let entity = SeedLibraryBridge.entity(for: id, in: library)
                                library.visit(id)
                                push(.entity(entity.id, root: entity.id, source: nil))
                            }
                        } else {
                            SearchView(embedded: true) { id in
                                let entity = SeedLibraryBridge.entity(for: id, in: library)
                                library.visit(id)
                                push(.entity(entity.id, root: entity.id, source: nil))
                            }
                        }
                    }
                    .navigationDestination(for: Destination.self) { destinationView($0) }
                }
            }
        }

        // Keep the same native dock occupancy across navigation. The map's
        // selected-work summary is canvas content, not a third glass panel.
        .tabViewBottomAccessory {
            NowPlaybackAccessory(previewEntity: NowSession.usesPreviewPlayback ? session.entity : nil,
                                 previewPlaying: session.previewPlaying, motionReceipt: motionReceipt, onPreviewToggle: { session.previewPlaying.toggle() },
                                 onOpen: returnToPlaying, onSearch: openSearchField,
                                 domesticRecord: library.playbackPlatform != .apple && session.holdsRecord ? session.entity : nil,
                                 onListen: listenToCounter)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { playbackFrame = $0 }
                .opacity(crateLifted ? 0.4 : 1).allowsHitTesting(!crateLifted)
        }
        .environment(\.playbackTop, playbackFrame.isEmpty ? .infinity : playbackFrame.minY)
        .environment(cratePageTransition)
        .modifier(ListeningDestinationPresenter())
        .onChange(of: listeningContext) { _, _ in library.listening.cancel() }
        .environment(stories)
        .environment(storySettings)
        .environment(research)
        .environment(readers)
        .task(id: storyRequest + "|" + String(settledStoryRequest == storyRequest)) {
            stories.setCurrentRoot(visibleStoryID ?? "")
            guard let id = visibleStoryID, let entity = resolvedEntity(id) else { return }
            guard settledStoryRequest == storyRequest, !Task.isCancelled else { return }
            if SeedNowContent.contains(id) && RecordShopArtReview.current == nil {
                // Bundled demo content keeps its reviewed stories; nothing is fetched.
                stories.load(id, reviewedStories: NowStoryContent.stories(for: entity, catalog: library.catalog), collectMaterials: false)
                return
            }
            // 0.3: one web-search call returns this page's leads and story.
            // The on-device collection pipeline is no longer started from here.
            guard let subject = subject(id) else { return }
            await research.load(subject, library: library, context: browseContext)
        }
        .sheet(item: $storyLookup, onDismiss: {
            if let target = lookupDestination { lookupDestination = nil; push(target) }
        }) { lookup in
            NameLookupSheet(name: lookup.name) { id in
                let entity = SeedLibraryBridge.entity(for: id, in: library)
                lookupDestination = .entity(entity.id, root: lookup.root, source: nil)
                library.visit(id); storyLookup = nil
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationBackground { ShopPageBackdrop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                checkClipboard()
                // The clipboard of another app can arrive a moment after this app comes forward.
                Task { try? await Task.sleep(for: .milliseconds(700)); checkClipboard() }
            }
            if phase != .active {
                cratePageTransition.finish()
                let lease = ShopPersistenceBackgroundLease()
                Task {
                    await library.catalog.flushPendingWrites()
                    await library.flushPendingWrites()
                    lease.finish()
                }
            }
            else { Task { await research.resumeSavedAnswers(library: library); await AccountStorefront.sync(library) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            library.catalog.flushPendingWritesBeforeTermination()
            library.flushPendingWritesBeforeTermination()
        }
        .modifier(DeepDiveReceiptHook(toast: $toast, research: research))
        .modifier(DomesticHooks(askPlatform: $askPlatform, platformAsked: $platformAsked, toast: $toast,
                                previewing: NowSession.usesPreviewPlayback, checkClipboard: checkClipboard))
        .tabBarMinimizeBehavior(.never)
        .tint(RecordStoreConcept.current?.accent ?? RecordShopArtReview.current?.accent ?? palette.ac.color)
        .preferredColorScheme(RecordStoreConcept.current?.colorScheme ?? .dark)
    }
    var body: some View {
        let _ = EvalPerformance.event("NowRootView.body")
        @Bindable var library = library
        tabContent
        .overlay {
            if let arrival = collectionArrival {
                CollectionArrivalView(arrival: arrival) {
                    if collectionArrival?.id == arrival.id { collectionArrival = nil; toast = savedToast; savedToast = nil }
                }.id(arrival.id)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                // At any depth in 此刻: the new song offers itself here.
                if !crateLifted, let entity = offeredPlaybackEntity {
                    SwitchPrompt(entity: entity, reduceMotion: reduceMotion, onAccept: returnToPlaying,
                                 onDismiss: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { session.dismissPending() } })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                // Back from QQ 音乐 / 网易云 with a copied link, on any tab.
                if clipboardOffer, library.playbackPlatform != .apple {
                    ClipboardPrompt(platform: library.playbackPlatform, onPaste: bringFromShare,
                                    onDismiss: { clipboardOffer = false; dismissedClipboardChange = UIPasteboard.general.changeCount })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12).padding(.top, 58)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: offeredPlaybackEntity?.id)
            .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: clipboardOffer)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 13.5)).padding(.horizontal, 18).padding(.vertical, 11)
                    .glassEffect(in: .capsule).padding(.horizontal, 22).padding(.bottom, 150)
                    .transition(.opacity).allowsHitTesting(false).accessibilityIdentifier("now-feedback")
            }
        }
        .sheet(item: $library.sourceSheet) { id in NavigationStack { SourcesView(id: id) } }
        .task { DesignFonts.shared.prepare(); ShopPlates.shared.prewarm() }
        .task { await AccountStorefront.sync(library) }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"), ProcessInfo.processInfo.arguments.contains("--ui-discovery-replay"),
               let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-entry=") }),
               let id = WorkID(rawValue: String(argument.dropFirst("--ui-entry=".count))), library.catalog.works[id] != nil {
                for _ in 0..<100 where playbackEntity == nil { try? await Task.sleep(for: .milliseconds(20)) }
                if let playbackEntity { session.receiveLiveTrack(playbackEntity) }
                path = [.entity(id.rawValue, root: session.entityID, source: nil)]
            }
            if CollectionWallFixture.requested {
                CollectionWallFixture.install(in: library)
                selection = .collection
            }
            if let spec = CollectionReviewFixture.spec {
                CollectionReviewFixture.install(spec, in: library)
                selection = .collection
            }
            #endif
        }
        .task(id: toast) {
            guard toast != nil else { return }
            do { try await Task.sleep(for: .seconds(2.5)); withAnimation { toast = nil } } catch {}
        }
        .onChange(of: selection) { _, value in
            if value == .collection { library.tab = .collection }
            else if value == .now { library.tab = .now }
        }
        .onChange(of: playbackEntity, initial: true) { _, _ in
            ArtworkTint.shared.prewarm(playbackEntity?.artworkAsset)
            if !NowSession.usesPreviewPlayback {
                session.receiveLiveTrack(playbackEntity, preserveReading: !path.isEmpty)
            }
        }
        .onChange(of: library.next) { _, next in
            if let queueRequest, let entity = resolvedEntity(queueRequest),
               next == library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)) {
                toast = "放完《\(session.entity.title)》就播《\(entity.title)》"
                self.queueRequest = nil
            }
        }
        .onChange(of: library.playbackError) { _, message in if let message { toast = message } }
        .onChange(of: library.playbackOperations.first?.id) { _, _ in
            // Two different actions can fail with identical text in one run
            // loop. Observe the receipt too, so the second failure still appears.
            if let message = library.playbackError { toast = message }
        }
    }

    @ViewBuilder private func destinationView(_ target: Destination) -> some View {
        switch target {
        case .graph(let root, let focus, let list):
            RelationMapView(root: root, initialFocus: focus, initiallyListing: list, queuedIDs: queuedIDs, savedIDs: savedIDs,
                            onEntity: { openFromMap($0, root: root) }, onNext: enqueue, onSave: save)
        case .entity(let id, let root, _):
            // 0.5.8: every work page uses the standard push, so the only way back is the native
            // right swipe (or the back button). The zoom transition added a pull-down dismissal
            // that fought the story's own pull gestures, and its interactive return stuttered.
            if let entity = resolvedEntity(id) {
                entityPage(entity, root: root).onAppear { session.remember(id) }
            }
        }
    }
    /// Back to the top of 此刻, showing the song that is playing now.
    private func returnToPlaying() {
        let measurement = EvalPerformance.begin("SongSwitch")
        defer { measurement?.end() }
        EvalFrameWindow.observe("SongSwitch")
        readers.closeThen {
            selection = .now
            path.removeAll()
            if session.pendingEntity != nil { session.acceptPending() }
            else if let playing = playbackEntity, !NowSession.usesPreviewPlayback { session.showLive(playing) }
        }
    }
    /// The window-level sleeve remains visible across this navigation change;
    /// the destination supplies its actual hero frame before the flight lands.
    private func openFromCrate(_ item: CrateItem, root: String, source: String) {
        library.crateExploration.record(item, from: visibleStoryID ?? root)
        if source == "crate" {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { push(.entity(item.id, root: root, source: nil)) }
        } else { push(.entity(item.id, root: root, source: source.isEmpty ? nil : source)) }
    }
    /// A tapped story name goes straight where it leads (anson 2026-11-18): a name whose
    /// identity is known opens its page; any other name is looked up in the catalogues.
    private func openStoryName(_ target: StoryTextLinks.Target, from origin: String, root: String, source pinnedSource: Source? = nil) {
        openStoryNameNow(target, from: origin, root: root, source: pinnedSource)
    }
    private func openStoryNameNow(_ target: StoryTextLinks.Target, from origin: String, root: String, source pinnedSource: Source? = nil) {
        if let id = target.entityID, let entity = resolvedEntity(id) {
            let destination = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
            guard destination != library.catalog.canonicalID(for: SeedLibraryBridge.workID(origin)) else { return }
            do {
                _ = try SeedLibraryBridge.install(entity, into: library)
                library.visit(destination)
                push(.entity(entity.id, root: root, source: nil))
            } catch { toast = library.catalog.storageError }
        } else {
            let source = pinnedSource ?? (research.story(for: origin) ?? stories.story(for: origin))?.source ?? Source(title: "", url: "")
            storyLookup = StoryLookup(name: target.name, source: source, root: root)
        }
    }
    /// 最近探索 is written once the push has settled, never during a transition (the write
    /// persists the library to disk on the main thread).
    private func noteRecentLater(_ id: String) {
        let work = SeedLibraryBridge.workID(id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            library.noteRecent(work)
        }
    }
    /// 打开 on the map: the work whose page lies right under the map is reached by going back
    /// to it, not by stacking a second copy of that page (MAP-COLLECTION-DESIGN §4.1).
    private func openFromMap(_ id: String, root: String) {
        let target = library.catalog.canonicalID(for: SeedLibraryBridge.workID(id))
        func same(_ other: String) -> Bool { library.catalog.canonicalID(for: SeedLibraryBridge.workID(other)) == target }
        let active = selection == .search ? searchPath : selection == .collection ? collectionPath : path
        if case .graph? = active.last {
            let below = active.dropLast().last
            let underneath: Bool
            switch below {
            case .entity(let under, _, _): underneath = same(under)
            case nil: underneath = selection == .now && same(session.entityID)
            default: underneath = false
            }
            if underneath {
                if selection == .search { searchPath.removeLast() }
                else if selection == .collection { collectionPath.removeLast() }
                else { path.removeLast() }
                return
            }
        }
        push(.entity(id, root: root, source: nil))
    }
    private func push(_ target: Destination) {
        let measurement = EvalPerformance.begin("PagePush")
        defer { measurement?.end() }
        EvalFrameWindow.observe("PagePush")
        if case .entity(let id, _, _) = target { noteRecentLater(id) }
        // Install reviewed text before the destination lays out. The crate's
        // sleeve flight must land on the final (compact) hero frame.
        if case .entity(let id, _, _) = target, let entity = resolvedEntity(id) {
            stories.load(id, reviewedStories: NowStoryContent.stories(for: entity, catalog: library.catalog), collectMaterials: false)
        }
        if selection == .search { searchPath.append(target) }
        else if selection == .collection { collectionPath.append(target) }
        else { path.append(target) }
    }

    private func pageRequest(_ id: String) -> String {
        let resolved = library.catalog.work(SeedLibraryBridge.workID(id)).catalogTrack != nil
        return id + ":" + String(storySettings.revision) + ":" + String(resolved)
            + ":" + String(appearances.value(for: listeningContext))
    }
    private func pageSettled(_ request: String) {
        guard request == storyRequest, settledStoryRequest != request else { return }
        settledStoryRequest = request
    }
    private func actions(for entity: SeedGraph.Entity, root: String, current: Bool) -> ShopPageActionsCache.Actions {
        pageActions.value(for: entity.id + "|" + root + "|" + String(current)) {
            .init(onStoryName: { openStoryName($0, from: entity.id, root: root) },
                  onReadingName: { openStoryName($0, from: entity.id, root: root, source: $1) },
                  onGraph: { openGraph($0, root: current ? nil : root) },
                  onOpen: { item, source in openFromCrate(item, root: root, source: source) },
                  onPlayback: togglePlayback, onNext: enqueue, onSave: save,
                  onWorks: { openGraph(entity.id, root: current ? nil : root, list: true) },
                  onObjectFrame: { objectFrames[$0] = $1 }, onRetry: { refresh(entity.id) },
                  onCreator: { openCreator(of: entity.id, root: root) })
        }
    }
    private func page(_ entity: SeedGraph.Entity, root: String, current: Bool) -> some View {
        let action = actions(for: entity, root: root, current: current)
        return ShopNowPage(entity: entity, transitionNamespace: objectTransition, navigationRoot: root,
                    isCurrent: current, isPlaying: current && isPlaying, idle: current && session.state == .idle,
                    onStoryName: action.onStoryName, onReadingName: action.onReadingName,
                    onGraph: action.onGraph, onOpen: action.onOpen, onPlayback: action.onPlayback,
                    onNext: action.onNext, onSave: action.onSave, onWorks: action.onWorks,
                    onObjectFrame: action.onObjectFrame, onRetry: action.onRetry, onCreator: action.onCreator)
            .equatable()
            .background(PageTransitionCompletion(token: pageRequest(entity.id), onSettled: pageSettled))
    }
    /// A QQ 音乐 / 网易云 user with no song yet sees the empty ledge (DomesticCounterView); so does an
    /// Apple Music user who has never played anything (ONBOARDING, 2026-11-18).
    @ViewBuilder private var nowPage: some View {
        let appleWaiting = library.playbackPlatform == .apple && playbackEntity == nil && path.isEmpty
            && SeedNowContent.contains(session.entityID) && RecordShopArtReview.current == nil
        if (library.playbackPlatform != .apple && !session.holdsRecord || appleWaiting) && !NowSession.usesPreviewPlayback {
            DomesticCounterView(platform: library.playbackPlatform, onPaste: bringFromShare, onSearch: openSearchField)
        } else {
            nowRecordPage
        }
    }
    private var nowRecordPage: some View {
        page(session.entity, root: session.entityID, current: true)
            .task { session.remember(session.entityID); await session.prepare() }
    }
    private func entityPage(_ entity: SeedGraph.Entity, root: String) -> some View {
        page(entity, root: root, current: false)
            .task(id: entity.id) {
                if SeedNowContent.contains(entity.id) {
                    await library.catalog.preparePublicSelection(SeedLibraryBridge.workID(entity.id))
                }
            }
    }
    /// The artist line under a title opens that artist's own page.
    private func openCreator(of id: String, root: String) {
        guard !SeedNowContent.contains(id) else { return }
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(id)))
        Task {
            guard let creator = await library.catalog.mainArtist(for: work.id, country: library.country) else { return }
            let entity = SeedLibraryBridge.entity(for: creator, in: library)
            library.visit(creator)
            push(.entity(entity.id, root: root, source: nil))
        }
    }
    private func openGraph(_ id: String, root: String? = nil, list: Bool = false) {
        guard let entity = resolvedEntity(id) else { return }
        do {
            _ = try SeedLibraryBridge.install(entity, into: library)
            session.remember(id)
            let origin = root ?? session.entityID
            let graphRoot = SeedNowContent.contains(id) && SeedNowContent.contains(origin) ? origin : id
            push(.graph(root: graphRoot, focus: id, list: list))
        } catch { toast = library.catalog.storageError }
    }
    private func togglePlayback() {
        // The counter's record cannot be played here; it opens in QQ 音乐 / 网易云.
        if library.playbackPlatform != .apple && !library.canControlPlayback && !NowSession.usesPreviewPlayback { listenToCounter(); return }
        if library.canControlPlayback { library.togglePlayback() }
        else if NowSession.usesPreviewPlayback { session.previewPlaying.toggle() }
        else { Task { await library.connectMusic() } }
    }
    private func bringsToCounter(_ id: WorkID) -> Bool {
        library.playbackPlatform != .apple && library.catalog.work(library.catalog.canonicalID(for: id)).isSong
    }
    private func bringIn(_ id: WorkID) {
        let entity = SeedLibraryBridge.entity(for: id, in: library)
        library.visit(id)
        session.bring(entity)
        path.removeAll()
        selection = .now
    }
    private func bringFromShare(_ text: String) {
        clipboardOffer = false; dismissedClipboardChange = UIPasteboard.general.changeCount
        Task {
            do { bringIn(try await library.importMusicShare(text)) }
            catch { toast = (error as? CatalogError) == .invalidLink ? "认不出这个链接里的歌" : (error as? LocalizedError)?.errorDescription ?? "没能打开这个链接" }
        }
    }
    private func listenToCounter() {
        guard session.holdsRecord else { openSearchField(); return }
        library.listen(library.catalog.canonicalID(for: SeedLibraryBridge.workID(session.entityID)))
    }
    private func openSearchField() {
        selection = .search
        if searchPath.isEmpty { searchFocusRequest += 1 } else { searchPath.removeAll(); searchFocusRequest += 1 }
    }
    /// Only asks whether the clipboard holds a web link (no paste prompt). The
    /// paste itself happens through PasteButton, and a dismissed link stays quiet.
    private func checkClipboard() {
        guard library.playbackPlatform != .apple, !NowSession.usesPreviewPlayback else { clipboardOffer = false; return }
        let board = UIPasteboard.general, change = board.changeCount
        guard change != dismissedClipboardChange, board.hasStrings || board.hasURLs else { clipboardOffer = false; return }
        // A link copied as a URL object (not as text) carries no text pattern to detect: its
        // presence is enough (anson 11-18 15:03: nothing was offered after copying in 网易云).
        if board.hasURLs { clipboardOffer = true; return }
        Task { @MainActor in
            let found = (try? await board.detectedPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL, \UIPasteboard.DetectedValues.links])) ?? []
            clipboardOffer = !found.isEmpty && change == board.changeCount && change != dismissedClipboardChange
        }
    }
    private func enqueue(_ entity: SeedGraph.Entity) {
        do {
            let id = try SeedLibraryBridge.install(entity, into: library)
            queueRequest = entity.id
            library.queueNext(id)
        } catch { toast = library.catalog.storageError }
    }
    private func save(_ entity: SeedGraph.Entity) {
        do {
            let alreadySaved = SeedLibraryBridge.saved(entity, in: library)
            try SeedLibraryBridge.save(entity, into: library)
            let active = selection == .search ? searchPath : selection == .collection ? collectionPath : path
            let origin: String?
            switch active.last {
            case .entity(let id, _, _):
                if id != entity.id { origin = id }
                else {
                    switch active.dropLast().last {
                    case .entity(let parent, _, _): origin = parent
                    case .graph(let root, _, _): origin = RelationTrailStore().load(root: root)?.nodes[id]?.via
                    case nil: origin = selection == .now && session.entityID != id ? session.entityID : nil
                    }
                }
            case .graph(let root, _, _): origin = RelationTrailStore().load(root: root)?.nodes[entity.id]?.via
            case nil: origin = session.entityID == entity.id ? nil : session.entityID
            }
            if let origin { library.recordCollectionOrigin(SeedLibraryBridge.workID(entity.id), from: origin) }
            if let error = library.persistenceError { toast = error; return }
            if entity.kind.isMusic && !alreadySaved {
                let target = CollectionTabTarget.resolve()
                collectionArrival = CollectionArrival(entity: entity, origin: objectFrames[entity.id] ?? .zero, target: target)
                #if DEBUG
                let frame = target?.iconFrame ?? .zero
                motionReceipt = String(data: try! JSONSerialization.data(withJSONObject: ["target": [frame.minX,frame.minY,frame.width,frame.height], "reduceMotion": reduceMotion]), encoding: .utf8)!
                #endif
                savedToast = "已收藏《\(SongTitlePresentation(entity.title).title)》"
                toast = nil
            } else {
                toast = entity.kind.isMusic ? "已收藏《\(SongTitlePresentation(entity.title).title)》" : "《\(entity.title)》已放进\(WorkVerb.save(entity.kind) ?? "想看")"
            }
        } catch { toast = library.catalog.storageError }
    }
}

/// The song that just started playing, as a small spinning record. Tap to go
/// to it (from any depth), swipe up to leave it.
private struct SwitchPrompt: View {
    let entity: SeedGraph.Entity
    let reduceMotion: Bool
    var onAccept: () -> Void
    var onDismiss: () -> Void
    @State private var spin = false
    var body: some View {
        Button(action: onAccept) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(white: 0.06))
                    Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6).padding(4)
                    Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6).padding(8)
                    PhysicalObject(entity: entity, showsDisc: false, size: CGSize(width: 22, height: 22))
                        .frame(width: 22, height: 22).clipShape(.circle)
                    Circle().fill(Color(white: 0.85)).frame(width: 3.5, height: 3.5)
                }
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 3.6).repeatForever(autoreverses: false), value: spin)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ArtworkPalette.tx)
                    Text(entity.subtitle).font(.system(size: 12)).foregroundStyle(ArtworkPalette.tx2)
                }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 34, height: 34).background(ArtworkPalette.tx, in: .circle)
            }
            .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 7)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height < -24 { onDismiss() } })
        .onAppear { spin = true }
        .accessibilityLabel("正在播放《\(entity.title)》")
        .accessibilityHint("回到这首")
        .accessibilityIdentifier("accept-track-switch")
    }
}
