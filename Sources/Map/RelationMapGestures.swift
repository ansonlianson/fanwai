import SwiftUI
import UIKit

/// Lets the one-finger pan and the two-finger pinch run together, so a pinch
/// that starts after the first finger has begun panning still zooms.
final class MapGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }
}

struct MapPanGesture: UIGestureRecognizerRepresentable {
    var move: (CGPoint, Bool) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> MapGestureDelegate { MapGestureDelegate() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator
        return gesture
    }
    func handleUIGestureRecognizerAction(_ gesture: UIPanGestureRecognizer, context: Context) {
        if gesture.state == .changed {
            move(context.converter.localTranslation ?? .zero, false)
            gesture.setTranslation(.zero, in: gesture.view)
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { move(.zero, true) }
    }
}

struct MapPinchGesture: UIGestureRecognizerRepresentable {
    var zoom: (CGFloat, CGPoint, Bool) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> MapGestureDelegate { MapGestureDelegate() }
    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let gesture = UIPinchGestureRecognizer()
        gesture.delegate = context.coordinator
        return gesture
    }
    func handleUIGestureRecognizerAction(_ gesture: UIPinchGestureRecognizer, context: Context) {
        if gesture.state == .changed {
            zoom(gesture.scale, context.converter.localLocation, false)
            gesture.scale = 1
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { zoom(1, context.converter.localLocation, true) }
    }
}
