import SwiftUI
import UIKit

/// A name tapped in a story whose identity is not known yet (anson 2026-11-18: the grey
/// 打开/搜索/复制 sheet is gone). The same catalogues the 搜索 tab asks: the listening
/// platform's songs, artists and albums, and Wikidata's films, series, games and books, in
/// the shop's own look. Choosing a row opens that page; nothing is joined by title alone.
/// A name whose identity is already known never comes here: it opens its page directly.
struct NameLookupSheet: View {
    let name: String
    let onSelect: (WorkID) -> Void
    @Environment(Library.self) private var library
    @State private var model = UnifiedSearchModel()

    /// Groups that carry the name itself come first; then artists, songs, albums and other works.
    /// Within a group, rows that carry the name (in the title or the credit) are shown and the
    /// catalogue's looser guesses are left out; when no row carries it, the guesses are all there is.
    private var sections: [(UnifiedSearchSection, [WorkID])] {
        let wanted = LeadMatch.norm(name)
        func carries(_ id: WorkID) -> Bool {
            let work = library.catalog.work(id)
            let title = LeadMatch.norm(SongTitlePresentation(work.title).title), full = LeadMatch.norm(work.title)
            return !wanted.isEmpty && (title == wanted || full.contains(wanted) || LeadMatch.norm(work.creator).contains(wanted))
        }
        func exact(_ id: WorkID) -> Bool {
            let work = library.catalog.work(id)
            return LeadMatch.norm(SongTitlePresentation(work.title).title) == wanted || LeadMatch.norm(work.title) == wanted
        }
        let order: [UnifiedSearchSection] = [.artists, .songs, .albums, .screen, .games, .books]
        var groups = order.compactMap { section -> (UnifiedSearchSection, [WorkID], Bool)? in
            let ids = ids(for: section)
            guard !ids.isEmpty else { return nil }
            let named = ids.filter(carries)
            let shown = named.isEmpty ? ids : named.filter(exact) + named.filter { !exact($0) }
            return (section, shown, named.contains(where: exact))
        }
        // Once some group carries the name, groups of mere guesses add nothing.
        let anyNamed = groups.contains { group in group.1.contains(where: carries) }
        if anyNamed { groups.removeAll { group in !group.1.contains(where: carries) } }
        return (groups.filter { $0.2 } + groups.filter { !$0.2 }).map { ($0.0, $0.1) }
    }
    private func ids(for section: UnifiedSearchSection) -> [WorkID] {
        let remote = model.remote[section] ?? []
        let local = library.catalog.localMatches(name).filter {
            !remote.contains($0) && UnifiedSearchSection.of(library.catalog.work($0)) == section
        }
        var seen = Set<WorkID>()
        return (remote + local.prefix(3)).filter { seen.insert(library.catalog.canonicalID(for: $0)).inserted }
    }

    var body: some View {
        let groups = sections
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 22, weight: .semibold)).foregroundStyle(ShopStyle.ink).lineLimit(2)
                .padding(.horizontal, 22).padding(.top, 30).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            List {
                ForEach(groups, id: \.0) { group in
                    Section {
                        ForEach(Array(group.1.prefix(group.0 == groups.first?.0 ? 4 : 3))) { row($0) }
                    } header: {
                        Text(group.0.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ShopStyle.secondary)
                            .textCase(nil).padding(.top, 2)
                    }
                }
                status(empty: groups.isEmpty)
            }
            .listStyle(.plain).listSectionSpacing(.compact).scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ShopStyle.ink)
        .task { model.run(name, scope: .all, library: library) }
        .onDisappear { model.cancel() }
        .accessibilityIdentifier("name-lookup")
    }

    @ViewBuilder private func status(empty: Bool) -> some View {
        if !model.pending.isEmpty {
            line(empty ? "在找…" : "还在找…").accessibilityIdentifier("name-lookup-pending")
        } else if empty, model.failed.isEmpty {
            line("没找到这个名字").accessibilityIdentifier("name-lookup-empty")
        } else if empty {
            HStack(spacing: 4) {
                Text("没连上资料 ·").foregroundStyle(ShopStyle.tertiary)
                Button("再找一次") { model.run(name, scope: .all, library: library) }
                    .buttonStyle(.plain).foregroundStyle(ShopStyle.accent)
            }
            .font(.system(size: 13)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            .accessibilityIdentifier("name-lookup-failed")
        }
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(ShopStyle.tertiary)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
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
        return Button { onSelect(id) } label: {
            HStack(spacing: 14) {
                ShopObject(entity: entity, height: 56).shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 2)
                    .frame(width: 60, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entity.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ShopStyle.ink).lineLimit(2)
                    Text([kindWord(work), creator == kindWord(work) ? "" : creator].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(ShopStyle.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(ShopStyle.line).frame(height: 0.5).padding(.leading, 74) }
        .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 18))
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
        .accessibilityIdentifier("name-lookup-\(id.rawValue)")
    }
}

/// 深挖 sits on the page itself (anson 11-18 14:20): beside 「没找到有出处的幕后」, and as the last
/// tile of the bin in place of 再翻一箱. The price is confirmed every time; nothing is shown after.
struct DeepDiveConfirmation: ViewModifier {
    let entity: SeedGraph.Entity
    @Binding var isPresented: Bool
    @Environment(Library.self) private var library
    @Environment(LeadResearch.self) private var research
    /// Cheap enough to read in a page body: no keychain read (`hasModel` is the settings' cached flag).
    @MainActor static func available(_ entity: SeedGraph.Entity, hasModel: Bool, library: Library, research: LeadResearch) -> Bool {
        let seed = SeedNowContent.contains(entity.id) && RecordShopArtReview.current == nil
        // Once a 深挖 has run, a second one would search the same way again: none is offered.
        return !seed && hasModel && research.state(entity.id) != .loading && research.jobs.values[entity.id]?.deepened != true
            && research.subject(entity.id, library: library) != nil
    }
    func body(content: Content) -> some View {
        content.confirmationDialog("深挖《\(SongTitlePresentation(entity.title, isSong: entity.kind == .song).title)》", isPresented: $isPresented, titleVisibility: .visible) {
            Button("深挖") {
                guard let subject = research.subject(entity.id, library: library) else { return }
                Task { await research.deepDive(subject, library: library) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text((research.deepEstimate?.text ?? "") + "\n再找一遍原曲、采样、同作歌曲和幕后。已找到的不会被替换。")
        }
    }
}

/// One line after a 深挖: what it found. The cost is in 设置 › 用量, not here (anson 11-18 14:20).
struct DeepDiveReceiptHook: ViewModifier {
    @Binding var toast: String?
    let research: LeadResearch
    func body(content: Content) -> some View {
        content.onChange(of: research.deepReceipt?.id) { _, _ in
            guard let receipt = research.deepReceipt else { return }
            if receipt.failed { toast = "深挖没有完成" + (receipt.reason.map { "：" + $0 } ?? ""); return }
            var parts = [receipt.newCards > 0 ? "新增 \(receipt.newCards) 张" : "没有新的卡"]
            if receipt.storyAdded { parts.append("找到幕后") }
            toast = "深挖完成 · " + parts.joined(separator: " · ")
        }
    }
}
