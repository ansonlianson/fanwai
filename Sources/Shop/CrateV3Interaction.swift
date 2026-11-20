import UIKit

extension CrateV3Scene: UIGestureRecognizerDelegate {
    func installInteraction() {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0; press.allowableMovement = .greatestFiniteMagnitude
        press.delegate = self; addGestureRecognizer(press)
        var browseStyle = UIButton.Configuration.plain()
        browseStyle.baseForegroundColor = CrateV3Materials.ink
        browseStyle.titleAlignment = .center
        browseStyle.titleTextAttributesTransformer = .init { value in
            var value = value; value.font = .systemFont(ofSize: 12, weight: .semibold); return value
        }
        browseStyle.subtitleTextAttributesTransformer = .init { value in
            var value = value; value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); return value
        }
        browseStyle.contentInsets = .init(top: 4, leading: 5, bottom: 10, trailing: 5)
        browseStyle.background.image = CrateV3Materials.indexPaper(size: .init(width: 86, height: 49), tab: true)
        browseButton.configuration = browseStyle
        browseButton.accessibilityIdentifier = "crate-browse"
        browseButton.addTarget(self, action: #selector(toggleBrowsing), for: .touchUpInside); addSubview(browseButton)
        browseButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(indexDragged(_:))))
        browseButton.accessibilityCustomActions = [-1, 1].map { step in
            UIAccessibilityCustomAction(name: step < 0 ? "向前翻" : "向后翻") { [weak self] _ in
                guard let self, self.heldID == nil, !self.windowTransition, !self.items.isEmpty else { return false }
                self.browsing = true
                self.moveStack(to: CGFloat(self.windowIndex+step), animated: true)
                self.persistBrowsing(); return true
            }
        }
        heldTitle.font = .systemFont(ofSize: 16, weight: .semibold); heldTitle.textColor = .white
        heldDetail.font = .systemFont(ofSize: 12.5); heldDetail.textColor = UIColor.white.withAlphaComponent(0.62)
        for label in [heldTitle, heldDetail] {
            label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 3; label.layer.shadowOffset = .zero
            label.textAlignment = .center; label.lineBreakMode = .byTruncatingTail; label.alpha = 0
            label.isAccessibilityElement = false; addSubview(label)
        }
        heldTitle.accessibilityIdentifier = "crate-held-title"
        heldChevron.image = UIImage(systemName: "chevron.compact.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        heldChevron.tintColor = UIColor.white.withAlphaComponent(0.7); heldChevron.contentMode = .center; heldChevron.alpha = 0
        addSubview(heldChevron)
    }
    @objc func indexDragged(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        switch pan.state {
        case .began:
            guard heldID == nil, openedID == nil, !windowTransition else { return }
            dragID = nil; dragging = true
            beginBrowsingGesture(horizontal: abs(translation.x) > abs(translation.y))
        case .changed:
            guard digging else { return }
            let travel = (browseAxisHorizontal ? -translation.x : translation.y) / sceneScale
            browseEntryProgress = min(1, abs(travel)/48)
            moveStack(to: browseStart + travel/48)
        case .ended, .cancelled:
            if digging { finishBrowsingGesture(cancelled: pan.state == .cancelled) }
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if heldID != nil || flippedID != nil { return bounds.contains(point) }
        if point.y < reservedTop + 4 { return false }
        if hitObject(point) != nil { return true }
        return point.y >= origin.y+100*sceneScale && bounds.contains(point)
    }
    override func accessibilityPerformEscape() -> Bool {
        guard heldID != nil else { return false }; returnHeld(); return true
    }
    func hitObject(_ point: CGPoint) -> String? {
        if let exposed = flippedID, let o = objects[exposed] {
            // While digging, only the uncovered sleeve can be picked; a touch
            // anywhere else stands the bin back up.
            return projected(o).insetBy(dx: -10, dy: -10).contains(point) ? exposed : nil
        }
        return interactiveIDs.reversed().first { id in
            guard let object=objects[id], object.layer.opacity > 0.5 else { return false }
            let rect = projected(object)
            if rect.contains(point) { return true }
            if [.person,.group].contains(object.item.entity.kind) {
                return extras(object).contains { projected(object,rect:$0).contains(point) }
            }
            return false
        }
    }
    /// Parts of an artist divider that stand above the card: its index tab
    /// and the clipped photo.
    func extras(_ o: Object) -> [CGRect] {
        var rects = [CrateV3Materials.tabRect(slot: o.tabSlot, width: o.size.width)]
        let left = o.tabSlot == 2
        rects.append(CGRect(x: left ? 10 : o.size.width-114, y: -62, width: 104, height: 124))
        return rects
    }
    func exposedFrame(_ id: String) -> CGRect? {
        guard let o=objects[id],let index=order.firstIndex(of:id) else { return nil }
        if heldID == id { return projected(o, usePresentation: false) }
        let box=projected(o, usePresentation: false)
        var covers:[CGRect]=[]
        for front in order.dropFirst(index+1) {
            guard let next=objects[front] else { continue }; covers.append(projected(next, usePresentation: false))
            if [.person,.group].contains(next.item.entity.kind) {
                covers += extras(next).map { projected(next,rect:$0, usePresentation: false) }
            }
        }
        // Artist photos and tabs protrude above the card. Pick a genuinely
        // visible point there; the covered card centre may belong to a film.
        let regions = ([.person, .group].contains(o.item.entity.kind)
            ? extras(o).map { projected(o, rect: $0, usePresentation: false) } : []) + [box]
        let frontTop = origin.y + 256*sceneScale
        for raw in regions {
            let region = raw.intersection(CGRect(x: 14, y: reservedTop+4, width: bounds.width-28, height: max(0, frontTop-reservedTop-4)))
            guard region.width >= 44, region.height >= 44 else { continue }
            for y in stride(from: region.minY, through: region.maxY-44, by: 4) {
                for x in stride(from: region.minX, through: region.maxX-44, by: 4) {
                    let target = CGRect(x: x, y: y, width: 44, height: 44)
                    if covers.allSatisfy({ !$0.intersects(target) }) { return target }
                }
            }
        }
        // The named strip is an independent, non-overlapping physical target.
        return nameButtons[id]?.frame
    }
    @objc func pressed(_ press: UILongPressGestureRecognizer) {
        let point=press.location(in:self)
        switch press.state {
        case .began:
            guard openedID == nil, !windowTransition else { return }
            dragStart=point; dragTime=CACurrentMediaTime(); dragging=false; digging=false
            dragLast=point; dragLastTime=dragTime; dragVX=0; dragVY=0
            if let held=heldID {
                // While something is in hand, only that object responds; a touch
                // anywhere else puts it back on release.
                dragID = objects[held].map { projected($0).insetBy(dx:-18,dy:-18).contains(point) } == true ? held : nil
                return
            }
            digBase = digSteps
            dragID=hitObject(point)
            if let id=dragID, let o=objects[id] {
                var pose=o.pose; pose.y += 6; pose.rx -= 2; pose.scale=o.home.scale*1.012
                setPose(id,pose,animated:true,stiffness:700,damping:0.8)
                UIImpactFeedbackGenerator(style:.light).impactOccurred()
            }
        case .changed:
            let now=CACurrentMediaTime(), dt=max(1,(now-dragLastTime)*1000)
            dragVX=dragVX*0.6+0.4*(point.x-dragLast.x)/sceneScale/dt
            dragVY=dragVY*0.6+0.4*(dragLast.y-point.y)/sceneScale/dt
            dragLast=point; dragLastTime=now
            let dx=(point.x-dragStart.x)/sceneScale, up=(dragStart.y-point.y)/sceneScale
            if heldID == nil {
                if !digging && hypot(dx, up) > 10 && (abs(dx) > abs(up)*1.15 || up < -10 || dragID == nil) {
                    beginBrowsingGesture(horizontal: abs(dx) > abs(up))
                }
                if digging {
                    let travel = browseAxisHorizontal ? -dx : -up
                    browseEntryProgress = min(1, abs(travel)/48)
                    moveStack(to: browseStart + travel / 48)
                    return
                }
            }
            guard let id=dragID, let o=objects[id] else { return }
            guard dragging || hypot(dx,up)>6 else { return }; dragging=true
            if heldID == id {
                // Lifting the object in hand carries it toward its own page.
                var pose=heldPose(o)
                pose.y += up > 0 ? up : up*0.8
                pose.x += dx*0.5; pose.rz = min(6,max(-6,dx*0.05))
                pose.scale *= 1+max(0,up)/900
                o.layer.removeAnimation(forKey:"pose"); o.layer.removeAnimation(forKey:"pose-depth"); setPose(id,pose,animated:false)
                setHint(visible: abs(up) < 40, animated: true)
                return
            }
            var rise=max(-6,up); let limit=o.size.height*1.6
            if rise>limit { rise=limit+(rise-limit)*0.35 }
            let p=min(1,max(0,rise/(o.size.height*0.9))), zf=min(1,max(0,(rise-o.size.height*0.5)/80))
            var pose=o.home
            pose.x += dx*0.85; pose.y += 6+rise; pose.z += zf*(90-o.home.z)
            pose.rx=o.home.rx*(1-p)-4*p; pose.rz=o.home.rz*(1-p)+min(9,max(-9,dx*0.07))
            pose.ry=min(14,max(-14,dragVX*22)); pose.scale=o.home.scale+(1.05-o.home.scale)*p+max(0,rise-o.size.height)/1400
            o.layer.removeAnimation(forKey:"pose"); o.layer.removeAnimation(forKey:"pose-depth"); setPose(id,pose,animated:false)
            if let index=order.firstIndex(of:id) {
                for front in order.dropFirst(index+1) where front != id {
                    // Sleeves already tipped forward by digging stay down.
                    if flippedID != nil { continue }
                    if var home=objects[front]?.home { home.rx -= 7*min(1,p*2); setPose(front,home,animated:true,stiffness:260,damping:0.75) }
                }
            }
        case .ended, .cancelled:
            defer { dragging = false; dragID = nil; applyPendingContent() }
            let up=(dragStart.y-point.y)/sceneScale
            if let held=heldID {
                let onHeld = dragID == held; dragID=nil
                guard onHeld, press.state != .cancelled else { returnHeld(); return }
                if !dragging || up>48 || dragVY>0.45 { openHeld() }
                else if up < -48 || dragVY < -0.45 { returnHeld() }
                else if let o=objects[held] { setPose(held,heldPose(o),animated:true,stiffness:260,damping:0.75); setHint(visible:true,animated:true) }
                return
            }
            if digging { finishBrowsingGesture(cancelled: press.state == .cancelled); return }
            guard let id=dragID, let o=objects[id] else {
                // A tap on nothing while digging stands every sleeve back up.
                if flippedID != nil && !dragging { dig(to: 0) }

                return
            }
            dragID=nil
            if press.state == .cancelled { settle(id); return }
            if dragging {
                // Pulled all the way out: straight into its page, no stop in hand.
                if up>o.size.height*0.95 || dragVY>0.95 { take(id, opening: true) }
                else if up>o.size.height*0.4 || dragVY>0.45 { take(id) }
                else { settle(id) }
            } else { take(id) }
        default: break
        }
    }
    /// Tip the front `steps` sleeves forward and show what is now uncovered.
    func dig(to target: Int) {
        let steps = max(0, min(order.count-1, target))
        guard steps != digSteps || (steps == 0 && flippedID != nil) else { return }
        digSteps = steps
        flippedID = steps == 0 ? nil : order[order.count-1-steps]
        applyFlip()
        digTick.selectionChanged(); digTick.prepare()
        showDigHint()
    }
    func showDigHint() {
        guard heldID == nil else { return }
        guard let id = flippedID ?? (digging ? order.last : nil), let o = objects[id] else {
            UIView.animate(withDuration: 0.15) { [self] in heldTitle.alpha = 0; heldDetail.alpha = 0 }
            return
        }
        heldTitle.text = o.item.entity.title
        heldDetail.text = Self.detail(o.item, relation: true)
        // On the crate's front board, below the tipped sleeves, only while digging.
        let top = origin.y + 266*sceneScale
        heldTitle.frame = CGRect(x: 24, y: top, width: bounds.width-48, height: 21)
        heldDetail.frame = CGRect(x: 24, y: top+21, width: bounds.width-48, height: 17)
        heldChevron.alpha = 0
        UIView.animate(withDuration: 0.15) { [self] in heldTitle.alpha = 1; heldDetail.alpha = 1 }
    }
    func applyFlip() {
        let index=flippedID.flatMap { order.firstIndex(of:$0) }
        for (i,id) in order.enumerated() where id != heldID && id != openedID {
            guard var pose=objects[id]?.home else { continue }
            if let index, i>index { pose.rx = -44+CGFloat(i-index-1)*7; pose.rz *= 0.4 }
            else if index == i { pose.rx -= 5; pose.y += 4 }
            setPose(id,pose,animated:true,stiffness:200,damping:0.58)
        }
        updateAccessibility()
    }
    func heldPose(_ o: Object) -> CrateV3Pose {
        let sc=min(1.2,250/max(o.visualRect.width,o.visualRect.height)), k:CGFloat=1.2
        let center:CGFloat = -40
        return CrateV3Pose(x:0,y:312-(-187.2+(center+187.2)/k)-(o.size.height-o.visualRect.midY)*sc,z:150,scale:sc)
    }
    func take(_ id: String, opening: Bool = false) {
        guard heldID == nil, let o=objects[id] else { return }
        heldID=id; flippedID=nil; digSteps=0; onPull?(o.item)
        if opening { openHeld(); return }
        showPortrait(id, expanded: true, animated: true)
        onHeldChanged?(true)
        setPose(id,heldPose(objects[id]!),animated:true,stiffness:190,damping:0.74)
        setDimmed(true); applyFlip(); layoutControls(); updateAccessibility()
        UIImpactFeedbackGenerator(style:.medium).impactOccurred(intensity:0.6)
        later(reduceMotion ? 0 : 0.22) { [weak self] in self?.layoutControls(); self?.setHint(visible:true,animated:true) }
    }
    /// "歌曲 · miki et nana", "配乐 · 电影 · 2025": the kind word is not repeated
    /// when the subtitle already starts with it.
    static func detail(_ item: CrateItem, relation: Bool) -> String {
        let kind = kindWord(item.entity.kind)
        let sub = [.person, .group].contains(item.entity.kind) ? "" : item.entity.subtitle
        var parts = relation ? [item.relation] : []
        if !sub.hasPrefix(kind) { parts.append(kind) }
        if !sub.isEmpty { parts.append(sub) }
        return parts.joined(separator: " · ")
    }
    static func kindWord(_ kind: SeedGraph.Kind) -> String {
        switch kind {
        case .song: "歌曲"
        case .album: "专辑"
        case .person: "艺人"
        case .group: "组合"
        case .film: "电影"
        case .game: "游戏"
        case .tv: "剧集"
        case .video: "视频"
        case .book: "书"
        case .manga: "漫画"
        }
    }
    func setHint(visible: Bool, animated: Bool) {
        let target: CGFloat = visible && heldID != nil ? 1 : 0
        let apply = { [self] in heldTitle.alpha = target; heldDetail.alpha = target; heldChevron.alpha = target }
        if animated && !reduceMotion { UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply) }
        else { apply() }
        heldChevron.layer.removeAnimation(forKey: "bob")
        if visible && heldID != nil && !reduceMotion {
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0; bob.toValue = -5; bob.duration = 0.42; bob.autoreverses = true; bob.repeatCount = 2
            bob.beginTime = CACurrentMediaTime()+0.15; bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            heldChevron.layer.add(bob, forKey: "bob")
        }
    }
    func setDimmed(_ value: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func shade(_ layer:CALayer, dark:Bool) {
            let key=ObjectIdentifier(layer)
            if dark {
                guard undimmed[key] == nil, let contents=layer.contents else { return }
                let cg=contents as! CGImage
                undimmed[key]=cg
                let image=UIImage(cgImage:cg,scale:CrateV3Materials.faceScale,orientation:.up)
                let rendered=CrateV3Materials.image(key:"dim:\(key):\(cg)",size:image.size,scale:CrateV3Materials.faceScale) { c in
                    image.draw(at:.zero); c.setBlendMode(.sourceAtop)
                    UIColor.black.withAlphaComponent(0.58).setFill(); c.fill(CGRect(origin:.zero,size:image.size))
                }
                layer.contents=rendered.cgImage
            } else if let image=undimmed.removeValue(forKey:key) { layer.contents=image }
        }
        for board in boards { shade(board,dark:value) }
        for (id,o) in objects { shade(o.layer,dark:value && id != heldID) }
        CATransaction.commit()
    }
    func layoutControls() {
        returnButton.isHidden=true; openButton.isHidden=true
        if let id=heldID, let o=objects[id] {
            // Use the destination, not the animated presentation, for stable labels.
            let pose=heldPose(o), k:CGFloat=1.2
            let foot=origin.y+(-187.2+(312-pose.y+187.2)*k)*sceneScale
            let bottom=foot+(o.visualRect.maxY-o.size.height)*pose.scale*k*sceneScale
            let top=foot+(o.visualRect.minY-o.size.height)*pose.scale*k*sceneScale
            // In the hand, a lead says why it is here; other objects say what they are.
            let note=leadMode && !o.item.note.isEmpty
            let y=min(bounds.height-(note ? 64 : 44),bottom+14)
            heldTitle.text=o.item.entity.title
            heldDetail.numberOfLines=note ? 2 : 1
            heldDetail.text=note ? o.item.relation+" · "+o.item.note : Self.detail(o.item, relation: false)
            heldTitle.frame=CGRect(x:24,y:y,width:bounds.width-48,height:21)
            heldDetail.frame=CGRect(x:24,y:y+22,width:bounds.width-48,height:note ? 36 : 17)
            heldChevron.frame=CGRect(x:bounds.midX-22,y:max(-30,top-34),width:44,height:28)
        }
        else if flippedID != nil || digging { showDigHint() }
        else { clearLabels() }
        layoutBrowsingControls()
    }
    @objc func returnHeld() {
        guard let id=heldID, let o=objects[id] else { return }
        heldID=nil; onHeldChanged?(false); setDimmed(false); setHint(visible:false,animated:true); layoutControls()
        showPortrait(id, expanded: false, animated: true)
        var pose=o.home; pose.y += o.size.height*0.85; pose.z=82.5; pose.rx *= 0.5; pose.scale=1.02
        setPose(id,pose,animated:true,stiffness:230,damping:0.8)
        later(reduceMotion ? 0 : 0.24) { [weak self] in self?.settle(id) }
        updateAccessibility()
    }
    func settle(_ id: String) {
        guard let o=objects[id] else { return }; flippedID=nil; applyFlip()
        setPose(id,o.home,animated:true,stiffness:330,damping:0.5)
        later(reduceMotion ? 0 : 0.24) { [weak self] in
            self?.jiggle(id); self?.updateAccessibility(); self?.applyPendingContent(); UIImpactFeedbackGenerator(style:.soft).impactOccurred()
        }
    }
    func jiggle(_ id: String) {
        guard !reduceMotion, let index=order.firstIndex(of:id) else { return }
        for j in [index-1,index+1] where order.indices.contains(j) {
            let neighbor=order[j]; guard neighbor != heldID, var pose=objects[neighbor]?.home else { continue }
            pose.rx += 2; pose.rz += j<index ? -1.8 : 1.8; pose.y += 2
            setPose(neighbor,pose,animated:true,stiffness:400,damping:0.6)
            later(0.08) { [weak self] in if let home=self?.objects[neighbor]?.home { self?.setPose(neighbor,home,animated:true,stiffness:300,damping:0.52) } }
        }
    }
    @objc func openHeld() {
        guard let id=heldID, let o=objects[id] else { return }
        heldID=nil; openedID=id; setDimmed(false); setHint(visible:false,animated:false); layoutControls()
        if pageTransition?.begin(o, from: self) == true {
            onHeldChanged?(false)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            onOpen?(o.item)
            return
        }
        onOpening?()
        let k:CGFloat=1.2
        let target=heroTarget.isEmpty ? CGRect(x:bounds.midX-75,y:12,width:150,height:150) : heroTarget
        let sc=min(target.width/o.size.width,target.height/o.size.height)/sceneScale/k
        let center=(target.midY-origin.y)/sceneScale
        let pose=CrateV3Pose(x:(target.midX-origin.x-182.5*sceneScale)/sceneScale/k,
            y:312-(-187.2+(center+187.2)/k)-o.size.height*sc/2,z:150,scale:sc)
        setPose(id,pose,animated:true,stiffness:210,damping:0.86)
        UIImpactFeedbackGenerator(style:.soft).impactOccurred()
        later(reduceMotion ? 0.2 : 0.42) { [weak self] in
            guard let self, self.openedID==id else { return }
            self.onHeldChanged?(false); self.onOpen?(o.item)
        }
    }
    func resume(version:Int) {
        guard version != lastResume else { return }; lastResume=version
        guard let id=openedID, let o=objects[id] else { return }; openedID=nil
        o.layer.isHidden = false; o.shadow.isHidden = false
        showPortrait(id, expanded: false, animated: false)
        var pose=o.home; pose.y += o.size.height*0.85; pose.z=82.5
        setPose(id,pose,animated:true,stiffness:200,damping:0.8)
        later(reduceMotion ? 0 : 0.3) { [weak self] in self?.settle(id) }
    }
    func later(_ seconds:Double, _ action:@escaping @MainActor ()->Void) {
        let token=changeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(seconds))
            guard let self,self.changeToken==token,!Task.isCancelled else { return }; action()
        }
    }
    func fade(_ layer:CALayer?,to opacity:Float,duration:Double) {
        guard let layer else { return }; let animation=CABasicAnimation(keyPath:"opacity")
        animation.fromValue=layer.presentation()?.opacity ?? layer.opacity; animation.toValue=opacity; animation.duration=duration
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.opacity=opacity; CATransaction.commit()
        if duration>0 { layer.add(animation,forKey:"fade") }
    }
}
