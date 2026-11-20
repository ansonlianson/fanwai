import SwiftUI
import UIKit

struct SearchView: View {
    var embedded = false
    var onOpen: ((WorkID) -> Void)? = nil
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var searchTask: Task<Void, Never>?
    @State private var knowledgePresented = false
    @State private var knowledgeTarget: WorkID?
    @State private var prepared = false
    @State private var drawerVisible = false
    @State private var drawerTask: Task<Void, Never>?
    @State private var resultRevision = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var listIdentity = UUID()
    @State private var listPosition = SearchListPositionController()

    private var session: SearchSessionState { library.searchSession }
    private var key: SearchSessionKey {
        SearchSessionKey(query: library.searchQuery, kind: library.searchKind,
                         country: library.country, recordingContext: library.recordingSearchContext, platform: library.playbackPlatform)
    }
    private var local: [WorkID] {
        library.catalog.localMatches(library.searchQuery).filter {
            !session.snapshot.results.contains($0) && library.searchKind.includes(workKind: $0.work.kind)
        }
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .onDisappear {
            rememberPosition()
            listPosition.suspend()
            searchTask?.cancel(); drawerTask?.cancel(); drawerVisible=false
            session.cancelRequest()
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var library = library
        ScrollViewReader { proxy in
            List {
                if key.query.isEmpty {
                    if !library.recent.isEmpty {
                        Section("最近探索") { ForEach(Array(library.recent.prefix(5))) { row($0) } }
                    }
                    if !ShopStyle.enabled { Section("从这里开始") { ForEach(library.catalog.entryPoints) { row($0) } } }
                } else {
                    if drawerVisible {
                        SearchCardCatalogue().frame(height:210)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .transition(.opacity.combined(with:.move(edge:.bottom)))
                    }
                    if !session.snapshot.results.isEmpty {
                        Section(library.searchKind.usesKnowledgeSearch ? "作品" : "作品目录") {
                            ForEach(session.snapshot.results) { row($0) }
                        }
                    }
                    if !local.isEmpty { Section("已有资料") { ForEach(local) { row($0) } } }
                    if !session.searching, let error = session.snapshot.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试") { search(proxy) }
                        }
                    } else if !session.searching && session.snapshot.submitted && local.isEmpty && session.snapshot.results.isEmpty {
                        ContentUnavailableView.search(text: library.searchQuery)
                    } else if !session.searching && !session.snapshot.submitted {
                        Button("搜索作品", systemImage: "magnifyingglass") { search(proxy) }
                    }
                }
            }
            .id(listIdentity)
            .accessibilityIdentifier("search-results")
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background { if ShopStyle.enabled { ShopPageBackdrop() } else { library.visualDirection.background } }
            .foregroundStyle(ShopStyle.enabled ? ShopStyle.ink : Color.primary)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if typeSize.isAccessibilitySize {
                    Picker("作品类型", selection: $library.searchKind) {
                        ForEach(CatalogSearchKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).controlSize(.large)
                    .accessibilityIdentifier("search-type")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .background(ShopStyle.enabled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(library.visualDirection.background))
                } else {
                    Picker("作品类型", selection: $library.searchKind) {
                        ForEach(CatalogSearchKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("search-type")
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(ShopStyle.enabled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(library.visualDirection.background))
                }
            }
            .searchable(text: $library.searchQuery, prompt: "作品、创作者或 Apple Music 链接")
            .onSubmit(of: .search) { search(proxy) }
            // Search as you type: a short pause after the last keystroke starts the lookup.
            .task(id: library.searchQuery) {
                let query = library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard prepared, query.count >= 2, !query.hasPrefix("https://") else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, !session.snapshot.submitted, !session.searching else { return }
                search(proxy)
            }
            .onChange(of: key) { old, next in
                guard prepared, session.activeKey != next else { return }
                rememberPosition(context: old)
                searchTask?.cancel(); drawerTask?.cancel(); drawerVisible=false
                session.activate(next)
                library.searchResults = session.snapshot.results
                resetList(proxy)
                if !next.query.isEmpty, !session.snapshot.submitted,
                   old.kind != next.kind || old.country != next.country {
                    search(proxy)
                }
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                session.activate(key)
                library.searchResults = session.snapshot.results
                let shouldSearch = library.searchOnPresentation
                library.searchOnPresentation = false
                if shouldSearch && !session.snapshot.submitted { search(proxy) }
                else { restorePosition(proxy) }
            }
            .toolbar {
                if !embedded { ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") {
                        rememberPosition()
                        listPosition.suspend()
                        dismiss()
                    }
                        .accessibilityIdentifier("search-close")
                } }
                // The catalogue region follows the Apple Music account; without a connection it is
                // chosen in 设置 (2026-11-16 anson 经 Claude, MAP-COLLECTION-DESIGN §7).
            }
        }
        .sheet(isPresented: $knowledgePresented, onDismiss: {
            if let next = knowledgeTarget {
                knowledgeTarget = nil
                rememberPosition()
                listPosition.suspend()
                open(next)
            }
        }) {
            KnowledgeSearchView(query: library.searchQuery) { next in knowledgeTarget = next; knowledgePresented = false }
        }
    }

    private func open(_ id: WorkID) {
        if let onOpen { onOpen(id) }
        else { dismiss(); library.openSearchResult(id) }
    }

    private func row(_ id: WorkID) -> some View {
        HStack(spacing: 4) {
            Button {
                rememberPosition(fallback: id)
                listPosition.suspend()
                open(id)
            } label: {
                HStack(spacing: 14) {
                    let work = library.catalog.work(id)
                    let entity = SeedLibraryBridge.entity(for: id, in: library)
                    if ShopStyle.enabled {
                        ShopObject(entity: entity, height: 56).shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 2)
                            .frame(width: 60, height: 58)
                    } else {
                        PhysicalObject(entity: entity, showsDisc: false, size: CGSize(width: 50, height: 54))
                            .frame(width: 50, height: 54)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entity.title).font(ShopStyle.enabled ? .system(size: 16, weight: .semibold) : .custom(DesignFonts.editorialName, size:17))
                            .foregroundStyle(ShopStyle.enabled ? ShopStyle.ink : Color(red:0.17,green:0.14,blue:0.11)).lineLimit(2)
                        Text([work.kind, VerifiedDisplayName.creator(work,catalog:library.catalog)].filter { !$0.isEmpty }.joined(separator:" · "))
                            .font(.system(size:12.5)).foregroundStyle(ShopStyle.enabled ? ShopStyle.secondary : Color(red:0.48,green:0.43,blue:0.36)).lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-result-\(id.rawValue)")
            CatalogMusicAction(work: library.catalog.work(id))
        }
        .padding(.horizontal, ShopStyle.enabled ? 4 : 12).padding(.vertical, ShopStyle.enabled ? 8 : 13)
        .background(ShopStyle.enabled ? Color.clear : Color(red:0.93,green:0.91,blue:0.86))
        .overlay(alignment: ShopStyle.enabled ? .bottom : .top) {
            if ShopStyle.enabled { Rectangle().fill(ShopStyle.line).frame(height: 0.5).padding(.leading, 74) }
            else { Rectangle().fill(Color(red:0.63,green:0.23,blue:0.18).opacity(0.5)).frame(height:1).padding(.top,7) }
        }
        .clipShape(.rect(cornerRadius: ShopStyle.enabled ? 0 : 3))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .modifier(SearchCardArrival(index:session.snapshot.results.firstIndex(of:id) ?? 0,revision:resultRevision))
        .id(id)
        .background {
            SearchListRowProbe(id: id, identity: listIdentity, controller: listPosition)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func rememberPosition(fallback: WorkID? = nil, context: SearchSessionKey? = nil) {
        let context = context ?? key
        guard session.activeKey == context, let position = listPosition.capture(fallback: fallback) else { return }
        session.rememberPosition(position, for: context)
    }

    private func resetList(_ proxy: ScrollViewProxy) {
        listIdentity = UUID()
        restorePosition(proxy)
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        let rowIDs = key.query.isEmpty
            ? Array(library.recent.prefix(5)) + library.catalog.entryPoints
            : session.snapshot.results + local
        listPosition.restore(session.snapshot.position, identity: listIdentity, validRowIDs: Set(rowIDs)) { anchor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    private func search(_ proxy: ScrollViewProxy) {
        searchTask?.cancel(); drawerTask?.cancel(); drawerVisible=false
        guard let token = session.begin(key) else {
            library.searchResults = []
            resetList(proxy)
            return
        }
        library.searchResults = []
        resetList(proxy)
        let context = token.key
        searchTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
                drawerTask = Task { @MainActor in
                    try? await Task.sleep(for:.milliseconds(300))
                    guard !Task.isCancelled, session.searching, key == context else { return }
                    withAnimation(.easeOut(duration:0.2)) { drawerVisible=true }
                }
                let ids: [WorkID]
                if PlatformSongLink.importURL(in: context.query) != nil {
                    ids = [try await library.importMusicShare(context.query)]
                } else if context.query.hasPrefix("https://") {
                    ids = [try await library.catalog.importLink(context.query, country: context.country)]
                } else if context.platform != .apple && context.kind == .song {
                    let rows = try await library.domesticCatalog.search(context.query, platform: context.platform)
                    try library.catalog.merge(.init(works: rows.map(\.work), relations: []))
                    ids = rows.map { $0.work.id }
                } else {
                    ids = try await library.catalog.search(context.query, country: context.country,
                                                           kind: context.kind, recordingContext: context.recordingContext)
                }
                try Task.checkCancellation()
                guard key == context, session.complete(token, results: ids) else { return }
                drawerTask?.cancel()
                withAnimation(.easeOut(duration:0.2)) { drawerVisible=false }
                resultRevision=UUID()
                library.searchResults = session.snapshot.results
            } catch {
                guard !Task.isCancelled, key == context else { return }
                drawerTask?.cancel(); drawerVisible=false
                let message = context.kind.usesKnowledgeSearch ? KnowledgeError.message(error) : CatalogError.message(error)
                session.fail(token, message: message)
            }
        }
    }
}

/// List is backed by a native scroll view. Its row layout, rather than a
/// SwiftUI appearance callback, determines when a saved anchor can be restored.
/// With an anchor, SearchListPosition.offset is the clipped part of that row.
/// This avoids depending on estimated heights of rows earlier in a lazy List.
@MainActor private final class SearchListPositionController: NSObject {
    private struct WeakRow { weak var view: SearchListProbeView? }
    private struct Restoration {
        let position: SearchListPosition
        let scrollTo: (WorkID) -> Void
        var anchorAttempts = 0
        var lastAttemptLayout: Int?
    }

    private var rows: [ObjectIdentifier: WeakRow] = [:]
    private var identity: UUID?
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var restoration: Restoration?
    private var scheduled = false
    private var ready = false
    private var layoutRevision = 0

    func restore(_ position: SearchListPosition, identity: UUID, validRowIDs: Set<WorkID>,
                 scrollTo: @escaping (WorkID) -> Void) {
        suspend()
        self.identity = identity
        scrollView = nil
        let validPosition = position.anchor.map { validRowIDs.contains($0) } == false
            ? SearchListPosition() : position
        restoration = Restoration(position: validPosition, scrollTo: scrollTo)
        scheduleLayoutCheck()
    }

    func suspend() {
        restoration = nil
        ready = false
        stopObserving()
    }

    func update(_ row: SearchListProbeView, laidOut: Bool = false) {
        rows[ObjectIdentifier(row)] = WeakRow(view: row)
        if laidOut, row.identity == identity { layoutRevision &+= 1 }
        if restoration != nil, row.identity == identity { scheduleLayoutCheck() }
    }

    func remove(_ row: SearchListProbeView) {
        rows[ObjectIdentifier(row)] = nil
    }

    func capture(fallback: WorkID?) -> SearchListPosition? {
        guard ready, let scroll = currentScrollView, scroll.bounds.height > 0 else { return nil }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        if top <= 0.5 { return SearchListPosition() }
        let bottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
        let frames = currentRows.compactMap { row -> (WorkID, CGRect)? in
            guard row.enclosingScrollView === scroll else { return nil }
            let frame = row.convert(row.bounds, to: scroll)
            guard frame.height > 0 else { return nil }
            return (row.id, frame)
        }
        let candidates = frames.filter { $0.1.maxY > top && $0.1.minY < bottom }
        let anchor = candidates.min { $0.1.minY < $1.1.minY }
            ?? frames.first { $0.0 == fallback }
        guard let anchor else { return nil }
        return SearchListPosition(offset: Double(max(0, top - anchor.1.minY)), anchor: anchor.0)
    }

    private var currentRows: [SearchListProbeView] {
        rows.values.compactMap(\.view).filter { $0.identity == identity && $0.window != nil }
    }

    private var currentScrollView: UIScrollView? {
        if let scrollView, scrollView.window != nil { return scrollView }
        return currentRows.first?.enclosingScrollView
    }

    private func scheduleLayoutCheck() {
        guard restoration != nil, !scheduled else { return }
        scheduled = true
        // Coalesce native layout/KVO notifications outside the layout pass.
        // There is no time-based retry and no polling after restoration ends.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.restoreAfterLayout()
        }
    }

    private func restoreAfterLayout() {
        guard var pending = restoration, let scroll = currentScrollView,
              scroll.window != nil, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        if scrollView !== scroll {
            stopObserving()
            scrollView = scroll
            observe(scroll)
        }
        if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
            finishRestoration()
            return
        }
        scroll.layoutIfNeeded()
        guard scroll.contentSize.height > 0 else { return }
        let insets = scroll.adjustedContentInset
        let desired: CGFloat
        if let anchor = pending.position.anchor {
            guard let row = currentRows.first(where: { $0.id == anchor && $0.enclosingScrollView === scroll }),
                  row.bounds.height > 0 else {
                // Each retry requires a completed native row layout, rather
                // than another KVO notification from the same layout pass.
                guard pending.lastAttemptLayout != layoutRevision else { return }
                guard pending.anchorAttempts < 3 else { finishRestoration(); return }
                pending.anchorAttempts += 1
                pending.lastAttemptLayout = layoutRevision
                restoration = pending
                pending.scrollTo(anchor)
                // Request a bounded confirmation layout even when scrollTo
                // was ignored and consequently produced no geometry change.
                // The next row layout either finds the anchor or advances the
                // attempt limit; a missing anchor cannot remain pending forever.
                scroll.setNeedsLayout()
                let probe = currentRows.first { $0.convert($0.bounds, to: scroll).intersects(scroll.bounds) }
                    ?? currentRows.first
                probe?.setNeedsLayout()
                return
            }
            let frame = row.convert(row.bounds, to: scroll)
            desired = frame.minY + CGFloat(pending.position.offset) - insets.top
        } else {
            desired = -insets.top
        }
        let maximum = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
        let target = min(max(-insets.top, desired), maximum)
        guard target.isFinite else { finishRestoration(); return }
        if abs(scroll.contentOffset.y - target) > 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
            // The resulting native geometry/layout notification confirms the
            // anchor's position before normal position capture is enabled.
        } else {
            finishRestoration()
        }
    }

    private func observe(_ scroll: UIScrollView) {
        observations = [
            scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.nativeGeometryChanged() },
            scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.nativeGeometryChanged() },
            scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.nativeGeometryChanged() },
            scroll.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in self?.nativeGeometryChanged() }
        ]
        scroll.panGestureRecognizer.addTarget(self, action: #selector(userDidPan(_:)))
    }

    nonisolated private func nativeGeometryChanged() {
        Task { @MainActor [weak self] in self?.scheduleLayoutCheck() }
    }

    @objc private func userDidPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { finishRestoration() }
    }

    private func finishRestoration() {
        restoration = nil
        ready = true
        stopObserving()
    }

    private func stopObserving() {
        observations.removeAll()
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(userDidPan(_:)))
    }
}

private struct SearchListRowProbe: UIViewRepresentable {
    let id: WorkID
    let identity: UUID
    let controller: SearchListPositionController

    func makeUIView(context: Context) -> SearchListProbeView {
        SearchListProbeView(id: id, identity: identity, controller: controller)
    }

    func updateUIView(_ view: SearchListProbeView, context: Context) {
        view.id = id
        view.identity = identity
        view.controller = controller
        controller.update(view)
    }

    static func dismantleUIView(_ view: SearchListProbeView, coordinator: ()) {
        view.controller?.remove(view)
    }
}

@MainActor private final class SearchListProbeView: UIView {
    var id: WorkID
    var identity: UUID
    weak var controller: SearchListPositionController?

    init(id: WorkID, identity: UUID, controller: SearchListPositionController) {
        self.id = id
        self.identity = identity
        self.controller = controller
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var enclosingScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { controller?.remove(self) }
        else { controller?.update(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller?.update(self, laidOut: true)
    }
}
