import SwiftUI
import UIKit

/// A return to the same page is a new appearance, even when a relationship map
/// had no story request to settle. The value is a cache, not view state.
@MainActor final class ShopPageAppearanceGeneration {
    private var context: String?
    private var generation = 0
    func value(for next: String) -> Int {
        if context != next { context = next; generation += 1 }
        return generation
    }
}

/// A native push announces its destination after its transition completes.
/// Updating the current page uses the next display transaction, without a
/// guessed timer or a second research trigger on the Discovery side.
struct PageTransitionCompletion: UIViewControllerRepresentable {
    let token: String
    let onSettled: (String) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.token = token; controller.onSettled = onSettled
        controller.schedule()
    }
    final class Controller: UIViewController {
        var token = ""
        var onSettled: ((String) -> Void)?
        private var delivered = ""
        private var pending = false
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            delivered = ""
            schedule()
        }
        func schedule() {
            guard !pending, token != delivered, viewIfLoaded?.window != nil else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard self.viewIfLoaded?.window != nil else { return }
                var owner: UIViewController? = self
                while let parent = owner?.parent { owner = parent }
                if let transition = self.transitionCoordinator ?? owner?.transitionCoordinator {
                    let registered = transition.animate(alongsideTransition: nil) { [weak self] context in
                        if !context.isCancelled { self?.deliver() }
                    }
                    if !registered { self.deliver() }
                } else { self.deliver() }
            }
        }
        private func deliver() {
            guard viewIfLoaded?.window != nil, token != delivered else { return }
            delivered = token; onSettled?(token)
        }
    }
}

@MainActor final class ShopPageActionsCache {
    struct Actions {
        let onStoryName: (StoryTextLinks.Target) -> Void
        let onReadingName: (StoryTextLinks.Target, Source) -> Void
        let onGraph: (String) -> Void
        let onOpen: (CrateItem, String) -> Void
        let onPlayback: () -> Void
        let onNext: (SeedGraph.Entity) -> Void
        let onSave: (SeedGraph.Entity) -> Void
        let onWorks: () -> Void
        let onObjectFrame: (String, CGRect) -> Void
        let onRetry: () -> Void
        let onCreator: () -> Void
    }
    private var values: [String: Actions] = [:]
    func value(for key: String, make: () -> Actions) -> Actions {
        if let value = values[key] { return value }
        if values.count >= 64 { values.removeAll() }
        let value = make(); values[key] = value; return value
    }
}
