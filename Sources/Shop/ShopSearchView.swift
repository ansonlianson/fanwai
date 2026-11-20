import SwiftUI

/// 搜索 (0.5.9, 2026-11-16 anson 经 Claude; review/E11-artwork-background/search/SEARCH-DESIGN.md).
/// One field, every kind at once: Apple Music (songs, artists, albums) and Wikidata (films,
/// series, games, books, manga) are asked together and their answers are grouped. A native scope
/// narrows it. Empty, it lists what was searched for, opened or looked up, newest first.
/// No type has to be chosen first.
enum UnifiedSearchScope: String, CaseIterable, Identifiable, Hashable {
    case all, music, screen, game, book
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "全部"; case .music: "音乐"; case .screen: "影视"; case .game: "游戏"; case .book: "书" }
    }
    var asksMusic: Bool { self == .all || self == .music }
    var asksWorks: Bool { self != .music }
    var sections: [UnifiedSearchSection] {
        switch self {
        case .all: UnifiedSearchSection.allCases
        case .music: [.songs, .artists, .albums]
        case .screen: [.screen]
        case .game: [.games]
        case .book: [.books]
        }
    }
}

enum UnifiedSearchSection: String, CaseIterable, Identifiable {
    case songs, screen, games, books, artists, albums
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: "歌曲"; case .screen: "影视"; case .games: "游戏"; case .books: "书与漫画"; case .artists: "音乐人"; case .albums: "专辑"
        }
    }
    @MainActor static func of(_ work: Work) -> UnifiedSearchSection? {
        if work.isSong || work.isMusicWork { return .songs }
        if work.isAlbum { return .albums }
        if work.isPerson { return .artists }
        switch work.kind {
        case "电影", "电视剧", "动画": return .screen
        case "游戏": return .games
        case "书籍", "文学作品", "漫画": return .books
        default: return nil
        }
    }
}

@MainActor @Observable final class UnifiedSearchModel {
    enum Source: Hashable { case music, works }
    private(set) var query = ""
    private(set) var platform = PlaybackPlatform.apple
    private(set) var scope = UnifiedSearchScope.all
    private(set) var remote: [UnifiedSearchSection: [WorkID]] = [:]
    private(set) var link: WorkID?
    private(set) var pending: Set<Source> = []
    private(set) var failed: [Source: String] = [:]
    /// Sources already answered for the current query. Switching scope only filters these
    /// locally; it never clears the list or asks again (0.5.10: the scope bar's glass was
    /// stuttering while the whole list emptied and refilled under it).
    private(set) var fetched: Set<Source> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var worksTask: Task<Void, Never>?

    func run(_ raw: String, scope: UnifiedSearchScope, library: Library) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q == query, platform == library.playbackPlatform, !q.isEmpty, failed.isEmpty {
            // Same words, another scope: ask only a catalogue this query has not been put to yet.
            self.scope = scope
            if scope.asksMusic, !fetched.contains(.music), !pending.contains(.music), PlatformSongLink.importURL(in: q) == nil && !q.hasPrefix("https://") {
                pending.insert(.music); task = Task { @MainActor in await self.music(q, library: library) }
            }
            if scope.asksWorks, !fetched.contains(.works), !pending.contains(.works), PlatformSongLink.importURL(in: q) == nil && !q.hasPrefix("https://") {
                pending.insert(.works); worksTask = Task { @MainActor in await self.works(q, library: library) }
            }
            return
        }
        task?.cancel(); worksTask?.cancel()
        query = q; platform = library.playbackPlatform; self.scope = scope; remote = [:]; link = nil; failed = [:]; fetched = []
        guard !q.isEmpty else { pending = []; return }
        if PlatformSongLink.importURL(in: q) != nil || q.hasPrefix("https://") {
            pending = [.music]
            task = Task { @MainActor in
                do { let id = PlatformSongLink.importURL(in: q) != nil ? try await library.importMusicShare(q) : try await library.catalog.importLink(q, country: library.country); guard !Task.isCancelled else { return }; link = id }
                catch { if !Task.isCancelled { failed[.music] = CatalogError.message(error) } }
                pending.remove(.music)
            }
            return
        }
        pending = Set([scope.asksMusic ? Source.music : nil, scope.asksWorks ? Source.works : nil].compactMap { $0 })
        // The two catalogues are asked side by side; each group appears as its answer arrives.
        if scope.asksMusic { task = Task { @MainActor in await self.music(q, library: library) } }
        if scope.asksWorks { worksTask = Task { @MainActor in await self.works(q, library: library) } }
    }
    func cancel() { task?.cancel(); worksTask?.cancel(); pending = [] }

    private func music(_ q: String, library: Library) async {
        let catalog = library.catalog, country = library.country, context = library.recordingSearchContext
        let selected = platform
        let songsTask = Task { @MainActor in
            if selected == .apple { return try await catalog.search(q, country: country, kind: .song, recordingContext: context) }
            let rows = try await library.domesticCatalog.search(q, platform: selected)
            try catalog.merge(.init(works: rows.map(\.work), relations: []))
            return rows.map { $0.work.id }
        }
        let artistsTask = Task { @MainActor in try await catalog.search(q, country: country, kind: .musicArtist) }
        let albumsTask = Task { @MainActor in try await catalog.search(q, country: country, kind: .album) }
        let (songs, artists, albums) = await withTaskCancellationHandler {
            (await songsTask.result, await artistsTask.result, await albumsTask.result)
        } onCancel: { songsTask.cancel(); artistsTask.cancel(); albumsTask.cancel() }
        let results: [CatalogSearchKind: Result<[WorkID], Error>] = [.song: songs, .musicArtist: artists, .album: albums]
        guard !Task.isCancelled, query == q, selected == platform, selected == library.playbackPlatform else { return }
        if case .success(let ids)? = results[.song] { remote[.songs] = ids }
        if case .success(let ids)? = results[.musicArtist] { remote[.artists] = ids }
        if case .success(let ids)? = results[.album] { remote[.albums] = ids }
        if case .failure(let error)? = results[.song] {
            if selected != .apple { failed[.music] = CatalogError.message(error) }
            else if case .failure? = results[.musicArtist] { failed[.music] = CatalogError.message(error) }
            else { fetched.insert(.music) }
        } else { fetched.insert(.music) }
        pending.remove(.music)
    }
    private func works(_ q: String, library: Library) async {
        let result = await Self.attempt { try await library.catalog.search(q, country: library.country, kind: .works) }
        guard !Task.isCancelled, query == q else { return }
        switch result {
        case .success(let ids):
            fetched.insert(.works)
            for id in ids {
                guard let section = UnifiedSearchSection.of(library.catalog.work(id)), [.screen, .games, .books].contains(section) else { continue }
                remote[section, default: []].append(id)
            }
        case .failure(let error): failed[.works] = KnowledgeError.message(error)
        }
        pending.remove(.works)
    }
    private static func attempt(_ body: @MainActor () async throws -> [WorkID]) async -> Result<[WorkID], Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

struct ShopSearchView: View {
    /// Bumped when the 搜索 tab is tapped again while already showing this page.
    var focusRequest = 0
    var onOpen: (WorkID) -> Void
    @Environment(Library.self) private var library
    @FocusState private var fieldFocused: Bool
    @Environment(\.openURL) private var openURL
    @State private var model = UnifiedSearchModel()
    @State private var scope = UnifiedSearchScope.all
    @State private var expanded = Set<UnifiedSearchSection>()
    @State private var history = SearchHistory.shared
    @State private var confirmingClear = false
    @Environment(LeadResearch.self) private var research

    private var trimmed: String { library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var library = library
        List {
            if trimmed.isEmpty { recentSearches } else { resultSections }
        }
        // A scope change filters what is already here; no list animation runs under the
        // scope bar's own glass transition.
        .animation(nil, value: scope)
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { ShopPageBackdrop() }
        .foregroundStyle(ShopStyle.ink)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.large)
        // The field stays in view above the 最近 list: with rows under it the system would
        // otherwise tuck it away until the list is pulled down.
        .searchable(text: $library.searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: library.playbackPlatform == .apple ? "作品、创作者或 Apple Music 链接" : "歌名、作品，或粘贴\(library.playbackPlatform.title)链接")
        .searchFocused($fieldFocused)
        .searchScopes($scope, activation: .onTextEntry) {
            ForEach(UnifiedSearchScope.allCases) { Text($0.title).tag($0) }
        }
        .onSubmit(of: .search) { model.run(library.searchQuery, scope: scope, library: library) }
        .onChange(of: scope) { _, next in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { model.run(library.searchQuery, scope: next, library: library) }
        }
        // Search as you type: a short pause after the last keystroke starts the lookup.
        .task(id: trimmed + ":" + library.playbackPlatform.rawValue) {
            if trimmed.isEmpty { model.run("", scope: scope, library: library); expanded = []; return }
            try? await Task.sleep(for: .milliseconds(trimmed.count >= 2 || trimmed.hasPrefix("https://") ? 500 : 900))
            guard !Task.isCancelled else { return }
            expanded = []
            model.run(library.searchQuery, scope: scope, library: library)
        }
        .task { seedRecentOnce() }
        // A second tap on the 搜索 tab starts typing (Apple Music's behaviour).
        .onChange(of: focusRequest) { _, _ in fieldFocused = true }
        // A pasted QQ/网易云 song link opens by itself; one result needs no extra tap.
        .onChange(of: model.link) { _, id in
            if let id, library.playbackPlatform != .apple, library.catalog.work(library.catalog.canonicalID(for: id)).isSong { onOpen(id) }
        }
        .accessibilityIdentifier("search-results")
    }

    // MARK: empty: everything searched for, opened or looked up, newest first

    /// One list (anson 2026-11-18 15:03): search picks and footprints together, so a song whose
    /// lookup was paid for can be found again. `Library.recent` holds it; pages from before this
    /// list existed (earlier search picks, songs already looked up) are added to its end once.
    @ViewBuilder private var recentSearches: some View {
        let items = recentIDs
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.self) { id in
                    row(id).swipeActions(edge: .trailing) {
                        Button("移除", role: .destructive) { history.remove(id); library.removeRecent(id) }
                    }
                }
            } header: {
                header("最近") {
                    Button("清除") { confirmingClear = true }
                        .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(ShopStyle.accent)
                        .accessibilityIdentifier("search-clear-recent")
                        .confirmationDialog("清除最近的记录？", isPresented: $confirmingClear, titleVisibility: .visible) {
                            Button("清除", role: .destructive) {
                                withAnimation(.easeOut(duration: 0.2)) { history.clear(); library.clearBrowsingHistory() }
                            }
                        } message: { Text("查过的幕后和卡片还在，搜这首歌就能再看到。") }
                }
            }
        }
    }
    private var recentIDs: [WorkID] {
        var seen = Set<WorkID>()
        return library.recent.map { library.catalog.canonicalID(for: $0) }
            .filter { library.catalog.works[$0] != nil && seen.insert($0).inserted }
    }
    private func seedRecentOnce() {
        let key = "pianwai.recent.seeded.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let catalog = library.catalog, jobs = research.jobs.values
        var lookedUp = Set(catalog.edges.compactMap(\.researchRoot).map { catalog.canonicalID(for: $0) })
        for (id, job) in jobs where job.storyResult == .present {
            if let work = WorkID(rawValue: id) { lookedUp.insert(catalog.canonicalID(for: work)) }
        }
        let dated = lookedUp.sorted {
            let a = jobs[$0.rawValue]?.startedAt ?? .distantPast, b = jobs[$1.rawValue]?.startedAt ?? .distantPast
            return a == b ? $0.rawValue < $1.rawValue : a > b
        }
        library.extendRecent(history.ids + dated)
    }

    // MARK: results, grouped

    @ViewBuilder private var resultSections: some View {
        if let link = model.link {
            Section { row(link) } header: { header("链接") { EmptyView() } }
        }
        ForEach(scope.sections) { section in
            let ids = ids(for: section)
            if !ids.isEmpty {
                let open = expanded.contains(section) || scope.sections.count == 1
                Section {
                    ForEach(open ? ids : Array(ids.prefix(3))) { row($0) }
                } header: {
                    header(section.title) {
                        if ids.count > 3 && scope.sections.count > 1 {
                            Button(open ? "收起" : "全部 \(ids.count) ›") {
                                withAnimation(.snappy(duration: 0.3)) {
                                    if open { expanded.remove(section) } else { expanded.insert(section) }
                                }
                            }
                            .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(ShopStyle.accent)
                            .accessibilityIdentifier("search-more-" + section.rawValue)
                        }
                    }
                }
            }
        }
        statusRows
    }

    /// Remote answers first, then works already known to the app (for instance a game found
    /// through a song's research) that the remote search did not return.
    private func ids(for section: UnifiedSearchSection) -> [WorkID] {
        let remote = model.remote[section] ?? []
        guard PlatformSongLink.importURL(in: trimmed) == nil, !trimmed.hasPrefix("https://") else { return [] }
        let local = library.catalog.localMatches(trimmed).filter {
            !remote.contains($0) && UnifiedSearchSection.of(library.catalog.work($0)) == section
        }
        var seen = Set<WorkID>()
        return (remote + local.prefix(5)).filter { seen.insert(library.catalog.canonicalID(for: $0)).inserted }
    }

    /// Only what is actually happening: which catalogue is still being asked, or which failed.
    @ViewBuilder private var statusRows: some View {
        let waiting = model.pending
        if !waiting.isEmpty || !model.failed.isEmpty {
            Section {
                if waiting.contains(.music) {
                    if PlatformSongLink.importURL(in: model.query) != nil || model.query.hasPrefix("https://") { statusLine("正在打开链接…") }
                    else if library.playbackPlatform == .apple { statusLine("在 Apple Music 里找…") }
                    else { ProgressView().listRowBackground(Color.clear).listRowSeparator(.hidden) }
                }
                if waiting.contains(.works) { statusLine("在维基数据里找…") }
                if let message = model.failed[.music] { retryLine(message) }
                if let message = model.failed[.works] { retryLine(message) }
            }
        } else if model.query == trimmed, !trimmed.isEmpty, model.link == nil,
                  scope.sections.allSatisfy({ ids(for: $0).isEmpty }) {
            ContentUnavailableView.search(text: trimmed)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
    }
    private func statusLine(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(ShopStyle.tertiary)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .accessibilityIdentifier("search-pending")
    }
    private func retryLine(_ message: String) -> some View {
        HStack(spacing: 4) {
            Text(message + " ·").foregroundStyle(ShopStyle.tertiary)
            Button("重试") { model.run(library.searchQuery, scope: scope, library: library) }
                .buttonStyle(.plain).foregroundStyle(ShopStyle.accent)
        }
        .font(.system(size: 13)).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(ShopStyle.ink)
            Spacer()
            trailing()
        }
        .textCase(nil).padding(.top, 6)
    }

    // MARK: one row

    private func kindWord(_ work: Work) -> String {
        switch work.kind {
        case "电视剧": "剧集"
        case "书籍", "文学作品": "书"
        case "音乐作品", "乐章": "乐曲"
        case "创作者": "音乐人"
        case "演奏视频", "音乐视频": "影像"
        default: work.kind
        }
    }
    private func row(_ id: WorkID) -> some View {
        let work = library.catalog.work(id)
        let entity = SeedLibraryBridge.entity(for: id, in: library)
        let creator = VerifiedDisplayName.creator(work, catalog: library.catalog)
        return HStack(spacing: 4) {
            Button { history.add(id); onOpen(id) } label: {
                HStack(spacing: 14) {
                    ShopObject(entity: entity, height: 56).shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 2)
                        .frame(width: 60, height: 58)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entity.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ShopStyle.ink).lineLimit(2)
                        Text([kindWord(work), creator].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12.5)).foregroundStyle(ShopStyle.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-result-\(id.rawValue)")
            CatalogMusicAction(work: work)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(ShopStyle.line).frame(height: 0.5).padding(.leading, 74) }
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 14))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .contextMenu {
            if let verb = WorkVerb.save(entity.kind) {
                let saved = SeedLibraryBridge.saved(entity, in: library)
                Button(saved ? (verb == "收藏" ? "取消收藏" : "移出" + verb) : verb, systemImage: saved ? "minus.circle" : WorkVerb.symbol(verb, saved: false)) {
                    if saved { SeedLibraryBridge.unsave(entity, in: library) } else { try? SeedLibraryBridge.save(entity, into: library) }
                }
            }
            if work.isSong {
                Button(library.playbackPlatform.listenTitle, systemImage: "play.fill") { library.listen(work.id) }
            } else if let url = work.appleMusicURL {
                Button("在 Apple Music 打开", systemImage: "arrow.up.forward.app") { openURL(url) }
            }
        }
    }
}

/// Works opened from search results, newest first (Apple Music's 最近搜索). Kept on this device.
@MainActor @Observable final class SearchHistory {
    static let shared = SearchHistory()
    private(set) var ids: [WorkID] = []
    @ObservationIgnored private let key = "pianwai.searchHistory.v1"
    init() {
        ids = (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(WorkID.init(rawValue:))
    }
    func add(_ id: WorkID) {
        ids.removeAll { $0 == id }; ids.insert(id, at: 0); ids = Array(ids.prefix(10)); save()
    }
    func remove(_ id: WorkID) { ids.removeAll { $0 == id }; save() }
    func clear() { ids = []; save() }
    private func save() { UserDefaults.standard.set(ids.map(\.rawValue), forKey: key) }
}
