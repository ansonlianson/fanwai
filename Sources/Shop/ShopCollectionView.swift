import SwiftUI

/// 收藏 (anson 2026-11-20): the songs you starred, each with the relation map you dug from it, and
/// the films, games and books you want to get to, face-out on shelves so all of them are in view.
/// No 稍后听 (Apple Music's own 插播 takes its place), no 听过 (搜索 › 最近 lists what you opened),
/// no shelf for what you finished, and no written commentary under the works: name and maker only.
/// Every work opens to its page; actions live in the note beside it (no separate edit mode).
struct ShopCollectionView: View {
    var onOpen: (WorkID) -> Void
    var onTrail: (String) -> Void
    var onNext: (WorkID) -> Void
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var annotating: String?
    @State private var showingSettings = false

    fileprivate struct Item: Identifiable {
        let id: String
        let work: WorkID
        let entity: SeedGraph.Entity
        let caption: String
        let actions: [ShopNoteAction]
    }

    private func isMusic(_ id: WorkID) -> Bool {
        let work = library.catalog.work(id)
        return work.isSong || work.isAlbum || work.isMusicWork
    }
    private var songs: [WorkID] { library.catalog.canonicalIDs(library.saved).filter(isMusic) }
    private var isEmpty: Bool { songs.isEmpty && library.watchLaterEntries.isEmpty }
    /// Each starred song's map, found by the song itself whatever ID the map was saved under.
    private func starredMaps() -> [WorkID: String] {
        let trails = RelationTrailStore()
        var found: [WorkID: String] = [:]
        for root in library.starredTrailRoots(trails.roots()) where (trails.load(root: root)?.nodes.count ?? 0) > 1 {
            found[library.catalog.canonicalID(for: SeedLibraryBridge.workID(root))] = root
        }
        return found
    }

    var body: some View {
        GeometryReader { geo in
            let maps = starredMaps()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    if isEmpty { emptyShelf(width: geo.size.width) }
                    if !songs.isEmpty {
                        section("音乐", songs.count) { ShopWall(items: songs.map { songItem($0, map: maps[$0]) }, width: geo.size.width, annotating: $annotating) }
                    }
                    ForEach(wishGroups, id: \.verb) { group in
                        section(group.verb, group.items.count) { ShopWall(items: group.items, width: geo.size.width, annotating: $annotating) }
                    }
                }
                .padding(.top, 6).padding(.bottom, 170)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .accessibilityIdentifier("wall-scroll")
        }
        .background { ShopPageBackdrop() }
        .foregroundStyle(ShopStyle.ink)
        .navigationTitle("收藏").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置").accessibilityIdentifier("collection-settings")
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, _ count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 19, weight: .semibold))
                Text("\(count)").font(.system(size: 13)).foregroundStyle(ShopStyle.tertiary)
            }.padding(.horizontal, 24)
            content()
        }
    }

    /// Nothing kept yet: the shelf itself, bare, and one line on how things get onto it.
    private func emptyShelf(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("还没有收藏").font(.system(size: 17, weight: .semibold))
                Text("在关系图里点歌名旁的 \(Image(systemName: "star")) 收藏一首歌；电影、书和游戏点「想看」「想读」「想玩」。")
                    .font(.system(size: 14)).foregroundStyle(ShopStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.bottom, 64)
            ShopPlank(width: width)
        }.padding(.top, 28).accessibilityIdentifier("wall-empty")
    }

    private var wishGroups: [(verb: String, items: [Item])] {
        let list = library.watchLaterEntries
        return ["想看", "想玩", "想读"].compactMap { verb in
            let items = list.compactMap { entry -> Item? in
                let e = SeedLibraryBridge.entity(for: entry.workID, in: library)
                guard WorkVerb.save(e.kind) == verb else { return nil }
                return Item(id: entry.id, work: entry.workID, entity: e, caption: e.subtitle, actions: watchActions(entry, entity: e))
            }
            return items.isEmpty ? nil : (verb, items)
        }
    }

    private func songItem(_ id: WorkID, map: String?) -> Item {
        let e = SeedLibraryBridge.entity(for: id, in: library)
        // The map dug from this song, as it was last left (anson 11-20: it follows later digging).
        var actions = [ShopNoteAction(title: "打开", symbol: "arrow.up.right") { onOpen(id) }]
        if let map { actions.append(ShopNoteAction(title: "关系图", symbol: "point.3.connected.trianglepath.dotted") { onTrail(map) }) }
        if library.catalog.work(id).isSong {
            if library.playbackPlatform == .apple {
                if library.next != id { actions.append(ShopNoteAction(title: "下一首播放", symbol: "text.line.first.and.arrowtriangle.forward") { onNext(id) }) }
            } else {
                actions.append(ShopNoteAction(title: library.playbackPlatform.listenTitle, symbol: "play.fill") { library.listen(id) })
            }
        }
        actions.append(ShopNoteAction(title: "移出", symbol: "star.slash", role: .destructive) { library.toggleSaved(id) })
        return Item(id: id.rawValue, work: id, entity: e, caption: e.subtitle, actions: actions)
    }

    private func watchActions(_ entry: WatchLaterEntry, entity: SeedGraph.Entity) -> [ShopNoteAction] {
        var actions = [ShopNoteAction(title: "打开", symbol: "arrow.up.right") { onOpen(entry.workID) }]
        if let link = WorkDestinations.links(entity, library: library, lead: nil).first {
            actions.append(ShopNoteAction(title: link.title, symbol: link.symbol) { openURL(link.url) })
        }
        actions.append(ShopNoteAction(title: "移出", symbol: "minus.circle", role: .destructive) { library.removeWatchLater(entry.id) })
        return actions
    }
}

/// A plank of the shop's own wood, the width of the screen.
struct ShopPlank: View {
    let width: CGFloat
    var body: some View {
        Image(uiImage: UIImage(named: "shelf-plank") ?? UIImage())
            .resizable().frame(width: width, height: 20)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14).offset(y: 14)
            }
            .accessibilityHidden(true)
    }
}

/// Works face-out, three to a shelf, each with its name under the plank; everything in view.
private struct ShopWall: View {
    let items: [ShopCollectionView.Item]
    let width: CGFloat
    @Binding var annotating: String?
    private let columns = 3, side: CGFloat = 22, gap: CGFloat = 16, objectHeight: CGFloat = 112

    var body: some View {
        let cell = (width - side * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: 26) {
            ForEach(rows.indices, id: \.self) { r in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(rows[r]) { item in
                            // A CD case is wider than tall; it gets a lower height so three fit a shelf.
                            ShopObject(entity: item.entity, height: item.entity.kind.isMusic ? objectHeight * 0.86 : objectHeight)
                                .shadow(color: .black.opacity(0.55), radius: 6, x: 2, y: 4)
                                .frame(width: cell, height: objectHeight, alignment: .bottom)
                                .overlay(alignment: .topLeading) {
                                    GeometryReader { g in
                                        ShopNoteHit(id: item.id, title: item.entity.title, caption: item.caption,
                                                    note: "", rect: CGRect(origin: .zero, size: g.size), namespace: nil, annotating: $annotating, actions: item.actions)
                                    }
                                }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, side).padding(.bottom, -3)
                    ShopPlank(width: width)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(rows[r]) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(SongTitlePresentation(item.entity.title).title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(item.caption).font(.system(size: 11)).foregroundStyle(ShopStyle.secondary).lineLimit(1)
                            }.frame(width: cell, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, side).padding(.top, 14)
                }
            }
        }
    }
}
