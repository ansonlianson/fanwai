import XCTest
import Observation
import UIKit
@testable import Pianwai

@MainActor final class PullOutReaderTests: XCTestCase {
    func testMotionDoesNotInvalidateUnchangedReadingObservers() {
        let reader = PullOutReader()
        let stillResting = expectation(description: "A small discovery hint does not rebuild reading observers")
        stillResting.isInverted = true
        withObservationTracking { _ = reader.isReading } onChange: { stillResting.fulfill() }
        for x in [2, 4, 8, 12, 0] { reader.move(to: CGFloat(x)) }
        wait(for: [stillResting], timeout: 0.01)
        reader.phase = .tracking
        let stillReading = expectation(description: "Following the finger does not invalidate the root's reading flag")
        stillReading.isInverted = true
        withObservationTracking { _ = reader.isReading } onChange: { stillReading.fulfill() }
        for x in 0...165 { reader.move(to: CGFloat(x)) }
        wait(for: [stillReading], timeout: 0.01)
        XCTAssertTrue(reader.isReading)
    }
    func testDeliberateDragAndTopPullThresholds() {
        XCTAssertFalse(PullOutReader.shouldExpand(offset: 30, velocity: 0, travel: 165))
        XCTAssertTrue(PullOutReader.shouldExpand(offset: 65, velocity: 0, travel: 165))
        XCTAssertTrue(PullOutReader.shouldExpand(offset: 40, velocity: 600, travel: 165))
        XCTAssertFalse(PullOutReader.shouldCollapse(pull: 40, downwardVelocity: 0))
        XCTAssertTrue(PullOutReader.shouldCollapse(pull: 65, downwardVelocity: 0))
        XCTAssertTrue(PullOutReader.shouldCollapse(pull: 20, downwardVelocity: 900))
        XCTAssertTrue(PullOutReader.shouldCollapse(pull: 120, downwardVelocity: 0))
        XCTAssertFalse(PullOutReader.shouldCollapse(pull: 5, downwardVelocity: 1500))
        XCTAssertFalse(PullOutReader.shouldCollapse(pull: 0, downwardVelocity: 1500), "An inertial arrival at the top is not a dismiss gesture")
        XCTAssertEqual(PullOutReader.follows(-200, travel: 165, length: 874), 0)
        for (p, hero, cabinet) in [(-0.6, 0.0, 0.0), (1.4, -90.75, 350.0)] {
            XCTAssertEqual(PullOutSceneMotion.displacement(progress: p, layer: .hero, travel: 165, cabinetExit: 350), hero, accuracy: 0.001)
            XCTAssertEqual(PullOutSceneMotion.displacement(progress: p, layer: .cabinet, travel: 165, cabinetExit: 350), cabinet, accuracy: 0.001)
        }
    }
    func testReadingPositionSurvivesVisitingAnotherWork() throws {
        let suite = "PullOut-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PullOutReaders(defaults: defaults)
        let first = store.reader(for: "first"); first.phase = .expanded; first.offset = 165; first.scrollOffset = 80
        store.active = first
        let second = store.reader(for: "second"); store.active = second
        store.leave(first)
        XCTAssertTrue(store.active === second)
        let restored = store.reader(for: "first")
        XCTAssertTrue(restored === first); XCTAssertEqual(restored.phase, .expanded); XCTAssertEqual(restored.scrollOffset, 80)
        XCTAssertEqual(second.phase, .rest)
    }
    func testDownwardInterruptionOfReopeningUsesCloseArbitration() {
        let reader = PullOutReader(); reader.canExpand = true
        reader.phase = .tracking; reader.offset = reader.travel
        reader.presentedOffset = reader.travel - 25; reader.cabinet = 1
        let host = ReaderVerticalPan(reader: reader, began: { _, _ in }, changed: { _, _ in }, ended: { _, _, _ in })
        let delegate = ReaderVerticalPan.Coordinator(host), pan = ReaderTestPan()
        pan.delta = CGPoint(x: 0, y: 15)
        XCTAssertTrue(delegate.gestureRecognizerShouldBegin(pan))
        XCTAssertTrue(delegate.mode == .closing, "Interrupting an opening spring downwards must use the short close threshold and leave the cabinet independent")
        pan.delta = CGPoint(x: 0, y: -15)
        XCTAssertTrue(delegate.gestureRecognizerShouldBegin(pan))
        XCTAssertTrue(delegate.mode == .opening)
        reader.phase = .rest; reader.offset = 0
        pan.delta = CGPoint(x: 0, y: 15)
        XCTAssertFalse(delegate.gestureRecognizerShouldBegin(pan), "After closing, the same downwards movement must be rejected")
    }
}

@MainActor private final class ReaderTestPan: UIPanGestureRecognizer {
    var delta = CGPoint.zero
    override func translation(in view: UIView?) -> CGPoint { delta }
}
