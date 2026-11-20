import UIKit

extension CrateV3Scene {
    var interactiveIDs: [String] {
        if let heldID { return [heldID] }
        if !browsing { return order.filter { featuredIDs.contains($0) } }
        return order.filter { id in
            items.firstIndex(where: { $0.id == id }).map { abs(CGFloat($0)-browseCursor) <= 1.15 } ?? false
        }
    }

    func updateNameButtons() {
        let named = browsing && items.indices.contains(windowIndex) ? [items[windowIndex].id] : featuredIDs
        for id in Array(nameButtons.keys) where !named.contains(id) {
            nameButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in named {
            guard let item = objects[id]?.item else { continue }
            let button = nameButtons[id] ?? UIButton(type: .system)
            if nameButtons[id] == nil {
                button.addAction(UIAction { [weak self] _ in
                    guard let self, self.heldID == nil, self.openedID == nil, !self.windowTransition else { return }
                    self.take(id)
                }, for: .touchUpInside)
                button.isAccessibilityElement = false
                addSubview(button); nameButtons[id] = button
            }
            let caption = leadMode && !item.note.isEmpty ? item.relation + " · " + item.note : item.relation
            if button.configuration?.title == item.entity.title && button.configuration?.subtitle == caption { continue }
            let lead = leadMode
            var style = UIButton.Configuration.plain()
            style.title = item.entity.title; style.subtitle = caption
            style.baseForegroundColor = CrateV3Materials.ink
            style.titleTextAttributesTransformer = .init { value in
                var value = value; value.font = .systemFont(ofSize: lead ? 13 : 11.5, weight: lead ? .semibold : .medium); return value
            }
            style.subtitleTextAttributesTransformer = .init { value in
                var value = value; value.font = .systemFont(ofSize: lead ? 11.5 : 9.5)
                value.foregroundColor = CrateV3Materials.ink.withAlphaComponent(lead ? 0.78 : 0.65); return value
            }
            style.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 8)
            style.titleAlignment = .center; style.titleLineBreakMode = .byTruncatingTail
            style.background.image = CrateV3Materials.indexPaper(size: lead ? CGSize(width: 340, height: 64) : CGSize(width: browsing ? 230 : 100, height: 43))
            if lead { style.subtitleLineBreakMode = .byWordWrapping; style.titlePadding = 2 }
            button.configuration = style; button.titleLabel?.numberOfLines = 1
            button.subtitleLabel?.numberOfLines = lead ? 2 : 1
        }
    }

    func layoutBrowsingControls() {
        let hidden = items.isEmpty || heldID != nil || openedID != nil
        browseButton.isHidden = hidden || leadMode || (!browsing && items.count <= featuredIDs.count)
        browseButton.isEnabled = !windowTransition
        browseButton.configuration?.title = browsing ? "收拢" : "翻找"
        browseButton.configuration?.subtitle = browsing ? "\(windowIndex+1) / \(items.count)" : "\(items.count) 件"
        browseButton.accessibilityLabel = browsing ? "收拢唱片箱" : "翻找箱内全部 \(items.count) 件作品"
        browseButton.accessibilityHint = "左右拨动箱内物件，上提抽出"
        browseButton.transform = .identity
        browseButton.frame = CGRect(x: origin.x+250*sceneScale, y: origin.y+225*sceneScale-14, width: 86*sceneScale, height: 49)
        browseButton.transform = CGAffineTransform(rotationAngle: -.pi/45)
        let named = nameButtons.keys.sorted { (objects[$0]?.home.x ?? 0) < (objects[$1]?.home.x ?? 0) }
        let rowWidth = leadMode ? min(bounds.width-36, 344*sceneScale) : min(bounds.width-52, 310*sceneScale)
        let width = leadMode ? rowWidth : browsing ? min(240, rowWidth) : rowWidth/CGFloat(max(1, named.count))
        let left = bounds.midX-width*CGFloat(named.count)/2
        for (i, id) in named.enumerated() {
            nameButtons[id]?.isHidden = hidden || windowTransition || digging
            nameButtons[id]?.frame = leadMode
                ? CGRect(x: left+CGFloat(i)*width, y: origin.y+254*sceneScale, width: width, height: 64)
                : CGRect(x: left+CGFloat(i)*width, y: origin.y+265*sceneScale, width: width, height: 44)
        }
        bringSubviewToFront(browseButton)
    }

    @objc func toggleBrowsing() { switchDisplay(browse: !browsing, index: windowIndex) }

    /// Rearrange existing objects without replacing the scene or fading the bin.
    func switchDisplay(browse: Bool, index: Int) {
        guard items.indices.contains(index), heldID == nil, openedID == nil, !windowTransition else { return }
        finishArrivalsForBrowsing(); clearLabels(); flippedID = nil; digSteps = 0
        browsing = browse; windowIndex = index; browseCursor = CGFloat(index)
        windowTransition = true
        arrangeStack(animated: true)
        persistBrowsing()
        later(reduceMotion ? 0.16 : 0.36) { [weak self] in
            guard let self else { return }
            self.windowTransition = false; self.layoutControls(); self.updateAccessibility(); self.applyPendingContent()
        }
    }

    func arrangeStack(animated: Bool) {
        let resting = items.filter { !featuredIDs.contains($0.id) }
        for (index, item) in items.enumerated() {
            guard var object = objects[item.id] else { continue }
            if browsing { object.home = CrateStackLayout.browsing(index: index, cursor: browseCursor) }
            else if let slot = featuredIDs.firstIndex(of: item.id) { object.home = CrateFeaturedLayout.pose(index: slot, count: featuredIDs.count) }
            else { object.home = CrateStackLayout.resting(index: resting.firstIndex(where: { $0.id == item.id })!, count: resting.count) }
            if let from = browseEntryPoses[item.id] {
                object.home = CrateStackLayout.interpolate(from, object.home, progress: browseEntryProgress)
            }
            object.home = CrateStackLayout.contained(object.home, kind: item.entity.kind)
            objects[item.id] = object
            guard item.id != heldID, item.id != openedID else { continue }
            if !animated { object.layer.removeAnimation(forKey: "pose"); object.layer.removeAnimation(forKey: "pose-depth") }
            setPose(item.id, object.home, animated: animated, stiffness: 270, damping: 0.88)
        }
        order = items.map(\.id).sorted { objects[$0]!.home.z < objects[$1]!.home.z }
        let details = browsing ? Set(items.enumerated().filter { abs($0.offset-windowIndex) <= 2 }.map { $0.element.id }) : Set(featuredIDs)
        if details != detailedIDs {
            detailedIDs = details
            for item in items { updateFace(item) }
        }
        updateNameButtons(); layoutBrowsingControls()
        if !digging { updateAccessibility() }
    }

    func moveStack(to cursor: CGFloat, animated: Bool = false) {
        guard !items.isEmpty else { return }
        browseCursor = min(CGFloat(items.count-1), max(0, cursor))
        let index = Int(browseCursor.rounded())
        if index != windowIndex { digTick.selectionChanged(); windowIndex = index }
        arrangeStack(animated: animated)
    }

    func beginBrowsingGesture(horizontal: Bool) {
        finishArrivalsForBrowsing(); clearLabels()
        if !browsing {
            browseEntryPoses = objects.mapValues(\.pose); browseEntryProgress = 0
            windowIndex = dragID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? windowIndex
            browseCursor = CGFloat(windowIndex); browsing = true
        }
        digging = true; browseStart = browseCursor; browseAxisHorizontal = horizontal
        flippedID = nil; dragID = nil; digTick.prepare()
        arrangeStack(animated: false)
    }

    func finishBrowsingGesture(cancelled: Bool) {
        digging = false; dragging = false; dragID = nil
        browseEntryPoses.removeAll(); browseEntryProgress = 1
        // Settle to the nearest sleeve, without a carousel-sized page jump.
        moveStack(to: cancelled ? browseStart : browseCursor.rounded(), animated: true)
        persistBrowsing(); layoutControls(); updateAccessibility(); applyPendingContent()
    }

    func finishArrivalsForBrowsing() {
        resetLoading()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for object in objects.values { object.layer.opacity = 1; object.layer.removeAnimation(forKey: "fade") }
        CATransaction.commit()
    }

    func persistBrowsing() {
        guard items.indices.contains(windowIndex) else { return }
        RelationTrailStore().defaults.set(browsing ? items[windowIndex].id : nil, forKey: "redesign.crateBrowse.v2." + entityID)
    }
}
