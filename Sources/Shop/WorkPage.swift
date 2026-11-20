import SwiftUI

struct WorkPage: View {
    let id: WorkID
    var isRoot = false
    var ownerTab: AppTab = .now
    @Environment(Library.self) private var library
    @State private var expanded = false
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0
    @State private var restoredReading = false
    @State private var knowledgePresented = false
    @State private var knowledgeTarget: WorkID?
    @State private var resumedCue: VideoCue?
    @State private var videoOpenFailed = false
    @State private var isVisible = false
    @State private var instancePath: [Route]?
    @State private var cueFocusTask: Task<Void, Never>?
    @State private var activeCueFocusID: UUID?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if id.work.isVideo { videoHero }
                else if id.work.isPerson || id == .manga { simpleHero }
                else { HeroPanel(id: id) }

                if let resumedCue, !knownVideoCues.contains(resumedCue) {
                    VideoCueRow(workID: id, cue: resumedCue) { openVideo(resumedCue.seconds) }
                }

                switch id {
                case .pool: poolContent
                case .film: filmContent
                case .animenz: animenzContent
                case .jane: janeContent
                case .distance: distanceContent
                case .ourFilm, .slow: scoreContent
                case .ushio, .yonezu, .utada, .yoshihara, .fujimoto, .ravel, .debussy, .animenzPerson: creatorContent
                case .poolAlbum, .janeAlbum, .distanceAlbum: albumContent
                case .manga: mangaContent
                default: DynamicWorkContent(id: id)
                }
                if Work.seeds[id] != nil { KnowledgeProgress(id: id) }
                MoreWorksView(id: id)
                if Work.seeds[id] == nil && id.work.knowledgeID == nil {
                    Button("查找更多关联", systemImage: "point.3.connected.trianglepath.dotted") { knowledgePresented = true }
                        .buttonStyle(.glass).controlSize(.large)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
        }
        .scrollPosition($scrollPosition)
        .accessibilityIdentifier("work-page-\(id.rawValue)")
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in max(0, geometry.contentOffset.y + geometry.contentInsets.top) } action: { _, value in scrollOffset = value }
        .onDisappear {
            isVisible = false
            cueFocusTask?.cancel(); cueFocusTask = nil
            activeCueFocusID = nil
            if restoredReading { library.saveReading(id, offset: Double(scrollOffset)) }
        }
        .onScrollPhaseChange { _, phase in
            // A user's new gesture takes precedence over a pending cold-start
            // restoration while source material is still arriving.
            if phase == .interacting { restoredReading = true }
            if phase == .idle, restoredReading { library.saveReading(id, offset: Double(scrollOffset)) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, restoredReading { library.saveReading(id, offset: Double(scrollOffset)) }
        }
        .onChange(of: library.videoCueFocus?.id) { _, requestID in
            // Consuming our request sets it to nil; do not cancel our own
            // pending layout wait in response to that state change.
            if requestID != nil { scheduleVideoCueFocus() }
        }
        .task(id: id) {
            if library.videoCueFocus?.entry.workID == id {
                await focusRequestedVideoCue()
            }
            if !restoredReading {
                let checkpoint = library.checkpoints[id.rawValue]
                if let checkpoint, checkpoint.offset > 0,
                   !library.demoMode, Work.seeds[id] == nil, let qid = id.work.knowledgeID {
                    // Restore after the saved source blocks can participate in
                    // layout; otherwise a short initial page clips the offset.
                    await WorkContextStore.shared.load(qid)
                    if let article = WorkContextStore.shared.values[qid]?.article,
                       !library.catalog.stories.contains(where: { $0.workID == id }) {
                        await WorkBackgroundStore.shared.load(article)
                    }
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                if !restoredReading, let checkpoint, checkpoint.offset > 0 {
                    scrollPosition.scrollTo(y: checkpoint.offset)
                }
                restoredReading = true
            }
            await library.catalog.enrich(id)
        }
        .background { Atmosphere(art: id.work.art) }
        .foregroundStyle(library.visualDirection.foreground)
        .navigationTitle(isRoot ? "此刻" : id.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Keep the prefix that belongs to this instance. Re-reading the
            // current stack on every appearance would let an older copy of
            // this work impersonate a later copy during a navigation transition.
            if instancePath == nil { instancePath = isRoot ? [] : ownerNavigationPath }
            isVisible = true
            library.reading = id
            if library.playing == id { library.showNewTrack = false }
            library.visit(id)
            scheduleVideoCueFocus()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if library.showNewTrack { NewTrackPrompt() }
        }
        .sheet(isPresented: $knowledgePresented, onDismiss: {
            if let next = knowledgeTarget { knowledgeTarget = nil; library.open(next) }
        }) {
            KnowledgeSearchView(query: id.displayTitle) { next in knowledgeTarget = next; knowledgePresented = false }
        }
        .toolbar {
            if !isRoot {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis") {
                        NavigationLink(value: Route.connections(id)) { Label("查看关联", systemImage: "point.3.connected.trianglepath.dotted") }
                        Button("来源", systemImage: "text.quote") { library.sourceSheet = id }
                        Button("查找更多关联", systemImage: "magnifyingglass") { knowledgePresented = true }
                        if let raw = id.work.url, let url = URL(string: raw) { ShareLink(item: url) }
                    }
                }
            }
        }
    }

    private var poolContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            relationHeading
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                RelatedTile(id: .film, relation: "配乐来自")
                RelatedTile(id: .animenz, relation: "钢琴改编")
            }.padding(.top, -14)
            StoryBlock(title: "电影院里，很小的声音也能被听清", sourceID: .pool,
                       sourceClaim: "牛尾宪辅说，《our film》和《slow summer eve》用了很细微的声音，细节在安静的影院里更容易听见。") {
                EntityLinkedText("《our film》陪着电次和玛奇玛看电影，《slow summer eve》出现在夏日祭。牛尾宪辅说，这两首用了很细微的声音，细节在安静的影院里更容易听见。", entities: ["our film": .ourFilm, "slow summer eve": .slow, "牛尾宪辅": .ushio])
            }
            VStack(spacing: 14) {
                SongRow(id: .ourFilm, subtitle: "牛尾宪辅")
                SongRow(id: .slow, subtitle: "牛尾宪辅")
            }.padding(.top, -12)
            NavigationLink(value: Route.work(.ushio)) {
                Label("牛尾宪辅", systemImage: "person.crop.circle")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
        }
    }

    private var filmContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            EntityLinkedText("电次在雨天遇见了咖啡店女孩蕾塞。原作来自藤本树的《电锯人》，电影由吉原达矢执导，牛尾宪辅配乐。", entities: ["藤本树": .fujimoto, "电锯人": .manga, "吉原达矢": .yoshihara, "牛尾宪辅": .ushio])
                .font(.body).lineSpacing(5)
            HStack {
                Button { library.toggleSaved(id) } label: {
                    Label(library.saved.contains(id) ? "已想看" : "想看", systemImage: library.saved.contains(id) ? "checkmark" : "plus")
                }.buttonStyle(.glass)
                if let url = URL(string: "https://movie.douban.com/subject/37291780/") {
                    Link(destination: url) { Label("豆瓣", systemImage: "arrow.up.right") }.buttonStyle(.glass)
                }
            }.controlSize(.large)
            relationHeading
            SongRow(id: .jane, subtitle: "片尾曲 · 米津玄师、宇多田光")
            SongRow(id: .pool, subtitle: "配乐 · 牛尾宪辅")
            NavigationLink(value: Route.work(.manga)) { EntityRow(id: .manga, relation: "原作", showsChevron: true) }.buttonStyle(.plain)
        }
    }

    private var videoHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { openVideo() } label: {
                Group {
                    if id.work.art.hasPrefix("https://"), let url = URL(string: id.work.art) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().aspectRatio(16/9, contentMode: .fit) }
                            else { Rectangle().fill(library.visualDirection.surface).aspectRatio(16/9, contentMode: .fit) }
                        }
                    } else if !id.work.art.isEmpty {
                        Image(id.work.art).resizable().aspectRatio(16/9, contentMode: .fit)
                    } else {
                        Rectangle().fill(library.visualDirection.surface).aspectRatio(16/9, contentMode: .fit)
                    }
                }
                    .overlay {
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                            .frame(width: 62, height: 62).glassEffect(.clear, in: .circle)
                    }
                    .clipShape(.rect(cornerRadius: 24))
            }.buttonStyle(.plain).accessibilityLabel("观看 \(RecordStoreArtwork.relationTitle(for: id))")
                .disabled(videoReference == nil)
            VStack(alignment: .leading, spacing: 6) {
                if id == .animenz {
                    EntityLinkedText("Animenz 的 in the pool", entities: ["Animenz": .animenzPerson, "in the pool": .pool]).font(.title2.bold())
                } else {
                    Text(id.displayTitle).font(.title2.bold())
                    CreatorNames(id: id).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(id.work.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { openVideo() } label: { Label("观看", systemImage: "play.fill") }
                    .disabled(videoReference == nil)
                    .accessibilityIdentifier("video-open-\(id.rawValue)")
                Button { library.toggleLater(id) } label: {
                    Label(library.watchLaterEntry(for: id) != nil ? "已加入" : "稍后看", systemImage: library.watchLaterEntry(for: id) != nil ? "checkmark" : "clock")
                }.accessibilityIdentifier("video-watch-later-\(id.rawValue)")
                Button { library.toggleSaved(id) } label: {
                    Image(systemName: library.saved.contains(id) ? "star.fill" : "star")
                }.accessibilityLabel(library.saved.contains(id) ? "取消收藏" : "收藏")
            }.buttonStyle(.glass).controlSize(.large)
            if videoOpenFailed { Text("暂时无法打开，请重试。").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var animenzContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            StoryBlock(title: "用钢琴写水面的光", sourceID: .animenz,
                       sourceClaim: "Animenz 的改编说明提到拉威尔和德彪西的手法，以及 1:16 的上行琶音和 3:35 的高音区处理。") {
                EntityLinkedText("Animenz 在改编说明里写，他借用了拉威尔和德彪西的手法，让向上流动的琴音像光掠过水面。后半段，同样的闪光被放进了更高的音区。", entities: ["Animenz": .animenzPerson, "拉威尔": .ravel, "德彪西": .debussy])
            }
            VStack(spacing: 0) {
                ForEach(Array(knownVideoCues.enumerated()), id: \.element.id) { index, cue in
                    if index > 0 { Divider().padding(.leading, 66) }
                    VideoCueRow(workID: id, cue: cue) { openVideo(cue.seconds) }
                }
            }
            SongRow(id: .pool, subtitle: "原曲 · 牛尾宪辅")
        }
    }

    private var janeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            StoryBlock(title: "两个人，两种节奏感", sourceID: .jane,
                       sourceClaim: "米津玄师谈《JANE DOE》的录制：他习惯紧盯拍点，宇多田光的节奏更自由；两人讨论过唱法，最终让她按自己的感觉演唱。") {
                EntityLinkedText("米津玄师说，自己习惯紧盯拍点，宇多田光的节奏更自由。录《JANE DOE》时，他打电话和她讨论过唱法，后来决定让她按自己的感觉来。", entities: ["米津玄师": .yonezu, "宇多田光": .utada])
                if expanded {
                    Text("两人靠来回传送录音合作。按米津的说法，他的音乐背景更接近另类摇滚、VOCALOID 和电脑制作；宇多田的唱法则带着 R&B 的感觉。两种节奏感，都留在了这首合唱里。")
                }
                Button(expanded ? "收起" : "展开") { withAnimation { expanded.toggle() } }
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            SongRow(id: .distance, subtitle: "米津喜欢的歌")
            NavigationLink(value: Route.work(.janeMV)) {
                Label("官方 MV", systemImage: "play.rectangle")
                Spacer()
                Image(systemName: "chevron.right")
            }.padding(.vertical, 8).accessibilityIdentifier("work-link-editorial:jane-doe-mv")
            NavigationLink(value: Route.work(.film)) { EntityRow(id: .film, relation: "片尾曲来自", showsChevron: true) }.buttonStyle(.plain)
        }
    }

    private var distanceContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            EntityLinkedText("聊到与宇多田光的合作时，米津玄师提到了自己喜欢的《FINAL DISTANCE》。", entities: ["宇多田光": .utada, "米津玄师": .yonezu])
                .font(.body).lineSpacing(5)
            SongRow(id: .jane, subtitle: "米津玄师与宇多田光的合作")
        }
    }

    private var scoreContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            EntityLinkedText(id == .ourFilm ? "电次和玛奇玛看电影时的配乐。牛尾宪辅在访谈里特地提到，这段音乐有一些很细微的声音。" : "夏日祭场景的配乐。牛尾宪辅把它与《our film》一起，列作影院里值得留意细节的两首曲子。", entities: ["牛尾宪辅": .ushio, "our film": .ourFilm])
                .font(.body).lineSpacing(5)
            SongRow(id: id == .ourFilm ? .slow : .ourFilm, subtitle: "同一张电影原声")
            NavigationLink(value: Route.work(.film)) { EntityRow(id: .film, relation: "配乐来自", showsChevron: true) }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var simpleHero: some View {
        if library.visualDirection == .orbit && id.work.isPerson {
            VStack(alignment: .leading, spacing: 14) {
                Text(id.displayTitle).font(.system(size: 34, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                let role = id.work.creator.isEmpty ? id.work.detail : id.work.creator
                if !role.isEmpty { Text(role).font(.subheadline).opacity(0.7).fixedSize(horizontal: false, vertical: true) }
            }
            .foregroundStyle(library.visualDirection.background)
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .background(library.visualDirection.foreground, in: .rect(cornerRadius: 5))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6).padding(.vertical, 12)
        } else {
        HStack(alignment: .center, spacing: 22) {
            Group {
                if library.visualDirection == .orbit {
                    RecordStoreArtwork(id: id, size: 106)
                } else if id.work.isPerson {
                    Text(String(id.displayTitle.prefix(2)))
                        .font(.system(size: 33, weight: .regular, design: .serif))
                        .frame(width: 94, height: 94)
                        .background(library.visualDirection.accent.opacity(0.13), in: .circle)
                } else {
                    Image(systemName: id.work.symbol).font(.system(size: 34, weight: .light))
                        .frame(width: 82, height: 106)
                        .background(library.visualDirection.accent.opacity(0.13), in: .rect(cornerRadius: 8))
                }
            }.foregroundStyle(library.visualDirection.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(id.displayTitle).font(.system(size: 34, weight: .semibold, design: library.visualDirection == .atlas ? .serif : .default))
                CreatorNames(id: id).foregroundStyle(library.visualDirection.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 26)
        }
    }
    private var creatorContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            EntityLinkedText(creatorContext, entities: ["JANE DOE": .jane, "FINAL DISTANCE": .distance, "电锯人 蕾塞篇": .film, "蕾塞篇": .film, "电锯人": .manga, "in the pool": .animenz, "Animenz": .animenzPerson, "宇多田光": .utada, "米津玄师": .yonezu, "牛尾宪辅": .ushio, "summer’s end": .poolAlbum].filter { $0.value != id })
                .font(.body).lineSpacing(5)
            relationHeading
            ForEach(Relations.displayEdges(for: id)) { edge in
                let target = edge.other(than: id)
                if target.work.isSong {
                    SongRow(id: target, subtitle: edge.label(from: id))
                } else {
                    NavigationLink(value: Route.work(target)) {
                        EntityRow(id: target, relation: edge.label(from: id), showsChevron: true)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var creatorContext: String {
        switch id {
        case .ushio: "《蕾塞篇》的配乐作曲家。影片原声收录在 summer’s end。"
        case .yonezu: "《JANE DOE》的词曲作者与演唱者。他在谈这次合作时，还提到了自己喜欢的宇多田光作品。"
        case .utada: "与米津玄师合作演唱《JANE DOE》。"
        case .yoshihara: "《电锯人 蕾塞篇》的导演。"
        case .fujimoto: "《电锯人》的原作者。《蕾塞篇》由这部漫画中的篇章改编。"
        case .ravel, .debussy: "Animenz 在 in the pool 的改编说明里提到，借鉴了这位作曲家的写法。"
        case .animenzPerson: "将牛尾宪辅的 in the pool 改编为钢琴独奏，并在视频说明里讲述了改编思路。"
        default: ""
        }
    }
    private var albumContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let raw = id.work.url, let url = URL(string: raw) {
                Link(destination: url) { Label("Apple Music", systemImage: "arrow.up.right") }
                    .buttonStyle(.glass).controlSize(.large)
            }
            Text("相关曲目").font(.title2.bold())
            ForEach(Relations.forEntity(id)) { edge in
                let song = edge.other(than: id)
                if song.work.isSong { SongRow(id: song, subtitle: song.work.creator) }
            }
        }
    }
    private var mangaContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            EntityLinkedText("藤本树的原作漫画。蕾塞篇是其中一个篇章，后来被改编成动画电影。", entities: ["藤本树": .fujimoto, "蕾塞篇": .film])
            Button { library.toggleSaved(id) } label: {
                Label(library.saved.contains(id) ? "已想读" : "想读", systemImage: library.saved.contains(id) ? "checkmark" : "plus")
            }.buttonStyle(.glass).controlSize(.large)
            NavigationLink(value: Route.work(.film)) { EntityRow(id: .film, relation: "改编电影", showsChevron: true) }.buttonStyle(.plain)
        }
    }
    private var relationHeading: some View {
        HStack {
            Text("关联").font(.title2.bold())
            Spacer()
            NavigationLink(value: Route.connections(id)) { Label("关系图", systemImage: "point.3.connected.trianglepath.dotted").font(.subheadline.weight(.medium)) }
                .accessibilityLabel("查看全部关联").buttonStyle(.glass).tint(library.visualDirection.accent)
        }
    }
    private var videoReference: VideoReference? {
        id.work.isVideo ? id.work.url.flatMap { VideoReference(url: $0) } : nil
    }
    private var knownVideoCues: [VideoCue] {
        VideoCues.animenz.filter { $0.video == videoReference }
    }
    private func openVideo(_ seconds: Int? = nil) {
        guard let url = videoReference?.destination(seconds: seconds) else { return }
        library.saveReading(id, offset: Double(scrollOffset))
        library.persist()
        openURL(url) { accepted in videoOpenFailed = !accepted }
    }
    private var ownerNavigationPath: [Route] {
        ownerTab == .now ? library.path : library.collectionPath
    }
    @MainActor private func scheduleVideoCueFocus() {
        guard isVisible, library.videoCueFocus != nil else { return }
        cueFocusTask?.cancel()
        cueFocusTask = Task { await focusRequestedVideoCue() }
    }
    @MainActor private func focusRequestedVideoCue() async {
        guard !Task.isCancelled, let instancePath,
              let request = library.takeVideoCueFocus(for: id, ownerTab: ownerTab,
                                                      destinationPath: instancePath, isVisible: isVisible),
              let cue = request.entry.cue else { return }
        activeCueFocusID = request.id
        resumedCue = cue
        restoredReading = true
        await Task.yield()
        guard !Task.isCancelled, isVisible, activeCueFocusID == request.id,
              library.tab == request.ownerTab, ownerTab == request.ownerTab,
              instancePath == request.destinationPath,
              ownerNavigationPath == request.destinationPath else { return }
        scrollPosition.scrollTo(id: cue.id, anchor: .center)
    }
}

struct HeroPanel: View {
    let id: WorkID
    var body: some View { VisualHeroPanel(id: id) }
}

struct RelatedTile: View {
    let id: WorkID
    let relation: String
    @Environment(Library.self) private var library
    private var isRecordStore: Bool { library.visualDirection == .orbit }

    var body: some View {
        NavigationLink(value: Route.work(id)) {
            VStack(alignment: .leading, spacing: 8) {
                if isRecordStore {
                    recordStoreArtwork
                } else {
                    GeometryReader { size in
                        Image(id.work.art).resizable().scaledToFill()
                            .frame(width: size.size.width, height: 132).clipped()
                            .accessibilityHidden(true)
                    }.frame(height: 132).clipShape(.rect(cornerRadius: 18))
                }
                Text(id == .animenz ? "Animenz" : id.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(isRecordStore ? 2 : 1)
                Text(relation).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
            .accessibilityIdentifier("work-link-\(id.rawValue)")
    }

    private var recordStoreArtwork: some View {
        GeometryReader { geometry in
            let isPortrait = id.work.kind == "电影" || id.work.kind == "漫画"
            let isVideo = id.work.kind == "演奏视频"
            let width = isPortrait ? min(geometry.size.width * 0.8, 176 * 0.72) : geometry.size.width
            let height = isPortrait ? CGFloat(176) : isVideo ? width * 9 / 16 : min(width, 176)
            Group {
                if id.work.art.isEmpty {
                    RecordStoreArtwork(id: id, size: min(geometry.size.width, 176))
                } else {
                    Image(id.work.art).resizable().scaledToFit()
                        .frame(width: width, height: height)
                        .background(VisualDirection.orbit.surface)
                        .clipShape(.rect(cornerRadius: 3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.03), .black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 0.7
                                )
                        }
                        .shadow(color: .black.opacity(0.24), radius: 7, x: 2, y: 5)
                }
            }
            .frame(width: geometry.size.width, height: 176, alignment: .bottomLeading)
        }
        .frame(height: 176)
        .accessibilityHidden(true)
    }
}

struct StoryBlock<Content: View>: View {
    let title: String
    let sourceID: WorkID
    let sourceClaim: String
    @ViewBuilder let content: Content
    @Environment(Library.self) private var library
    @State private var showsSource = false
    private var source: Source { sourceID == .animenz ? .animenz : sourceID == .jane ? .gq : .interview }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(title).font(.title3.bold())
                Spacer(minLength: 10)
                Menu("更多", systemImage: "ellipsis") {
                    Button(source.title, systemImage: "text.quote") { showsSource = true }
                }.labelStyle(.iconOnly).font(.body).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
            }
            content.font(.body).lineSpacing(5)
        }
        .sheet(isPresented: $showsSource) {
            NavigationStack {
                ScrollView { SourceEvidenceView(source: source, claim: sourceClaim).padding(22) }
                    .navigationTitle("出处").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSource = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}

struct SongRow: View {
    let id: WorkID
    let subtitle: String
    @Environment(Library.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: Route.work(id)) {
                HStack(spacing: 12) {
                    if library.visualDirection == .orbit {
                        RecordStoreArtwork(id: id, size: 58)
                    } else {
                        Image(id.work.art).resizable().scaledToFill().frame(width: 58, height: 58).clipShape(.rect(cornerRadius: 11))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(id.displayTitle).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityIdentifier("work-link-\(id.rawValue)")
            Button("播放选项", systemImage: "ellipsis") { library.songSheet = id }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
        }
        .padding(.vertical, 4)
    }
}

struct EntityRow: View {
    let id: WorkID
    let relation: String
    var showsChevron = false
    @Environment(Library.self) private var library
    var body: some View {
        HStack(spacing: 14) {
            if library.visualDirection == .orbit && id.work.isPerson && id.work.art.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(id.displayTitle).font(.system(.headline, design: .serif))
                    if !relation.isEmpty { Text(relation).font(.caption).opacity(0.7) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(library.visualDirection.background)
                .background(library.visualDirection.foreground, in: .rect(cornerRadius: 3))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            } else {
                if library.visualDirection == .orbit {
                    RecordStoreArtwork(id: id, size: 58, showsPlaceholderTitle: false)
                } else if id.work.art.isEmpty {
                Image(systemName: id.work.symbol)
                    .font(.title2).frame(width: 56, height: 64).background(.quaternary, in: .rect(cornerRadius: 10))
                } else {
                Image(id.work.art).resizable().scaledToFill().frame(width: 56, height: 64).clipShape(.rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(id.displayTitle).font(.headline)
                Text(relation).font(.caption).foregroundStyle(.secondary)
            }
            }
            Spacer()
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.padding(.vertical, 6)
            .contentShape(.rect)
    }
}

/// Entity IDs are assigned in the editorial payload; runtime navigation never guesses by name.
struct EntityLinkedText: View {
    let content: String
    let entities: [String: WorkID]
    @Environment(Library.self) private var library
    init(_ content: String, entities: [String: WorkID]) {
        self.content = content; self.entities = entities
    }
    private var attributed: AttributedString {
        var text = AttributedString(content)
        var linked: [Range<AttributedString.Index>] = []
        for (name, id) in entities.sorted(by: { $0.key.count > $1.key.count }) {
            if let range = text.range(of: name), !linked.contains(where: { $0.overlaps(range) }) {
                linked.append(range)
                text[range].link = URL(string: "pianwai://entity/\(id.rawValue)")
                text[range].underlineStyle = .single
            }
        }
        return text
    }
    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "pianwai", url.host == "entity", let id = WorkID(rawValue: url.lastPathComponent) else { return .systemAction }
                library.open(id)
                return .handled
            })
    }
}

struct CreatorNames: View {
    let id: WorkID
    var body: some View {
        if id.work.creatorIDs.isEmpty {
            Text(id.work.creator)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(id.work.creatorIDs.enumerated()), id: \.element) { index, creator in
                    if index > 0 { Text("、") }
                    NavigationLink(value: Route.work(creator)) { Text(creator.displayTitle).underline() }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}
