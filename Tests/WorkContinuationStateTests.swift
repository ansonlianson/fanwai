import XCTest
@testable import Pianwai

final class WorkContinuationStateTests: XCTestCase {
    func testOnlySuccessfulEmptySourcesOfferAnotherStartingPoint() {
        let state = WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded)
        XCTAssertTrue(state.offersAnotherStartingPoint,
                      "A completed page without story or discovery destinations still needs an exit, even if it has an introduction")
    }

    func testARequestThatHasNotCompletedCannotProduceAnEmptyState() {
        for state in [
            WorkContinuationState(catalog: .pending, context: .succeeded, background: .succeeded),
            WorkContinuationState(catalog: .succeeded, context: .pending, background: .succeeded),
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .pending)
        ] {
            XCTAssertFalse(state.offersAnotherStartingPoint,
                           "Not-started, in-flight and cancelled requests are not evidence of empty content")
        }
    }

    func testFailedSourcesDoNotBecomeKnownEmpty() {
        for state in [
            WorkContinuationState(catalog: .failed, context: .succeeded, background: .succeeded),
            WorkContinuationState(catalog: .succeeded, context: .failed, background: .succeeded),
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .failed)
        ] {
            XCTAssertFalse(state.offersAnotherStartingPoint)
        }
    }

    func testEachExistingWayToContinueSuppressesTheEmptyExit() {
        let states = [
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded, hasRelations: true),
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded, hasEditorial: true),
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded, hasBackgroundExcerpt: true),
            WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded, hasOtherEntryPoint: true)
        ]
        for state in states { XCTAssertFalse(state.offersAnotherStartingPoint) }
    }

    func testBackgroundReadingDoesNotDependOnGraphRelationships() {
        let state = WorkContinuationState(catalog: .succeeded, context: .succeeded, background: .succeeded,
                                          hasRelations: false, hasEditorial: false, hasBackgroundExcerpt: true)
        XCTAssertFalse(state.offersAnotherStartingPoint,
                       "A source excerpt can lead to another work without creating a graph edge or editorial story")
    }
}
