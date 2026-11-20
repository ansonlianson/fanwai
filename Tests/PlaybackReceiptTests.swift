import XCTest
@testable import Pianwai

final class PlaybackReceiptTests: XCTestCase {
    private let completed = Date(timeIntervalSince1970: 1_800_000_000)
    private let observed = Date(timeIntervalSince1970: 1_799_999_999)
    private let issued = Date(timeIntervalSince1970: 1_799_999_990)

    func testExistingReceiptInitializerCapturesCompletionAndOnlyObservedResultsGetObservationTime() {
        let before = Date()
        let receipt = MusicPlaybackReceipt(command: .resume, catalogID: nil, verification: .observed)
        let after = Date()
        XCTAssertGreaterThanOrEqual(receipt.completedAt, before)
        XCTAssertLessThanOrEqual(receipt.completedAt, after)
        XCTAssertEqual(receipt.observedAt, receipt.completedAt)

        for verification: MusicPlaybackReceipt.Verification in [.acceptedBySystem, .unconfirmed] {
            let value = MusicPlaybackReceipt(command: .insertNext, catalogID: "1840081736", verification: verification,
                                             completedAt: completed, observedAt: observed)
            XCTAssertEqual(value.completedAt, completed)
            XCTAssertNil(value.observedAt, "An accepted or unconfirmed command cannot claim an observation")
        }
    }

    func testObservedRecordPreservesExactReceiptTimesAndOperationContext() throws {
        let receipt = MusicPlaybackReceipt(command: .playNow, catalogID: "1840081736", verification: .observed,
                                            completedAt: completed, observedAt: observed)
        let uuid = UUID()
        let record = try XCTUnwrap(PlaybackOperationRecord(result: .success(receipt), command: .playNow,
            targetWorkID: .jane, catalogID: "1840081736", issuedAt: issued, completedAt: completed.addingTimeInterval(10),
            originEntryID: "queue-occurrence-A", id: uuid))
        XCTAssertEqual(record.id, uuid)
        XCTAssertEqual(record.command, .playNow)
        XCTAssertEqual(record.targetWorkID, .jane)
        XCTAssertEqual(record.catalogID, "1840081736")
        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(record.verification, .observed)
        XCTAssertEqual(record.issuedAt, issued)
        XCTAssertEqual(record.completedAt, completed, "The later history-write time must not replace the receipt time")
        XCTAssertEqual(record.observedAt, observed)
        XCTAssertEqual(record.originEntryID, "queue-occurrence-A")
        XCTAssertNil(record.failureCode)
        XCTAssertNil(record.failureMessage)
    }

    func testSuccessfulAcceptanceRemainsAcceptanceWithoutClaimingTheQueueWasObserved() throws {
        let receipt = acceptedReceipt()
        let record = try XCTUnwrap(PlaybackOperationRecord(result: .success(receipt), command: .insertNext, targetWorkID: .jane))
        XCTAssertEqual(record.outcome, .succeeded)
        XCTAssertEqual(record.verification, .acceptedBySystem)
        XCTAssertNil(record.observedAt)
        XCTAssertEqual(record.completedAt, completed)
    }

    func testFailuresAndUncertaintyNeverBecomeSuccessfulHistory() throws {
        let failure = MusicPlaybackFailure(.timedOut, "请先查看 Apple Music", diagnostic: "DO-NOT-PERSIST-THIS")
        let rejected = try XCTUnwrap(PlaybackOperationRecord(result: .failure(failure), command: .insertNext,
            targetWorkID: .jane, catalogID: "1840081736", issuedAt: issued, completedAt: completed, originEntryID: "origin-A"))
        XCTAssertEqual(rejected.outcome, .failed)
        XCTAssertNil(rejected.verification)
        XCTAssertNil(rejected.observedAt)
        XCTAssertEqual(rejected.completedAt, completed)
        XCTAssertEqual(rejected.failureCode, .timedOut)
        XCTAssertEqual(rejected.failureMessage, failure.message)
        XCTAssertEqual(rejected.catalogID, "1840081736")

        for verification: MusicPlaybackReceipt.Verification in [.unconfirmed, .acceptedBySystem] {
            let receipt = MusicPlaybackReceipt(command: .insertNext, catalogID: "1840081736", verification: verification, completedAt: completed)
            let uncertain = try XCTUnwrap(PlaybackOperationRecord(result: .uncertain(receipt, failure), command: .insertNext))
            XCTAssertEqual(uncertain.outcome, .uncertain)
            XCTAssertEqual(uncertain.verification, verification)
            XCTAssertNil(uncertain.observedAt)
            XCTAssertEqual(uncertain.failureCode, .timedOut)
        }
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(rejected), encoding: .utf8))
        XCTAssertFalse(json.contains("DO-NOT-PERSIST-THIS"))
        XCTAssertFalse(json.contains("diagnostic"))
    }

    func testContradictoryReceiptIdentityOrUnconfirmedSuccessCannotCreateARecord() {
        XCTAssertNil(PlaybackOperationRecord(result: .success(acceptedReceipt()), command: .playNow))
        XCTAssertNil(PlaybackOperationRecord(result: .success(acceptedReceipt()), command: .insertNext, catalogID: "1837522108"))
        let receipt = MusicPlaybackReceipt(command: .insertNext, catalogID: "1840081736", verification: .unconfirmed, completedAt: completed)
        XCTAssertNil(PlaybackOperationRecord(result: .success(receipt), command: .insertNext))
    }

    func testAllOutcomeVariantsRoundTripWithEvidenceAndOptionalUnknownTimesIntact() throws {
        let failure = MusicPlaybackFailure(.notConfirmed, "未确认")
        let variants: [MusicPlaybackActionResult] = [
            .success(acceptedReceipt()),
            .success(.init(command: .insertNext, catalogID: "1840081736", verification: .observed,
                            completedAt: completed, observedAt: observed)),
            .failure(failure),
            .uncertain(.init(command: .insertNext, catalogID: "1840081736", verification: .unconfirmed, completedAt: completed), failure),
            .uncertain(acceptedReceipt(), failure)
        ]
        for result in variants {
            let original = try XCTUnwrap(PlaybackOperationRecord(result: result, command: .insertNext,
                targetWorkID: .jane, completedAt: completed, originEntryID: "origin-A"))
            let restored = try JSONDecoder().decode(PlaybackOperationRecord.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(restored, original)
            XCTAssertNil(restored.issuedAt, "Unknown issue time is not invented on restore")
        }
    }

    func testDecodedContradictoryStatusCannotMasqueradeAsSuccess() throws {
        let record = try XCTUnwrap(PlaybackOperationRecord(result: .success(acceptedReceipt()), command: .insertNext))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let changes: [[String: Any]] = [
            ["verification": "unconfirmed"],
            ["verification": "observed"], // Missing observation evidence.
            ["outcome": "failed"],
            ["outcome": "uncertain"], // Missing associated failure.
            ["observedAt": completed.timeIntervalSinceReferenceDate],
            ["failureCode": "timedOut", "failureMessage": "Uncertain"]
        ]
        for change in changes {
            let corrupted = original.merging(change) { _, new in new }
            XCTAssertThrowsError(try JSONDecoder().decode(PlaybackOperationRecord.self, from: JSONSerialization.data(withJSONObject: corrupted)))
        }
    }

    func testHistoryRetentionBoundsAgeCountAndDuplicateUUIDWithoutCollapsingCommands() throws {
        var records: [PlaybackOperationRecord] = try (0..<60).map { offset in
            let receipt = MusicPlaybackReceipt(command: .insertNext, catalogID: "1840081736", verification: .acceptedBySystem,
                                               completedAt: completed.addingTimeInterval(-Double(offset)))
            return try XCTUnwrap(PlaybackOperationRecord(result: .success(receipt), command: .insertNext, targetWorkID: .jane))
        }
        records += [records[0], records[1]]
        records.append(try record(at: completed.addingTimeInterval(-PlaybackOperationRecord.historyLifetime - 1)))
        records.append(try record(at: completed.addingTimeInterval(1)))
        let retained = PlaybackOperationRecord.retained(Array(records.reversed()), now: completed)
        XCTAssertEqual(retained.count, 50)
        XCTAssertEqual(Set(retained.map(\.id)).count, 50)
        XCTAssertEqual(retained.first?.completedAt, completed)
        XCTAssertEqual(retained.last?.completedAt, completed.addingTimeInterval(-49))
        XCTAssertTrue(retained.allSatisfy { $0.command == .insertNext && $0.targetWorkID == .jane })

        let boundary = try record(at: completed.addingTimeInterval(-PlaybackOperationRecord.historyLifetime))
        XCTAssertEqual(PlaybackOperationRecord.retained([boundary], now: completed), [boundary])
    }

    func testCanonicalTargetRemappingPreservesTheHistoricalReceipt() throws {
        let original = try XCTUnwrap(PlaybackOperationRecord(result: .success(acceptedReceipt()), command: .insertNext,
            targetWorkID: .jane, issuedAt: issued, originEntryID: "origin-A"))
        let target = try XCTUnwrap(WorkID(rawValue: "apple:song:1840081736"))
        let remapped = original.remappingTarget(to: target)
        XCTAssertEqual(remapped.targetWorkID, target)
        XCTAssertEqual(remapped.remappingTarget(to: .jane), original, "Only the target alias may change")
        XCTAssertEqual(original.targetWorkID, .jane)
        XCTAssertNil(original.remappingTarget(to: nil).targetWorkID)
        XCTAssertEqual(original.remappingTarget(to: nil).id, original.id)
    }

    func testDistinctReceiptTimesRemainDistinctEvenForTheSameCommand() {
        let first = acceptedReceipt()
        let second = MusicPlaybackReceipt(command: first.command, catalogID: first.catalogID, verification: first.verification,
                                          completedAt: completed.addingTimeInterval(1))
        XCTAssertNotEqual(first, second)
    }

    private func acceptedReceipt() -> MusicPlaybackReceipt {
        .init(command: .insertNext, catalogID: "1840081736", verification: .acceptedBySystem, completedAt: completed)
    }

    private func record(at date: Date) throws -> PlaybackOperationRecord {
        let receipt = MusicPlaybackReceipt(command: .insertNext, catalogID: "1840081736", verification: .acceptedBySystem, completedAt: date)
        return try XCTUnwrap(PlaybackOperationRecord(result: .success(receipt), command: .insertNext, targetWorkID: .jane))
    }
}
