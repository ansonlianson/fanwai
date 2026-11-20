import SwiftUI

/// One work and its direct neighbors. Spatial proximity never invents a link.
struct RecordStoreRelationMap: View {
    let center: WorkID
    let edges: [RelationEdge]
    let size: CGSize
    var accommodatesNavigation = false
    var selectedID: WorkID?
    let select: (RelationEdge) -> Void
    let openCenter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var objects
    private let style = VisualDirection.orbit
    private var visible: [RelationEdge] { Array(edges.prefix(4)) }
    private var height: CGFloat { max(accommodatesNavigation ? 448 : 500, min(560, size.height)) }
    private var smallSize: CGFloat { size.width < 360 || height < 500 ? 76 : 84 }
    private var largeSize: CGFloat { size.width < 360 || height < 500 ? 118 : 132 }
    private var rootPosition: CGPoint {
        CGPoint(x: size.width * (visible.count == 1 ? 0.37 : 0.5), y: height * (visible.count == 1 ? 0.34 : 0.5))
    }

    var body: some View {
        ZStack {
            style.background
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, edge in
                connection(index)
                    .stroke(selectedID == edge.other(than: center) ? style.accent.opacity(0.72) : style.foreground.opacity(0.23),
                            style: StrokeStyle(lineWidth: selectedID == edge.other(than: center) ? 1.8 : 1, lineCap: .round))
                    .accessibilityHidden(true)
            }
            root
                .matchedGeometryEffect(id: center.rawValue, in: objects)
                .position(rootPosition)
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, edge in
                node(edge)
                    .matchedGeometryEffect(id: edge.other(than: center).rawValue, in: objects)
                    .position(position(index))
            }
        }
        .frame(width: size.width, height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: center)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selectedID)
    }

    private func position(_ index: Int) -> CGPoint {
        let points: [(CGFloat, CGFloat)]
        switch visible.count {
        case 1: points = [(0.68, 0.76)]
        case 2: points = [(0.24, 0.16), (0.76, 0.84)]
        case 3: points = [(0.5, 0.15), (0.24, 0.84), (0.76, 0.84)]
        default: points = [(0.24, 0.16), (0.76, 0.16), (0.24, 0.84), (0.76, 0.84)]
        }
        return CGPoint(x: size.width * points[index].0, y: height * points[index].1)
    }

    private func connection(_ index: Int) -> Path {
        let p = position(index)
        // Endpoints are behind opaque objects. Labels have a small paper backing.
        let start = CGPoint(x: rootPosition.x + (p.x < rootPosition.x ? -1 : 1) * largeSize * 0.32,
                            y: rootPosition.y + (p.y < rootPosition.y ? -0.45 : 0.18) * largeSize)
        let end = CGPoint(x: p.x, y: p.y - 30)
        let dx = end.x - start.x
        let dy = end.y - start.y
        return Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + dx * 0.12, y: start.y + dy * 0.55),
                          control2: CGPoint(x: end.x - dx * 0.22, y: end.y - dy * 0.22))
        }
    }

    private var root: some View {
        Button(action: openCenter) {
            VStack(spacing: 8) {
                RecordStoreArtwork(id: center, size: largeSize, showsDisc: true,
                                   discOffset: 0.25, showsPlaceholderTitle: false)
                    .rotationEffect(.degrees(center.work.isSong || center.work.isAlbum ? -3 : 0))
                Text(RecordStoreArtwork.relationTitle(for: center))
                    .font(.system(size: 21, weight: .semibold)).tracking(-0.6)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(style.background)
            }
            .frame(width: min(188, size.width * 0.48))
            .contentShape(.rect)
        }
        .foregroundStyle(style.foreground)
        .buttonStyle(RecordObjectPressStyle())
        .accessibilityLabel("当前中心，\(center.displayTitle)，查看详情")
    }

    private func node(_ edge: RelationEdge) -> some View {
        let target = edge.other(than: center)
        let selected = selectedID == target
        return Button { select(edge) } label: {
            VStack(spacing: 7) {
                RecordStoreArtwork(id: target, size: smallSize, showsPlaceholderTitle: false,
                                   showsCreatorRole: false)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(style.accent.opacity(0.8), lineWidth: 1)
                                .frame(width: RecordStoreArtwork.objectWidth(for: target, size: smallSize) + 9,
                                       height: RecordStoreArtwork.objectHeight(for: target, size: smallSize) + 9)
                        }
                    }
                VStack(spacing: 4) {
                    Text(RecordStoreArtwork.relationTitle(for: target))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2).frame(minHeight: 18)
                        .foregroundStyle(style.foreground)
                    Text(edge.label(from: center))
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? style.accent : style.secondary)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(style.background)
            }
            .frame(width: min(144, size.width * 0.43), height: height < 500 ? 136 : 148)
            .contentShape(.rect)
        }
        .buttonStyle(RecordObjectPressStyle())
        .accessibilityLabel("\(edge.label(from: center))，\(target.displayTitle)，\(target.work.kind)")
        .accessibilityIdentifier("relation-node-\(target.rawValue)")
    }
}
