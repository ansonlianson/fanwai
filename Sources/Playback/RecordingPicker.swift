import SwiftUI
import UIKit

/// Public catalog candidates stay a user choice. Opening one does not assert
/// that it is the sourced recording, nor add a made-up performance relation.
struct RecordingPicker: View {
    let entityID: String
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var versions = RecordingVersionsStore.shared
    @State private var loading = true
    @State private var failed: StorySourcePage?
    @State private var browser: StorySourcePage?
    @State private var showFailure = false
    private var work: Work { library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entityID))) }
    private var entries: RecordingVersionsStore.Versions {
        _ = versions.revision
        return versions.versions(for: work, library: library)
    }
    var body: some View {
        let known = entries.known, candidates = entries.candidates
        NavigationStack {
            List {
                if !known.isEmpty {
                    Section("能听的版本") { ForEach(known, id: \.self) { row($0) } }
                }
                if !candidates.isEmpty {
                    Section("目录里找到的版本") { ForEach(candidates, id: \.self) { row($0) } }
                }
                if loading && known.isEmpty && candidates.isEmpty { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                else if known.isEmpty && candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(library.playbackPlatform.title) 里没有这首").foregroundStyle(.secondary)
                        ElsewhereSearch(title: ElsewhereSearch.title(work), artist: work.creator)
                    }.listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden).background(ShopNowPage.base)
            .navigationTitle("能听的版本").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { dismiss() }.tint(.primary) } }
        }
        .preferredColorScheme(.dark).presentationDetents([.medium, .large])
        .task(id: entityID) { await load() }
        .confirmationDialog("没能打开 Apple Music", isPresented: $showFailure, titleVisibility: .visible) {
            if let failed { Button("在 Safari 打开") { browser = failed } }
        }
        .sheet(item: $browser) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
        .accessibilityIdentifier("recording-picker")
    }
    private func row(_ id: WorkID) -> some View {
        let record = library.catalog.work(id)
        let album = record.albumID.map { library.catalog.work($0).title } ?? ""
        return Button {
            dismiss()
            library.listen(id)
        } label: {
            HStack(spacing: 12) {
                ShopCover(artwork: record.art, title: record.title, workID: id).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).foregroundStyle(ArtworkPalette.tx).lineLimit(2).truncationMode(.middle)
                    Text([record.creator, album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    let year = record.releaseDate.map { String($0.prefix(4)) } ?? ""
                    let detail = [!year.isEmpty && !record.detail.contains(year) ? year : "", record.detail]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if library.currentTrack.map({ library.catalog.canonicalID(for: $0) == id }) == true {
                    Image(systemName: "speaker.wave.2.fill").accessibilityLabel("正在听这版")
                } else { Image(systemName: "play.fill") }
            }
        }.disabled(library.playbackBusy).accessibilityIdentifier("recording-choice-" + id.rawValue)
    }
    private func load() async {
        await versions.load(work, library: library)
        loading = false
    }
}

/// The least a song page offers when the reader's platform has no version of it (anson 11-18):
/// copy its title and artist, or search for it on another platform.
struct ElsewhereSearch: View {
    let title: String
    let artist: String
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    /// The name as released, without the version note the page strips from its title.
    @MainActor static func title(_ work: Work) -> String {
        SongTitlePresentation(work.discovery?.canonicalTitle ?? work.title, isSong: true).title
    }
    var query: String { [title, artist].filter { !$0.isEmpty }.joined(separator: " ") }
    var body: some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = query
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task { @MainActor in try? await Task.sleep(for: .seconds(1.8)); withAnimation { copied = false } }
            } label: {
                Label(copied ? "已复制" : "复制歌名和歌手", systemImage: copied ? "checkmark" : "doc.on.doc").lineLimit(1)
            }
            .buttonStyle(.plain).contentTransition(.opacity)
            .font(.system(size: 13.5, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 38).fixedSize()
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityIdentifier("elsewhere-copy")
            Menu {
                ForEach(Self.places(query)) { place in
                    Button(place.title) { openURL(place.url) }
                }
            } label: {
                Label("去别处搜", systemImage: "magnifyingglass").lineLimit(1)
                    .font(.system(size: 13.5, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 38).fixedSize()
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("elsewhere-search")
        }
        .foregroundStyle(ShopStyle.ink)
    }
    static func places(_ query: String) -> [PageLink] {
        func url(_ base: String, _ name: String) -> URL? {
            var c = URLComponents(string: base); c?.queryItems = [.init(name: name, value: query)]; return c?.url
        }
        let path = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""
        return [
            PageLink(title: PlaybackPlatform.qq.title, url: PlaybackPlatform.qq.searchURL(query), search: true),
            PageLink(title: PlaybackPlatform.netease.title, url: PlaybackPlatform.netease.searchURL(query), search: true),
            URL(string: "https://open.spotify.com/search/" + path).map { PageLink(title: "Spotify", url: $0, search: true) },
            url("https://www.youtube.com/results", "search_query").map { PageLink(title: "YouTube", url: $0, search: true) },
            url("https://search.bilibili.com/all", "keyword").map { PageLink(title: "哔哩哔哩", url: $0, search: true) },
        ].compactMap { $0 }
    }
}

struct PageDestinationButton: View {
    let link: PageLink
    @Environment(\.openURL) private var openURL
    @State private var showFailure = false
    @State private var browser: StorySourcePage?
    var body: some View {
        Group {
            if link.search { button.font(.system(size: 12)).foregroundStyle(ArtworkPalette.tx2) }
            else {
                button.font(.system(size: 13.5, weight: .medium)).padding(.horizontal, 14).frame(minHeight: 38).fixedSize()
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .confirmationDialog("没能打开 " + link.title, isPresented: $showFailure, titleVisibility: .visible) {
            Button("在 Safari 打开") { browser = .init(url: link.url) }
        }
        .sheet(item: $browser) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
    }
    private var button: some View {
        Button { openURL(link.url) { if !$0 { showFailure = true } } } label: {
            Label(link.search ? "在\(link.title)搜索" : link.title, systemImage: link.symbol).lineLimit(1)
        }.buttonStyle(.plain).accessibilityIdentifier("lookup-" + link.title)
    }
}
