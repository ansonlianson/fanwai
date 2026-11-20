import UIKit

/// A short save must finish even when no research job holds background time.
@MainActor final class ShopPersistenceBackgroundLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save library") { [weak self] in
            self?.finish()
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
