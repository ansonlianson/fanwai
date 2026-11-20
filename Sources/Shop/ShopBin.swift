import SwiftUI
import UIKit

/// Shared look of the shop pages (此刻, 收藏, 搜索, 关系图).
@MainActor enum ShopStyle {
    static let base = Color(red: 0.090, green: 0.074, blue: 0.055)
    static let ink = Color(red: 0.93, green: 0.92, blue: 0.89)
    static let secondary = Color(red: 0.71, green: 0.68, blue: 0.62)
    static let tertiary = Color(red: 0.55, green: 0.52, blue: 0.47)
    static let accent = Color(red: 0.86, green: 0.80, blue: 0.65)
    static let line = Color(red: 0.93, green: 0.92, blue: 0.89).opacity(0.12)
    static var enabled: Bool { ShopPlates.shared.isAvailable }

    /// Which photographed object stands for a kind of work.
    static func objectKind(_ kind: SeedGraph.Kind) -> String {
        switch kind {
        case .song, .album: "cd"
        case .film, .tv: "bd"
        case .game: "game"
        case .video: "video"
        case .book, .manga: "book"
        case .person, .group: "person"
        }
    }
    static func heroPart(_ kind: SeedGraph.Kind) -> String {
        switch kind {
        case .song, .album: "lp"
        case .film, .tv, .video, .game: "bd"
        case .book, .manga: "book"
        case .person, .group: "person"
        }
    }
}

/// Dark shop backdrop for list-like pages: the shop photograph far out of focus.
struct ShopPageBackdrop: View {
    var body: some View { ShopMapBackdrop() }
}

// MARK: - The bin

struct ShopBinEntry: Identifiable, Hashable {
    let id: String
    let kind: String          // cd | bd | game | video | book | person | anon | end
    var title: String? = nil  // printed on the divider label; nil = anonymous stock
    var relation: String? = nil
    var artwork: String? = nil
    var coverTitle = ""
    var placeholder = false
    var action = false
}

/// A row of bin compartments laid side by side in a native horizontal scroll view.
/// The strip starts at plate row `top` and ends at `bottom`; its height follows the width.
struct ShopBinStrip<Hit: View>: View {
    let entries: [ShopBinEntry]
    let width: CGFloat
    var top: CGFloat = 1580
    var bottom: CGFloat = ShopPlates.plateHeight
    var leadIn: CGFloat = 36
    /// <1 draws the bin slightly smaller than the scene so the next compartment peeks in.
    var scale: CGFloat = 1
    var tail = true
    /// The plain compartments around the works: stocked, or bare ("empty") when nothing was found.
    var stock = "anon"
    /// What stood in compartments 1, 2, … a moment ago; it sinks out behind the front board once
    /// `departed` turns true (翻到箱底, anson 11-18 17:30).
    var departing: [ShopBinEntry] = []
    var departed = false
    var onPullUp: (() -> Void)? = nil
    /// A work opened from the bin zooms out of its own cover, and its page shrinks back into it.
    var transitionNamespace: Namespace.ID? = nil
    @ViewBuilder var hit: (ShopBinEntry, CGRect) -> Hit

    var body: some View {
        let plates = ShopPlates.shared
        let k = width / ShopPlates.plateWidth * scale
        let leadW = plates.tile(stock)?.width ?? 385
        let terminal = entries.filter { $0.action }
        var sequence = [ShopBinEntry(id: "__lead", kind: stock)] + entries.filter { !$0.action }
            + (tail && terminal.isEmpty ? [ShopBinEntry(id: "__tail", kind: stock)] : [])
        // Keep actions beside the actual works; padding stock must not push a small bin's
        // next action out of view.
        sequence += terminal
        // A page with little or nothing found still gets a bin as wide as the screen: more plain
        // stock is slotted in so the end board never stops halfway across.
        var filled = leadIn - leadW + sequence.reduce(0) { $0 + (plates.tile($1.kind)?.width ?? 0) }
        var fill = 0
        while filled * k < width, fill < 8 {
            fill += 1
            sequence.append(ShopBinEntry(id: "__fill\(fill)", kind: stock))
            filled += plates.tile(stock)?.width ?? 385
        }
        sequence.append(ShopBinEntry(id: "__end", kind: "end"))
        var origins: [CGFloat] = []
        var x = leadIn - leadW
        for e in sequence { origins.append(x); x += plates.tile(e.kind)?.width ?? 0 }
        let contentWidth = max(width, x * k + 10)
        let height = (bottom - top) * k
        return ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(sequence.enumerated()), id: \.offset) { i, e in
                    ShopBinTile(entry: e, k: k, leaving: i >= 1 && i <= departing.count ? departing[i - 1] : nil,
                                gone: departed, delay: Double(max(0, i - 1)) * 0.11)
                        .offset(x: origins[i] * k, y: -top * k)
                }
                if let transitionNamespace {
                    // Zoom anchors over each cover. They must be rendered (a clear view gives the
                    // zoom nothing to attach to, and it then falls back to the middle of the screen)
                    // and placed by layout, not by offset.
                    ForEach(Array(sequence.enumerated()), id: \.offset) { i, e in
                        if e.title != nil, !e.placeholder, let q = plates.tile(e.kind)?.item?.quadPoints, q.count == 4 {
                            let xs = q.map(\.x), ys = q.map(\.y)
                            Rectangle().fill(Color.black.opacity(0.002))
                                .frame(width: (xs.max()! - xs.min()!) * k, height: (ys.max()! - ys.min()!) * k)
                                .matchedTransitionSource(id: e.id, in: transitionNamespace) { $0.clipShape(.rect(cornerRadius: 3)) }
                                .allowsHitTesting(false).accessibilityHidden(true)
                                .padding(.leading, (origins[i] + xs.min()!) * k).padding(.top, (ys.min()! - top) * k)
                        }
                    }
                }
                ForEach(Array(sequence.enumerated()), id: \.offset) { i, e in
                    if e.title != nil, !e.placeholder || e.action, let b = plates.tile(e.kind)?.item?.bounds {
                        hit(e, CGRect(x: (origins[i] + b.minX) * k, y: (b.minY - top) * k, width: b.width * k, height: b.height * k))
                    }
                }
            }
            .frame(width: contentWidth, height: height, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: height)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard let onPullUp, v.translation.height < -70, abs(v.translation.width) < 40 else { return }
            onPullUp()
        })
    }
}

/// One compartment: stock behind, the featured work with its divider label, front board.
struct ShopBinTile: View {
    let entry: ShopBinEntry
    let k: CGFloat
    /// What stood here a moment ago (a blank sleeve, plain stock): it sinks behind the front board.
    var leaving: ShopBinEntry? = nil
    var gone = false
    var delay = 0.0
    /// Bottom of the front board, in plate pixels: a sinking sleeve is never drawn below it.
    static let frontBottom: CGFloat = 2196
    var body: some View {
        let plates = ShopPlates.shared
        let folder = "tiles/" + entry.kind
        if let tile = plates.tile(entry.kind) {
            ZStack(alignment: .topLeading) {
                if let bg = tile.bg { ShopLayerImage(image: plates.image(folder, bg.file), frame: bg.frame.rect, k: k) }
                if let leaving, let old = plates.tile(leaving.kind) { departing(leaving, old) }
                if let item = tile.item { Self.item(entry, item, folder: folder, k: k) }
                if let front = tile.front { ShopLayerImage(image: plates.image(folder, front.file), frame: front.frame.rect, k: k) }
            }
            .frame(width: tile.width * k, height: ShopPlates.plateHeight * k, alignment: .topLeading)
            .transition(.opacity)
        }
    }
    private func departing(_ e: ShopBinEntry, _ old: ShopTile) -> some View {
        let plates = ShopPlates.shared
        let folder = "tiles/" + e.kind
        return ZStack(alignment: .topLeading) {
            if let bg = old.bg {
                ShopLayerImage(image: plates.image(folder, bg.file), frame: bg.frame.rect, k: k)
                    .opacity(gone ? 0 : 1)
                    .animation(.easeOut(duration: 0.4).delay(delay + 0.06), value: gone)
            }
            if let item = old.item {
                Self.item(e, item, folder: folder, k: k)
                    .offset(y: gone ? 310 * k : 0)
                    .opacity(gone ? 0 : 1)
                    .animation(.easeIn(duration: 0.38).delay(delay), value: gone)
            }
        }
        .frame(width: old.width * k, height: Self.frontBottom * k, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }
    /// The featured object: its cover (or the clerk's card), the shell, and the divider label.
    static func item(_ entry: ShopBinEntry, _ item: ShopTile.Item, folder: String, k: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ShopOnQuad(quad: item.quadPoints.map { CGPoint(x: $0.x * k, y: $0.y * k) }) { size in
                if entry.action {
                    ZStack {
                        Color(red: 0.337, green: 0.220, blue: 0.118)
                        Image(uiImage: PrintedTexture.fibres).resizable(resizingMode: .tile).opacity(0.22)
                    }
                } else {
                    ShopCover(artwork: entry.artwork, title: entry.coverTitle, placeholder: entry.placeholder || entry.title == nil,
                              workID: entry.title == nil ? nil : WorkID(rawValue: entry.id))
                }
            }
            ShopLayerImage(image: ShopPlates.shared.image(folder, item.file), frame: item.frame.rect, k: k)
            if let title = entry.title {
                ShopOnQuad(quad: item.tabPoints.map { CGPoint(x: $0.x * k, y: $0.y * k) }) { size in
                    ShopTabText(title: title, relation: entry.relation, size: size)
                }
            }
        }
    }
}

// MARK: - The same photographed objects, cut out for lists, the map and search

struct ShopSprite: View {
    let kind: String          // cd | bd | game | video | book | person | lp
    let artwork: String?
    let title: String
    let height: CGFloat
    var workID: WorkID? = nil

    private struct Source { let folder: String; let file: String; let frame: CGRect; let quad: [CGPoint]; let crop: CGRect }
    private static func source(_ kind: String) -> Source? {
        let plates = ShopPlates.shared
        if kind == "lp", let m = plates.main("lp"), let s = m.slots["hero"], let q = s.quadPoints, let o = s.over, let f = s.frame {
            return Source(folder: "lp", file: o, frame: f.rect, quad: q, crop: bbox(q).inset(left: 10, top: 12, right: 10, bottom: 6))
        }
        guard let tile = plates.tile(kind), let item = tile.item else { return nil }
        let q = item.quadPoints
        // the case or print only, not the divider card behind it
        let crop: CGRect
        switch kind {
        case "cd": crop = bbox(q).inset(left: 46, top: 10, right: 10, bottom: 8)
        case "bd": crop = bbox(q).inset(left: 8, top: 48, right: 8, bottom: 9)
        case "game": crop = bbox(q).inset(left: 11, top: 19, right: 8, bottom: 9)
        case "video": crop = bbox(q).inset(left: 13, top: 64, right: 14, bottom: 159)
        case "book": crop = bbox(q).inset(left: 7, top: 4, right: 6, bottom: 6)
        default: crop = bbox(q).inset(left: 12, top: 16, right: 12, bottom: 30)
        }
        return Source(folder: "tiles/" + kind, file: item.file, frame: item.frame.rect, quad: q, crop: crop)
    }
    private static func bbox(_ q: [CGPoint]) -> CGRect {
        let xs = q.map(\.x), ys = q.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    static func aspect(_ kind: String) -> CGFloat {
        guard let s = source(kind) else { return 1 }
        return s.crop.width / s.crop.height
    }

    var body: some View {
        if let s = Self.source(kind) {
            let k = height / s.crop.height
            let o = s.crop.origin
            ZStack(alignment: .topLeading) {
                ShopOnQuad(quad: s.quad.map { CGPoint(x: ($0.x - o.x) * k, y: ($0.y - o.y) * k) }) { _ in
                    ShopCover(artwork: artwork, title: title, workID: workID)
                }
                ShopLayerImage(image: ShopPlates.shared.image(s.folder, s.file), frame: s.frame, k: k, origin: o)
            }
            .frame(width: s.crop.width * k, height: height, alignment: .topLeading)
            .clipped()
            .accessibilityHidden(true)
        }
    }
}

private extension CGRect {
    func inset(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: minX - left, y: minY - top, width: width + left + right, height: height + top + bottom)
    }
}

// MARK: - A note that pops up beside a work (P36/P38 rule), shared by the bin pages

struct ShopNoteAction: Identifiable {
    let title: String
    let symbol: String?
    var role: ButtonRole? = nil
    let action: () -> Void
    var id: String { title }
}

struct ShopNoteHit: View {
    let id: String
    let title: String
    let caption: String
    let note: String
    let rect: CGRect
    let namespace: Namespace.ID?
    @Binding var annotating: String?
    let actions: [ShopNoteAction]
    /// A work near the top of the screen gets its note below it; above, the note would sit under
    /// the title bar, out of sight (anson 11-20, 收藏 after scrolling).
    @State private var nearTop = false
    var body: some View {
        let showing = Binding(get: { annotating == id }, set: { if !$0 && annotating == id { annotating = nil } })
        Button { annotating = id } label: { Color.clear.contentShape(.rect) }
            .buttonStyle(.plain)
            .frame(width: rect.width, height: rect.height)
            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY < 340 } action: { nearTop = $0 }
            .modifier(OptionalTransitionSource(id: id, namespace: namespace))
            .accessibilityLabel(title + (caption.isEmpty ? "" : "，" + caption))
            .accessibilityIdentifier("shop-work-" + id)
            .popover(isPresented: showing, attachmentAnchor: .rect(.bounds), arrowEdge: nearTop ? .top : .bottom) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { annotating = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain).frame(width: 25, height: 25).accessibilityLabel("关闭注释")
                    }
                    if !caption.isEmpty { Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    if !note.isEmpty {
                        Text(note).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .leading), GridItem(.flexible(), spacing: 8, alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(actions) { a in
                            Button(role: a.role) {
                                annotating = nil
                                Task { @MainActor in try? await Task.sleep(for: .milliseconds(220)); a.action() }
                            } label: {
                                HStack(spacing: 5) {
                                    if let symbol = a.symbol { Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)) }
                                    Text(a.title).lineLimit(1).fixedSize()
                                }.frame(maxWidth: .infinity)
                            }
                            .font(.system(size: 12.5, weight: .medium)).buttonStyle(.glass)
                            .accessibilityIdentifier("shop-note-" + a.title)
                        }
                    }.padding(.top, 4)
                }.padding(18).frame(width: 286)
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
            }
            .padding(.leading, rect.minX).padding(.top, rect.minY)
    }
}

private struct OptionalTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) } else { content }
    }
}

/// A work as its photographed object; falls back to the drawn object when the shop layers are absent.
struct ShopObject: View {
    let entity: SeedGraph.Entity
    let height: CGFloat
    /// Music as its LP sleeve (the page's own work) instead of a CD case.
    var asSleeve = false
    var palette: ArtworkPalette = .fallback
    var body: some View {
        if ShopStyle.enabled {
            ShopSprite(kind: asSleeve && entity.kind.isMusic ? "lp" : ShopStyle.objectKind(entity.kind),
                       artwork: VerifiedArtworkAssets.designAsset(for: entity.id) ?? entity.artworkAsset,
                       title: entity.title, height: height, workID: SeedLibraryBridge.workID(entity.id))
        } else {
            PhysicalObject(entity: entity, scale: height / PhysicalObject.baseSize(for: entity.kind).height, palette: palette, showsDisc: false)
        }
    }
}
