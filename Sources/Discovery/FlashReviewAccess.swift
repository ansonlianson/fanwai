import Foundation

/// Read compatibility for pre-ARCH2 review artifacts; never selects a provider.
enum FlashReviewAccess {
    static let isEnabled = false
    static let cacheNamespace = "flash-evidence-v3"
    static func usesBundledContent(_ id: String) -> Bool { SeedNowContent.contains(id) }
}
