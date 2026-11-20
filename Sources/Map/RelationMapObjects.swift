import SwiftUI

struct MapCurve: Shape {
    var from: CGPoint
    var to: CGPoint
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(from.x, from.y), .init(to.x, to.y)) }
        set { from = CGPoint(x: newValue.first.first, y: newValue.first.second); to = CGPoint(x: newValue.second.first, y: newValue.second.second) }
    }
    var control: CGPoint {
        CGPoint(x: (from.x+to.x)/2 - (to.y-from.y)*0.12, y: (from.y+to.y)/2 + (to.x-from.x)*0.12)
    }
    var labelPoint: CGPoint { CGPoint(x: (from.x+2*control.x+to.x)/4, y: (from.y+2*control.y+to.y)/4) }
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: from); path.addQuadCurve(to: to, control: control); return path
    }
}

struct RelationMapObject: View {
    let entity: SeedGraph.Entity
    let root: Bool
    let focused: Bool
    let onPath: Bool
    let dimmed: Bool
    let expanded: Bool
    let pending: Int
    let label: String?
    let cameraScale: CGFloat
    let showsRelation: Bool
    let palette: ArtworkPalette
    let ping: Int
    /// In focus and open: the corner chip says a second tap folds it back.
    var collapsible = false
    var displayTitle: String? = nil
    var detail: String? = nil
    var sizeMultiplier: CGFloat = 1
    var keepsNameVisible = false
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The camera scale while a finger pinches (0.5.9). Labels follow it continuously; their font
    /// size itself is set from the committed scale, so text is crisp again after the pinch, and the
    /// two meet exactly at the commit — no jump in size when the finger lifts.
    @Environment(MapZoom.self) private var zoom: MapZoom?
    var objectScale: CGFloat { (root && entity.kind.isMusic ? 104/64 : 1) * sizeMultiplier }
    var objectHeight: CGFloat { PhysicalObject.baseSize(for: entity.kind).height * objectScale }
    private var liveScale: CGFloat { max(0.01, zoom?.scale ?? cameraScale) }
    /// Font size in map coordinates for a given camera scale: never smaller than 10pt on screen.
    private func nameSize(_ scale: CGFloat) -> CGFloat { Self.nameSize(scale, root: root) }
    static func nameSize(_ scale: CGFloat, root: Bool) -> CGFloat { max(root ? 14 : 12, 10 / max(scale, 0.01)) }
    /// How much the name block must grow or shrink now so that, on screen, it already shows the
    /// size it will be drawn at after the pinch commits.
    private var nameFollow: CGFloat { nameSize(liveScale) / nameSize(cameraScale) }
    /// The width the name is laid out in, in map coordinates. It follows the live scale too, so the
    /// name is cut off at the same letter during the pinch as after it: nothing jumps when the
    /// finger lifts (anson 11-18). `base` is the on-screen width at scale 1.
    static func nameWidth(_ base: CGFloat, live: CGFloat, committed: CGFloat, root: Bool) -> CGFloat {
        base / min(max(live, 0.01), 1) / (nameSize(live, root: root) / nameSize(committed, root: root))
    }
    /// Names fade in over a short stretch of zoom instead of popping at a threshold.
    static func nameOpacity(live: CGFloat, always: Bool, showsRelation: Bool) -> CGFloat {
        if always { return 1 }
        func ramp(_ at: CGFloat) -> CGFloat { min(1, max(0, (live - (at - 0.07)) / 0.14)) }
        return max(ramp(0.62), showsRelation ? ramp(0.42) : 0)
    }
    private var nameOpacity: CGFloat {
        Self.nameOpacity(live: liveScale, always: keepsNameVisible || root || focused || onPath, showsRelation: showsRelation)
    }
    var body: some View {
        let motionReduced = reduceMotion
        Button(action: action) {
            VStack(spacing: 7) {
                Group {
                    if ShopStyle.enabled {
                        ShopObject(entity: entity, height: objectHeight * (root ? 1.05 : 1.3), asSleeve: root)
                            .shadow(color: .black.opacity(0.55), radius: 5, x: 2, y: 4)
                    } else {
                        PhysicalObject(entity: entity, scale: objectScale, palette: palette, discLeading: root ? 0.30 : 0.22,
                                       showsPersonName: false,
                                       showsPrintedTitle: PhysicalObject.baseSize(for: entity.kind).width*objectScale*cameraScale >= 44)
                    }
                }
                    .compositingGroup()
                    // Opaque warm shading keeps unprinted paper distinct from
                    // the blue felt, including when artwork cannot be loaded.
                    .saturation(dimmed ? 0.85 : 1)
                    .colorMultiply(dimmed ? (entity.kind.isMusic ? Color(white: 0.90) : Color(red: 0.82, green: 0.77, blue: 0.68)) : .white)
                    .overlay(alignment: .topLeading) {
                        if showsRelation, let label {
                            ObjectLabel(relation: label)
                                .scaleEffect(1 / min(liveScale, 1), anchor: .topLeading)
                                .offset(x: -4, y: -16 / min(liveScale, 1))
                                .zIndex(10)
                        }
                    }
                    .background {
                        RadialGradient(colors: [(ShopStyle.enabled ? ShopStyle.accent : palette.ac.color).opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: 95)
                            .frame(width: 190, height: 190).opacity(focused ? 1 : 0).allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if pending > 0 && !expanded {
                            cornerChip(Text(String(pending)).font(.system(size: 10.5, weight: .semibold)))
                        } else if collapsible {
                            cornerChip(Image(systemName: "minus").font(.system(size: 10, weight: .bold)))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .offset(y: focused ? -4 : 0)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: ping) { content, value in
                        content.scaleEffect(motionReduced ? 1 : value)
                    } keyframes: { _ in
                        CubicKeyframe(1.14, duration: 0.36)
                        CubicKeyframe(1, duration: 0.54)
                        CubicKeyframe(1.14, duration: 0.36)
                        CubicKeyframe(1, duration: 0.54)
                    }
                VStack(spacing: 2) {
                    Text(displayTitle ?? entity.title).font(.system(size: nameSize(cameraScale), weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: Self.nameWidth(96, live: liveScale, committed: cameraScale, root: root))
                        .accessibilityIdentifier("map-name-" + entity.id)
                    if let detail {
                        Text(detail).font(.system(size: max(10, 8/max(cameraScale,0.01))))
                            .foregroundStyle(ArtworkPalette.tx2).lineLimit(1).truncationMode(.tail)
                            .frame(width: Self.nameWidth(112, live: liveScale, committed: cameraScale, root: root))
                    }
                }
                .scaleEffect(nameFollow, anchor: .top)
                .opacity(nameOpacity * (dimmed ? 0.58 : 1))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: keepsNameVisible || root || focused || onPath)
            }.frame(width: 108, alignment: .top)
                .foregroundStyle(ArtworkPalette.tx)
                .contentShape(.rect)
        }.buttonStyle(.plain)
            .accessibilityLabel(entity.title)
            .accessibilityValue(collapsible ? "已展开，再点一次收起" : expanded ? "已展开" : pending > 0 ? "还有 \(pending) 个关联" : "")
            .accessibilityIdentifier("map-node-" + entity.id)
    }
    /// The paper disc in a sleeve's corner: how many more it holds, or「−」to fold it back.
    private func cornerChip(_ content: some View) -> some View {
        content.foregroundStyle(ArtworkPalette.paperInk).frame(width: 21, height: 21)
            .background(Color(red: 233/255, green: 227/255, blue: 214/255), in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            .rotationEffect(.degrees(-8)).shadow(color: .black.opacity(0.45), radius: 2, y: 2)
            .offset(x: 7, y: 6)
    }
}

/// A quiet woven surface; the objects and their paths carry the contrast.
struct FeltBackdrop: View {
    let palette: ArtworkPalette
    var body: some View {
        ZStack {
            palette.bg.color
            RadialGradient(colors: [.white.opacity(0.055), .clear], center: UnitPoint(x: 0.45, y: 0.35), startRadius: 0, endRadius: 560)
            Canvas { context, size in
                for y in stride(from: CGFloat(0), to: size.height, by: 4) {
                    for x in stride(from: CGFloat(0), to: size.width, by: 4) {
                        let row = Int(y/4), column = Int(x/4)
                        let vertical = (row + column) % 2 == 0
                        let rect = CGRect(x: x, y: y, width: vertical ? 0.6 : 2.8, height: vertical ? 2.8 : 0.6)
                        context.fill(Path(rect), with: .color(.white.opacity((row*13+column*7)%3 == 0 ? 0.025 : 0.012)))
                    }
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
