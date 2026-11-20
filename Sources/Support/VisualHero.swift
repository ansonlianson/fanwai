import SwiftUI

struct VisualHeroPanel: View {
    let id: WorkID
    @Environment(Library.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    private var style: VisualDirection { library.visualDirection }
    private var palette: ArtworkPalette { .asset(id.work.art) }
    private var controlsCurrentTrack: Bool { library.canControlPlayback && library.currentTrack == id }
    private var canQueueThisTrack: Bool {
        library.canQueueNext && id.work.hasCatalogRecording
    }
    private var needsRecordingLookup: Bool {
        id.work.canFindCatalogVersion
    }
    private var primaryTitle: String {
        if controlsCurrentTrack { return library.isPlaying ? "暂停" : "播放" }
        if needsRecordingLookup { return id.work.catalogVersionSearchTitle }
        if canQueueThisTrack { return "下一首" }
        return library.listenLater.contains(id) ? "已加入稍后听" : "加入稍后听"
    }
    private var primarySymbol: String {
        if controlsCurrentTrack { return library.isPlaying ? "pause.fill" : "play.fill" }
        if needsRecordingLookup { return "magnifyingglass" }
        if canQueueThisTrack { return "text.line.first.and.arrowtriangle.forward" }
        return library.listenLater.contains(id) ? "checkmark" : "plus"
    }

    var body: some View {
        Group {
            switch style {
            case .spectrum: spectrum
            case .atlas: atlas
            case .orbit: recordStore
            }
        }
        .foregroundStyle(style.foreground)
    }

    private var spectrum: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                Ellipse().fill(palette.ac.color.opacity(0.16))
                    .frame(width: 290, height: 170).blur(radius: 42).offset(y: 24)
                artwork(width: 234, height: id == .film ? 282 : 234, radius: 8)
                    .rotationEffect(.degrees(-3))
                    .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(palette.ac.color).frame(width: 9, height: 9).offset(x: 17, y: 13)
                    }
            }
            .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 3)
            heading(size: 38, weight: .semibold)
            if id.work.isSong || needsRecordingLookup { controls }
            metadata
        }
        .padding(.horizontal, 4).padding(.bottom, 8)
    }

    private var atlas: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 20) {
                artwork(width: 170, height: id == .film ? 225 : 170, radius: 2)
                    .padding(7).background(style.surface)
                    .shadow(color: Color.brown.opacity(0.13), radius: 12, x: 0, y: 8)
                    .rotationEffect(.degrees(-3))
                VStack(alignment: .leading, spacing: 10) {
                    Text(id.work.kind).font(.caption.weight(.medium)).foregroundStyle(style.accent)
                    Text(id.displayTitle).font(.system(size: 32, weight: .semibold, design: .serif))
                        .tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                    CreatorNames(id: id).font(.subheadline).foregroundStyle(style.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            Rectangle().fill(style.foreground.opacity(0.18)).frame(height: 1)
            if id.work.isSong || needsRecordingLookup { controls }
            metadata
        }
        .padding(6).padding(.bottom, 4)
    }

    private var recordStore: some View {
        VStack(alignment: .leading, spacing: 18) {
            if id.work.art.isEmpty {
                compactRecordStoreIdentity
            } else {
                heading(size: 38, weight: .black)
                RecordStoreArtwork(id: id, size: id == .film ? 248 : 216,
                                   showsDisc: true, discOffset: 0.32, showsPlaceholderTitle: false)
                    .rotationEffect(.degrees(id.work.isSong || id.work.isAlbum ? -4 : 0))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            if id.work.isSong || needsRecordingLookup { controls }
            metadata
        }.padding(.horizontal, 4)
    }

    @ViewBuilder private var compactRecordStoreIdentity: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            if ["电影", "电视剧"].contains(id.work.kind) {
                Button { library.sourceSheet = id } label: {
                    RecordStoreArtwork(id: id, size: 140, showsPlaceholderTitle: false)
                        .fixedSize()
                }.buttonStyle(.plain).accessibilityLabel("封面来源")
            } else {
                RecordStoreArtwork(id: id, size: 80, showsPlaceholderTitle: false)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(id.displayTitle)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !id.work.creator.isEmpty || !id.work.creatorIDs.isEmpty {
                    CreatorNames(id: id)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(style.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(size: CGFloat, weight: Font.Weight) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(id.displayTitle).font(.system(size: size, weight: weight)).tracking(-1.2)
                .lineLimit(2).minimumScaleFactor(0.75)
            CreatorNames(id: id).font(.subheadline.weight(.medium)).foregroundStyle(style.secondary)
        }
    }

    private func artwork(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        Image(id.work.art).resizable().scaledToFill()
            .frame(width: width, height: height).clipped()
            .clipShape(.rect(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.15), lineWidth: 0.7) }
            .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if controlsCurrentTrack { library.togglePlayback() }
                else if needsRecordingLookup { library.findRecording(for: id) }
                else if canQueueThisTrack { library.queueNext(id) }
                else { library.toggleListenLater(id) }
            } label: {
                Label(primaryTitle, systemImage: primarySymbol).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).foregroundStyle(style.background)
            }
            .buttonStyle(.glassProminent).tint(style.accent).controlSize(.large)
            .disabled((controlsCurrentTrack || canQueueThisTrack) && library.playbackBusy)
            Button { library.toggleSaved(id) } label: {
                Image(systemName: library.saved.contains(id) ? "star.fill" : "star")
                    .frame(width: 25)
            }.buttonStyle(.glass).controlSize(.large)
                .accessibilityLabel(library.saved.contains(id) ? "取消收藏" : "收藏")
            Spacer(minLength: 0)
            Menu("更多", systemImage: "ellipsis") {
                NavigationLink(value: Route.connections(id)) { Label("查看关联", systemImage: "point.3.connected.trianglepath.dotted") }
                if id.work.isSong {
                    Button("播放选项", systemImage: "music.note.list") { library.songSheet = id }
                        .accessibilityIdentifier("work-playback-options-\(id.rawValue)")
                }
                Button("来源", systemImage: "text.quote") { library.sourceSheet = id }
                if let raw = id.work.url, let url = URL(string: raw) {
                    Link(id.work.externalLinkTitle, destination: url)
                    ShareLink(item: url)
                }
            }.labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large)
                .accessibilityIdentifier("work-more-\(id.rawValue)")
        }
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(id.displayDetail).font(.caption).foregroundStyle(style.secondary)
            Spacer(minLength: 8)
            if let album = id.work.albumID {
                NavigationLink(value: Route.work(album)) {
                    HStack(spacing: 5) {
                        Text(album.displayTitle).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }.font(.caption.weight(.medium)).foregroundStyle(style.secondary)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct VisualAtmosphere: View {
    let art: String
    let style: VisualDirection
    var body: some View {
        ZStack(alignment: .top) {
            style.background
            if style == .spectrum && !art.isEmpty {
                Image(art).resizable().scaledToFill().frame(height: 480).clipped()
                    .blur(radius: 80).opacity(0.32)
                    .mask(LinearGradient(colors: [.white, .white.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [Color(red: 0.06, green: 0.20, blue: 0.22).opacity(0.55), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else if style == .atlas {
                LinearGradient(colors: [style.surface.opacity(0.9), style.background], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else if style == .orbit {
                LinearGradient(colors: [style.surface.opacity(0.7), style.background], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
