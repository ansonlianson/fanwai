import SwiftUI
import CoreImage
import UIKit

// Scheme A ("中古盘店的翻片箱"): photographed shop layers rendered offline (Design/review/CL1-store-art),
// with every cover, name tag and play state drawn live on top. Each work's shell (case, sleeve, divider,
// reflections, shading) is one straight-alpha image; the cover is mapped underneath it with a homography.

struct ShopFrame: Decodable, Hashable {
    let x, y, w, h: CGFloat
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(CGFloat.self); y = try c.decode(CGFloat.self)
        w = try c.decode(CGFloat.self); h = try c.decode(CGFloat.self)
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// A static shop scene with the work on the ledge (compose.py layers.json).
struct ShopMainLayers: Decodable {
    struct Slot: Decodable {
        let quad: [[CGFloat]]?
        let over: String?
        let frame: ShopFrame?
        var quadPoints: [CGPoint]? { quad?.map { CGPoint(x: $0[0], y: $0[1]) } }
        var bounds: CGRect {
            var r = frame?.rect ?? .null
            for p in quadPoints ?? [] { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        }
    }
    struct Matte: Decodable { let over: String; let frame: ShopFrame }
    let size: [CGFloat]
    let bg: String?
    let slots: [String: Slot]
    let order: [String]
    let front: Matte?
}

/// One compartment of the bin, x relative to its own left edge.
struct ShopTile: Decodable {
    struct Layer: Decodable { let file: String; let frame: ShopFrame }
    struct Item: Decodable {
        let file: String
        let frame: ShopFrame
        let quad: [[CGFloat]]
        let tab: [[CGFloat]]
        var quadPoints: [CGPoint] { quad.map { CGPoint(x: $0[0], y: $0[1]) } }
        var tabPoints: [CGPoint] { tab.map { CGPoint(x: $0[0], y: $0[1]) } }
        var bounds: CGRect {
            var r = CGRect.null
            for p in quadPoints + tabPoints { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        }
    }
    let kind: String
    let width: CGFloat
    let height: CGFloat
    let bg: Layer?
    let front: Layer?
    let item: Item?
}

@MainActor final class ShopPlates {
    static let shared = ShopPlates()
    /// Plate width in pixels; the scene is laid out on a 402-pt-wide reference at 3x.
    static let plateWidth: CGFloat = 1206
    static let plateHeight: CGFloat = 2622
    private var mains: [String: ShopMainLayers] = [:]
    private var tiles: [String: ShopTile] = [:]
    private var images: [String: UIImage] = [:]
    private var prewarmed = false
    private let root = Bundle.main.resourceURL?.appendingPathComponent("ShopPlates")
    var isAvailable: Bool { root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("lp/layers.json").path) } ?? false }

    func main(_ name: String) -> ShopMainLayers? {
        if let m = mains[name] { return m }
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("layers.json")),
              let m = try? JSONDecoder().decode(ShopMainLayers.self, from: data) else { return nil }
        mains[name] = m
        return m
    }
    func tile(_ kind: String) -> ShopTile? {
        if let t = tiles[kind] { return t }
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("tiles").appendingPathComponent(kind).appendingPathComponent("tile.json")),
              let t = try? JSONDecoder().decode(ShopTile.self, from: data) else { return nil }
        tiles[kind] = t
        return t
    }
    func image(_ folder: String, _ file: String) -> UIImage {
        let key = folder + "/" + file
        if let i = images[key] { return i }
        // Decoded once and kept decoded; otherwise a full-plate PNG is decoded again on the
        // main thread whenever a page holding it is drawn anew (mid-push or mid-swipe-back).
        let i = root.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent(folder).appendingPathComponent(file).path) }
            .map { $0.preparingForDisplay() ?? $0 } ?? UIImage()
        images[key] = i
        return i
    }
    /// Decode the shop photographs off the main thread at launch, so the first page that shows
    /// them, often in the middle of a transition, does not stall on decoding (0.5.8).
    func prewarm() {
        guard let root, !prewarmed else { return }
        prewarmed = true
        let folders = ["lp", "lp_paused", "bd", "book", "person"]
            + ["anon", "empty", "cd", "bd", "game", "video", "book", "person", "end"].map { "tiles/" + $0 }
        Task.detached(priority: .utility) {
            var prepared: [String: PreparedPlate] = [:]
            for folder in folders {
                let dir = root.appendingPathComponent(folder)
                for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                where file.hasSuffix(".png") || file.hasSuffix(".jpg") {
                    if let image = UIImage(contentsOfFile: dir.appendingPathComponent(file).path)?.preparingForDisplay() {
                        prepared[folder + "/" + file] = PreparedPlate(image: image)
                    }
                }
            }
            await MainActor.run {
                for (key, plate) in prepared where ShopPlates.shared.images[key] == nil { ShopPlates.shared.images[key] = plate.image }
            }
        }
    }
}

private struct PreparedPlate: @unchecked Sendable { let image: UIImage }


enum ShopHomography {
    /// maps the rect (0,0,w,h) onto quad TL,TR,BR,BL
    static func transform(size: CGSize, quad q: [CGPoint]) -> ProjectionTransform {
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
        var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y), u = Double(q[i].x), v = Double(q[i].y)
            A[2*i] = [x, y, 1, 0, 0, 0, -u*x, -u*y, u]
            A[2*i+1] = [0, 0, 0, x, y, 1, -v*x, -v*y, v]
        }
        for c in 0..<8 {
            var p = c
            for r in c..<8 where abs(A[r][c]) > abs(A[p][c]) { p = r }
            A.swapAt(c, p)
            let d = A[c][c]
            if abs(d) < 1e-12 { continue }
            for k in c..<9 { A[c][k] /= d }
            for r in 0..<8 where r != c {
                let f = A[r][c]
                if f == 0 { continue }
                for k in c..<9 { A[r][k] -= f * A[c][k] }
            }
        }
        let h = (0..<8).map { A[$0][8] }
        var t = ProjectionTransform()
        t.m11 = h[0]; t.m12 = h[3]; t.m13 = h[6]
        t.m21 = h[1]; t.m22 = h[4]; t.m23 = h[7]
        t.m31 = h[2]; t.m32 = h[5]; t.m33 = 1
        return t
    }
    static func size(_ q: [CGPoint]) -> CGSize {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        return CGSize(width: (d(q[0], q[1]) + d(q[3], q[2])) / 2, height: (d(q[0], q[3]) + d(q[1], q[2])) / 2)
    }
}

/// Content laid out at the quad's natural size, then projected onto it.
struct ShopOnQuad<Content: View>: View {
    let quad: [CGPoint]
    @ViewBuilder var content: (CGSize) -> Content
    var body: some View {
        let size = ShopHomography.size(quad)
        content(size)
            .frame(width: max(1, size.width), height: max(1, size.height))
            .projectionEffect(ShopHomography.transform(size: size, quad: quad))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

/// A plate image placed in plate pixels (k = points per plate pixel, origin = plate pixel at (0,0)).
struct ShopLayerImage: View {
    let image: UIImage
    let frame: CGRect
    let k: CGFloat
    var origin: CGPoint = .zero
    var body: some View {
        Image(uiImage: image).resizable().interpolation(.high)
            .frame(width: frame.width * k, height: frame.height * k)
            .offset(x: (frame.minX - origin.x) * k, y: (frame.minY - origin.y) * k)
            .allowsHitTesting(false)
    }
}

/// Live cover: bundled asset, remote URL, or a printed fallback with the title.
/// While the picture (or where to find it) is still on its way the stock stays blank with a
/// band of light crossing it; the title is printed only once nothing was found.
struct ShopCover: View {
    let artwork: String?
    let title: String
    var placeholder = false
    var workID: WorkID? = nil
    var sharedPresentation: ArtworkPresentation? = nil
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WorkArtworkStore.shared
    @State private var failedURLs: Set<String> = []
    @State private var ownPresentation = ArtworkPresentation()
    @State private var endedArtwork: String?
    private var presentation: ArtworkPresentation { sharedPresentation ?? ownPresentation }
    private var artworkIdentity: String { workID?.rawValue ?? title }
    /// The request whose own lookups (picture metadata, a recording's cover) have finished.
    @State private var lookedUp: String?
    /// Twenty seconds of looking is the end of waiting; a picture found later still fades in.
    @State private var waitedOut = false
    private var printedReview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-isolate-data") && args.contains("--ui-printed-covers")
        #else
        return false
        #endif
    }
    private var work: Work? {
        workID.flatMap { library.catalog.works[library.catalog.canonicalID(for: $0)] }
    }
    private var selectedArtwork: String? {
        if printedReview { return nil }
        let observed = artwork?.hasPrefix("observed-cover-") == true ? artwork : nil
        let options = [observed, work.flatMap { ArtworkLocation.displayValue(for: $0, catalog: library.catalog, excluding: failedURLs) },
            artwork, work?.art, work.flatMap { store.metadata(for: $0)?.thumbnailURL }]
        return options.compactMap { $0 }.first { !$0.isEmpty && !failedURLs.contains($0) }
    }
    private var requestKey: String {
        [workID?.rawValue ?? "", work?.knowledgeID ?? "", work?.bangumiID ?? "", work?.art ?? "",
         work.flatMap(OfficialWorkArtwork.publisherPage)?.absoluteString ?? "", String(!failedURLs.isEmpty)].joined(separator: "|")
    }
    /// Where this cover is has not been settled yet: this card's own lookups, or the page's.
    private var searching: Bool {
        guard !placeholder, !printedReview, let work, selectedArtwork == nil else { return false }
        return lookedUp != requestKey || CoverLookups.shared.isLooking(work.id)
    }
    var body: some View {
        let chosen = selectedArtwork
        let searching = searching
        let picture = placeholder ? nil : presentation.image(for: artworkIdentity, source: chosen)
        let loading = chosen != nil && picture == nil && endedArtwork != chosen
        let state: CoverState = picture != nil ? .picture : (loading || (searching && !waitedOut)) ? .waiting : .printed
        GeometryReader { geo in
            ZStack {
                if placeholder {
                    Color(red: 0.86, green: 0.84, blue: 0.79)
                    Image(uiImage: PrintedTexture.fibres).resizable(resizingMode: .tile).opacity(0.18)
                } else {
                    ZStack {
                        fallback(state)
                        if let picture {
                            Image(uiImage: picture).resizable().scaledToFill()
                                .transition(.opacity)
                                .onAppear { if let chosen { measureShown(chosen) } }
                        }
                    }
                    .modifier(CoverReveal(value: state))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .task(id: artworkIdentity + "|" + (chosen ?? "")) {
            guard !placeholder, !printedReview else { return }
            let result = await presentation.load(chosen, for: artworkIdentity)
            if result == .failed, let chosen { endedArtwork = chosen; failedURLs.insert(chosen) }
        }
        .task(id: searching) {
            waitedOut = false
            guard searching else { return }
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { waitedOut = true }
        }
        .task(id: requestKey) {
            let key = requestKey
            guard !placeholder, !printedReview, let work else { lookedUp = key; return }
            measureCard(work)
            async let metadata: Void = store.loadWork(work, primaryFailed: !failedURLs.isEmpty)
            // A visible composition can use a verified recording's album cover.
            // Share the picker cache and its strict identity checks, even when
            // this card was outside the first six prefetched items.
            async let recording: Void = {
                if work.isMusicWork, work.art.isEmpty {
                    await RecordingVersionsStore.shared.load(work, library: library, prefetch: true)
                }
            }()
            _ = await (metadata, recording)
            if !Task.isCancelled { lookedUp = key }
            measureCard(work)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                failedURLs = failedURLs.filter { raw in
                    URL(string: raw).map { ArtworkImageCache.shared.permanentlyMissing($0) } ?? false
                }
                if !placeholder, !printedReview, let work, store.metadata(for: work) == nil {
                    Task { await store.loadWork(work, primaryFailed: !failedURLs.isEmpty, retry: true) }
                }
            }
        }
    }
    private func measureShown(_ artwork: String) {
        guard P17Metrics.enabled, let workID else { return }
        let row = ["event": "imageShown", "work": workID.rawValue, "image": DiscoveryCore.digest([artwork]), "host": URL(string: artwork)?.host ?? "bundle"]
        Task { await P17Metrics.shared.record(row) }
    }
    private func measureCard(_ work: Work) {
        guard P17Metrics.enabled else { return }
        let selected = selectedArtwork ?? ""
        let row = ["event": "card", "work": work.id.rawValue, "kind": work.kind,
            "source": selected.isEmpty ? "none" : URL(string: selected)?.host ?? "bundle", "image": selected.isEmpty ? "" : DiscoveryCore.digest([selected]),
            "wikidata": String(work.knowledgeID != nil), "bangumi": String(work.bangumiID != nil),
            "douban": String(work.url?.contains("douban.com/subject/") == true), "failedSources": String(failedURLs.count)]
        Task { await P17Metrics.shared.record(row) }
    }
    /// The cover's own stock. Waiting: blank, with light crossing it. Printed: the title, because
    /// no picture was found. Under a picture it is simply covered.
    private func fallback(_ state: CoverState) -> some View {
        GeometryReader { geometry in
            let pad = min(10, geometry.size.width * 0.08)
            let layout = PrintedCoverTypography.layout(title, width: max(1, geometry.size.width - pad * 2), height: max(1, geometry.size.height - pad * 2))
            ZStack {
                Color(red: 0.914, green: 0.886, blue: 0.824)
                Image(uiImage: PrintedTexture.fibres).resizable(resizingMode: .tile).opacity(0.2)
                VStack(spacing: 0) {
                    ForEach(Array(layout.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: layout.fontSize, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                }.foregroundStyle(Color(red: 0.122, green: 0.102, blue: 0.078)).multilineTextAlignment(.center).padding(pad)
                    .opacity(state == .printed ? 1 : 0)
                if state == .waiting { CoverSheen(strength: 0.85).transition(.opacity) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Name + relation printed on the divider's paper label.
struct ShopTabText: View {
    let title: String
    let relation: String?
    let size: CGSize
    var body: some View {
        VStack(alignment: .leading, spacing: max(0.5, size.height * 0.04)) {
            Text(title).font(.system(size: size.height * 0.40, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.55)
            if let relation, !relation.isEmpty {
                Text(relation).font(.system(size: size.height * 0.31)).lineLimit(1).minimumScaleFactor(0.6).opacity(0.72)
            }
        }
        .foregroundStyle(Color(red: 0.14, green: 0.13, blue: 0.12))
        .frame(width: size.width, height: size.height, alignment: .leading)
        .opacity(0.92)
    }
}

/// The relation map stays inside the shop: the same photograph, out of focus and dimmed.
struct ShopMapBackdrop: View {
    @MainActor static let blurred: UIImage? = {
        guard let m = ShopPlates.shared.main("lp_paused"), let bg = m.bg,
              let cg = ShopPlates.shared.image("lp_paused", bg).cgImage else { return nil }
        let scale: CGFloat = 0.25
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 22 pt on a 402-pt-wide screen ≈ 16 px at a quarter of the 1206-px plate.
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 16).cropped(to: input.extent)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = context.createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
    }()
    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / ShopPlates.plateWidth
            ZStack {
                ShopNowPage.base
                if let blurred = Self.blurred {
                    // Blurred once, at a quarter of the plate's size, instead of a live 22-pt blur
                    // that every glass control above it (scope bar, tabs, map) re-samples per frame.
                    Image(uiImage: blurred).resizable().interpolation(.medium)
                        .frame(width: ShopPlates.plateWidth * k, height: ShopPlates.plateHeight * k)
                        .opacity(0.8)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.40), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
