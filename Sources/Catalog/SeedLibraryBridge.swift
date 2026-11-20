import Foundation

/// Explicit identity bridge. Similar names never establish identity: notably
/// the seed's Distance album is not the legacy FINAL DISTANCE recording.
enum SeedLibraryBridge {
    /// A regional catalog lookup or a translated person label must not rewrite
    /// what Apple Music says is playing. Keep the reading object independent.
    @MainActor static func playbackEntity(in library: Library) -> SeedGraph.Entity? {
        guard let id = library.currentTrack else { return nil }
        let base = entity(for: id, in: library)
        guard let metadata = library.currentPlaybackMetadata else { return base }
        let art = metadata.artworkAsset ?? ArtworkLocation.remoteURL(metadata.artworkURL)?.absoluteString ?? base.artworkAsset
        return presentingVersion(.init(id: base.id, kind: base.kind,
            title: metadata.title.isEmpty ? base.title : metadata.title,
            subtitle: metadata.artist.isEmpty ? base.subtitle : metadata.artist,
            artworkAsset: art, fallbackGlyph: base.fallbackGlyph, hook: base.hook, actions: base.actions))
    }
    @MainActor static func entity(for rawID: WorkID, in library: Library) -> SeedGraph.Entity {
        let id = library.catalog.canonicalID(for: rawID)
        if let seed = (SeedGraph.bundled.entities + SeedNowContent.extras).first(where: {
            library.catalog.canonicalID(for: workID($0.id)) == id
        }) { return presentingVersion(seed) }
        let work = library.catalog.work(id)
        let kind: SeedGraph.Kind = work.isPerson ? .person : work.isVideo ? .video : work.isAlbum ? .album : work.isSong || ["音乐作品", "乐章"].contains(work.kind) ? .song :
            work.kind == "游戏" ? .game :
            work.kind == "漫画" ? .manga : work.kind == "电视剧" ? .tv : ["电影", "动画"].contains(work.kind) ? .film : .book
        return presentingVersion(.init(id: id.rawValue, kind: kind, title: VerifiedDisplayName.title(work, catalog: library.catalog), subtitle: VerifiedDisplayName.creator(work, catalog: library.catalog),
                     artworkAsset: ArtworkLocation.displayValue(for: work, catalog: library.catalog)
                        ?? VerifiedArtworkAssets.asset(for: id) ?? appleArtistPhoto(work),
                     fallbackGlyph: nil, hook: "", actions: kind.isMusic ? (id.rawValue.hasPrefix("lead:") ? ["收藏"] : ["下一首播放", "收藏"])
                        : [.person, .group].contains(kind) ? []
                        : kind == .video ? ["播放视频", "想看"] : [WorkVerb.save(kind) ?? "想看"]))
    }
    /// iTunes artists: the Apple Music header photo for that exact artist ID.
    @MainActor private static func appleArtistPhoto(_ work: Work) -> String? {
        guard let artistID = work.appleArtistID else { return nil }
        guard let url = WorkArtworkStore.shared.appleArtists[artistID], !url.isEmpty else { return nil }
        return url
    }
    private static func presentingVersion(_ entity: SeedGraph.Entity) -> SeedGraph.Entity {
        let display = SongTitlePresentation(entity.title, isSong: entity.kind == .song)
        return .init(id: entity.id, kind: entity.kind, title: display.title,
                     subtitle: display.identity(creator: entity.subtitle), artworkAsset: entity.artworkAsset,
                     fallbackGlyph: entity.fallbackGlyph, hook: entity.hook, actions: entity.actions)
    }
    static func workID(_ entityID: String) -> WorkID {
        switch entityID {
        case "pool": .pool
        case "film": .film
        case "jane": .jane
        case "summer": .poolAlbum
        case "ushio": .ushio
        case "animenzv": .animenz
        case "animenz": .animenzPerson
        case "manga": .manga
        case "fujimoto": .fujimoto
        case "yoshihara": .yoshihara
        case "yonezu": .yonezu
        case "utada": .utada
        case "janemv": .janeMV
        case "olk": WorkID(rawValue: "editorial:one-last-kiss")!
        case "olkmv": WorkID(rawValue: "editorial:one-last-kiss-mv")!
        default:
            if entityID.contains(":"), let id = WorkID(rawValue: entityID) { id }
            else { WorkID(rawValue: "design-seed:" + entityID)! }
        }
    }
    @MainActor static func install(_ entity: SeedGraph.Entity, into library: Library) throws -> WorkID {
        let id = workID(entity.id)
        guard library.catalog.works[library.catalog.canonicalID(for: id)] == nil else { return id }
        let kind: String = switch entity.kind {
        case .song: "歌曲"
        case .album: "专辑"
        case .film: "电影"
        case .tv: "电视剧"
        case .game: "游戏"
        case .book: "书籍"
        case .manga: "漫画"
        case .person, .group: "创作者"
        case .video: "演奏视频"
        }
        let work = Work(id: id, title: entity.title, creator: entity.subtitle, kind: kind,
                        art: entity.artworkAsset ?? "", detail: "", url: nil, linkedCreatorIDs: [])
        try library.catalog.merge(CatalogSnapshot(works: [work], relations: []))
        return id
    }
    /// Music goes into 收藏 (anson 2026-11-20: no 稍后听; Apple Music's 插播 is 下一首播放), the rest into 想看 / 想玩 / 想读.
    @MainActor static func save(_ entity: SeedGraph.Entity, into library: Library) throws {
        let id = library.catalog.canonicalID(for: try install(entity, into: library))
        if entity.kind.isMusic {
            if !library.catalog.canonicalIDs(library.saved).contains(id) { library.toggleSaved(id) }
        } else if library.watchLaterEntry(for: id) == nil { library.toggleLater(id) }
    }
    @MainActor static func saved(_ entity: SeedGraph.Entity, in library: Library) -> Bool {
        let id = library.catalog.canonicalID(for: workID(entity.id))
        return entity.kind.isMusic ? library.catalog.canonicalIDs(library.saved).contains(id) : library.watchLaterEntry(for: id) != nil
    }
    /// Takes a work back out of 收藏 / 想看 (a second tap on a saved button).
    @MainActor static func unsave(_ entity: SeedGraph.Entity, in library: Library) {
        let id = library.catalog.canonicalID(for: workID(entity.id))
        if entity.kind.isMusic {
            if library.catalog.canonicalIDs(library.saved).contains(id) { library.toggleSaved(id) }
        } else if let entry = library.watchLaterEntry(for: id) { library.removeWatchLater(entry.id) }
    }
}
