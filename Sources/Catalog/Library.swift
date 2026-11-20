import SwiftUI
import Observation
import CryptoKit

extension WorkID { @MainActor var work: Work { CatalogStore.shared.work(self) } }

struct Work: Identifiable, Codable, Equatable, Sendable {
    let id: WorkID
    let title: String
    let creator: String
    let kind: String
    let art: String
    let detail: String
    let url: String?
    var isSong: Bool { kind == "歌曲" }
    var isMusicWork: Bool { ["音乐作品", "乐章"].contains(kind) || discovery?.layer.isComposition == true }
    var isPerson: Bool { kind == "创作者" }
    var appleArtistID: String? {
        guard isPerson else { return nil }
        if let catalogID { return catalogID }
        return id.rawValue.hasPrefix("apple:artist:") ? String(id.rawValue.dropFirst("apple:artist:".count)) : nil
    }
    var isAlbum: Bool { kind == "专辑" }
    var isVideo: Bool { ["演奏视频", "音乐视频"].contains(kind) }
    var symbol: String {
        if isPerson { return "person.crop.circle" }
        if isAlbum { return "square.stack" }
        if isVideo { return "play.rectangle" }
        if kind == "游戏" { return "gamecontroller" }
        if ["电影", "动画"].contains(kind) { return "film" }
        if kind == "电视剧" { return "tv" }
        if isSong || isMusicWork { return "music.note" }
        return "book.closed"
    }
    var linkedAlbumID: WorkID? = nil
    var linkedCreatorIDs: [WorkID]? = nil
    var catalogID: String? = nil
    var storeCountry: String? = nil
    var knowledgeID: String? = nil
    var knowledgeIdentitySource: Source? = nil
    var doubanRating: Double? = nil
    var doubanRatingSource: String? = nil
    var versionSearchQuery: String? = nil
    var releaseDate: String? = nil
    var editorialNotes: [StoryMaterial]? = nil
    // Optional for compatibility with existing libraries. No preview URL is stored.
    var catalogSource: Source? = nil
    var catalogFetchedAt: Date? = nil
    var catalogTrack: CatalogTrackIdentity? = nil
    var resolvedRegion: String? = nil
    var regionOrigin: PlaybackRegionOrigin? = nil
    var catalogTrackCount: Int? = nil
    var bangumiID: String? = nil
    var seriesIDs: [String]? = nil
    var discovery: DiscoveryIdentity? = nil
    var publicIdentifiers: PublicRecordingIdentifiers? = nil
    var platformRecording: PlatformRecording? = nil
    var albumID: WorkID? {
        if let linkedAlbumID { return linkedAlbumID }
        return switch id {
        case .pool, .ourFilm, .slow: .poolAlbum
        case .jane: .janeAlbum
        case .distance: .distanceAlbum
        default: nil
        }
    }
    var creatorIDs: [WorkID] {
        if let linkedCreatorIDs { return linkedCreatorIDs }
        return switch id {
        case .pool, .ourFilm, .slow, .poolAlbum: [.ushio]
        case .film: [.yoshihara]
        case .animenz: [.animenzPerson]
        case .jane, .janeAlbum: [.yonezu, .utada]
        case .distance, .distanceAlbum: [.utada]
        case .manga: [.fujimoto]
        default: []
        }
    }

    @MainActor static var catalog: [WorkID: Work] { CatalogStore.shared.works }
    static let seeds: [WorkID: Work] = [
        .pool: .init(id: .pool, title: "in the pool", creator: "牛尾宪辅", kind: "歌曲", art: "pool", detail: "4:05 · 2025", url: "https://music.apple.com/us/song/1837522108", storeCountry: "us"),
        .film: .init(id: .film, title: "电锯人 蕾塞篇", creator: "吉原达矢", kind: "电影", art: "film", detail: "动画电影 · 2025", url: "https://chainsawman.dog/movie_reze/"),
        .animenz: .init(id: .animenz, title: "in the pool", creator: "Animenz", kind: "演奏视频", art: "animenz", detail: "钢琴改编 · 5:24", url: "https://www.bilibili.com/video/BV1QHyZBbEnT/"),
        .jane: .init(id: .jane, title: "JANE DOE", creator: "米津玄师、宇多田光", kind: "歌曲", art: "jane", detail: "3:56 · 2025", url: "https://music.apple.com/us/song/1840081736", storeCountry: "us"),
        .distance: .init(id: .distance, title: "FINAL DISTANCE", creator: "宇多田光", kind: "歌曲", art: "distance", detail: "5:38 · 2001", url: "https://music.apple.com/us/song/1444855975", storeCountry: "us"),
        .ourFilm: .init(id: .ourFilm, title: "our film", creator: "牛尾宪辅", kind: "歌曲", art: "pool", detail: "1:10 · 2025", url: "https://music.apple.com/us/song/1837521650", storeCountry: "us"),
        .slow: .init(id: .slow, title: "slow summer eve", creator: "牛尾宪辅", kind: "歌曲", art: "pool", detail: "1:30 · 2025", url: "https://music.apple.com/us/song/1837522113", storeCountry: "us"),
        .manga: .init(id: .manga, title: "电锯人", creator: "藤本树", kind: "漫画", art: "", detail: "原作漫画", url: nil),
        .ushio: .init(id: .ushio, title: "牛尾宪辅", creator: "作曲家", kind: "创作者", art: "", detail: "《蕾塞篇》配乐", url: "https://music.apple.com/us/artist/kensuke-ushio/939561587", catalogID: "939561587", storeCountry: "us"),
        .yonezu: .init(id: .yonezu, title: "米津玄师", creator: "音乐人", kind: "创作者", art: "", detail: "《JANE DOE》词曲与演唱", url: nil),
        .utada: .init(id: .utada, title: "宇多田光", creator: "音乐人", kind: "创作者", art: "", detail: "《JANE DOE》合作演唱", url: nil),
        .yoshihara: .init(id: .yoshihara, title: "吉原达矢", creator: "导演", kind: "创作者", art: "", detail: "《电锯人 蕾塞篇》导演", url: nil),
        .fujimoto: .init(id: .fujimoto, title: "藤本树", creator: "漫画家", kind: "创作者", art: "", detail: "《电锯人》原作者", url: nil),
        .ravel: .init(id: .ravel, title: "拉威尔", creator: "作曲家", kind: "创作者", art: "", detail: "Animenz 在改编说明中提到", url: nil),
        .debussy: .init(id: .debussy, title: "德彪西", creator: "作曲家", kind: "创作者", art: "", detail: "Animenz 在改编说明中提到", url: nil),
        .animenzPerson: .init(id: .animenzPerson, title: "Animenz", creator: "钢琴演奏与改编", kind: "创作者", art: "", detail: "in the pool 钢琴改编", url: nil),
        .poolAlbum: .init(id: .poolAlbum, title: "summer’s end", creator: "牛尾宪辅", kind: "专辑", art: "pool", detail: "《蕾塞篇》电影原声 · 2025", url: "https://music.apple.com/us/album/1837521647", storeCountry: "us"),
        .janeAlbum: .init(id: .janeAlbum, title: "JANE DOE — Single", creator: "米津玄师、宇多田光", kind: "专辑", art: "jane", detail: "单曲发行 · 2025", url: "https://music.apple.com/us/album/1840081735", storeCountry: "us"),
        .distanceAlbum: .init(id: .distanceAlbum, title: "Final Distance", creator: "宇多田光", kind: "专辑", art: "distance", detail: "单曲发行 · 2001", url: "https://music.apple.com/us/album/1444855971", storeCountry: "us")
    ]
}

enum Route: Hashable, Codable {
    case work(WorkID)
    case connections(WorkID)
}

enum AppTab: String, Hashable, Codable { case now, collection }

/// Stable persisted values, independent of picker order and translated labels.
/// An unfamiliar future selection must not make the user's whole library unreadable.
enum CollectionSection: String, CaseIterable, Hashable, Codable, Sendable {
    case works, listenLater, watchLater

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = (try? container.decode(String.self)).flatMap(Self.init(rawValue:)) ?? .works
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}


@Observable @MainActor
final class Library {
    var tab: AppTab = .now { didSet { navigationDidChange() } }
    var path: [Route] = [] { didSet { navigationDidChange() } }
    var collectionPath: [Route] = [] { didSet { navigationDidChange() } }
    var collectionSection: CollectionSection = .works {
        didSet { if collectionSection != oldValue { persist() } }
    }
    var focus: WorkID = .pool
    var reading: WorkID = .pool
    /// Compatibility value for existing artwork views. `currentTrack` is the
    /// authoritative optional playback identity; never render this without a gate.
    var playing: WorkID = .pool
    private(set) var currentTrack: WorkID?
    private(set) var currentEntryID: String?
    var isPlaying = false
    private(set) var isPlaybackUnidentified = false
    private(set) var canControlPlayback = false
    private(set) var canPlayCatalog = false
    var canQueueNext: Bool { playbackPlatform == .apple && canPlayCatalog && currentEntryID != nil }
    var playbackBusy: Bool { activePlaybackCommand != nil || music.commandInFlight != nil }
    private(set) var activePlaybackCommand: MusicPlaybackCommand?
    private(set) var playbackOperations: [PlaybackOperationRecord] = []
    var next: WorkID? {
        didSet { nextOriginEntryID = next == nil ? nil : currentEntryID }
    }
    var songSheet: WorkID? {
        didSet {
            guard songSheet != oldValue else { return }
            clearPlaybackFeedback()
            if let id = songSheet {
                let canonical = catalog.canonicalID(for: id)
                let candidates = [operationKey(.insertNext, id: canonical), operationKey(.playNow, id: canonical)]
                if let key = candidates.first(where: { uncertainOperations[$0] != nil }), let issue = uncertainOperations[key] {
                    showPlaybackIssue(issue.message, uncertain: true, key: key)
                }
            }
        }
    }
    var sourceSheet: WorkID?
    var searchPresented = false
    // Transient presentation only; opening or cancelling discovery never
    // changes either navigation path or the persisted reading destination.
    var discoveryPresented = false
    var discoveryExcludedID: WorkID?
    var searchOnPresentation = false
    private var searchAfterSongDismissal = false
    var playerPresented = false
    var showNewTrack = false
    var notice: String?
    var saved: [WorkID] = []
    private(set) var watchLaterEntries: [WatchLaterEntry] = []
    /// Legacy work-level projection. Collection rows use upload-level entries.
    var later: [WorkID] {
        get { var seen = Set<WorkID>(); return watchLaterEntries.map(\.workID).filter { seen.insert($0).inserted } }
        set {
            watchLaterEntries = catalog.canonicalIDs(newValue).flatMap { id in
                let existing = watchLaterEntries.filter { $0.workID == id }
                return existing.isEmpty ? [WatchLaterEntry.forWork(id, catalog: catalog)] : existing
            }
        }
    }
    var videoCueFocus: VideoCueFocus?
    var savedVideoSheet: WatchLaterEntry?
    private(set) var watchedIDs: [WorkID] = []
    var listenLater: [WorkID] = []
    private(set) var listenedIDs: [WorkID] = []
    private(set) var collectionOrigins: [String: String] = [:]
    @ObservationIgnored private var completionSnapshot: MusicPlaybackSnapshot?
    private(set) var currentPlaybackMetadata: MusicNowPlayingMetadata?
    var recent: [WorkID] = []
    var checkpoints: [String: ReadingCheckpoint] = [:]
    var graphCheckpoints: [String: GraphCheckpoint] = [:]
    var startedBrowsing = false
    var country = "jp" { didSet { persist() } }
    var playbackPlatform = PlaybackPlatform.apple {
        didSet {
            preferences.set(playbackPlatform.rawValue, forKey: "playback.platform.v1")
            if playbackPlatform != oldValue { listening.cancel() }
        }
    }
    /// First run (ONBOARDING, 2026-11-18): set once the listening app and the model have been
    /// chosen, or the model was put off with 以后再说. People who chose before 0.5.30 never see it.
    var onboardingDone = false {
        didSet { preferences.set(onboardingDone, forKey: "onboarding.done.v1") }
    }
    let listening: ListeningRouter
    let domesticCatalog: DomesticMusicCatalog
    let crateExploration: CrateExploration
    var persistenceError: String?
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { recordingSearchContext = nil } }
    }
    var searchResults: [WorkID] = []
    let searchSession = SearchSessionState()
    var searchKind: CatalogSearchKind = .song {
        didSet { if searchKind != oldValue { recordingSearchContext = nil } }
    }
    private(set) var recordingSearchContext: RecordingSearchContext?
    let music: any MusicPlaybackClient
    /// Apple Music authorization, changed only when it changes. The playback
    /// snapshot is replaced every second; views that only need "connected?"
    /// read this so they are not redrawn each second (Settings flicker, 11-17).
    private(set) var musicConnected = false
    var connectionMessage: String?
    var playbackError: String? {
        didSet { if playbackError == nil { playbackUncertain = false } }
    }
    var playbackUncertain = false
    private(set) var pendingSong: WorkID?
    let demoMode: Bool
    let initialExperience: ExperienceScenario
    let catalog: CatalogStore
    @ObservationIgnored private let persistence: LibraryPersistence
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let navigationFixtureActive: Bool
    @ObservationIgnored private var restoring = true
    private var uncertainOperations: [PlaybackOperationKey: PlaybackUncertainty] = [:]
    @ObservationIgnored private var displayedPlaybackOperation: PlaybackOperationKey?
    @ObservationIgnored private var playbackObservationID: String?
    @ObservationIgnored private var nextOriginEntryID: String?
    @ObservationIgnored private var graphCheckpointOrder: [String] = []
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceDirty = false
    var appearance = 0 {
        didSet {
            if !restoring && !demoMode { preferences.set(appearance, forKey: "appearance") }
        }
    }
    var visualDirection: VisualDirection = .orbit {
        didSet {
            // The selected product direction is fixed; alternatives are review fixtures.
            if !demoMode, visualDirection != .orbit { visualDirection = .orbit }
        }
    }

    private struct PlaybackOperationKey: Hashable {
        let command: String
        let id: WorkID?
    }
    private struct PlaybackUncertainty {
        let message: String
        let originTrack: WorkID?
        let originObservationID: String?
    }
    private struct PlaybackActionContext {
        let id = UUID()
        let key: PlaybackOperationKey
        let originTrack: WorkID?
        let originObservationID: String?
        let issuedAt: Date
    }

    init(defaults: UserDefaults = .standard,
         arguments: [String] = ProcessInfo.processInfo.arguments,
         catalog: CatalogStore = .shared,
         music: any MusicPlaybackClient = MusicPlaybackService(),
         domesticCatalog: DomesticMusicCatalog = .shared) {
        self.catalog = catalog
        self.music = music
        self.domesticCatalog = domesticCatalog
        crateExploration = CrateExploration(defaults: defaults)
        listening = ListeningRouter(defaults: defaults, catalog: domesticCatalog)
        preferences = defaults
        playbackPlatform = defaults.string(forKey: "playback.platform.v1").flatMap(PlaybackPlatform.init(rawValue:)) ?? .apple
        // Someone who already answered the old 用什么听歌 sheet has been through the first run.
        onboardingDone = defaults.bool(forKey: "onboarding.done.v1") || defaults.bool(forKey: "domestic.platformAsked")
        demoMode = arguments.contains("--demo") || arguments.contains(where: { $0.hasPrefix("--scene=") || $0.hasPrefix("--experience=") })
        navigationFixtureActive = arguments.contains { argument in
            ["--scene=", "--sources=", "--work=", "--relations="].contains { argument.hasPrefix($0) }
        }
        initialExperience = arguments.first(where: { $0.hasPrefix("--experience=") })
            .flatMap { ExperienceScenario(rawValue: String($0.dropFirst(13))) } ?? .ready
        persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
        appearance = defaults.integer(forKey: "appearance")
        visualDirection = demoMode ? (defaults.string(forKey: "visualDirection").flatMap(VisualDirection.init(rawValue:)) ?? .orbit) : .orbit
        if demoMode, let argument = arguments.first(where: { $0.hasPrefix("--visual=") }),
           let direction = VisualDirection(rawValue: String(argument.dropFirst(9))) {
            visualDirection = direction
        }
        // Review fixtures are deterministic and never read/write the real library.
        if !demoMode {
            do {
                let state = try persistence.load()
                saved = state.saved; listenLater = state.listenLater; later = state.watchLater
                collectionSection = state.collectionSection ?? .works
                if let entries = state.watchLaterEntries { watchLaterEntries = entries }
                watchedIDs = state.watchedIDs ?? []
                listenedIDs = state.listenedIDs ?? []
                collectionOrigins = state.collectionOrigins ?? [:]
                playbackOperations = PlaybackOperationRecord.retained(state.playbackOperations ?? [])
                for operation in state.unresolvedPlaybackOperations ?? [] {
                    uncertainOperations[.init(command: operation.command.rawValue, id: operation.targetWorkID)] =
                        .init(message: operation.message, originTrack: operation.originTrack,
                              originObservationID: operation.originEntryID)
                }
                recent = state.recent; checkpoints = state.checkpoints; startedBrowsing = state.startedBrowsing
                graphCheckpoints = state.graphCheckpoints ?? [:]
                graphCheckpointOrder = graphCheckpoints.keys.sorted()
                country = state.country
                if let navigation = state.navigation {
                    tab = navigation.tab; focus = navigation.focus; reading = navigation.reading
                    path = navigation.path; collectionPath = navigation.collectionPath
                } else if let last = state.lastWork {
                    focus = catalog.canonicalID(for: last); reading = focus
                }
            } catch { persistenceError = error.localizedDescription }
        } else {
            startedBrowsing = true
            canControlPlayback = initialExperience.hasPlayback
            canPlayCatalog = initialExperience.hasPlayback || initialExperience == .idle
            isPlaying = canControlPlayback
            currentTrack = canControlPlayback ? .pool : nil
            currentEntryID = canControlPlayback ? "demo:pool" : nil
        }
        // Every launch override uses the injected arguments, never global ProcessInfo.
        if let argument = arguments.first(where: { $0.hasPrefix("--scene=") }) {
            switch argument.dropFirst(8) {
            case "home": focus = .pool
            case "search": searchPresented = true
            case "playing-change": path = [.work(.film)]; playing = .jane; currentTrack = canControlPlayback ? .jane : nil; showNewTrack = canControlPlayback
            case "empty-collection": tab = .collection; saved = []; listenLater = []; later = []
            case "song": path = [.work(.jane)]; songSheet = .jane
            case "film": path = [.work(.film)]
            case "animenz": path = [.work(.animenz)]
            case "relations": path = [.connections(.pool)]
            case "reading": path = [.work(.jane)]
            case "collection": tab = .collection; saved = [.jane, .film, .distance]; later = [.animenz]; listenLater = [.ourFilm, .distance]
            case "creator": path = [.work(.utada)]
            case "album": path = [.work(.poolAlbum)]
            case "ordinary": focus = .distance; playing = .distance; currentTrack = canControlPlayback ? .distance : nil
            case "inline": path = [.work(.film)]
            case "sparse-creator": path = [.work(.ravel)]
            default: break
            }
        }
        if let raw = arguments.first(where: { $0.hasPrefix("--sources=") }), let id = WorkID(rawValue: String(raw.dropFirst(10))) {
            let id = catalog.canonicalID(for: id); path = [.work(id)]; sourceSheet = id
        }
        if let raw = arguments.first(where: { $0.hasPrefix("--work=") }), let id = WorkID(rawValue: String(raw.dropFirst(7))) {
            path = [.work(catalog.canonicalID(for: id))]
        }
        if let raw = arguments.first(where: { $0.hasPrefix("--relations=") }), let id = WorkID(rawValue: String(raw.dropFirst(12))) {
            path = [.connections(catalog.canonicalID(for: id))]
        }
        // Collection shortcuts are review-only. A stray argument on a normal
        // launch neither changes the user's selection nor disables persistence.
        if demoMode, let argument = arguments.first(where: { $0.hasPrefix("--collection=") }) {
            switch argument.dropFirst(13) {
            case "listen": collectionSection = .listenLater
            case "later": collectionSection = .watchLater
            default: collectionSection = .works
            }
            tab = .collection
        }
        if demoMode || navigationFixtureActive {
            let routes = tab == .now ? path : collectionPath
            if let route = routes.last { reading = route.workID }
            else if tab == .now { reading = focus }
        }
        pruneGraphCheckpoints()
        musicConnected = music.snapshot.authorization == .authorized
        restoring = false
        if !demoMode { catalog.retainedIDs = { [weak self] in self?.retainedWorkIDs() ?? [] } }
    }

    /// Everything the reader's own lists point at: 收藏、稍后听、看过听过、最近探索、阅读位置、播放记录、
    /// 搜索记录 and the relation maps' trails. The catalogue writes these to disk even when they
    /// arrived as search results (CatalogRetention). Read from the same snapshot the library saves,
    /// so a list added later is covered without another list to maintain here.
    func retainedWorkIDs(trails: RelationTrailStore = RelationTrailStore()) -> Set<WorkID> {
        var ids = Set<WorkID>([currentTrack, playing, next, reading, focus].compactMap { $0 })
        ids.formUnion(SearchHistory.shared.ids)
        let roots = trails.roots()
        ids.formUnion(roots.compactMap { WorkID(rawValue: $0) })
        // A song in 收藏 keeps its whole map, so every work on it stays (anson 11-20).
        for root in starredTrailRoots(roots) {
            if let map = trails.load(root: root) { ids.formUnion(map.nodes.keys.map(SeedLibraryBridge.workID)) }
        }
        let navigation = LibraryNavigationSnapshot(tab: tab, focus: focus, reading: reading, path: path, collectionPath: collectionPath)
        let snapshot = LibrarySnapshot(saved: saved, listenLater: listenLater, watchLater: later, recent: recent,
            checkpoints: checkpoints, lastWork: reading, startedBrowsing: startedBrowsing, country: country, navigation: navigation,
            graphCheckpoints: graphCheckpoints, watchedIDs: watchedIDs, playbackOperations: playbackOperations,
            unresolvedPlaybackOperations: nil, watchLaterEntries: watchLaterEntries, collectionSection: collectionSection,
            listenedIDs: listenedIDs, collectionOrigins: collectionOrigins)
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return ids }
        let pattern = try! NSRegularExpression(pattern: #""([a-z][a-z0-9\-]*:[^"\s]+)""#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let raw = text[range].replacingOccurrences(of: "\\/", with: "/")
            if let id = WorkID(rawValue: raw), catalog.works[id] != nil || catalog.works[catalog.canonicalID(for: id)] != nil { ids.insert(id) }
        }
        return ids
    }

    isolated deinit { flashTask?.cancel(); persistenceTask?.cancel() }

    func startServices() {
        guard !demoMode else { return }
        music.onSnapshot = { [weak self] snapshot in self?.receivePlayback(snapshot) }
        music.startObserving()
    }

    func connectMusic() async {
        guard !demoMode, !playbackBusy else { return }
        activePlaybackCommand = .requestAuthorization
        connectionMessage = nil
        defer { activePlaybackCommand = nil }
        let result = await music.requestAuthorization()
        receivePlayback(music.snapshot)
        switch result {
        case .success:
            connectionMessage = currentTrack == nil && !isPlaybackUnidentified ? "连接好了。播放一首歌后，再回到这里。" : nil
            if let currentTrack, !startedBrowsing { explore(currentTrack) }
        case .failure(let failure), .uncertain(_, let failure): connectionMessage = failure.message
        }
    }

    /// The adapter callback is a small, deterministic reducer; tests can supply
    /// actual-shaped snapshots without authorizing or mutating a real player.
    func receivePlayback(_ snapshot: MusicPlaybackSnapshot) {
        let measurement = EvalPerformance.begin("Playback.receive")
        defer { measurement?.end() }
        let connected = snapshot.authorization == .authorized
        if musicConnected != connected { musicConnected = connected }
        guard !demoMode else { return }
        if activePlaybackCommand != .skipToNext && activePlaybackCommand != .playNow,
           let before = completionSnapshot, MusicPlaybackCompletion.finished(before, snapshot) {
            let completed = before.collectionEnd ?? before.nowPlaying?.catalogID.map { MusicQueueSelection(catalogID: $0, kind: .song) }
            for id in listenLater where catalog.work(id).queueSelection == completed && completed != nil { markListened(id) }
        }
        completionSnapshot = snapshot
        canPlayCatalog = snapshot.canPlayCatalog
        let previous = currentTrack
        let previousEntryID = playbackObservationID ?? currentEntryID
        currentEntryID = snapshot.currentEntryID.flatMap { $0.isEmpty ? nil : $0 }
        guard snapshot.availability == .ready else {
            currentPlaybackMetadata = nil
            currentTrack = nil; canControlPlayback = false; isPlaying = false
            isPlaybackUnidentified = false
            currentEntryID = nil
            playbackObservationID = nil
            next = nil; showNewTrack = false; playerPresented = false
            return
        }
        guard let track = snapshot.nowPlaying else {
            currentPlaybackMetadata = nil
            currentTrack = nil
            canControlPlayback = false
            isPlaying = snapshot.status == .playing
            isPlaybackUnidentified = snapshot.status != .stopped
                && (snapshot.status != .unknown || previous != nil || previousEntryID != nil || isPlaybackUnidentified)
            showNewTrack = false; playerPresented = false
            if snapshot.status == .stopped {
                currentEntryID = nil
                playbackObservationID = nil
                next = nil
            }
            // A missing title is not evidence of a stopped or replaced queue.
            // Keep the last known occurrence for later metadata reconciliation;
            // the current entry remains exactly what the system supplied.
            return
        }
        isPlaybackUnidentified = false
        currentPlaybackMetadata = track
        let numericID = (track.kind == .unknown ? nil : track.catalogID).flatMap { value -> String? in
            guard !value.isEmpty, value.count < 24, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  value.contains(where: { $0 != "0" }) else { return nil }
            return value
        }
        let namespace = track.kind == .musicVideo ? "music-video" : "song"
        let kind = track.kind == .musicVideo ? "演奏视频" : track.kind == .song ? "歌曲" : "作品"
        let anonymousBridge = track.source == .mediaPlayer && track.id.hasPrefix("media:0:")
        let localIdentity = track.id.isEmpty || anonymousBridge
            ? [track.source.rawValue, track.title, track.artist, track.albumTitle ?? "", track.duration.map { String(Int($0.rounded())) } ?? ""].joined(separator: "\u{0}")
            : track.id
        let externalID = numericID.flatMap { WorkID(rawValue: "apple:\(namespace):\($0)") }
            ?? WorkID.localPlaybackID("\(track.kind.rawValue)\u{0}\(localIdentity)")
        let id = catalog.canonicalID(for: externalID)
        let existing = catalog.works[id]
        if existing == nil || id.rawValue.hasPrefix("local:") || id.rawValue.hasPrefix("apple:") {
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名作品" : track.title
            let artwork = track.artworkAsset.flatMap { ObservedArtwork.image($0) != nil ? $0 : nil }
                ?? ArtworkLocation.remoteURL(track.artworkURL)?.absoluteString
                ?? existing.map { ArtworkLocation.stored($0.art) } ?? ""
            let detail = track.albumTitle ?? existing?.detail ?? ""
            if existing == nil || existing?.title != title || existing?.creator != track.artist || existing?.art != artwork || existing?.detail != detail
                || (existing?.releaseDate == nil && track.releaseDate != nil)
                || (existing?.editorialNotes != track.editorialNotes && !(track.editorialNotes?.isEmpty ?? true)) {
                let item = Work(id: id, title: title, creator: track.artist, kind: kind, art: artwork, detail: detail,
                                url: existing?.url,
                                linkedAlbumID: existing?.linkedAlbumID, linkedCreatorIDs: existing?.linkedCreatorIDs,
                                catalogID: numericID, storeCountry: existing?.storeCountry, knowledgeID: existing?.knowledgeID,
                                releaseDate: existing?.releaseDate ?? track.releaseDate, editorialNotes: (track.editorialNotes?.isEmpty == false ? track.editorialNotes : existing?.editorialNotes))
                do { try catalog.merge(CatalogSnapshot(works: [item], relations: [])) }
                catch { connectionMessage = "正在播放已同步，作品资料暂时未能保存。" }
            }
        }
        currentTrack = id; playing = id
        playbackObservationID = currentEntryID
        canControlPlayback = snapshot.canControlPlayback
        isPlaying = snapshot.status == .playing
        reconcileUncertainOperations(snapshot)
        if next == id, let origin = nextOriginEntryID, let observed = currentEntryID, origin != observed {
            next = nil
        }
        if previous != id {
            // Materializing metadata for the same queue occurrence is not a new song.
            if previousEntryID == nil || currentEntryID == nil || previousEntryID != currentEntryID {
                showNewTrack = startedBrowsing && reading != id
            }
            Task {
                let storefront = await PlaybackRegionResolver.appStoreCountry()
                await catalog.resolvePlaybackRegion(id, browsingRegion: country, storefront: storefront)
                _ = storefront // 0.3: leads come from LeadResearch; the relation pipeline is not started here.
            }
        }
    }

    func togglePlayback() {
        guard canControlPlayback else { return }
        if demoMode { isPlaying.toggle(); return }
        let command: MusicPlaybackCommand = isPlaying ? .pause : .resume
        guard let context = beginPlaybackAction(command, id: nil) else { return }
        Task {
            let result = command == .pause ? await music.pause() : await music.resume()
            handle(result, command: command, id: nil, context: context)
        }
    }

    /// Presentation is independent of the per-operation guard. Dismissing an alert
    /// or looking at another song must not accidentally permit an ambiguous retry.
    func clearPlaybackFeedback() {
        playbackError = nil; playbackUncertain = false; displayedPlaybackOperation = nil
    }

    func isPlaybackUncertain(for id: WorkID?, command: MusicPlaybackCommand) -> Bool {
        uncertainOperations[operationKey(command, id: id)] != nil
    }

    /// Only call after an explicit user acknowledgement of checking Apple Music.
    /// This clears a guard; it never repeats the mutation itself.
    func acknowledgePlaybackCheck(for id: WorkID?, command: MusicPlaybackCommand) {
        let key = operationKey(command, id: id)
        uncertainOperations[key] = nil
        if displayedPlaybackOperation == key { clearPlaybackFeedback() }
        persist()
    }

    /// Global alerts retain the exact operation that produced their message.
    /// The current player may already be on a different song by acknowledgement.
    func acknowledgeDisplayedPlaybackCheck() {
        guard let key = displayedPlaybackOperation else { clearPlaybackFeedback(); return }
        uncertainOperations[key] = nil
        clearPlaybackFeedback()
        persist()
    }

    private func operationKey(_ command: MusicPlaybackCommand, id: WorkID?) -> PlaybackOperationKey {
        let target: WorkID?
        switch command {
        case .insertNext, .playNow: target = id.map { catalog.canonicalID(for: $0) }
        default: target = currentTrack
        }
        return .init(command: command.rawValue, id: target)
    }

    private func beginPlaybackAction(_ command: MusicPlaybackCommand, id: WorkID?) -> PlaybackActionContext? {
        guard !playbackBusy else { return nil }
        clearPlaybackFeedback()
        let key = operationKey(command, id: id)
        if let unresolved = uncertainOperations[key] {
            showPlaybackIssue(unresolved.message, uncertain: true, key: key)
            return nil
        }
        activePlaybackCommand = command
        pendingSong = id
        return .init(key: key, originTrack: currentTrack, originObservationID: playbackObservationID, issuedAt: Date())
    }

    private func showPlaybackIssue(_ message: String, uncertain: Bool, key: PlaybackOperationKey? = nil) {
        displayedPlaybackOperation = uncertain ? key : nil
        playbackError = message; playbackUncertain = uncertain
    }

    private func handle(_ result: MusicPlaybackActionResult, command: MusicPlaybackCommand, id: WorkID?, context: PlaybackActionContext) {
        pendingSong = nil; activePlaybackCommand = nil
        let relevant = songSheet == nil || songSheet == id
        let target = id ?? context.originTrack
        let requestedCatalogID = id.flatMap { catalog.work($0).queueSelection?.catalogID }
        var resolvedResult = result
        var record = PlaybackOperationRecord(result: result, command: command, targetWorkID: target,
            catalogID: requestedCatalogID, issuedAt: context.issuedAt,
            originEntryID: context.originObservationID, id: context.id)
        if record == nil {
            // A contradictory result cannot be shown as a successful insert.
            // It also cannot safely authorize an automatic repeat.
            resolvedResult = .uncertain(.init(command: command, catalogID: requestedCatalogID, verification: .unconfirmed),
                                        .init(.notConfirmed, "播放结果尚未确认，请先查看 Apple Music。"))
            record = PlaybackOperationRecord(result: resolvedResult, command: command, targetWorkID: target,
                catalogID: requestedCatalogID, issuedAt: context.issuedAt,
                originEntryID: context.originObservationID, id: context.id)
        }
        if let record {
            playbackOperations = PlaybackOperationRecord.retained([record] + playbackOperations)
        }
        switch resolvedResult {
        case .success(let receipt):
            uncertainOperations[context.key] = nil
            if relevant { clearPlaybackFeedback() }
            if receipt.command == .insertNext, let id {
                next = id
                nextOriginEntryID = context.originObservationID
                if songSheet == id { songSheet = nil }
                flash("已加入下一首")
            } else if receipt.command == .playNow, songSheet == id { songSheet = nil }
        case .failure(let failure):
            if relevant {
                let kept = id.map { catalog.canonicalIDs(saved).contains(catalog.canonicalID(for: $0)) } == true
                let message = failure.code == .catalogUnavailable ? (kept ? "这首歌暂时无法播放。" : "这首歌暂时无法播放。可以先收藏。") : failure.message
                showPlaybackIssue(message, uncertain: false)
            }
        case .uncertain(_, let failure):
            uncertainOperations[context.key] = .init(message: failure.message, originTrack: context.originTrack,
                                                     originObservationID: context.originObservationID)
            if relevant { showPlaybackIssue(failure.message, uncertain: true, key: context.key) }
        }
        // Save the result and its retry guard together. A relaunch between an
        // uncertain mutation and an explicit check must not permit duplicates.
        persist()
    }

    private func reconcileUncertainOperations(_ snapshot: MusicPlaybackSnapshot) {
        guard let currentTrack else { return }
        var resolved = Set<PlaybackOperationKey>()
        for (key, issue) in uncertainOperations {
            let changedOccurrence: Bool
            if let origin = issue.originObservationID, !origin.isEmpty,
               let observed = snapshot.currentEntryID, !observed.isEmpty {
                changedOccurrence = origin != observed
            } else {
                changedOccurrence = issue.originTrack != nil && issue.originTrack != currentTrack
            }
            switch key.command {
            case MusicPlaybackCommand.playNow.rawValue, MusicPlaybackCommand.insertNext.rawValue:
                // Same catalog song may be queued twice. Seeing the already-playing
                // occurrence is not confirmation that an uncertain insert succeeded.
                if key.id == currentTrack, snapshot.status == .playing, changedOccurrence { resolved.insert(key) }
            case MusicPlaybackCommand.pause.rawValue:
                if key.id == currentTrack, snapshot.status == .paused { resolved.insert(key) }
            case MusicPlaybackCommand.resume.rawValue:
                if key.id == currentTrack, snapshot.status == .playing { resolved.insert(key) }
            case MusicPlaybackCommand.skipToNext.rawValue:
                if changedOccurrence { resolved.insert(key) }
            default: break
            }
        }
        for key in resolved { uncertainOperations[key] = nil }
        if let displayedPlaybackOperation, resolved.contains(displayedPlaybackOperation) { clearPlaybackFeedback() }
        if !resolved.isEmpty { persist() }
    }

    private func navigationDidChange() {
        guard !restoring else { return }
        pruneGraphCheckpoints()
        let routes = tab == .now ? path : collectionPath
        if let route = routes.last { reading = catalog.canonicalID(for: route.workID) }
        else if tab == .now, startedBrowsing { reading = focus }
        persist()
    }

    func visit(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        if !startedBrowsing { focus = id; startedBrowsing = true }
        reading = id
        recent = catalog.canonicalIDs(recent)
        recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        if currentTrack == id { showNewTrack = false }
        persist()
    }
    /// 搜索 with nothing typed lists these, newest first (anson 2026-11-18 15:03): every page
    /// searched for, opened or looked up, so a song whose lookup was paid for can be found again.
    static let recentLimit = 300
    /// Every work page opened, and every song a lookup finished for, without moving the reading position.
    func noteRecent(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        guard catalog.works[id] != nil, recent.first != id else { return }
        recent = catalog.canonicalIDs(recent)
        recent.removeAll { $0 == id }; recent.insert(id, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        persist()
    }
    /// Older pages (found by search before, looked up before) join the end of the list once.
    func extendRecent(_ older: [WorkID]) {
        var seen = Set<WorkID>()
        let merged = (catalog.canonicalIDs(recent) + older.map { catalog.canonicalID(for: $0) })
            .filter { catalog.works[$0] != nil && seen.insert($0).inserted }
        guard merged != recent else { return }
        recent = Array(merged.prefix(Self.recentLimit))
        persist()
    }
    func removeRecent(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        guard recent.contains(where: { catalog.canonicalID(for: $0) == id }) else { return }
        recent.removeAll { catalog.canonicalID(for: $0) == id }
        persist()
    }
    func clearBrowsingHistory() {
        recent = []
        persist()
    }
    /// The relation maps that start from a song in 收藏. A starred song keeps its map however deep
    /// it goes and however often 清除浏览记录 runs (anson 11-20).
    func starredTrailRoots(_ roots: [String]) -> Set<String> {
        let starred = Set(catalog.canonicalIDs(saved))
        guard !starred.isEmpty else { return [] }
        return Set(roots.filter { starred.contains(catalog.canonicalID(for: SeedLibraryBridge.workID($0))) })
    }
    /// 清除浏览记录's share of the maps: every map goes except those of songs in 收藏.
    func clearRelationTrails(_ trails: RelationTrailStore = RelationTrailStore()) {
        let roots = trails.roots(), keep = starredTrailRoots(roots)
        for root in roots where !keep.contains(root) { trails.remove(root: root) }
    }
    func explore(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        restoring = true
        focus = id; startedBrowsing = true; path = []; tab = .now
        restoring = false
        visit(id)
    }

    /// A search result continues the stack that presented search. Only the first
    /// exploration creates a new root; choosing a recording never changes tabs
    /// underneath an existing collection or reading journey.
    func openSearchResult(_ rawID: WorkID) {
        if startedBrowsing { open(rawID) }
        else { explore(rawID) }
    }

    /// A knowledge work can have several recordings or releases. Search opens
    /// a separate catalog identity without guessing or replacing this work.
    func findRecording(for rawID: WorkID) {
        let item = catalog.work(rawID)
        guard let kind = item.catalogVersionSearchKind else { return }
        let hint = item.versionSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = hint.flatMap { !$0.isEmpty && $0.count <= 200 ? $0 : nil }
            ?? [item.title, item.creator].filter { !$0.isEmpty }.joined(separator: " ")
        searchKind = kind
        recordingSearchContext = RecordingSearchContext(
            source: item,
            creators: item.creatorIDs.compactMap { catalog.works[catalog.canonicalID(for: $0)] },
            release: item.albumID.flatMap { catalog.works[catalog.canonicalID(for: $0)] },
            query: searchQuery, kind: kind
        )
        searchResults = []
        searchOnPresentation = true
        if songSheet != nil {
            searchAfterSongDismissal = true
            songSheet = nil
        } else { searchPresented = true }
    }

    func songSheetDidDismiss() {
        guard searchAfterSongDismissal else { return }
        searchAfterSongDismissal = false
        searchPresented = true
    }
    func saveReading(_ rawID: WorkID, offset: Double) {
        guard offset.isFinite, offset >= 0 else { return }
        let id = catalog.canonicalID(for: rawID)
        var checkpoint = checkpoints[id.rawValue] ?? ReadingCheckpoint(workID: id, offset: 0, updatedAt: Date())
        checkpoint.offset = offset
        checkpoint.updatedAt = Date()
        checkpoints[id.rawValue] = checkpoint
        persist()
    }
    func setBackgroundExpanded(_ rawID: WorkID, expanded: Bool, secondID: String? = nil) {
        let id = catalog.canonicalID(for: rawID)
        var checkpoint = checkpoints[id.rawValue] ?? ReadingCheckpoint(workID: id, offset: 0, updatedAt: Date())
        checkpoint.backgroundExpanded = expanded
        if expanded, let secondID { checkpoint.backgroundSecondExcerptID = secondID }
        checkpoint.updatedAt = Date()
        checkpoints[id.rawValue] = checkpoint
        persist()
    }
    /// One checkpoint per graph root in this version. Two tabs opening the same
    /// root share that checkpoint; independent simultaneous graph windows are not modeled.
    func saveGraph(root rawRoot: WorkID, checkpoint: GraphCheckpoint) {
        guard !restoring, !demoMode, !navigationFixtureActive else { return }
        let root = catalog.canonicalID(for: rawRoot)
        let key = root.rawValue
        // An outgoing view can save after a native pop. Do not resurrect its state.
        guard activeGraphRoots.contains(key) else { return }
        let normalized = GraphCheckpoint(
            center: catalog.canonicalID(for: checkpoint.center),
            history: checkpoint.history.suffix(40).map {
                GraphTrailEntry(id: catalog.canonicalID(for: $0.id), page: min(999, max(0, $0.page)), filter: min(2, max(0, $0.filter)))
            },
            page: min(999, max(0, checkpoint.page)), filter: min(2, max(0, checkpoint.filter)),
            presentation: min(1, max(0, checkpoint.presentation)), network: checkpoint.network
        )
        graphCheckpoints[key] = normalized
        graphCheckpointOrder.removeAll { $0 == key }
        graphCheckpointOrder.append(key)
        while graphCheckpointOrder.count > 40 {
            graphCheckpoints[graphCheckpointOrder.removeFirst()] = nil
        }
        persist()
    }

    private var activeGraphRoots: Set<String> {
        Set((path + collectionPath).compactMap { route -> String? in
            guard case .connections(let id) = route else { return nil }
            return catalog.canonicalID(for: id).rawValue
        })
    }

    private func pruneGraphCheckpoints() {
        guard !graphCheckpoints.isEmpty || !graphCheckpointOrder.isEmpty else { return }
        let active = activeGraphRoots
        let retained = graphCheckpoints.filter { active.contains($0.key) }
        if retained != graphCheckpoints { graphCheckpoints = retained }
        graphCheckpointOrder.removeAll { !active.contains($0) }
    }

    /// Fold a burst of navigation, reading and collection updates into one save.
    /// Keep a bounded window rather than postponing continuously arriving data.
    func persist() {
        guard !restoring, !demoMode, !navigationFixtureActive else { return }
        // Pruning belongs to the current navigation state, even while its disk
        // snapshot is batched. These checkpoint fields do not call persist().
        pruneGraphCheckpoints()
        persistenceDirty = true
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) }
            catch { return }
            guard let self else { return }
            self.persistenceTask = nil
            self.writePendingState()
        }
    }

    func flushPendingWrites() async {
        persistenceTask?.cancel(); persistenceTask = nil
        writePendingState()
    }

    func flushPendingWritesBeforeTermination() {
        persistenceTask?.cancel(); persistenceTask = nil
        writePendingState()
    }

    private func writePendingState() {
        guard persistenceDirty else { return }
        persistenceDirty = false
        let measurement = EvalPerformance.begin("Library.persist")
        defer { measurement?.end() }
        guard !restoring, !demoMode, !navigationFixtureActive else { return }
        do {
            let navigation = LibraryNavigationSnapshot(tab: tab, focus: focus, reading: reading, path: path, collectionPath: collectionPath)
            let unresolved = uncertainOperations.compactMap { key, issue -> UnresolvedPlaybackOperation? in
                guard let command = MusicPlaybackCommand(rawValue: key.command) else { return nil }
                return .init(command: command, targetWorkID: key.id, message: issue.message,
                             originTrack: issue.originTrack, originEntryID: issue.originObservationID)
            }.sorted { ($0.command.rawValue, $0.targetWorkID?.rawValue ?? "") < ($1.command.rawValue, $1.targetWorkID?.rawValue ?? "") }
            try persistence.save(LibrarySnapshot(saved: saved, listenLater: listenLater, watchLater: later, recent: recent,
                                                 checkpoints: checkpoints, lastWork: startedBrowsing ? reading : nil,
                                                 startedBrowsing: startedBrowsing, country: country, navigation: navigation,
                                                 graphCheckpoints: graphCheckpoints,
                                                 watchedIDs: watchedIDs.isEmpty ? nil : watchedIDs,
                                                 playbackOperations: playbackOperations.isEmpty ? nil : playbackOperations,
                                                 unresolvedPlaybackOperations: unresolved.isEmpty ? nil : unresolved,
                                                 watchLaterEntries: watchLaterEntries,
                                                 collectionSection: collectionSection,
                                                 listenedIDs: listenedIDs.isEmpty ? nil : listenedIDs,
                                                 collectionOrigins: collectionOrigins.isEmpty ? nil : collectionOrigins))
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription; persistenceDirty = true }
    }

    func open(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        if videoCueFocus?.entry.workID != id { videoCueFocus = nil }
        visit(id)
        if tab == .collection {
            if collectionPath.last != .work(id) { collectionPath.append(.work(id)) }
        } else if path.last != .work(id) { path.append(.work(id)) }
    }
    func toggleSaved(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        saved = catalog.canonicalIDs(saved)
        if saved.contains(id) { saved.removeAll { $0 == id } }
        else { saved.insert(id, at: 0) }
        persist()
    }
    func toggleLater(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        let entry = WatchLaterEntry.forWork(id, catalog: catalog)
        if let existing = watchLaterEntry(for: id) {
            watchLaterEntries.removeAll { $0.id == existing.id }
        } else { watchLaterEntries.insert(entry, at: 0) }
        persist()
    }
    func watchLaterEntry(for rawID: WorkID) -> WatchLaterEntry? {
        let id = catalog.canonicalID(for: rawID)
        let candidate = WatchLaterEntry.forWork(id, catalog: catalog)
        return watchLaterEntries.first { $0.id == candidate.id }
            ?? watchLaterEntries.first { $0.workID == id && $0.video == nil }
    }
    func saveForLater(_ rawID: WorkID, cue: VideoCue) {
        let id = catalog.canonicalID(for: rawID)
        var entry = WatchLaterEntry.forWork(id, catalog: catalog)
        guard cue.isValid, entry.video == cue.video else { return }
        entry.cue = cue
        if let index = watchLaterEntries.firstIndex(where: { $0.id == entry.id || ($0.workID == id && $0.video == nil) }) {
            guard watchLaterEntries[index].cue != cue else { return }
            watchLaterEntries[index] = entry
        } else { watchLaterEntries.insert(entry, at: 0) }
        persist()
    }
    func removeWatchLater(_ entryID: String) {
        guard watchLaterEntries.contains(where: { $0.id == entryID }) else { return }
        watchLaterEntries.removeAll { $0.id == entryID }
        persist()
    }
    func openWatchLater(_ requested: WatchLaterEntry) {
        guard let entry = watchLaterEntries.first(where: { $0.id == requested.id }) else { return }
        videoCueFocus = nil
        let current = WatchLaterEntry.forWork(entry.workID, catalog: catalog)
        if let video = entry.video, video != current.video {
            // Keep an earlier upload inspectable if the work's current link
            // changes. Never transpose its cue onto the replacement upload.
            savedVideoSheet = entry
        } else {
            open(entry.workID)
            if entry.cue != nil {
                videoCueFocus = VideoCueFocus(entry: entry, ownerTab: tab,
                                               destinationPath: tab == .now ? path : collectionPath)
            }
        }
    }

    /// Claim synchronously on the main actor, before any layout wait. The old
    /// tab, an earlier occurrence in this stack, and a disappeared page all
    /// leave the request intact for its intended visible destination.
    func takeVideoCueFocus(for rawID: WorkID, ownerTab: AppTab,
                           destinationPath: [Route], isVisible: Bool) -> VideoCueFocus? {
        let id = catalog.canonicalID(for: rawID)
        guard isVisible, tab == ownerTab, let request = videoCueFocus,
              request.ownerTab == ownerTab, request.destinationPath == destinationPath,
              (ownerTab == .now ? path : collectionPath) == destinationPath,
              catalog.canonicalID(for: request.entry.workID) == id,
              let cue = request.entry.cue, cue.isValid,
              cue.video == WatchLaterEntry.forWork(id, catalog: catalog).video else { return nil }
        videoCueFocus = nil
        return request
    }
    /// Completing a pending item does not change its saved-work status. A plain
    /// removal, or opening a video, never records that the user has watched it.
    func markWatched(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        guard let entry = watchLaterEntry(for: id) else { return }
        markWatchLaterEntryWatched(entry.id)
    }
    func markWatchLaterEntryWatched(_ entryID: String) {
        guard let entry = watchLaterEntries.first(where: { $0.id == entryID }) else { return }
        watchLaterEntries.removeAll { $0.id == entryID }
        let id = catalog.canonicalID(for: entry.workID)
        watchedIDs = catalog.canonicalIDs(watchedIDs)
        if !watchedIDs.contains(id) { watchedIDs.insert(id, at: 0) }
        persist()
    }
    func toggleListenLater(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        listenLater = catalog.canonicalIDs(listenLater)
        if listenLater.contains(id) { listenLater.removeAll { $0 == id } }
        else {
            guard catalog.work(id).isSong || catalog.work(id).isAlbum || catalog.work(id).isMusicWork else { return }
            listenLater.insert(id, at: 0)
        }
        persist()
    }
    func recordCollectionOrigin(_ rawID: WorkID, from entityID: String) {
        let key = catalog.canonicalID(for: rawID).rawValue
        guard collectionOrigins[key] == nil else { return }
        collectionOrigins[key] = entityID; persist()
    }
    func moveListenLater(_ id: WorkID, toPositionOf target: WorkID) {
        guard id != target, listenLater.contains(id), let index = listenLater.firstIndex(of: target) else { return }
        var ordered = listenLater
        ordered.removeAll { $0 == id }
        ordered.insert(id, at: min(index, ordered.count))
        listenLater = ordered; persist()
    }
    func moveWatchLater(_ id: String, toPositionOf target: String) {
        guard id != target, let source = watchLaterEntries.firstIndex(where: { $0.id == id }),
              let index = watchLaterEntries.firstIndex(where: { $0.id == target }) else { return }
        var ordered = watchLaterEntries
        let entry = ordered.remove(at: source)
        ordered.insert(entry, at: min(index, ordered.count))
        watchLaterEntries = ordered; persist()
    }
    func markListened(_ rawID: WorkID) {
        let id = catalog.canonicalID(for: rawID)
        guard listenLater.contains(id) else { return }
        listenLater.removeAll { $0 == id }
        if !listenedIDs.contains(id) { listenedIDs.insert(id, at: 0) }
        persist()
    }
    /// The user explicitly chose immediate playback. Failure leaves an exact
    /// Music URL available to the caller; it never triggers an automatic retry.
    func playLinkedMusic(_ rawID: WorkID) async -> Bool {
        guard playbackPlatform == .apple else { return false }
        let id = catalog.canonicalID(for: rawID)
        guard let work = catalog.works[id], work.appleMusicURL != nil,
              let selection = work.queueSelection,
              let context = beginPlaybackAction(.playNow, id: id) else { return false }
        let result = await music.playStoreSelection(selection)
        handle(result, command: .playNow, id: id, context: context)
        if case .success = result { return playbackError == nil }
        return false
    }
    func playListenLater() async -> Bool {
        guard playbackPlatform == .apple else { return false }
        let ordered = catalog.canonicalIDs(listenLater)
        // Records without an Apple Music link (a 乐曲 card, say) are skipped, not a reason to play nothing.
        let playable = ordered.filter { catalog.work($0).queueSelection != nil }
        guard let first = playable.first ?? ordered.first, let context = beginPlaybackAction(.playNow, id: first) else { return false }
        let selections = playable.compactMap { catalog.work($0).queueSelection }
        guard !selections.isEmpty else {
            handle(.failure(.init(.catalogUnavailable, "稍后听里的唱片都还没有 Apple Music 链接")), command: .playNow, id: first, context: context)
            return false
        }
        let result = await music.playCollection(selections)
        handle(result, command: .playNow, id: first, context: context)
        if case .success = result { return playbackError == nil }
        return false
    }
    func queueCollectedRecordNext(_ rawID: WorkID) {
        guard playbackPlatform == .apple else { return }
        let id = catalog.canonicalID(for: rawID)
        guard catalog.work(id).isAlbum else { queueNext(id); return }
        guard let context = beginPlaybackAction(.insertNext, id: id) else { return }
        guard let selection = catalog.work(id).queueSelection else {
            handle(.failure(.init(.catalogUnavailable, "这张唱片还没有 Apple Music 链接")), command: .insertNext, id: id, context: context)
            return
        }
        Task { handle(await music.insertCollectionNext([selection]), command: .insertNext, id: id, context: context) }
    }
    /// Fixture-only capability switch. Production capabilities always come from MusicKit.
    func setPlaybackAvailable(_ available: Bool) {
        guard demoMode else { return }
        canControlPlayback = available
        canPlayCatalog = available || initialExperience == .idle
        currentTrack = available ? playing : nil
        currentEntryID = available ? "demo:\(playing.rawValue)" : nil
        isPlaying = available
        if !available { next = nil; showNewTrack = false }
    }
    func queueNext(_ rawID: WorkID) {
        guard playbackPlatform == .apple else { return }
        let id = catalog.canonicalID(for: rawID)
        if demoMode {
            guard canQueueNext else { songSheet = id; return }
            next = id; songSheet = nil; flash("已设为下一首")
            return
        }
        guard let context = beginPlaybackAction(.insertNext, id: id) else { return }
        let work = catalog.work(id)
        guard let catalogID = work.catalogRecordingID, work.isSong else {
            handle(.failure(.init(.catalogUnavailable, "这个版本暂时不能加入 Apple Music，可以先收藏。")), command: .insertNext, id: id, context: context)
            return
        }
        Task { handle(await music.insertNext(catalogID: catalogID), command: .insertNext, id: id, context: context) }
    }
    func startNow(_ rawID: WorkID) {
        if playbackPlatform != .apple { listen(rawID); return }
        let id = catalog.canonicalID(for: rawID)
        if demoMode {
            guard canPlayCatalog else { songSheet = id; return }
            if next == id { next = nil }
            playing = id; currentTrack = id; canControlPlayback = true; isPlaying = true; songSheet = nil
            currentEntryID = "demo:\(id.rawValue)"
            showNewTrack = reading != id
            return
        }
        guard let context = beginPlaybackAction(.playNow, id: id) else { return }
        let work = catalog.work(id)
        guard let catalogID = work.catalogRecordingID, work.isSong else {
            handle(.failure(.init(.catalogUnavailable, "这个版本暂时不能在 Apple Music 中播放。")), command: .playNow, id: id, context: context)
            return
        }
        Task { handle(await music.playNow(catalogID: catalogID), command: .playNow, id: id, context: context) }
    }
    func skip() {
        guard canControlPlayback else { return }
        if demoMode {
            playing = next ?? (playing == .pool ? .jane : .distance)
            currentTrack = playing; next = nil; showNewTrack = reading != playing
            currentEntryID = "demo:\(playing.rawValue)"
            return
        }
        guard let context = beginPlaybackAction(.skipToNext, id: nil) else { return }
        Task { handle(await music.skipToNext(), command: .skipToNext, id: nil, context: context) }
    }
    func followPlayback() {
        guard let currentTrack else { return }
        explore(currentTrack)
        showNewTrack = false
    }
    func flash(_ text: String) {
        flashTask?.cancel()
        notice = text
        flashTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if self?.notice == text { self?.notice = nil }
        }
    }
}

private extension Route {
    var workID: WorkID {
        switch self {
        case .work(let id), .connections(let id): id
        }
    }
}

/// Only explicit, sourced edges are stored. Sharing a neighbor does not create a new edge.
enum RelationKind: String, Codable, Sendable {
    case composedBy, performedBy, inAlbum, soundtrackOf, endingOf, adaptedFrom
    case directedBy, authoredBy, arrangedBy, techniqueReference, liked, interviewMention
    case artistIdentity, soundtrackRelease, themeMusic, musicVideoOf, commissionReference, songContext, publicRelation
    case performanceOf, coverOf, remixOf, partOf, usedIn, samplesFrom
}

struct RelationEdge: Identifiable, Codable, Equatable, Sendable {
    let from: WorkID
    let to: WorkID
    let predicate: RelationKind
    let label: String
    let inverseLabel: String
    let source: Source
    /// Owns a report's nested edges. Replacing it cannot delete another recording's facts.
    var researchRoot: WorkID? = nil
    var id: String { "\(from.rawValue)-\(predicate.rawValue)-\(to.rawValue)" + (predicate == .publicRelation ? "-" + label : "")
        + (source.title == "线索" ? source.researchProvider.map { "|provider:" + $0 } ?? "" : "")
        + (researchRoot.map { "|owner:" + $0.rawValue } ?? "") }
    func other(than id: WorkID) -> WorkID { id == from ? to : from }
    func label(from id: WorkID) -> String { id == from ? label : inverseLabel }
}

@MainActor enum Relations {
    static var edges: [RelationEdge] { CatalogStore.shared.edges }
    static let seeds: [RelationEdge] = [
        edge(.pool, .film, .soundtrackOf, "配乐来自", "电影配乐", .movie),
        edge(.pool, .ushio, .composedBy, "作曲", "创作", .interview),
        edge(.animenz, .pool, .adaptedFrom, "原曲", "钢琴改编", .animenz),
        edge(.pool, .poolAlbum, .inAlbum, "收录于", "收录歌曲", musicSource(.pool)),
        edge(.ourFilm, .film, .soundtrackOf, "配乐来自", "电影配乐", .interview),
        edge(.slow, .film, .soundtrackOf, "配乐来自", "电影配乐", .interview),
        edge(.ourFilm, .ushio, .composedBy, "作曲", "创作", .interview),
        edge(.slow, .ushio, .composedBy, "作曲", "创作", .interview),
        edge(.ourFilm, .poolAlbum, .inAlbum, "收录于", "收录歌曲", musicSource(.ourFilm)),
        edge(.slow, .poolAlbum, .inAlbum, "收录于", "收录歌曲", musicSource(.slow)),
        edge(.jane, .film, .endingOf, "片尾曲来自", "片尾曲", .jane),
        edge(.jane, .yonezu, .composedBy, "词曲与演唱", "词曲与演唱", .jane),
        edge(.jane, .utada, .performedBy, "合作演唱", "合作演唱", .jane),
        edge(.jane, .janeAlbum, .inAlbum, "收录于", "收录歌曲", musicSource(.jane)),
        edge(.jane, .distance, .interviewMention, "合作访谈中提及", "在这次合作的访谈中提到", .gq),
        edge(.yonezu, .distance, .liked, "提到喜欢", "米津提到喜欢", .gq),
        edge(.distance, .utada, .performedBy, "演唱", "演唱作品", musicSource(.distance)),
        edge(.distance, .distanceAlbum, .inAlbum, "收录于", "收录歌曲", musicSource(.distance)),
        edge(.film, .manga, .adaptedFrom, "原作", "改编电影", .movie),
        edge(.film, .yoshihara, .directedBy, "导演", "导演作品", .movie),
        edge(.manga, .fujimoto, .authoredBy, "作者", "漫画作品", .movie),
        edge(.animenz, .animenzPerson, .arrangedBy, "改编与演奏", "改编与演奏", .animenz),
        edge(.animenz, .ravel, .techniqueReference, "借鉴写法", "在改编说明中被提及", .animenz),
        edge(.animenz, .debussy, .techniqueReference, "借鉴写法", "在改编说明中被提及", .animenz)
    ]
    static func forEntity(_ id: WorkID) -> [RelationEdge] { edges.filter { $0.from == id || $0.to == id } }
    static func sources(for id: WorkID) -> [Source] {
        var seen = Set<String>()
        var sources = forEntity(id).map(\.source) + CatalogStore.shared.stories.filter { $0.workID == id }.flatMap { [$0.source] + ($0.additionalSources ?? []) }
        if sources.isEmpty, let url = id.work.url {
            sources.append(Source(title: id.work.title, detail: "作品资料", url: url))
        }
        return sources.filter { seen.insert($0.id).inserted }
    }
    private static func edge(_ from: WorkID, _ to: WorkID, _ predicate: RelationKind, _ label: String, _ inverse: String, _ source: Source) -> RelationEdge {
        RelationEdge(from: from, to: to, predicate: predicate, label: label, inverseLabel: inverse, source: source)
    }
    private static func musicSource(_ id: WorkID) -> Source {
        Source(title: "\(Work.seeds[id]!.title) · Apple Music", detail: "歌曲、歌手与发行信息", url: Work.seeds[id]!.url!)
    }
}
