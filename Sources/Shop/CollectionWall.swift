import SwiftUI
import UniformTypeIdentifiers

struct CollectionWall: View {
    var onTrail: (String) -> Void
    var onNext: (WorkID) -> Void
    var dockHeight: CGFloat = 128
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRecord: WorkID?
    @State private var selectedShelf: String?
    @State private var editing = false
    @State private var dragging: String?
    @State private var settlingID: WorkID?
    @State private var recordDrag: WallRecordDrag?
    @GestureState private var recordTouchActive = false
    @State private var trails: [RelationTrailStore.Entry] = []
    @State private var feedback: String?
    @State private var shelfBounds = CGRect.zero
    @State private var orderOpacity = 1.0
    @State private var orderFade: Task<Void,Never>?
    private let trailStore = RelationTrailStore()
    private var palette: ArtworkPalette { .asset("pool") }
    private var selection: WatchLaterEntry? { library.watchLaterEntries.first { $0.id == selectedShelf } }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(spacing: 8) {
                            sectionHeader("稍后听", count: "\(library.listenLater.count) 张") {
                                if library.playbackPlatform == .apple, !library.listenLater.isEmpty {
                                    Button {
                                        Task { if await library.playListenLater() { feedback = "\(library.listenLater.count) 张唱片已按顺序排进 Apple Music" } }
                                    } label: { Label("全部播放", systemImage: "play.fill").font(.system(size: 13.5, weight: .medium)) }
                                        .buttonStyle(.glass).disabled(library.playbackBusy).accessibilityIdentifier("wall-play-all")
                                }
                            }
                            recordBox
                            if let id = selectedRecord, library.listenLater.contains(id) { recordCaption(id) }
                        }
                        if !library.watchLaterEntries.isEmpty {
                            VStack(spacing: 10) {
                                sectionHeader("想看", count: "\(library.watchLaterEntries.count) 件") { EmptyView() }
                                shelf.id("wall-shelf")
                            }
                        }
                        if !trails.isEmpty {
                            VStack(spacing: 6) {
                                sectionHeader("足迹", count: nil) { EmptyView() }
                                ForEach(trails) { trail in trailRow(trail) }
                            }
                        }
                        completedRows
                    }.padding(.top, 8).padding(.bottom, dockHeight + 16)
                }
                .accessibilityIdentifier("wall-scroll")
                .scrollIndicators(.hidden)
                .foregroundStyle(ArtworkPalette.tx)
                .navigationTitle("收藏").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if editing { Button("完成") { finishRecordDrag(); editing = false; dragging = nil }.accessibilityIdentifier("wall-edit-done") }
                        else { Menu { Button("编辑", action: beginEditing) } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多") }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let selection { shelfCard(selection).padding(.horizontal, 12).padding(.bottom, 8).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .task(id: selectedShelf) {
                    guard selectedShelf != nil else { return }
                    // Wait for the native inset to acquire its final height before
                    // bringing the entire selected shelf above the card.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(motion) { reader.scrollTo("wall-shelf", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if let feedback {
                        Text(feedback).font(.system(size: 13)).padding(14).glassEffect(in: .capsule)
                            .padding(12).accessibilityIdentifier("wall-feedback").allowsHitTesting(false)
                    }
                }
                .task { trails = trailStore.entries() }
                .task(id: feedback) {
                    guard feedback != nil else { return }
                    try? await Task.sleep(for: .seconds(2.6)); if !Task.isCancelled { feedback = nil }
                }
                .onChange(of: library.listenLater) { _, ids in
                    if let selectedRecord, !ids.contains(selectedRecord) { self.selectedRecord = nil }
                }
                .onChange(of: library.watchLaterEntries) { _, entries in if !entries.contains(where: { $0.id == selectedShelf }) { selectedShelf = nil } }
                .onChange(of: recordTouchActive) { _, active in if !active { finishRecordDrag() } }
                .onDisappear { finishRecordDrag() }
                .animation(motion, value: selectedRecord)
                .animation(motion, value: selectedShelf)
                .animation(motion, value: library.listenLater)
                .animation(motion, value: library.watchLaterEntries)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The native large title renders above the scroll view's safe area.
            // Bound the content at the dock, while preserving that top overflow.
            .clipShape(WallViewport(topOverflow: geometry.safeAreaInsets.top + 100))
        }
        .background(ArtworkBackdrop(artwork: "pool", palette: palette))
    }
    private func sectionHeader<Actions: View>(_ title: String, count: String?, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(DesignType.chapter.font)
            if let count { Text(count).font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx3) }
            Spacer(); actions()
        }.padding(.horizontal, 22)
    }
    private var recordBox: some View {
        ZStack(alignment: .bottom) {
            CrateLining().clipShape(.rect(cornerRadius: 8)).padding(.horizontal, 20).frame(height: 160)
            if library.listenLater.isEmpty {
                WhiteLabelSleeve()
                    .rotation3DEffect(.degrees(14), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.4)
                    .offset(y: -28).accessibilityElement(children: .ignore).accessibilityHidden(false)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("在此刻页点稍后听，唱片会放到这里").accessibilityIdentifier("wall-empty")
            } else {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: -92) {
                            ForEach(Array(library.listenLater.enumerated()), id: \.element) { index, id in
                                record(id, index: index) {
                                    guard !editing else { return }
                                    selectedShelf = nil
                                    selectedRecord = selectedRecord == id ? nil : id
                                    withAnimation(motion) { reader.scrollTo(id, anchor: .center) }
                                }.id(id)
                            }
                        }.padding(.leading, 12).padding(.trailing, 20)
                            .padding(.top, selectedRecord == nil ? 14 : 48).padding(.bottom, selectedRecord == nil ? 6 : 26)
                    }.scrollIndicators(.hidden)
                        .scrollDisabled(recordDrag != nil)
                        .scrollClipDisabled()
                        .clipShape(WallViewport(topOverflow: 64))
                        .coordinateSpace(name: "wall-records")
                        .padding(.horizontal, 24)
                }
            }
            WallSidePanels().frame(height: 160).padding(.horizontal, 12).allowsHitTesting(false)
            WallCrateFront().frame(height: 46).padding(.horizontal, 12).allowsHitTesting(false)
        }.frame(height: library.listenLater.isEmpty ? 212 : selectedRecord == nil ? 170 : 224)
    }
    private func record(_ id: WorkID, index: Int, onSelect: @escaping () -> Void) -> some View {
        let selected = selectedRecord == id
        let lifted = recordDrag?.id == id
        let variation = CGFloat((lifted ? recordDrag?.originIndex ?? index : index) % 3 - 1)
        let sleeve = PhysicalObject(entity: SeedLibraryBridge.entity(for: id, in: library), scale: 150/64,
                              palette: palette, showsDisc: selected, discLeading: 0.28, size: CGSize(width: 150, height: 150))
            .overlay(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [ArtworkPalette.paper.opacity(0.85), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 2.5).offset(y: -1.5).allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                // The exposed edge is cardboard, with the next jacket in its
                // contact shadow. Keep these on each sleeve, not on the row.
                Rectangle().fill(LinearGradient(colors: [ArtworkPalette.paper, Color(red: 0.55, green: 0.48, blue: 0.36)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 2.5).padding(.vertical, 1)
                LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 8).offset(x: 8)
            }
            .shadow(color: .black.opacity(0.75), radius: 4, x: 6, y: 1)
        return sleeve
            .contentShape(.rect)
            .onTapGesture(perform: onSelect)
            .onLongPressGesture(perform: beginEditing)
            .highPriorityGesture(recordGesture(id), including: editing ? .all : .none)
            .overlay(alignment: .topLeading) {
                if editing && recordDrag == nil {
                    // Subsequent sleeves expose their right-hand 58pt strip.
                    // The control belongs to the object, before its transform,
                    // and clears the preceding sleeve's contact edge.
                    removeButton { library.toggleListenLater(id) }
                        .offset(x: selected || index == 0 ? -6 : 98, y: -6)
                        .accessibilityIdentifier("wall-remove-listen-" + id.rawValue)
                }
            }
            .rotationEffect(.degrees(selected ? 0 : Double(variation) * 0.35), anchor: .bottom)
            .rotation3DEffect(.degrees(selected ? 0 : 14), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.75)
            .scaleEffect(lifted && !reduceMotion ? 1.05 : 1, anchor: .bottom)
            .shadow(color: .black.opacity(lifted && !reduceMotion ? 0.45 : 0), radius: 18, x: 0, y: 12)
            .offset(x: lifted && !reduceMotion ? (recordDrag?.translation.width ?? 0) - CGFloat(index - (recordDrag?.originIndex ?? index)) * 58 : 0,
                    y: lifted && !reduceMotion ? -10 + variation : selected ? -34 : -4 + variation + (settlingID == id && !reduceMotion ? 1 : 0))
            .padding(.leading, selected ? 58 : 0).padding(.trailing, selected ? 62 : 0)
            .zIndex(selected || lifted ? 20 : Double(library.listenLater.count-index))
            .animation(motion, value: lifted)
            .animation(motion, value: index)
            .opacity(orderOpacity)
            .accessibilityElement(children: editing ? .contain : .ignore).accessibilityHidden(false)
            .accessibilityLabel(SeedLibraryBridge.entity(for: id, in: library).title)
            .accessibilityAddTraits(editing ? [] : .isButton).accessibilityIdentifier("wall-record-" + id.rawValue)
            .accessibilityValue(lifted ? "排序中" : selected ? "已抽出" : "箱内")
    }
    private func beginEditing() {
        withAnimation(motion) { selectedRecord = nil; selectedShelf = nil; editing = true }
    }
    private func recordGesture(_ id: WorkID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("wall-records"))
            .updating($recordTouchActive) { _, active, _ in active = true }
            .onChanged { value in
                guard editing, let index = library.listenLater.firstIndex(of: id) else { return }
                if recordDrag == nil { recordDrag = WallRecordDrag(id: id, originIndex: index) }
                guard recordDrag?.id == id else { return }
                recordDrag?.translation = value.translation
                let origin = recordDrag?.originIndex ?? index
                let destination = min(library.listenLater.count - 1, max(0, origin + Int((value.translation.width / 58).rounded())))
                if destination != index {
                    let target = library.listenLater[destination]
                    if reduceMotion {
                        guard orderFade == nil else { return }
                        orderFade = Task { @MainActor in
                            withAnimation(.easeOut(duration:0.1)) { orderOpacity = 0 }
                            try? await Task.sleep(for:.milliseconds(100))
                            library.moveListenLater(id,toPositionOf:target)
                            withAnimation(.easeIn(duration:0.1)) { orderOpacity = 1 }
                            try? await Task.sleep(for:.milliseconds(100)); orderFade = nil
                        }
                    } else { withAnimation(motion) { library.moveListenLater(id, toPositionOf: target) } }
                }
            }
            .onEnded { _ in finishRecordDrag() }
    }
    private func finishRecordDrag() {
        guard let id = recordDrag?.id else { return }
        withAnimation(motion) { recordDrag = nil; settlingID = id }
        Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(120))
            withAnimation(motion) { if settlingID == id { settlingID = nil } }
        }
    }
    private func recordCaption(_ id: WorkID) -> some View {
        let entity = SeedLibraryBridge.entity(for: id, in: library)
        return VStack(alignment: .leading, spacing: 5) {
            Text(entity.title).font(.system(size: 17, weight: .semibold))
            Text(entity.subtitle).font(.system(size: 13.5)).foregroundStyle(ArtworkPalette.tx2).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 10) {
                if library.playbackPlatform == .apple {
                    Button("下一首播放") { onNext(id) }.disabled(library.playbackBusy || library.next == id)
                        .accessibilityIdentifier("wall-next")
                }
                Button(library.playbackPlatform.listenTitle) { library.listen(id) }
                    .accessibilityIdentifier("wall-listen")
            }.font(.system(size: 13.5)).buttonStyle(.glass).padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 4)
    }
    private var shelf: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(library.watchLaterEntries) { entry in
                        let entity = SeedLibraryBridge.entity(for: entry.workID, in: library)
                        let size = shelfSize(entity.kind)
                        let object = PhysicalObject(entity: entity, scale: size.width/PhysicalObject.baseSize(for: entity.kind).width,
                                       palette: palette, showsDisc: false, size: size)
                        object
                            .contentShape(.rect)
                            .onTapGesture { if !editing { selectedShelf = entry.id; selectedRecord = nil } }
                            .onLongPressGesture(perform: beginEditing)
                            .onDrag {
                                editing = true; dragging = "shelf:" + entry.id
                                return NSItemProvider(object: dragging! as NSString)
                            } preview: {
                                object.overlay(alignment: .topLeading) { removalMark.offset(x: -6, y: -6) }
                            }
                            .onDrop(of: [UTType.text], delegate: WallDropDelegate(target: "shelf:" + entry.id, dragging: $dragging) { source in
                                guard source.hasPrefix("shelf:") else { return }
                                library.moveWatchLater(String(source.dropFirst(6)), toPositionOf: entry.id)
                            })
                            .overlay(alignment: .topLeading) {
                                if editing {
                                    WallRemovalControl(bounds: shelfBounds) { library.removeWatchLater(entry.id) }.offset(x: -6, y: -6)
                                        .accessibilityIdentifier("wall-remove-shelf-" + entry.workID.rawValue)
                                }
                            }
                            .offset(y: selectedShelf == entry.id ? -8 : 0)
                            .accessibilityElement(children: editing ? .contain : .ignore).accessibilityHidden(false)
                            .accessibilityAddTraits(editing ? [] : .isButton).accessibilityLabel(entity.title)
                            .accessibilityIdentifier("wall-shelf-" + entry.workID.rawValue)
                    }
                }.frame(height: 154, alignment: .bottom).padding(.horizontal, 14).padding(.bottom, 4)
            }.scrollIndicators(.hidden).clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shelfBounds = $0 }
                .padding(.horizontal, 24)
                .background { CrateLining().padding(.horizontal, 14).padding(.top, 14) }
                .overlay { WallSidePanels().padding(.horizontal, 14).padding(.top, 14).allowsHitTesting(false) }
            CabinetShelf().frame(height: 17).padding(.horizontal, 10)
        }
    }
    private func shelfSize(_ kind: SeedGraph.Kind) -> CGSize {
        let base = PhysicalObject.baseSize(for: kind)
        let scale = kind == .video ? 150/base.width : 124/base.height
        return CGSize(width: base.width*scale, height: base.height*scale)
    }
    private func shelfCard(_ entry: WatchLaterEntry) -> some View {
        let entity = SeedLibraryBridge.entity(for: entry.workID, in: library)
        let work = library.catalog.work(entry.workID)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PhysicalObject(entity: entity, scale: 50/PhysicalObject.baseSize(for: entity.kind).height, palette: palette, showsDisc: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(entity.subtitle).font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx2)
                    if let rating = work.doubanRating, work.doubanRatingSource != nil {
                        Text("豆瓣 \(rating, specifier: "%.1f")").font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { selectedShelf = nil } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            if let origin = library.collectionOrigins[entry.workID.rawValue], let source = SeedNowContent.entity(origin) {
                Text("从《\(source.title)》走过来").font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx2)
            }
            HStack(spacing: 10) {
                Button("标为看过") { library.markWatchLaterEntryWatched(entry.id); selectedShelf = nil }
                    .accessibilityIdentifier("wall-mark-watched")
                let action = entity.kind == .video ? "播放视频" : "豆瓣"
                if let url = EntityActions.destination(action, entity, library: library) { Link(action, destination: url) }
            }.font(.system(size: 13.5, weight: .medium)).buttonStyle(.glass)
        }.padding(16).glassEffect(in: .rect(cornerRadius: 26))
            .accessibilityElement(children: .contain).accessibilityIdentifier("wall-shelf-card")
    }
    private func trailEntity(_ id: String) -> SeedGraph.Entity? {
        let work = library.catalog.canonicalID(for: SeedLibraryBridge.workID(id))
        guard library.catalog.works[work] != nil else { return SeedNowContent.entity(id) }
        return SeedLibraryBridge.entity(for: work, in: library)
    }
    private func trailRow(_ trail: RelationTrailStore.Entry) -> some View {
        let path = trail.map.focusPath
        return HStack(spacing: 14) {
            Button { onTrail(trail.id) } label: {
                HStack(spacing: 14) {
                    HStack(spacing: 3) {
                        ForEach(Array(path.prefix(3).enumerated()), id: \.element) { index, id in
                            if index > 0 { Rectangle().fill(palette.ac.color).frame(width: 8, height: 1.5) }
                            if let entity = trailEntity(id) {
                                PhysicalObject(entity: entity, scale: 32/PhysicalObject.baseSize(for: entity.kind).height, palette: palette, showsDisc: false)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(trail.map.root == trail.map.focus ? trailEntity(trail.map.root)?.title ?? "" : "\(trailEntity(trail.map.root)?.title ?? "") → \(trailEntity(trail.map.focus)?.title ?? "")")
                            .font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                        Text("\(trail.updatedAt == .distantPast ? "" : trailDate(trail.updatedAt) + "，")" + (trail.map.root == trail.map.focus && Set(trail.map.visits).count <= 1 ? "" : "走了 \(max(0, Set(trail.map.visits).count-1)) 站，") + "摊开 \(trail.map.nodes.count) 件")
                            .font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain).accessibilityIdentifier("wall-trail-" + trail.id)
            if editing { removeButton { trailStore.remove(root: trail.id); trails = trailStore.entries() } }
        }.padding(.horizontal, 22).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(ArtworkPalette.line).frame(height: 0.5).padding(.horizontal, 22) }
    }
    @ViewBuilder private var completedRows: some View {
        if !library.listenedIDs.isEmpty { completionRow("听过", ids: library.listenedIDs) }
        if !library.watchedIDs.isEmpty { completionRow("看过", ids: library.watchedIDs) }
    }
    private func completionRow(_ title: String, ids: [WorkID]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, count: "\(ids.count) 件") { EmptyView() }
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(ids) { id in
                        VStack(spacing: 8) {
                            PhysicalObject(entity: SeedLibraryBridge.entity(for: id, in: library), palette: palette, showsDisc: false)
                            Text(SeedLibraryBridge.entity(for: id, in: library).title).font(.system(size: 11)).lineLimit(1).frame(width: 80)
                        }.accessibilityIdentifier("wall-completed-" + id.rawValue)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }
    }
    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { removalMark }
            .buttonStyle(.plain).accessibilityLabel("移出")
    }
    private var removalMark: some View {
        Image(systemName: "minus.circle.fill").font(.system(size: 24)).symbolRenderingMode(.palette)
            .foregroundStyle(ArtworkPalette.paperInk, ArtworkPalette.paper)
    }
    private func appleURL(_ id: WorkID) -> URL? {
        guard let raw = library.catalog.work(id).url, let url = URL(string: raw), url.host == "music.apple.com" else { return nil }
        return url
    }
    private func trailDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }
}

private struct WallRecordDrag {
    let id: WorkID
    let originIndex: Int
    var translation = CGSize.zero
}

private struct WallViewport: Shape {
    var topOverflow: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY-topOverflow,
                    width: rect.width, height: rect.height+topOverflow))
    }
}

/// A partial object may pass behind a side board; a half delete control must
/// never become a target. It returns as soon as its whole corner is exposed.
private struct WallRemovalControl: View {
    let bounds: CGRect
    var action: () -> Void
    @State private var frame = CGRect.zero
    private var visible: Bool { !frame.isEmpty && bounds.insetBy(dx: 1, dy: 0).contains(frame) }
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").font(.system(size: 24)).symbolRenderingMode(.palette)
                .foregroundStyle(ArtworkPalette.paperInk, ArtworkPalette.paper)
        }.buttonStyle(.plain).accessibilityLabel("移出")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .opacity(visible ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
    }
}

private struct WallDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    var move: (String) -> Void
    func dropEntered(info: DropInfo) { if let dragging, dragging != target { withAnimation(.easeOut(duration: 0.2)) { move(dragging) } } }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
