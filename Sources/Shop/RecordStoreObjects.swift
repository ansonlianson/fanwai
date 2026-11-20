import SwiftUI
import UIKit

/// The same physical object is used at full size, in the crate and on the map.
/// A crate gives it a uniform size; artwork stays top-aligned inside the casing.
struct PhysicalObject: View {
    let kind: SeedGraph.Kind
    let title: String
    var subtitle = ""
    var artwork: String?
    var fallbackGlyph: String?
    var scale: CGFloat = 1
    var palette: ArtworkPalette = .fallback
    var showsDisc = true
    var discLeading: CGFloat = 0.22
    var isPlaying = false
    var size: CGSize?
    var showsPersonName = true
    var showsPrintedTitle = true
    var fallbackID = ""
    var inkIndex: Int?
    var relation: String?
    var labelTitle: String?
    var cratePresentation = false
    var compactLabel = false
    var elevation: CGFloat = 0
    var discVisibility = 1.0
    var labelVisibility = 1.0
    var onArtworkFailure: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entity: SeedGraph.Entity, scale: CGFloat = 1, palette: ArtworkPalette = .fallback,
         showsDisc: Bool = true, discLeading: CGFloat = 0.22, isPlaying: Bool = false,
         size: CGSize? = nil, showsPersonName: Bool = true, relation: String? = nil, labelTitle: String? = nil,
         cratePresentation: Bool = false, compactLabel: Bool = false, elevation: CGFloat = 0,
         discVisibility: Double = 1, labelVisibility: Double = 1, showsPrintedTitle: Bool = true, inkIndex: Int? = nil) {
        kind = entity.kind; title = entity.title; subtitle = entity.subtitle
        artwork = VerifiedArtworkAssets.designAsset(for: entity.id) ?? entity.artworkAsset
        fallbackGlyph = entity.fallbackGlyph
        self.scale = scale; self.palette = palette; self.showsDisc = showsDisc
        self.discLeading = discLeading; self.isPlaying = isPlaying; self.size = size
        self.showsPersonName = showsPersonName; self.relation = relation; self.labelTitle = labelTitle
        self.cratePresentation = cratePresentation; self.compactLabel = compactLabel
        self.elevation = elevation
        self.discVisibility = discVisibility; self.labelVisibility = labelVisibility
        self.showsPrintedTitle = showsPrintedTitle
        self.fallbackID = entity.id; self.inkIndex = inkIndex
    }
    init(kind: SeedGraph.Kind, title: String, subtitle: String = "", artwork: String? = nil,
         fallbackGlyph: String? = nil, scale: CGFloat = 1, palette: ArtworkPalette = .fallback,
         showsDisc: Bool = true, discLeading: CGFloat = 0.22, isPlaying: Bool = false,
         size: CGSize? = nil, showsPersonName: Bool = true, relation: String? = nil, labelTitle: String? = nil,
         cratePresentation: Bool = false, compactLabel: Bool = false,
         onArtworkFailure: (() -> Void)? = nil, fallbackID: String = "", inkIndex: Int? = nil) {
        self.onArtworkFailure = onArtworkFailure
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.artwork = artwork
        self.fallbackGlyph = fallbackGlyph; self.scale = scale; self.palette = palette
        self.showsDisc = showsDisc; self.discLeading = discLeading; self.isPlaying = isPlaying
        self.size = size; self.showsPersonName = showsPersonName; self.relation = relation; self.labelTitle = labelTitle
        self.cratePresentation = cratePresentation; self.compactLabel = compactLabel
        self.fallbackID = fallbackID; self.inkIndex = inkIndex
    }
    static func baseSize(for kind: SeedGraph.Kind) -> CGSize {
        switch kind.objectKind {
        case .film, .game: CGSize(width: 56, height: 72)
        case .manga: CGSize(width: 50, height: 72)
        case .book: CGSize(width: 52, height: 76)
        case .person: CGSize(width: 58, height: 68)
        case .video: CGSize(width: 86, height: 54)
        default: CGSize(width: 64, height: 64)
        }
    }
    private var width: CGFloat { size?.width ?? Self.baseSize(for: kind).width * scale }
    private var height: CGFloat { size?.height ?? Self.baseSize(for: kind).height * scale }
    private var personBorder: CGFloat { scale > 2 ? 9 : 5 * min(1, scale) }
    private var personBottom: CGFloat { scale > 2 ? 32 : 18 * min(1, scale) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if kind.objectKind == .song && showsDisc {
                SpinningRecord(size: width * 0.92, label: palette.ac.color, playing: isPlaying && !reduceMotion)
                    .frame(width: width * 0.92, height: width * 0.92)
                    .overlay {
                        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.08), .white.opacity(0.27)],
                            startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 0.75)
                    }
                    .opacity(discVisibility)
                    .offset(x: width * discLeading, y: height * 0.04)
            }
            if kind == .book || kind == .manga {
                ForEach(0..<(kind == .book ? 3 : 1), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill([Color(red: 0.71, green: 0.68, blue: 0.62), Color(red: 0.79, green: 0.76, blue: 0.70), ArtworkPalette.paper][i])
                        .frame(width: width-2, height: height-2)
                        .offset(x: CGFloat((kind == .book ? 3-i : 1)*2), y: CGFloat(kind == .book ? 2-i : 0))
                }
            }
            if kind.objectKind == .song {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.63, green: 0.59, blue: 0.51))
                    .frame(width: width, height: height).offset(x: 1.1, y: 1.4)
            }
            casing
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.44), radius: 0.9, x: 0, y: 1.2)
                .shadow(color: .black.opacity(0.38 + elevation * 0.10), radius: 3 + elevation * 13, x: 1, y: 3 + elevation * 14)
            if let relation {
                ObjectLabel(relation: relation, title: labelTitle.map { SongTitlePresentation($0, isSong: kind == .song).title }, compact: compactLabel)
                    .opacity(labelVisibility)
                    .frame(maxWidth: labelTitle == nil ? nil : max(20, width*0.62), alignment: .leading)
                    .offset(x: 10, y: compactLabel ? 3 : 8)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
        .id(DesignFonts.shared.songtiAvailable)
    }
    @ViewBuilder private var casing: some View {
        switch kind.objectKind {
        case .film, .game:
            VStack(spacing: 0) {
                if kind != .game {
                Text("Blu-ray").font(.system(size: 7.5, weight: .bold)).tracking(0.45)
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 13)
                    .background(LinearGradient(colors: [Color(red: 0.23, green: 0.45, blue: 0.69), Color(red: 0.16, green: 0.34, blue: 0.53)], startPoint: .top, endPoint: .bottom))
                }
                sleeve.padding(.horizontal, 3).padding(.bottom, 3).padding(.top, kind == .game ? 3 : 0)
            }
            .background(kind == .game ? Color(white: 0.055) : Color(red: 47/255, green: 95/255, blue: 147/255))
            .overlay {
                LinearGradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .clear, location: 0.30), .init(color: .clear, location: 0.70), .init(color: .white.opacity(0.08), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(.rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        case .person:
            VStack(spacing: 0) {
                sleeve
                if showsPersonName {
                    Text(title).font(.custom(DesignFonts.editorialName, size: scale > 2 ? 14 : 9 * min(1, scale)))
                        .foregroundStyle(Color(red: 58/255, green: 53/255, blue: 48/255)).lineLimit(1)
                        .frame(height: personBottom)
                } else { Color.clear.frame(height: personBottom) }
            }
            .padding([.top, .horizontal], personBorder)
            .background(Color(red: 242/255, green: 239/255, blue: 232/255), in: .rect(cornerRadius: 2))
        case .video:
            sleeve.padding(4)
                .background(ArtworkPalette.border, in: .rect(cornerRadius: 2))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                        .foregroundStyle(.white).frame(width: 18, height: 18)
                        .background(.black.opacity(0.55), in: .circle).padding(9)
                }
        case .book, .manga:
            sleeve.clipShape(.rect(cornerRadius: kind == .book ? 4 : 3))
                .overlay(alignment: .leading) {
                    LinearGradient(stops: [.init(color: .black.opacity(kind == .book ? 0.5 : 0.4), location: 0),
                                           .init(color: .white.opacity(0.18), location: 0.55),
                                           .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: kind == .book ? 9 : 5)
                }
        default:
            sleeve
                .overlay {
                    LinearGradient(stops: [.init(color: .white.opacity(0.13), location: 0), .init(color: .clear, location: 0.14), .init(color: .clear, location: 0.78), .init(color: .black.opacity(0.17), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .clipShape(.rect(cornerRadius: 1.5))
                .overlay(alignment: .top) { Color.white.opacity(0.28).frame(height: 0.65).padding(.horizontal, 1) }
                .overlay(alignment: .leading) { Color.white.opacity(0.11).frame(width: 0.5) }
                .overlay(alignment: .trailing) { Color.black.opacity(0.24).frame(width: 0.75) }
        }
    }
    private var sleeve: some View {
        GeometryReader { proxy in
            Group {
                if let image = recordedArtwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if allowsRemoteArtwork, let artwork, artwork.hasPrefix("https://"), let url = URL(string: artwork) {
                    CachedArtworkImage(url: url, onFailure: { onArtworkFailure?() }) { image, loading in
                        let state: CoverState = image != nil ? .picture : loading ? .waiting : .printed
                        ZStack {
                            printedFallback(titled: state == .printed)
                            if state == .waiting { CoverSheen(strength: 0.45).transition(.opacity) }
                            if let image { image.resizable().scaledToFill().transition(.opacity) }
                        }
                        .modifier(CoverReveal(value: state))
                    }
                } else if let artwork, let image = ObservedArtwork.image(artwork) {
                    Image(uiImage: image).resizable().scaledToFill()
                        // This square official portrait has considerable headroom.
                        // Bring its face into the narrow exposed crate strip.
                        .offset(y: cratePresentation && artwork == "verified-ikuta-official" ? -proxy.size.width * 0.30 : 0)
                } else { printedFallback() }
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .top).clipped()
                .animation(.easeInOut(duration: 0.32), value: artwork)
        }
    }
    private var allowsRemoteArtwork: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return !ProcessInfo.processInfo.arguments.contains("--ui-network=real-relations")
        #else
        return true
        #endif
    }
    private var recordedArtwork: UIImage? {
        #if DEBUG && targetEnvironment(simulator)
        return artwork.flatMap(PublicRelationsFixture.artwork)
        #else
        return nil
        #endif
    }
    /// `titled: false` while the picture is still on its way: blank stock, nothing printed yet.
    @ViewBuilder private func printedFallback(titled: Bool = true) -> some View {
        let printed = showsPrintedTitle && titled
        if kind.objectKind == .person {
            LinearGradient(colors: [Color(red: 59/255, green: 49/255, blue: 41/255), Color(red: 46/255, green: 59/255, blue: 52/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.20), .init(color: .white.opacity(0.07), location: 0.46), .init(color: .clear, location: 0.67)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .top) {
                    Canvas { context, size in
                        for i in 0..<Int(size.width) {
                            context.fill(Path(CGRect(x:CGFloat(i),y:0,width:1,height:1+CGFloat(i*7%11)/11)),with:.color(Color(red:0.58,green:0.48,blue:0.36).opacity(0.65)))
                        }
                    }.frame(height: 2)
                }
                .overlay(Rectangle().strokeBorder(.black.opacity(0.25), lineWidth: 0.8))
                // No photograph: a printed initial, so the frame reads as a
                // name plate and not as a picture that failed to load.
                .overlay {
                    GeometryReader { proxy in
                        Text(String(title.trimmingCharacters(in: .whitespaces).prefix(1)))
                            .font(.custom(DesignFonts.editorialName, size: proxy.size.width * 0.5))
                            .foregroundStyle(ArtworkPalette.paper.opacity(0.62)).minimumScaleFactor(0.5)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .opacity(titled ? 1 : 0)
                    }
                }
        } else if cratePresentation {
            // Uniform crate layers expose only their top strip. Never crop a
            // full-size title or initial through that strip or its paper tag.
            if [.film, .book, .manga].contains(kind.objectKind) {
                InkStock(index: inkIndex ?? ObjectInk.index(fallbackID))
            } else { PaperStock(dark: kind.objectKind == .video) }
        } else {
        switch kind.objectKind {
        case .song:
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.custom(DesignFonts.editorialName, size: 10.5 * scale))
                    .lineLimit(3).minimumScaleFactor(0.65)
                Spacer(minLength: 0)
                Text(subtitle).font(.system(size: 7.5 * scale, weight: .medium))
                    .foregroundStyle(ArtworkPalette.paperInk.opacity(0.6)).lineLimit(2)
            }
            .padding(7 * scale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(printed ? 1 : 0)
            .foregroundStyle(ArtworkPalette.paperInk).background(PaperStock())
            .overlay(alignment: .bottomTrailing) {
                Circle().stroke(ArtworkPalette.paperInk.opacity(0.35), lineWidth: scale)
                    .frame(width: 12 * scale, height: 12 * scale).padding(7 * scale)
                    .opacity(printed ? 1 : 0)
            }
        case .person:
            PaperStock()
        case .film, .game, .book, .manga:
            HStack(spacing: 1.44 * scale) {
                let columns = title.split(whereSeparator: \.isWhitespace).map { Array($0.prefix(7)) }
                ForEach(Array(columns.reversed().enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 1.44 * scale) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, glyph in
                            Text(String(glyph)).font(.custom(DesignFonts.editorialName, size: 12 * scale))
                                .frame(height: 12 * scale)
                        }
                    }
                }
            }
            .opacity(printed ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(ArtworkPalette.paper).background(InkStock(index: inkIndex ?? ObjectInk.index(fallbackID)))
        default:
            Text(title).font(.custom(DesignFonts.editorialName, size: 11))
                .multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail).opacity(titled ? 1 : 0)
                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(ArtworkPalette.paper).background(Color(red: 42/255, green: 47/255, blue: 51/255))
        }
        }
    }
}

/// Paper label shared by crate layers and graph objects, SPEC §7.3.
struct ObjectLabel: View {
    let relation: String
    var title: String?
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ZStack { Text(relation).id(relation).transition(.opacity) }.animation(.easeInOut(duration: 0.2), value: relation).font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(red: 138/255, green: 126/255, blue: 102/255))
            if let title { Text(title).font(.custom(DesignFonts.editorialName, size: compact ? 10.5 : 11.5)).foregroundStyle(ArtworkPalette.paperInk) }
        }.lineLimit(1).truncationMode(.tail).padding(.horizontal, 7).padding(.vertical, compact ? 2 : 4)
            .background {
                RoundedRectangle(cornerRadius: 1).fill(Color(red: 238/255, green: 232/255, blue: 215/255))
                    .overlay {
                        Image(uiImage:PrintedTexture.fibres).resizable(resizingMode:.tile).opacity(0.035).allowsHitTesting(false)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            }
            .rotationEffect(.degrees(-0.6), anchor: .topLeading)
            .shadow(color: .black.opacity(0.28), radius: 0.6, y: 0.8)
    }
}

/// Preserve the turn angle through pause/resume; no jump back to twelve o'clock.
private struct SpinningRecord: UIViewRepresentable {
    let size: CGFloat
    let label: Color
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeUIView(context:Context) -> RotatingDiscView { RotatingDiscView() }
    func updateUIView(_ view:RotatingDiscView,context:Context) {
        view.image=DiscTexture.image(label:label)
        view.setPlaying(playing && !reduced)
    }
}
private final class RotatingDiscView:UIView {
    var image:UIImage? { didSet { layer.contents=image?.cgImage } }
    private var running=false
    private var angle:CGFloat=0
    override func layoutSubviews() { super.layoutSubviews(); layer.contentsGravity = .resizeAspect }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(restore), name: UIApplication.didBecomeActiveNotification, object: nil)
            restore()
        } else { NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil) }
    }
    /// Core Animation drops a running animation when the app is backgrounded
    /// or the view leaves its window. `running` alone then says "spinning"
    /// over a still record.
    @objc private func restore() {
        guard running, window != nil, layer.animation(forKey:"rotation") == nil else { return }
        running=false; setPlaying(true)
    }
    func setPlaying(_ value:Bool) {
        if value, running, window != nil, layer.animation(forKey:"rotation") == nil { running=false }
        guard value != running else { return }; running=value
        if !value {
            if let shown=layer.presentation() { angle=atan2(shown.transform.m12,shown.transform.m11) }
            layer.removeAnimation(forKey:"rotation"); layer.transform=CATransform3DMakeRotation(angle,0,0,1)
        } else {
            let spin=CABasicAnimation(keyPath:"transform.rotation.z"); spin.fromValue=angle; spin.toValue=angle+2*CGFloat.pi
            spin.duration=9; spin.repeatCount = .infinity; layer.add(spin,forKey:"rotation")
        }
    }
}
@MainActor private enum DiscTexture {
    static func image(label:Color) -> UIImage {
        let color=UIColor(label), size:CGFloat=256
        return CrateV3Materials.image(key:"disc-p29:\(color.description)",size:CGSize(width:size,height:size)) { c in
            UIColor(white:0.045,alpha:1).setFill(); c.fillEllipse(in:CGRect(x:0,y:0,width:size,height:size))
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.17).cgColor); c.setLineWidth(0.45)
            for r in stride(from:size*0.18,through:size*0.49,by:size/145) { c.strokeEllipse(in:CGRect(x:size/2-r,y:size/2-r,width:r*2,height:r*2)) }
            c.saveGState(); c.addEllipse(in:CGRect(x:0,y:0,width:size,height:size)); c.clip()
            for degrees:CGFloat in [30,210] {
                c.saveGState(); c.translateBy(x:size/2,y:size/2); c.rotate(by:degrees * .pi/180)
                let beam=UIBezierPath(); beam.move(to:.zero); beam.addLine(to:CGPoint(x:size,y:-size*0.25)); beam.addLine(to:CGPoint(x:size,y:size*0.25)); beam.close()
                beam.addClip()
                let light = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.33).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                    locations: [0, 0.48, 1])!
                c.drawLinearGradient(light, start: CGPoint(x: size*0.45, y: -size*0.25),
                    end: CGPoint(x: size*0.45, y: size*0.25), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                c.restoreGState()
            }; c.restoreGState()
            color.setFill(); c.fillEllipse(in:CGRect(x:size*0.35,y:size*0.35,width:size*0.3,height:size*0.3))
            UIColor(white:0.05,alpha:1).setFill(); c.fillEllipse(in:CGRect(x:size*0.4825,y:size*0.4825,width:size*0.035,height:size*0.035))
        }
    }
}

struct RecordDisc: View {
    let size: CGFloat
    var label: Color = ArtworkPalette.fallback.ac.color
    var body: some View {
        Image(uiImage:DiscTexture.image(label:label)).resizable().frame(width:size,height:size)
            .shadow(color:.black.opacity(0.5),radius:5,y:4)
    }
}

/// Compatibility adapter for the existing artwork retrieval and legacy pages.
/// It deliberately preserves WorkArtworkStore's verified remote-image fallback.
struct RecordStoreArtwork: View {
    let id: WorkID
    let size: CGFloat
    var showsDisc = false
    var discOffset: CGFloat = 0.22
    var showsPlaceholderTitle = true
    var showsCreatorRole = true
    var isThumbnail = false
    @Environment(Library.self) private var library
    @State private var artworkStore = WorkArtworkStore.shared
    @State private var failedPrimary = false
    private var work: Work { library.catalog.work(library.catalog.canonicalID(for: id)) }
    private var artwork: String? {
        if !failedPrimary, let art = ArtworkLocation.displayValue(for: work, catalog: library.catalog) { return art }
        return artworkStore.metadata(for: work)?.thumbnailURL
    }
    private var kind: SeedGraph.Kind {
        if work.isPerson { return .person }
        if work.isVideo { return .video }
        if work.kind == "游戏" { return .game }
        if ["电影", "电视剧"].contains(work.kind) { return .film }
        if work.kind == "漫画" { return .manga }
        if ["书籍", "文学作品"].contains(work.kind) { return .book }
        return .song
    }
    static func relationTitle(for id: WorkID) -> String {
        id == .animenz ? "Animenz 的 in the pool" : id.displayTitle
    }
    static func objectWidth(for id: WorkID, size: CGFloat) -> CGFloat {
        if ["电影", "漫画", "书籍", "文学作品", "电视剧"].contains(id.work.kind) { return size * 0.7 }
        if id.work.isVideo { return size * 1.76 }
        return size
    }
    static func objectHeight(for id: WorkID, size: CGFloat) -> CGFloat { size }
    var body: some View {
        let base = PhysicalObject.baseSize(for: kind)
        PhysicalObject(kind: kind, title: id.displayTitle, subtitle: id.work.creator,
                       artwork: artwork, scale: size / max(base.width, base.height),
                       palette: .asset(id.work.art), showsDisc: showsDisc, discLeading: discOffset,
                       onArtworkFailure: { failedPrimary = true })
            .frame(width: size, height: size)
            .task(id: id.rawValue + String(failedPrimary)) {
                if artwork == nil { await artworkStore.loadWork(work) }
                else if failedPrimary, let qid = work.knowledgeID { await artworkStore.load(qid) }
            }
    }
}

struct RecordObjectPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
