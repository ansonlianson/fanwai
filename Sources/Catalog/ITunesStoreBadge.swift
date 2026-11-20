import SwiftUI

extension Work {
    var iTunesStoreURL: URL? {
        guard appleMusicURL == nil else { return nil }
        guard catalogSource?.title == "iTunes" else { return nil }
        guard let original = ITunesCatalogPayload.validStoreURL(url),
              var parts = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
        var query = (parts.queryItems ?? []).filter { $0.name != "app" }
        query.append(.init(name: "app", value: "itunes")); parts.queryItems = query
        return parts.url
    }
}

/// Search keeps the reading target separate from the direct playback action.
struct CatalogMusicAction: View {
    let work: Work
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    var body: some View {
        if let url = work.appleMusicURL, work.isPerson || library.playbackPlatform == .apple {
            Button {
                if work.isPerson { openURL(url) }
                else { library.listen(work.id) }
            } label: {
                Image(systemName: work.isPerson ? "arrow.up.forward" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.18, blue: 0.13))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.06), in: .circle)
            }.buttonStyle(.plain).disabled(library.playbackBusy)
                .accessibilityLabel(work.isPerson ? "在 Apple Music 打开" : "播放")
                .accessibilityIdentifier("apple-music-action-" + work.id.rawValue)
        } else if work.isSong, library.playbackPlatform != .apple {
            Button { library.listen(work.id) } label: {
                Image(systemName: "play.fill").frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(library.playbackPlatform.listenTitle)
                .accessibilityIdentifier("platform-music-action-" + work.id.rawValue)
        } else { ITunesStoreBadge(work: work, compact: true) }
    }
}

/// Unmodified official assets; clear space is outside the image, with no effects.
struct ITunesStoreBadge: View {
    let work: Work
    var compact = false
    var body: some View {
        if let url = work.iTunesStoreURL {
            Link(destination: url) {
                Image(compact ? "iTunesStoreSmallBadge" : "iTunesStoreBadge")
                    .resizable().scaledToFit().frame(height: compact ? 20 : 32)
                    .fixedSize().padding(compact ? 4 : 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 iTunes Store 查看")
            .accessibilityIdentifier("itunes-badge-" + work.id.rawValue)
        }
    }
}
