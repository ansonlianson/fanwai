import UIKit

/// A page owns the entire interaction. Replacing its entity replaces this
/// value, including states whose delayed completion was cancelled.
struct CrateSceneInteraction {
    var heldID: String?
    var flippedID: String?
    var openedID: String?
    var dragID: String?
    var dragging = false
    var digging = false
    var digBase = 0
    var digSteps = 0
    var windowTransition = false
    var isBusy: Bool {
        heldID != nil || openedID != nil || dragID != nil || flippedID != nil
            || dragging || digging || windowTransition
    }
}

extension CrateV3Scene {
    func clearLabels() {
        for label in [heldTitle, heldDetail] {
            label.layer.removeAllAnimations(); label.text = nil; label.alpha = 0
        }
        heldChevron.layer.removeAllAnimations(); heldChevron.alpha = 0
    }

    func resetScene(for nextEntity: String) {
        changeToken = UUID()
        resetLoading()
        artworkTasks.values.forEach { $0.cancel() }; artworkTasks.removeAll()
        setDimmed(false)
        for object in objects.values {
            object.layer.removeAllAnimations(); object.layer.removeFromSuperlayer()
            object.shadow.removeAllAnimations(); object.shadow.removeFromSuperlayer()
        }
        objects.removeAll(); order.removeAll(); imageKeys.removeAll(); undimmed.removeAll()
        interaction = CrateSceneInteraction(); pendingContent = nil
        dragStart = .zero; dragLast = .zero; dragTime = 0; dragLastTime = 0; dragVX = 0; dragVY = 0
        nameButtons.values.forEach { $0.removeFromSuperview() }; nameButtons.removeAll()
        clearLabels(); windowIndex = 0; browsing = false; browseCursor = 0; browseStart = 0
        detailedIDs.removeAll(); featuredIDs.removeAll(); browseEntryPoses.removeAll(); browseEntryProgress = 1; entityID = nextEntity
        let token = changeToken
        Task { @MainActor [weak self] in
            guard let self, self.changeToken == token, self.heldID == nil else { return }
            self.onHeldChanged?(false)
        }
    }

    func applyPendingContent() {
        guard !interaction.isBusy, let pending = pendingContent else { return }
        pendingContent = nil
        configure(items: pending.items, entityID: entityID, reduceMotion: reduceMotion,
                  loading: pending.loading, categories: pending.categories)
    }
}
