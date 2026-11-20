import SwiftUI
import UIKit
import Observation

/// Owns the lifted sleeve above both navigation pages until the destination
/// hero has laid out. The source scene may disappear without ending the flight.
@MainActor @Observable final class CratePageTransition {
    private(set) var coveredEntityID: String?
    @ObservationIgnored private var flight: CratePageFlightView?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func begin(_ object: CrateV3Scene.Object, from scene: CrateV3Scene) -> Bool {
        guard flight == nil, let window = scene.window else { return false }
        let face = object.layer.presentation() ?? object.layer
        // The presentation layer describes the pose, but Core Animation may
        // omit its contents. The model layer always owns the rendered face.
        let contents = object.layer.contents
        let transform = CATransform3DConcat(face.transform, CATransform3DMakeScale(scene.sceneScale, scene.sceneScale, 1))
        let position = scene.convert(CGPoint(x: scene.origin.x + face.position.x * scene.sceneScale,
                                             y: scene.origin.y + face.position.y * scene.sceneScale), to: window)
        // A single snapshot retains the old page while navigation changes below
        // it. Remove the moving sleeve so it cannot leave a second copy behind.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        object.layer.isHidden = true; object.shadow.isHidden = true
        CATransaction.commit()
        guard let backdrop = window.snapshotView(afterScreenUpdates: true) else {
            object.layer.isHidden = false; object.shadow.isHidden = false
            return false
        }
        let overlay = CratePageFlightView(frame: window.bounds, backdrop: backdrop,
                                         contents: contents, bounds: face.bounds,
                                         anchor: face.anchorPoint, position: position,
                                         transform: transform, objectSize: object.size,
                                         visualRect: object.visualRect,
                                         reduceMotion: scene.reduceMotion)
        flight = overlay; coveredEntityID = object.item.id
        window.addSubview(overlay)
        // A disappearing destination, scene interruption or failed navigation
        // cannot leave the window covered indefinitely.
        timeout = Task { [weak self, weak overlay] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self?.flight === overlay else { return }
            self?.finish()
        }
        return true
    }

    func destinationDidLayout(_ id: String, frame: CGRect) {
        // Navigation first reports an unplaced frame (sometimes above the
        // screen). Keep the sleeve in hand until the real destination lands.
        guard coveredEntityID == id, frame.width > 0, frame.height > 0,
              let flight, flight.bounds.contains(frame) else { return }
        flight.land(at: frame, reveal: { [weak self] in
            withAnimation(.easeIn(duration: flight.reduceMotion ? 0.2 : 0.16)) {
                self?.coveredEntityID = nil
            }
        }, completion: { [weak self] in self?.finish() })
    }

    func finish() {
        timeout?.cancel(); timeout = nil
        coveredEntityID = nil
        flight?.removeFromSuperview(); flight = nil
    }
}

@MainActor private final class CratePageFlightView: UIView {
    let reduceMotion: Bool
    private let backdrop: UIView
    private let sleeve = CALayer()
    private let objectSize: CGSize
    private let visualRect: CGRect
    private var started = false

    init(frame: CGRect, backdrop: UIView, contents: Any?, bounds: CGRect,
         anchor: CGPoint, position: CGPoint, transform: CATransform3D,
         objectSize: CGSize, visualRect: CGRect, reduceMotion: Bool) {
        self.backdrop = backdrop; self.objectSize = objectSize; self.visualRect = visualRect; self.reduceMotion = reduceMotion
        super.init(frame: frame)
        backgroundColor = .clear
        // Block a second navigation while the first object is still in flight.
        isAccessibilityElement = true; accessibilityIdentifier = "crate-page-transition"
        accessibilityLabel = "正在打开作品"
        backdrop.frame = self.bounds; addSubview(backdrop)
        sleeve.contents = contents; sleeve.bounds = bounds; sleeve.anchorPoint = anchor
        sleeve.position = position; sleeve.transform = transform
        sleeve.contentsScale = CrateV3Materials.faceScale
        sleeve.allowsEdgeAntialiasing = true; layer.addSublayer(sleeve)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func land(at globalFrame: CGRect, reveal: @escaping @MainActor () -> Void,
              completion: @escaping @MainActor () -> Void) {
        guard !started else { return }; started = true
        let target = convert(globalFrame, from: nil)
        if reduceMotion {
            reveal()
            UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in completion() }
            return
        }
        let scale = min(target.width / visualRect.width, target.height / visualRect.height)
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let position = CGPoint(x: target.midX-(visualRect.midX-objectSize.width/2)*scale,
                               y: target.midY-(visualRect.midY-objectSize.height)*scale)
        let motion = CAAnimationGroup()
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(cgPoint: sleeve.position)
        move.toValue = NSValue(cgPoint: position)
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = NSValue(caTransform3D: sleeve.transform)
        turn.toValue = NSValue(caTransform3D: transform)
        motion.animations = [move, turn]; motion.duration = 0.52
        move.duration = motion.duration; turn.duration = motion.duration
        motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.24, 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sleeve.position = position; sleeve.transform = transform
        sleeve.add(motion, forKey: "land"); CATransaction.commit()
        UIView.animate(withDuration: 0.38, delay: 0.06, options: [.curveEaseInOut], animations: {
            self.backdrop.alpha = 0
        })
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.40))
            guard let self, self.window != nil else { return }
            reveal()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.16
            self.sleeve.opacity = 0; self.sleeve.add(fade, forKey: "reveal-hero")
            CATransaction.commit()
            try? await Task.sleep(for: .seconds(0.17))
            completion()
        }
    }
}
