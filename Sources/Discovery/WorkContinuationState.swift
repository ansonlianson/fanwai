import Foundation

/// A successful empty lookup is different from an unstarted, cancelled or
/// failed lookup. Introductory prose and provider links describe the current
/// work; they do not by themselves provide a new place to explore.
struct WorkContinuationState: Equatable, Sendable {
    enum LoadState: Equatable, Sendable {
        case pending, succeeded, failed
    }

    let catalog: LoadState
    let context: LoadState
    let background: LoadState
    var hasRelations = false
    var hasEditorial = false
    var hasBackgroundExcerpt = false
    var hasOtherEntryPoint = false

    var offersAnotherStartingPoint: Bool {
        catalog == .succeeded && context == .succeeded && background == .succeeded
            && !hasRelations && !hasEditorial && !hasBackgroundExcerpt && !hasOtherEntryPoint
    }
}
