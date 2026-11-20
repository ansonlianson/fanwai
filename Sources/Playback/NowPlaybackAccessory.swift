import SwiftUI

/// The native TabView owns the glass/background and safe area. This view only
/// renders the observed system track, never the entity currently being read.
struct NowPlaybackAccessory: View {
    var previewEntity: SeedGraph.Entity?
    var previewPlaying = false
    var motionReceipt = ""
    var onPreviewToggle: () -> Void = {}
    /// Tapping the record and title returns to the playing song's page.
    var onOpen: () -> Void = {}
    var onSearch: () -> Void = {}
    @Environment(Library.self) private var library
    private var observed: SeedGraph.Entity? {
        SeedLibraryBridge.playbackEntity(in: library)
    }
    private var entity: SeedGraph.Entity? { observed ?? previewEntity }
    private var playing: Bool { observed != nil ? library.isPlaying : previewEntity != nil && previewPlaying }
    private var needsConnection: Bool { !library.musicConnected && previewEntity == nil }

    /// QQ 音乐 / 网易云 (DOMESTIC-STORY-ART/DESIGN.md ③④): the bar is 「手上这张」,
    /// the record brought in, with 去听; never a second search field. A copied link is offered
    /// from the top of the screen (ClipboardPrompt), not here.
    var domesticRecord: SeedGraph.Entity? = nil
    var onListen: () -> Void = {}
    private var domestic: Bool { library.playbackPlatform != .apple && !library.isPlaying }
    var body: some View {
        Group {
            if domestic { domesticBar } else { player }
        }
    }
    /// Laid out like the Apple Music mini player: record, title and artist, then the
    /// one action that matters, here opening the song in the user's own app.
    @ViewBuilder private var domesticBar: some View {
        let platform = library.playbackPlatform
        HStack(spacing: 11) {
            if let record = domesticRecord {
                HStack(spacing: 11) {
                    PhysicalObject(entity: record, showsDisc: false, size: CGSize(width: 32, height: 32))
                        .frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("now-playback-title")
                        Text(record.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect).onTapGesture { onOpen() }
                .accessibilityAddTraits(.isButton).accessibilityIdentifier("now-playback-open")
                Button(action: onListen) { PlatformIcon(platform: platform, size: 26).frame(width: 40, height: 44) }
                    .buttonStyle(.plain).disabled(library.listening.busy)
                    .accessibilityLabel(platform.openTitle).accessibilityIdentifier("now-domestic-listen")
            } else {
                HStack(spacing: 11) {
                    PlatformIcon(platform: platform, size: 26)
                    Text(platform.title).font(.system(size: 14, weight: .medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onSearch) { Image(systemName: "magnifyingglass").font(.system(size: 18)).frame(width: 40, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("搜索歌曲").accessibilityIdentifier("now-platform-search")
            }
        }
        .padding(.horizontal, 12).frame(height: 52)
        .accessibilityElement(children: .contain).accessibilityIdentifier("now-mini-player")
    }
    private var player: some View {
        HStack(spacing: 11) {
            if let entity {
                HStack(spacing: 11) {
                    // Apple Music's mini player uses a small square cover; match its proportion.
                    PhysicalObject(entity: entity, showsDisc: false, size: CGSize(width: 32, height: 32))
                        .frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entity.title).font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("now-playback-title")
                        Text(entity.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect).onTapGesture { onOpen() }
                .accessibilityAddTraits(.isButton).accessibilityIdentifier("now-playback-open")
            } else {
                Text(needsConnection ? "连接 Apple Music" : library.isPlaybackUnidentified ? "Apple Music 正在播放" : "Apple Music 没在播放")
                    .font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                if library.canControlPlayback { library.togglePlayback() }
                else if previewEntity != nil { onPreviewToggle() }
                else { Task { await library.connectMusic() } }
            } label: {
                Image(systemName: needsConnection ? "link" : playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 19)).frame(width: 40, height: 44)
            }.buttonStyle(.plain)
                .disabled(library.playbackBusy || (!needsConnection && entity == nil))
                .accessibilityLabel(needsConnection ? "连接 Apple Music" : playing ? "暂停" : "播放")
                .accessibilityIdentifier("now-playback-toggle")
            Button { library.skip() } label: {
                Image(systemName: "forward.fill").font(.system(size: 18)).frame(width: 40, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("下一首")
                .disabled(!library.canControlPlayback || library.playbackBusy)
        }
        .padding(.horizontal, 12).frame(height: 52)
        .accessibilityElement(children: .contain).accessibilityIdentifier("now-mini-player").accessibilityValue(motionReceipt)
    }
}
