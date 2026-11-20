import SwiftUI

/// Douban's words for setting a work aside and for having finished it, by what the work is.
/// One saved list underneath (收藏 for music, the watch-later entries for the rest);
/// only the word shown follows the kind (2026-11-16 anson 经 Claude, MAP-COLLECTION-DESIGN §3.2).
enum WorkVerb {
    static func save(_ kind: SeedGraph.Kind) -> String? {
        switch kind {
        case .song, .album: "收藏"
        case .game: "想玩"
        case .book, .manga: "想读"
        case .film, .tv, .video: "想看"
        case .person, .group: nil
        }
    }
    static func done(_ kind: SeedGraph.Kind) -> String {
        switch kind {
        case .song, .album: "听过"
        case .game: "玩过"
        case .book, .manga: "读过"
        default: "看过"
        }
    }
    static let saveActions: Set<String> = ["收藏", "稍后听", "稍后看", "想看", "想玩", "想读"]
    static func isSave(_ action: String) -> Bool { saveActions.contains(action) }
    static func saved(_ action: String) -> String { action == "收藏" ? "已收藏" : "已在" + (action == "稍后看" ? "想看" : action) }
    /// The button's mark: a star for 收藏, a bookmark for the rest; filled once saved.
    static func symbol(_ action: String, saved: Bool) -> String { action == "收藏" ? (saved ? "star.fill" : "star") : (saved ? "checkmark" : "bookmark") }
    /// 「想看 · 想玩」: the words for the kinds actually present, in a fixed order.
    static func joined(_ kinds: [SeedGraph.Kind], _ word: (SeedGraph.Kind) -> String?) -> String {
        let order = ["想看", "想玩", "想读", "看过", "玩过", "读过"]
        let present = Set(kinds.compactMap(word))
        let words = order.filter(present.contains)
        return words.isEmpty ? (word(.film) ?? "") : words.joined(separator: " · ")
    }
}

@MainActor enum EntityActions {
    static func playbackID(_ entity: SeedGraph.Entity, library: Library) -> WorkID? {
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        if work.isMusicWork { return RecordingVersionsStore.shared.preferredRecording(for: work, library: library) }
        if work.isSong, library.playbackPlatform != .apple || work.appleMusicURL != nil { return work.id }
        if work.isAlbum, library.playbackPlatform == .apple, work.appleMusicURL != nil { return work.id }
        return nil
    }
    static func labels(_ entity: SeedGraph.Entity, library: Library) -> [String] {
        let work = library.catalog.work(SeedLibraryBridge.workID(entity.id))
        // Nothing to queue until a playable version is known (anson 11-18 14:20: the button
        // did nothing visible on such pages). The page offers 能听的版本 instead.
        // 收藏 for music is the ☆ beside the song on its relation-map card (anson 11-20), not a button here.
        if work.isMusicWork {
            return playbackID(entity, library: library) == nil ? [] : [library.playbackPlatform.listenTitle]
        }
        if library.playbackPlatform != .apple {
            if work.isSong { return [library.playbackPlatform.listenTitle] }
            if work.isAlbum { return [] }
        }
        if work.isSong, work.appleMusicURL != nil { return ["播放", "下一首播放"] }
        if work.isAlbum, work.appleMusicURL != nil { return ["播放"] }
        if entity.kind.isMusic, work.isSong || work.isAlbum, !library.demoMode { return [] }
        // Public artist lookup is a bounded selection, never a complete catalog.
        let publicArtist = entity.kind == .person && (SeedNowContent.entity(entity.id) == nil || library.catalog.work(SeedLibraryBridge.workID(entity.id)).catalogSource?.title == "iTunes")
        var authored = publicArtist ? ["在 Apple Music 打开"] : entity.kind == .person ? ["在 Apple Music 打开", "看全部作品"] : entity.actions
        // Every work that is not a person can be set aside, whatever its ID looks like,
        // and the button says it the way that kind is said (想看 / 想玩 / 想读).
        if !entity.kind.isMusic, let verb = WorkVerb.save(entity.kind) {
            authored = authored.filter { !WorkVerb.isSave($0) }
            authored.insert(verb, at: authored.first == "播放视频" ? 1 : 0)
        }
        var seen = Set<String>()
        return authored.filter { action in
            seen.insert(action).inserted
                && (action != "下一首播放" || library.playbackPlatform == .apple)
                && (WorkVerb.isSave(action) || ["下一首播放", "看全部作品"].contains(action) || destination(action, entity, library: library) != nil)
        }
    }
    static func destination(_ action: String, _ entity: SeedGraph.Entity, library: Library) -> URL? {
        if action == "豆瓣", entity.id == "film" { return URL(string: "https://movie.douban.com/subject/37291780/") }
        let id = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
        guard let work = library.catalog.works[id] else { return nil }
        if action == "播放" || action == "在 Apple Music 打开" { return work.appleMusicURL }
        guard let raw = work.url, let url = URL(string: raw), let host = url.host else { return nil }
        switch action {
        case "豆瓣": return host == "douban.com" || host.hasSuffix(".douban.com") ? url : nil
        case "播放视频", "看频道": return ["youtube.com", "youtu.be", "bilibili.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) ? url : nil
        default: return nil
        }
    }
}

struct EntityActionButtons: View {
    let entity: SeedGraph.Entity
    var queued = false
    var saved = false
    /// Links shown by the page itself (see WorkDestinations), left out here.
    var excluding: Set<String> = []
    var onNext: (SeedGraph.Entity) -> Void
    var onSave: (SeedGraph.Entity) -> Void
    var onWorks: () -> Void
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var failedURL: URL?
    @State private var showFailure = false
    @State private var browser: StorySourcePage?
    var body: some View {
        HStack(spacing: 10) {
            ForEach(EntityActions.labels(entity, library: library).filter { !excluding.contains($0) }, id: \.self) { action in
                let isSaved = saved || SeedLibraryBridge.saved(entity, in: library)
                let completed = action == "下一首播放" ? queued : WorkVerb.isSave(action) && isSaved
                Button {
                    switch action {
                    case _ where action == library.playbackPlatform.listenTitle:
                        library.listen(SeedLibraryBridge.workID(entity.id))
                    case "下一首播放": onNext(entity)
                    case _ where WorkVerb.isSave(action):
                        // A second tap takes it back out; the button itself shows the change.
                        if isSaved { SeedLibraryBridge.unsave(entity, in: library) } else { onSave(entity) }
                    case "看全部作品": onWorks()
                    default: if let url = EntityActions.destination(action, entity, library: library) { open(url) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if action == library.playbackPlatform.listenTitle { Image(systemName: "play.fill") }
                        if completed { Image(systemName: "checkmark").font(.system(size: 11.5, weight: .semibold)) }
                        Text(completed ? (action == "下一首播放" ? "已排下一首" : WorkVerb.saved(action)) : action)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }.font(.system(size: 13.5, weight: .medium)).frame(maxWidth: .infinity, minHeight: 38)
                }.buttonStyle(.plain)
                    .foregroundStyle(action == library.playbackPlatform.listenTitle ? ShopStyle.accent : ShopStyle.ink)
                    .glassEffect(action == library.playbackPlatform.listenTitle ? .regular.tint(ShopStyle.accent.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
                    .disabled(action == "下一首播放" && completed || ["播放", "下一首播放"].contains(action) && library.playbackBusy)
                    .accessibilityIdentifier("entity-action-" + action)
            }
        }
        .confirmationDialog("没能打开 Apple Music", isPresented: $showFailure, titleVisibility: .visible) {
            if let failedURL { Button("在 Safari 打开") { browser = .init(url: failedURL) } }
        }
        .sheet(item: $browser) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
    }
    private func open(_ url: URL) { openURL(url) { if !$0 { failedURL = url; showFailure = true } } }
}

/// ☆ in a song's page and in its relation map's top bar: 收藏 the song together with its map
/// (anson 2026-11-20). A second tap takes it back out; the star shows which.
struct ShopStarAction: View {
    let entity: SeedGraph.Entity
    let onSave: (SeedGraph.Entity) -> Void
    @Environment(Library.self) private var library
    var body: some View {
        let saved = SeedLibraryBridge.saved(entity, in: library)
        Button { if saved { SeedLibraryBridge.unsave(entity, in: library) } else { onSave(entity) } } label: {
            Image(systemName: saved ? "star.fill" : "star")
        }
        .foregroundStyle(ShopStyle.ink)
        .accessibilityLabel(saved ? "取消收藏" : "收藏").accessibilityIdentifier("page-star")
    }
}
