import SwiftUI

struct RecordStoreRelationList: View {
    let center: WorkID
    let edges: [RelationEdge]
    let select: (RelationEdge) -> Void
    let openCenter: () -> Void
    // Kept for existing callers. Expanding the network belongs to the map.
    var explore: ((RelationEdge) -> Void)? = nil
    var scrollOffset: Binding<CGFloat> = .constant(0)
    #if DEBUG
    var expandsForDesignRendering = false
    #endif

    @Environment(Library.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    private let design = VisualDirection.orbit
    private let artworkSize: CGFloat = 54
    private var sectionSpacing: CGFloat { typeSize.isAccessibilitySize ? 12 : 0 }

    var body: some View {
        #if DEBUG
        if expandsForDesignRendering {
            designContent
        } else {
            scrollingContent
        }
        #else
        scrollingContent
        #endif
    }

    private var scrollingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) { sections }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .modifier(RelationListScrollRestoration(offset: scrollOffset))
        .accessibilityIdentifier("relation-list")
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .background(design.background)
        .foregroundStyle(design.foreground)
    }

    #if DEBUG
    /// The same sections without lazy loading, for a window-independent design
    /// artifact. This does not reproduce scrolling or system navigation chrome.
    private var designContent: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) { sections }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(design.background)
            .foregroundStyle(design.foreground)
    }
    #endif

    @ViewBuilder private var sections: some View {
        currentWork.padding(.bottom, 16)

        ForEach(Array(edges.enumerated()), id: \.element.id) { index, edge in
            relationRow(edge)
            if index < edges.count - 1 {
                Rectangle()
                    .fill(design.foreground.opacity(0.09))
                    .frame(height: 0.5)
                    .padding(.leading, typeSize.isAccessibilitySize ? 0 : artworkSize + 12)
                    .accessibilityHidden(true)
            }
        }
        // This appends other direct works of this center, never another depth.
        MoreWorksView(id: center).padding(.top, 16)
    }

    private var currentWork: some View {
        Button(action: openCenter) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                thumbnail(for: center)
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecordStoreArtwork.relationTitle(for: center))
                        .font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if center != .animenz {
                        Text(center.work.creator)
                            .font(.subheadline)
                            .foregroundStyle(design.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(design.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(center.displayTitle)，\(center.work.creator)")
        .accessibilityHint("打开作品详情")
    }

    @ViewBuilder private func relationRow(_ edge: RelationEdge) -> some View {
        if typeSize.isAccessibilitySize {
            accessibleRelationRow(edge)
        } else {
            compactRelationRow(edge)
        }
    }

    /// At accessibility sizes the complete title and relationship use the row
    /// width; the artwork and song action cannot squeeze either line.
    private func accessibleRelationRow(_ edge: RelationEdge) -> some View {
        let neighbor = edge.other(than: center)
        return VStack(alignment: .leading, spacing: 12) {
            Button { library.open(neighbor) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    thumbnail(for: neighbor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RecordStoreArtwork.relationTitle(for: neighbor))
                            .font(.body)
                        Text(subtitle(for: edge))
                            .font(.subheadline)
                            .foregroundStyle(design.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(edge.label(from: center))，\(neighbor.displayTitle)，\(neighbor.work.creator)，\(neighbor.work.kind)")
            .accessibilityHint("打开作品详情")
            .accessibilityIdentifier("relation-row-\(neighbor.rawValue)")
            .contextMenu { relationActions(edge) }

            if neighbor.work.isSong {
                Button { library.songSheet = neighbor } label: {
                    Label("播放选项", systemImage: "ellipsis")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(design.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(neighbor.displayTitle) 播放选项")
                .accessibilityHint(library.canControlPlayback ? "选择下一首播放、稍后听或现在播放" : "加入稍后听或在 Apple Music 中查看")
            }
        }
    }

    private func compactRelationRow(_ edge: RelationEdge) -> some View {
        let neighbor = edge.other(than: center)
        return HStack(alignment: .center, spacing: 4) {
            Button { library.open(neighbor) } label: {
                HStack(spacing: 12) {
                    thumbnail(for: neighbor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RecordStoreArtwork.relationTitle(for: neighbor))
                            .font(.body)
                            .lineLimit(1)
                        Text(subtitle(for: edge))
                            .font(.subheadline)
                            .foregroundStyle(design.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !neighbor.work.isSong {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium)).foregroundStyle(design.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .padding(.vertical, 3).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(edge.label(from: center))，\(neighbor.displayTitle)，\(neighbor.work.creator)，\(neighbor.work.kind)")
            .accessibilityHint("打开作品详情")
            .accessibilityIdentifier("relation-row-\(neighbor.rawValue)")
            .contextMenu { relationActions(edge) }
            if neighbor.work.isSong {
                Button { library.songSheet = neighbor } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.medium))
                        .foregroundStyle(design.secondary)
                        .frame(width: 44, height: 44).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(neighbor.displayTitle) 播放选项")
                .accessibilityHint(library.canControlPlayback ? "选择下一首播放、稍后听或现在播放" : "加入稍后听或在 Apple Music 中查看")
            }
        }
    }

    @ViewBuilder private func relationActions(_ edge: RelationEdge) -> some View {
        Button("查看关系与出处", systemImage: "text.quote") { select(edge) }
    }

    private func thumbnail(for id: WorkID) -> some View {
        RecordStoreArtwork(id: id, size: artworkSize, showsPlaceholderTitle: false,
                           showsCreatorRole: false, isThumbnail: true)
            .accessibilityHidden(true)
    }

    private func subtitle(for edge: RelationEdge) -> String {
        let neighbor = edge.other(than: center)
        let relationship = edge.label(from: center)
        let creator = neighbor.work.creator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !neighbor.work.isPerson, neighbor != .animenz,
              !creator.isEmpty, creator != relationship,
              creator != neighbor.displayTitle else { return relationship }
        return "\(relationship) · \(creator)"
    }
}

