import SwiftUI
import UIKit

struct CrateV3Pose: Equatable {
    var x: CGFloat = 0, y: CGFloat = 8, z: CGFloat = 0
    var rx: CGFloat = 0, ry: CGFloat = 0, rz: CGFloat = 0, scale: CGFloat = 1
    var transform: CATransform3D {
        var t = CATransform3DMakeTranslation(x, -y, z)
        t = CATransform3DRotate(t, rx * .pi/180, 1, 0, 0)
        t = CATransform3DRotate(t, ry * .pi/180, 0, 1, 0)
        t = CATransform3DRotate(t, rz * .pi/180, 0, 0, 1)
        return CATransform3DScale(t, scale, scale, scale)
    }
}

/// A shared off-centre camera projects each complete sleeve before compositing.
/// This prevents the oversized photo/tab planes from being sliced by the back
/// rim or another sleeve when Core Animation sorts intersecting 3D planes.
enum CrateV3Camera {
    static func project(_ world: CATransform3D, at position: CGPoint) -> CATransform3D {
        var camera = CATransform3DIdentity
        camera.m31 = (position.x-182.5)/900
        camera.m32 = (position.y+187.2)/900
        camera.m34 = -1/900; camera.m33 = 0.000001
        return CATransform3DConcat(world, camera)
    }
}

/// Every panel and sleeve uses the same camera and physical floor.
/// The physical floor is y=304, so all feet sit at y=312-8, at every depth.
@MainActor final class CrateV3Scene: UIView {
    let stage = CALayer()
    var boards: [CALayer] = []
    struct Object {
        var item: CrateItem
        let layer: CALayer
        let shadow: CALayer
        var home: CrateV3Pose
        var pose: CrateV3Pose
        /// Artist dividers only: which index-tab position this card uses.
        var tabSlot = 0
        var dividerFace: CGImage?
        var portraitFace: CGImage?
        var portraitExpanded = false
        var size: CGSize { CrateV3Materials.size(item.entity.kind) }
        var visualRect: CGRect { portraitExpanded ? CrateV3Materials.portraitRect : CGRect(origin: .zero, size: size) }
    }
    var objects: [String: Object] = [:]
    var order: [String] = []
    var items: [CrateItem] = []
    var entityID = ""
    var reduceMotion = false
    var onOpen: ((CrateItem) -> Void)?
    var onPull: ((CrateItem) -> Void)?
    var onHeldChanged: ((Bool) -> Void)?
    weak var pageTransition: CratePageTransition?
    var sceneScale: CGFloat = 1
    var origin = CGPoint.zero
    let returnButton = UIButton(type: .system)
    let openButton = UIButton(type: .system)
    /// Shown under a lifted object so the first tap confirms what was picked.
    /// The object itself is the only control: tap it again or lift it to open.
    let heldTitle = UILabel()
    let heldDetail = UILabel()
    let heldChevron = UIImageView()
    var onOpening: (() -> Void)?
    var interaction = CrateSceneInteraction()
    var dragID: String? { get { interaction.dragID } set { interaction.dragID = newValue } }
    var dragStart = CGPoint.zero
    var dragTime: TimeInterval = 0
    var dragLast = CGPoint.zero
    var dragLastTime: TimeInterval = 0
    var dragVX: CGFloat = 0
    var dragVY: CGFloat = 0
    var dragging: Bool { get { interaction.dragging } set { interaction.dragging = newValue } }
    var openedID: String? { get { interaction.openedID } set { interaction.openedID = newValue } }
    var lastResume = 0
    var measuredFull = false
    var measuredFirst = false
    var heroTarget = CGRect.zero
    /// The fixed page header ends here. Fit the planted crate below it; only
    /// an object deliberately lifted into the hand can enter this region.
    var reservedTop: CGFloat = 0
    var windowTransition: Bool { get { interaction.windowTransition } set { interaction.windowTransition = newValue } }
    var heldID: String? { get { interaction.heldID } set { interaction.heldID = newValue } }
    var flippedID: String? { get { interaction.flippedID } set { interaction.flippedID = newValue } }
    var digging: Bool { get { interaction.digging } set { interaction.digging = newValue } }
    var digBase: Int { get { interaction.digBase } set { interaction.digBase = newValue } }
    var digSteps: Int { get { interaction.digSteps } set { interaction.digSteps = newValue } }
    struct ContentUpdate { let items: [CrateItem]; let loading: Bool; let categories: [String] }
    var pendingContent: ContentUpdate?
    let digTick = UISelectionFeedbackGenerator()
    var windowIndex = 0
    var browsing = false
    /// 0.3: a crate of leads has no hidden stock. It is always the continuous
    /// stack, with the front sleeve's sentence on the index card.
    var leadMode = false
    var morphPrints: [UUID: CALayer] = [:]
    var browseCursor: CGFloat = 0
    var browseEntryPoses: [String: CrateV3Pose] = [:]
    var browseEntryProgress: CGFloat = 1
    var browseStart: CGFloat = 0
    var browseAxisHorizontal = true
    var detailedIDs: Set<String> = []
    var featuredIDs: [String] = []
    var featuredLimit = 3
    let browseButton = UIButton(type: .system)
    var nameButtons: [String: UIButton] = [:]
    var artworkTasks: [String: Task<Void, Never>] = [:]
    var imageKeys: [String: String] = [:]
    var undimmed: [ObjectIdentifier: CGImage] = [:]
    var sourceFrame: CGRect = .zero
    struct Blank { let layer: CALayer; let home: CrateV3Pose; let category: String }
    var blanks: [Int: Blank] = [:]
    var loadingStarted = false
    var loadingTask: Task<Void, Never>?
    var arrivalTask: Task<Void, Never>?
    var pendingArrivals: [String] = []
    var arrivingID: String?
    var isLoading = false
    var categories: [String] = []
    var changeToken = UUID()
    private var accessibilityItems: [UIAccessibilityElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; clipsToBounds = false
        layer.addSublayer(stage); stage.anchorPoint = .zero
        stage.contentsScale = 3; stage.rasterizationScale = 3
        stage.bounds = CGRect(x: 0, y: 0, width: 365, height: 312)
        buildBox()
        installInteraction()
        accessibilityIdentifier = "record-crate"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let footer: CGFloat = 12
        let available = max(1, bounds.height - reservedTop - 12 - footer)
        sceneScale = min((bounds.width-28)/365, available/240)
        origin = CGPoint(x: (bounds.width-365*sceneScale)/2, y: bounds.height-312*sceneScale-footer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.position = origin
        // Keep the stage transform affine (z scale 1). A plain CALayer with a
        // non-affine transform is flattened offscreen with all its sublayers
        // first, which softened every sleeve, label and board in the crate.
        // Each sleeve already carries its own projection, so z scale is unused.
        stage.transform = CATransform3DMakeScale(sceneScale, sceneScale, 1)
        CATransaction.commit()
        let capacity = sceneScale < 0.68 ? 2 : 3
        if !browsing && featuredLimit != capacity && !interaction.isBusy {
            featuredLimit = capacity
            configure(items: items, entityID: entityID, reduceMotion: reduceMotion, loading: isLoading, categories: categories)
        }
        layoutControls(); updateAccessibility()
    }
    func panel(_ name: String, _ rect: CGRect, z: CGFloat, rx: CGFloat = 0, ry: CGFloat = 0,
               shade: CGFloat = 0, vertical: Bool = false, front: Bool = false, shape: CGPath? = nil) {
        let l = CALayer(); l.name = name; l.bounds = CGRect(origin: .zero, size: rect.size)
        l.allowsEdgeAntialiasing = true
        l.anchorPoint = .zero; l.position = rect.origin
        // The back and floor stay behind the display. The front lip occludes
        // planted feet until the object is lifted forward past it.
        l.zPosition = name == "floor" ? -1000 : name == "back" ? -900 : name == "backrim" ? -850 : name.hasPrefix("side") ? -700 : name.hasPrefix("rim") ? 22 : z
        var t = CATransform3DMakeTranslation(0, 0, z)
        t = CATransform3DRotate(t, rx * .pi/180, 1, 0, 0)
        t = CATransform3DRotate(t, ry * .pi/180, 0, 1, 0)
        l.transform = CrateV3Camera.project(t, at: l.position)
        l.contents = CrateV3Materials.board(name, size: rect.size, shade: shade, vertical: vertical, front: front).cgImage
        l.contentsScale = 3; l.isDoubleSided = true
        if let shape { let mask = CAShapeLayer(); mask.path = shape; l.mask = mask }
        if name.hasPrefix("side") {
            let grip = CALayer(); grip.frame = CGRect(x: 96, y: 36, width: 52, height: 17)
            grip.backgroundColor = UIColor(red: 0.035, green: 0.025, blue: 0.02, alpha: 1).cgColor
            grip.cornerRadius = 8; grip.borderWidth = 0.7; grip.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
            l.addSublayer(grip)
        }
        stage.addSublayer(l); boards.append(l)
    }
    func buildBox() {
        panel("floor", CGRect(x: 12, y: 304, width: 341, height: 176), z: 12, rx: -90, shade: 0.80)
        panel("back", CGRect(x: 12, y: 162, width: 341, height: 142), z: -164, shade: 0.62)
        panel("backrim", CGRect(x: 0, y: 162, width: 365, height: 12), z: -164, rx: -90)
        let side = CGMutablePath(); side.move(to: CGPoint(x: 0, y: 88)); side.addLine(to: CGPoint(x: 176, y: 6))
        side.addLine(to: CGPoint(x: 176, y: 142)); side.addLine(to: CGPoint(x: 0, y: 142)); side.closeSubpath()
        panel("side-left", CGRect(x: 12, y: 162, width: 176, height: 142), z: 12, ry: 90, shade: 0.55, shape: side)
        panel("side-right", CGRect(x: 353, y: 162, width: 176, height: 142), z: 12, ry: 90, shade: 0.35, shape: side)
        for x: CGFloat in [0,353] { panel("rim-\(x)", CGRect(x: x, y: 256, width: 12, height: 221), z: 24, rx: -115.17, vertical: true) }
        panel("frontrim", CGRect(x: 0, y: 256, width: 365, height: 12), z: 24, rx: -90)
        panel("front", CGRect(x: 0, y: 256, width: 365, height: 56), z: 24, front: true)
    }
    func configure(items: [CrateItem], entityID: String, reduceMotion: Bool, loading: Bool, categories: [String]) {
        self.reduceMotion = reduceMotion
        if self.entityID == entityID && interaction.isBusy {
            pendingContent = ContentUpdate(items: items, loading: loading, categories: categories)
            return
        }
        var changed = self.items.map(\.id) != items.map(\.id) || self.entityID != entityID
        self.isLoading = loading; self.categories = categories
        if self.entityID != entityID {
            resetScene(for: entityID)
            measuredFull=false; measuredFirst=false
            Task { await P17Metrics.shared.event("selection",entity:entityID) }
            self.items = items
            if let anchor = RelationTrailStore().defaults.string(forKey: "redesign.crateBrowse.v2." + entityID),
               let index = items.firstIndex(where: { $0.id == anchor }) { browsing = true; windowIndex = index; browseCursor = CGFloat(index) }
        } else {
            let anchor = self.items.indices.contains(windowIndex) ? self.items[windowIndex].id : nil
            self.items = items
            if browsing, let anchor, let index = items.firstIndex(where: { $0.id == anchor }) { windowIndex = index; browseCursor = CGFloat(index) }
        }
        if leadMode { browsing = true }
        if loading && !loadingStarted { beginLoading(categories: categories) }
        windowIndex = min(windowIndex, max(0, items.count-1))
        browseCursor = min(CGFloat(max(0, items.count-1)), browseCursor)
        featuredIDs = CrateFeaturedSelection.items(items, limit: featuredLimit).map(\.id)
        let resting = items.filter { !featuredIDs.contains($0.id) }
        let poses = Dictionary(uniqueKeysWithValues: items.enumerated().map { i, item in
            let pose: CrateV3Pose
            if browsing { pose = CrateStackLayout.browsing(index: i, cursor: browseCursor) }
            else if let slot = featuredIDs.firstIndex(of: item.id) {
                pose = CrateFeaturedLayout.pose(index: slot, count: featuredIDs.count)
            } else { pose = CrateStackLayout.resting(index: resting.firstIndex(where: { $0.id == item.id })!, count: resting.count) }
            return (item.id, CrateStackLayout.contained(pose, kind: item.entity.kind))
        })
        let sorted = items.sorted { poses[$0.id]!.z < poses[$1.id]!.z }
        changed = changed || order != sorted.map(\.id)
        let nextIDs = Set(items.map(\.id))
        for id in Array(objects.keys) where !nextIDs.contains(id) {
            objects[id]?.layer.removeFromSuperlayer(); objects[id]?.shadow.removeFromSuperlayer()
            objects[id] = nil; artworkTasks[id]?.cancel(); artworkTasks[id] = nil; imageKeys[id] = nil
        }
        order = sorted.map(\.id)
        detailedIDs = browsing ? Set(items.enumerated().filter { abs($0.offset-windowIndex) <= 2 }.map { $0.element.id }) : Set(featuredIDs)
        for item in sorted {
            let size = CrateV3Materials.size(item.entity.kind)
            let home = poses[item.id]!
            let offset = home.x
            let tabSlot = (featuredIDs.firstIndex(of: item.id) ?? items.firstIndex(where: { $0.id == item.id }) ?? 0) % 3
            if var old = objects[item.id] {
                old.item = item; old.home = home; old.tabSlot = tabSlot; objects[item.id] = old
                if heldID != item.id && openedID != item.id && old.portraitExpanded {
                    showPortrait(item.id, expanded: false, animated: false)
                }
                if (changed || old.pose != home) && heldID != item.id && openedID != item.id && dragID != item.id && arrivingID != item.id && !pendingArrivals.contains(item.id) { setPose(item.id, home, animated: false) }
            } else {
                // One layer per object, its 4x face as the layer's own contents (the
                // sleeve shadow is drawn into the face). On device, a 3D-transformed
                // layer with a sublayer and a shadow was flattened offscreen first,
                // at a resolution that made every sleeve soft.
                let l = CALayer(); l.name = item.id
                l.anchorPoint = CrateV3Materials.faceAnchor(size)
                l.allowsEdgeAntialiasing = true
                l.bounds = CGRect(origin: .zero, size: CrateV3Materials.faceSize(size)); l.position = CGPoint(x: 182.5, y: 312)
                l.contentsScale = CrateV3Materials.faceScale; l.contentsGravity = .resize
                let shadow = CALayer(); shadow.bounds = CGRect(x: 0, y: 0, width: size.width*1.06, height: 30)
                shadow.anchorPoint = CGPoint(x: 0.5, y: 0); shadow.position = CGPoint(x: 182.5+offset, y: 304)
                shadow.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor; shadow.cornerRadius = 15
                shadow.zPosition = -800
                stage.addSublayer(shadow); stage.addSublayer(l)
                objects[item.id] = Object(item: item, layer: l, shadow: shadow, home: home, pose: home, tabSlot: tabSlot)
                setPose(item.id, home, animated: false)
                if detailedIDs.contains(item.id) && loadingStarted && (!blanks.isEmpty || loading) { queueArrival(item.id) }
            }
            updateFace(item)
        }
        if !loading && pendingArrivals.isEmpty && arrivingID == nil { finishLoading(); measureVisible() }
        updateNameButtons()
        setNeedsLayout(); updateAccessibility()
    }
    func updateFace(_ item: CrateItem) {
        let asset = VerifiedArtworkAssets.designAsset(for: item.id) ?? item.entity.artworkAsset ?? ""
        guard detailedIDs.contains(item.id) else {
            let art = CrateV3Materials.artworkCache.object(forKey: asset as NSString)
                ?? (asset.isEmpty || asset.hasPrefix("https:") ? nil : ObservedArtwork.image(asset))
            let key = "stock:" + item.entity.title + "|" + item.relation + "|" + asset + (art == nil ? "" : ":loaded")
            guard imageKeys[item.id] != key else { return }
            imageKeys[item.id] = key; artworkTasks[item.id]?.cancel(); artworkTasks[item.id] = nil
            if var object = objects[item.id] {
                object.dividerFace = art.map {
                    CrateV3Materials.face(item, artwork: $0, artworkKey: asset, depth: -40, tabSlot: object.tabSlot, rasterScale: 1.5).cgImage
                } ?? CrateV3Materials.stockFace(item).cgImage
                object.portraitFace = nil; object.portraitExpanded = false
                CATransaction.begin(); CATransaction.setDisableActions(true)
                object.layer.contents = object.dividerFace
                CATransaction.commit(); objects[item.id] = object
            }
            return
        }
        let key = [asset, item.entity.title, item.entity.subtitle, item.relation, String(objects[item.id]?.tabSlot ?? 0)].joined(separator: "|")
        guard imageKeys[item.id] != key else { return }; imageKeys[item.id] = key
        artworkTasks[item.id]?.cancel()
        func install(_ image: UIImage?, key: String) {
            installFace(item, artwork: image, key: key)
        }
        if let cached=CrateV3Materials.artworkCache.object(forKey:asset as NSString) { install(cached,key:asset+":loaded"); return }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-network=real-relations") {
            install(PublicRelationsFixture.artwork(asset) ?? ObservedArtwork.image(asset),key:asset+":recorded"); return
        }
        #endif
        install(ObservedArtwork.image(asset), key: asset)
        // The crate shows sleeves larger than the 600px catalogue art; ask the
        // same image service for a bigger rendition of the same asset.
        let large = asset.contains("mzstatic.com") ? asset.replacingOccurrences(of: "600x600bb", with: "1200x1200bb").replacingOccurrences(of: "320x320bb", with: "640x640bb") : asset
        guard let url = URL(string: large), url.scheme == "https", let host = url.host,
              !host.contains("bgm"), !host.contains("bangumi") else { return }
        let token = changeToken
        artworkTasks[item.id] = Task { [weak self] in
            let started=Date()
            let result=try? await PianwaiRuntime.session.data(from:url)
            await P17Metrics.shared.request(host:host,queued:started,started:started,status:result == nil ? "failed" : "ok")
            guard let (data, response) = result,
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000,
                  !Task.isCancelled, let image = UIImage(data: data), let self,
                  self.changeToken == token, self.imageKeys[item.id] == key else { return }
            CrateV3Materials.artworkCache.countLimit=64
            CrateV3Materials.artworkCache.setObject(image,forKey:asset as NSString)
            self.installFace(item, artwork: image, key: asset+":loaded")
        }
    }
    private func installFace(_ item: CrateItem, artwork: UIImage?, key: String) {
        guard var object = objects[item.id] else { return }
        object.dividerFace = CrateV3Materials.face(item, artwork: artwork, artworkKey: key, depth: 0, tabSlot: object.tabSlot).cgImage
        if [.person, .group].contains(item.entity.kind), let artwork {
            object.portraitFace = CrateV3Materials.portrait(item, artwork: artwork, artworkKey: key).cgImage
        }
        objects[item.id] = object
        showPortrait(item.id, expanded: heldID == item.id || object.portraitExpanded, animated: heldID == item.id)
    }
    func showPortrait(_ id: String, expanded: Bool, animated: Bool) {
        guard var object = objects[id] else { return }
        let next = expanded && object.portraitFace != nil
        let changed = next != object.portraitExpanded
        object.portraitExpanded = next
        CATransaction.begin(); CATransaction.setDisableActions(true)
        object.layer.contents = next ? object.portraitFace : object.dividerFace
        CATransaction.commit(); objects[id] = object
        if changed && animated {
            let fade = CATransition(); fade.type = .fade; fade.duration = reduceMotion ? 0.15 : 0.34
            object.layer.add(fade, forKey: "portrait-face")
            if !reduceMotion { morphPortrait(object, expanding: next) }
        }
        if heldID == id && changed {
            setPose(id, heldPose(object), animated: animated, stiffness: 190, damping: 0.74)
            layoutControls(); updateAccessibility()
        }
    }
    /// The print clipped to the divider grows into the portrait (and back),
    /// instead of one picture being swapped for the other.
    private func morphPortrait(_ object: Object, expanding: Bool) {
        guard let portrait = object.portraitFace else { return }
        let inset = CrateV3Materials.faceInset, size = object.size, full = CrateV3Materials.faceSize(size)
        let left = object.tabSlot == 2
        let small = CGRect(x: inset.left + (left ? 10 : size.width-114), y: inset.top-62, width: 104, height: 124)
        let large = CrateV3Materials.portraitRect.offsetBy(dx: inset.left, dy: inset.top)
        let tilt = CGFloat.pi * (left ? -3 : 3.5) / 180
        let print = CALayer()
        print.contents = portrait; print.contentsScale = CrateV3Materials.faceScale
        print.contentsRect = CGRect(x: large.minX/full.width, y: large.minY/full.height, width: large.width/full.width, height: large.height/full.height)
        let from = expanding ? small : large, to = expanding ? large : small
        print.bounds = CGRect(origin: .zero, size: to.size); print.position = CGPoint(x: to.midX, y: to.midY)
        print.transform = CATransform3DMakeRotation(expanding ? 0 : tilt, 0, 0, 1)
        object.layer.addSublayer(print)
        let group = CAAnimationGroup(); group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        let bounds = CABasicAnimation(keyPath: "bounds.size"); bounds.fromValue = from.size; bounds.toValue = to.size
        let position = CABasicAnimation(keyPath: "position"); position.fromValue = CGPoint(x: from.midX, y: from.midY); position.toValue = CGPoint(x: to.midX, y: to.midY)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z"); turn.fromValue = expanding ? tilt : 0; turn.toValue = expanding ? 0 : tilt
        group.animations = [bounds, position, turn]
        print.add(group, forKey: "morph")
        let token = UUID(); morphPrints[token] = print
        // Not `later`: that is dropped when the page changes, and the print must never stay.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.36))
            self?.morphPrints.removeValue(forKey: token)?.removeFromSuperlayer()
        }
    }
    func setPose(_ id: String, _ pose: CrateV3Pose, animated: Bool, stiffness: CGFloat = 300, damping: CGFloat = 0.7) {
        guard var object = objects[id] else { return }
        let previous = object.layer.presentation()?.transform ?? object.layer.transform
        let previousDepth = object.layer.presentation()?.zPosition ?? object.layer.zPosition
        CATransaction.begin(); CATransaction.setDisableActions(true)
        object.pose = pose
        let transform = CrateV3Camera.project(pose.transform, at: object.layer.position)
        object.layer.transform = transform; object.layer.zPosition = pose.z
        object.shadow.bounds = CGRect(x: 0, y: 0, width: object.size.width*pose.scale*0.9, height: 18)
        object.shadow.position = CGPoint(x: 182.5+pose.x, y: 304)
        let shadowWorld = CATransform3DRotate(CATransform3DMakeTranslation(0,0,pose.z+6), -.pi/2,1,0,0)
        object.shadow.transform = CrateV3Camera.project(shadowWorld, at: object.shadow.position)
        object.shadow.opacity = Float(max(0, 1-(pose.y-8)/50))
        CATransaction.commit(); objects[id] = object
        if animated && reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = object.layer.opacity; fade.duration = 0.2
            object.layer.add(fade, forKey: "reduced-transition")
        }
        if animated && !reduceMotion {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1; spring.stiffness = stiffness; spring.damping = 2*damping*sqrt(stiffness)
            spring.fromValue = NSValue(caTransform3D: previous); spring.toValue = NSValue(caTransform3D: transform)
            spring.duration = spring.settlingDuration; object.layer.add(spring, forKey: "pose")
            let depth = spring.copy() as! CASpringAnimation
            depth.keyPath = "zPosition"; depth.fromValue = previousDepth; depth.toValue = pose.z
            object.layer.add(depth, forKey: "pose-depth")
        }
    }
    func projected(_ object: Object, usePresentation: Bool = true) -> CGRect {
        projected(object, rect: object.visualRect, usePresentation: usePresentation)
    }
    func projected(_ object: Object, rect: CGRect, usePresentation: Bool = true) -> CGRect {
        let t = usePresentation ? (object.layer.presentation()?.transform ?? object.layer.transform) : object.layer.transform
        let points = [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)].map { p in
            let x=p.x-object.size.width/2, y=p.y-object.size.height
            let w=x*t.m14+y*t.m24+t.m44
            let px=object.layer.position.x+(x*t.m11+y*t.m21+t.m41)/w
            let py=object.layer.position.y+(x*t.m12+y*t.m22+t.m42)/w
            return CGPoint(x:origin.x+px*sceneScale, y:origin.y+py*sceneScale)
        }
        let xs=points.map(\.x),ys=points.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
    func updateAccessibility() {
        accessibilityItems = interactiveIDs.compactMap { id in
            guard let object = objects[id] else { return nil }
            let element = CrateV3Accessibility(accessibilityContainer: self)
            element.accessibilityIdentifier = "crate-item-"+id
            element.accessibilityLabel = object.item.relation+" "+object.item.entity.title
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = exposedFrame(id) ?? projected(object)
            element.activate = { [weak self] in
                guard let self else { return }
                if self.heldID == id { self.openHeld() } else if self.heldID == nil { self.take(id) } else { self.returnHeld() }
            }
            return element
        }
        returnButton.isHidden = true; openButton.isHidden = true
        accessibilityElements = accessibilityItems + [browseButton].filter { !$0.isHidden }
        let frame = convert(CGRect(x:origin.x,y:origin.y,width:365*sceneScale,height:312*sceneScale),to: nil)
        let state: [String:Any] = ["settled":!windowTransition && arrivingID == nil && pendingArrivals.isEmpty && !isLoading,"systemReduceMotion":UIAccessibility.isReduceMotionEnabled,"reduceMotion":reduceMotion,
                                  "frame":[frame.minX,frame.minY,frame.width,frame.height],"order":interactiveIDs,"inventory":items.map(\.id),"rendered":objects.count,"detailed":detailedIDs.count,"cursor":browseCursor,"focused":items.indices.contains(windowIndex) ? items[windowIndex].id : "","browsing":browsing,"total":items.count,"held":heldID ?? "","exposed":flippedID ?? "", "loading":isLoading,"blanks":blanks.count]
        if let data = try? JSONSerialization.data(withJSONObject: state) { accessibilityValue = String(data:data,encoding:.utf8) }
    }
}
@MainActor final class CrateV3Accessibility: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

struct RecordCrateV3: UIViewRepresentable {
    let items: [CrateItem]
    let entityID: String
    var loading = false
    var categories: [String] = []
    var leadMode = false
    var heroFrame = CGRect.zero
    var headerBottom: CGFloat = 0
    var resumeVersion = 0
    var onOpen: (CrateItem) -> Void
    var onPull: (CrateItem) -> Void
    var onHeldChanged: (Bool) -> Void
    var onOpening: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(CratePageTransition.self) private var pageTransition
    func makeUIView(context: Context) -> CrateV3Scene { CrateV3Scene() }
    func updateUIView(_ view: CrateV3Scene, context: Context) {
        view.onOpen = onOpen; view.onPull = onPull; view.onHeldChanged = onHeldChanged; view.onOpening = onOpening
        view.pageTransition = pageTransition
        view.heroTarget = view.convert(heroFrame, from: nil)
        if view.entityID != entityID || !view.interaction.isBusy {
            view.reservedTop = headerBottom > 0 ? view.convert(CGPoint(x: 0, y: headerBottom), from: nil).y : 0
        }
        view.leadMode = leadMode
        view.configure(items: items, entityID: entityID, reduceMotion: PianwaiRuntime.reduceMotion(reduceMotion), loading: loading, categories: categories)
        view.resume(version: resumeVersion)
    }
}
