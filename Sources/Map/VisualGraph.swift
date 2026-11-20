import SwiftUI

/// Three art directions over the same, source-backed relationship layer.
/// Coordinates are stable: no force simulation, random placement, or idle animation.
struct VisualRelationMap: View {
    let center: WorkID
    let edges: [RelationEdge]
    let size: CGSize
    let style: VisualDirection
    var selectedID: WorkID? = nil
    let select: (RelationEdge) -> Void
    let openCenter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var positions

    private var palette: GraphPalette { GraphPalette(style: style) }
    private var visible: [RelationEdge] { Array(edges.prefix(4)) }
    private var origin: CGPoint {
        switch style {
        case .spectrum: return point(0.50, 0.48)
        case .atlas: return point(0.27, 0.25)
        case .orbit: return point(0.29, 0.42)
        }
    }

    var body: some View {
        ZStack {
            backdrop
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, edge in
                let position = neighborPosition(index)
                let tint = edgeColor(index, edge)
                connection(to: position, index: index)
                    .stroke(tint.opacity(selectedID == edge.other(than: center) ? 1 : style == .atlas ? 0.65 : 0.8), style: StrokeStyle(lineWidth: selectedID == edge.other(than: center) ? 3 : style == .orbit ? 2.3 : 1.7, lineCap: .round))
                    .accessibilityHidden(true)
                if style == .atlas {
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .position(lineStart(index)).accessibilityHidden(true)
                }
                neighbor(edge, index: index, tint: tint)
                    .scaleEffect(selectedID == edge.other(than: center) && !reduceMotion ? 1.045 : 1)
                    .opacity(selectedID == nil || selectedID == edge.other(than: center) ? 1 : 0.55)
                    .matchedGeometryEffect(id: edge.other(than: center).rawValue, in: positions)
                    .position(position)
                    .transition(.opacity)
            }
            centerNode
                .matchedGeometryEffect(id: center.rawValue, in: positions)
                .position(origin)
                .transition(.opacity)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: style == .atlas ? 0.34 : 0.48, dampingFraction: 0.86), value: center)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.28), value: style)
        .animation(.easeOut(duration: 0.18), value: selectedID)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * y)
    }

    private func neighborPosition(_ index: Int) -> CGPoint {
        let anchors: [(CGFloat, CGFloat)]
        switch style {
        case .spectrum:
            anchors = [(0.21, 0.15), (0.80, 0.25), (0.77, 0.84), (0.20, 0.77)]
        case .atlas:
            anchors = [(0.76, 0.16), (0.76, 0.47), (0.25, 0.78), (0.76, 0.81)]
        case .orbit:
            anchors = [(0.78, 0.16), (0.78, 0.48), (0.78, 0.81), (0.24, 0.82)]
        }
        let p = anchors[min(index, anchors.count - 1)]
        return point(p.0, p.1)
    }

    private func lineStart(_ index: Int) -> CGPoint {
        if style == .atlas {
            return CGPoint(x: origin.x + (index < 2 ? 62 : 0), y: origin.y + (index < 2 ? -24 : 26))
        }
        return origin
    }

    private func connection(to end: CGPoint, index: Int) -> Path {
        let start = lineStart(index)
        return Path { p in
            p.move(to: start)
            switch style {
            case .spectrum:
                let bend: CGFloat = index.isMultiple(of: 2) ? -24 : 24
                p.addCurve(to: end,
                           control1: CGPoint(x: start.x + bend, y: start.y + (end.y - start.y) * 0.52),
                           control2: CGPoint(x: end.x - bend, y: end.y - (end.y - start.y) * 0.25))
            case .atlas:
                let mid = CGPoint(x: (start.x + end.x) / 2, y: end.y)
                p.addQuadCurve(to: end, control: mid)
            case .orbit:
                let bendX = index == 3 ? start.x - 48 : min(size.width - 24, end.x + 36)
                p.addCurve(to: end,
                           control1: CGPoint(x: bendX, y: start.y),
                           control2: CGPoint(x: bendX, y: end.y))
            }
        }
    }

    @ViewBuilder private var backdrop: some View {
        palette.background
        if style == .spectrum {
            Ellipse().fill(GraphPalette.tint(for: center).opacity(0.20))
                .frame(width: size.width * 0.8, height: size.height * 0.65)
                .blur(radius: 65).position(origin)
            Ellipse().fill(Color(graphHex: 0x886A9D).opacity(0.12))
                .frame(width: 210, height: 190).blur(radius: 60)
                .position(point(0.9, 0.18))
        } else if style == .orbit {
            Circle().trim(from: 0.57, to: 0.87)
                .stroke(palette.accent.opacity(0.48), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 226, height: 226).rotationEffect(.degrees(-35)).position(origin)
            Ellipse().fill(palette.accent.opacity(0.055)).frame(width: 240, height: 350)
                .blur(radius: 60).position(point(0.2, 0.5))
        }
    }

    private func neighbor(_ edge: RelationEdge, index: Int, tint: Color) -> some View {
        let id = edge.other(than: center)
        return Button { select(edge) } label: {
            VStack(alignment: style == .atlas ? .leading : .center, spacing: 7) {
                artwork(id, center: false, tint: tint)
                Text(shortTitle(id))
                    .font(.system(size: 13, weight: .semibold, design: style == .atlas ? .serif : .default))
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(style == .atlas ? .leading : .center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(edge.label(from: center))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .multilineTextAlignment(style == .atlas ? .leading : .center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, style == .atlas ? 0 : 4)
            .padding(.vertical, 5)
            .frame(width: style == .atlas ? 110 : 118)
            .background {
                if style != .atlas {
                    RoundedRectangle(cornerRadius: 18).fill(palette.background.opacity(0.85)).blur(radius: 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GraphNodePressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("\(edge.label(from: center))，\(id.work.title)，\(id.work.kind)")
        .accessibilityHint("查看关系与出处")
    }

    private var centerNode: some View {
        Button(action: openCenter) {
            VStack(alignment: style == .atlas ? .leading : .center, spacing: 10) {
                artwork(center, center: true, tint: GraphPalette.tint(for: center))
                VStack(alignment: style == .atlas ? .leading : .center, spacing: 5) {
                    Text(shortTitle(center))
                        .font(.system(size: style == .orbit ? 20 : 19, weight: .semibold, design: style == .atlas ? .serif : .default))
                        .tracking(style == .orbit ? -0.7 : -0.3)
                        .foregroundStyle(palette.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(center.work.isPerson ? center.work.creator : center.work.kind)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
                .multilineTextAlignment(style == .atlas ? .leading : .center)
            }
            .padding(8)
            .frame(width: style == .atlas ? 148 : 166)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(palette.background.opacity(style == .atlas ? 1 : 0.94))
                    .blur(radius: style == .atlas ? 0 : 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GraphNodePressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("当前中心，\(center.work.title)，查看详情")
    }

    @ViewBuilder private func artwork(_ id: WorkID, center isCenter: Bool, tint: Color) -> some View {
        let dimensions = artworkSize(id, center: isCenter)
        let radius: CGFloat = id.work.isPerson ? dimensions.width / 2 : (style == .atlas ? 3 : 14)
        ZStack {
            if !id.work.art.isEmpty {
                Image(id.work.art).resizable().scaledToFill()
                    .frame(width: dimensions.width, height: dimensions.height)
                    .clipped()
            } else if id.work.isPerson {
                Circle().fill(LinearGradient(colors: [tint.opacity(style == .atlas ? 0.2 : 0.25), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(personGlyph(id))
                    .font(.system(size: isCenter ? 32 : 25, weight: .regular, design: .serif))
                    .tracking(1.5).foregroundStyle(style == .atlas ? palette.ink : tint)
            } else {
                Rectangle().fill(style == .atlas ? Color(graphHex: 0xE7DDCB) : tint.opacity(0.15))
                VStack(spacing: 7) {
                    Image(systemName: "book.closed").font(.system(size: 17, weight: .light))
                    Text(id.work.title).font(.system(size: isCenter ? 20 : 16, weight: .medium, design: .serif))
                        .lineLimit(2).multilineTextAlignment(.center)
                }.foregroundStyle(style == .atlas ? palette.ink : tint).padding(8)
            }
        }
        .frame(width: dimensions.width, height: dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .stroke(style == .atlas ? palette.ink.opacity(0.13) : tint.opacity(isCenter ? 0.65 : 0.3), lineWidth: isCenter ? 1.4 : 0.8)
        }
        .padding(style == .atlas ? 5 : 0)
        .background {
            if style == .atlas {
                Rectangle().fill(Color.white.opacity(0.9))
                    .shadow(color: palette.ink.opacity(0.12), radius: 5, x: 0, y: 3)
            }
        }
        .shadow(color: style == .spectrum ? tint.opacity(isCenter ? 0.30 : 0.12) : .clear, radius: isCenter ? 24 : 10, y: 4)
        .accessibilityHidden(true)
    }

    private func artworkSize(_ id: WorkID, center isCenter: Bool) -> CGSize {
        let width: CGFloat = isCenter ? (style == .orbit ? 142 : (style == .atlas ? 114 : 126)) : (style == .atlas ? 82 : 84)
        if id.work.kind == "电影" || id.work.kind == "漫画" {
            return CGSize(width: isCenter ? width * 0.84 : width * 0.84, height: isCenter ? width * 1.08 : width * 1.12)
        }
        if id.work.kind == "演奏视频" { return CGSize(width: width, height: width * 0.66) }
        return CGSize(width: width, height: width)
    }

    private func shortTitle(_ id: WorkID) -> String {
        if id == .animenz { return "Animenz 改编" }
        if id == .janeAlbum { return "JANE DOE" }
        return id.work.title
    }

    private func personGlyph(_ id: WorkID) -> String {
        switch id {
        case .animenzPerson: return "A"
        case .ushio: return "牛尾"
        case .yonezu: return "米津"
        case .utada: return "宇多田"
        case .yoshihara: return "吉原"
        case .fujimoto: return "藤本"
        default: return String(id.work.title.prefix(2))
        }
    }

    private func edgeColor(_ index: Int, _ edge: RelationEdge) -> Color {
        if style == .atlas {
            return [Color(graphHex: 0x496C9A), Color(graphHex: 0xA85E40), Color(graphHex: 0x5B775E), Color(graphHex: 0x8F6480)][index % 4]
        }
        if style == .orbit {
            return style.secondary
        }
        return GraphPalette.tint(for: edge.other(than: center))
    }
}

private struct GraphNodePressStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct GraphPalette {
    let style: VisualDirection
    var background: Color {
        style.background
    }
    var ink: Color { style == .atlas ? Color(graphHex: 0x25302E) : Color(graphHex: 0xF4F5EE) }
    var secondary: Color { style == .atlas ? Color(graphHex: 0x68716B) : Color(graphHex: 0xA5B2B1) }
    var accent: Color { style == .orbit ? Color(graphHex: 0xD8FA72) : Color(graphHex: 0x90CFCA) }
    static func tint(for id: WorkID) -> Color {
        switch id {
        case .film: Color(graphHex: 0xE8A279)
        case .animenz, .animenzPerson, .ravel, .debussy: Color(graphHex: 0xB6A0DD)
        case .manga, .fujimoto: Color(graphHex: 0xE8C484)
        case .jane, .janeAlbum, .yonezu: Color(graphHex: 0xD2C3E6)
        case .distance, .distanceAlbum, .utada: Color(graphHex: 0xECAC9E)
        default: Color(graphHex: 0x94CFCC)
        }
    }
}

private extension Color {
    init(graphHex: UInt32) {
        self.init(.sRGB, red: Double((graphHex >> 16) & 0xFF) / 255, green: Double((graphHex >> 8) & 0xFF) / 255, blue: Double(graphHex & 0xFF) / 255, opacity: 1)
    }
}
