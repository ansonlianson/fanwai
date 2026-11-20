import Foundation

/// A historical receipt for one user operation. It does not describe the
/// current system queue and must never be replayed to restore playback.
struct PlaybackOperationRecord: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case succeeded, failed, uncertain }

    let id: UUID
    let command: MusicPlaybackCommand
    private(set) var targetWorkID: WorkID?
    let catalogID: String?
    let verification: MusicPlaybackReceipt.Verification?
    let outcome: Outcome
    let issuedAt: Date?
    let completedAt: Date
    let observedAt: Date?
    let originEntryID: String?
    let failureCode: MusicPlaybackFailure.Code?
    let failureMessage: String?

    /// Receipt identity and time take precedence over caller fallback metadata.
    /// A contradictory receipt is rejected rather than turned into a success.
    init?(result: MusicPlaybackActionResult, command: MusicPlaybackCommand,
          targetWorkID: WorkID? = nil, catalogID: String? = nil,
          issuedAt: Date? = nil, completedAt: Date = Date(),
          originEntryID: String? = nil, id: UUID = UUID()) {
        let receipt: MusicPlaybackReceipt?
        let failure: MusicPlaybackFailure?
        switch result {
        case .success(let value):
            guard value.verification != .unconfirmed else { return nil }
            receipt = value; failure = nil; outcome = .succeeded
        case .failure(let value):
            receipt = nil; failure = value; outcome = .failed
        case .uncertain(let value, let error):
            receipt = value; failure = error; outcome = .uncertain
        }
        if let receipt {
            guard receipt.command == command else { return nil }
            if let requested = catalogID, let returned = receipt.catalogID, requested != returned { return nil }
        }
        self.id = id
        self.command = command
        self.targetWorkID = targetWorkID
        self.catalogID = receipt?.catalogID ?? catalogID
        verification = receipt?.verification
        self.issuedAt = issuedAt
        self.completedAt = receipt?.completedAt ?? completedAt
        observedAt = receipt?.observedAt
        self.originEntryID = originEntryID
        failureCode = failure?.code
        failureMessage = failure?.message
        guard isConsistent else { return nil }
    }

    static let historyLimit = 50
    static let historyLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Catalogue aliases may change the local target ID, never the historical
    /// command, result, occurrence, timestamps, or event UUID.
    func remappingTarget(to target: WorkID?) -> Self {
        var copy = self
        copy.targetWorkID = target
        return copy
    }

    /// Newest first, bounded by both age and count. Repeated event UUIDs are
    /// deduplicated; repeated commands remain distinct user operations.
    static func retained(_ records: [Self], now: Date = Date()) -> [Self] {
        var ids = Set<UUID>()
        return Array(records.filter { record in
            let age = now.timeIntervalSince(record.completedAt)
            return record.isConsistent && age.isFinite && age >= 0 && age <= historyLifetime
        }.sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.filter { ids.insert($0.id).inserted }.prefix(historyLimit))
    }

    private var isConsistent: Bool {
        guard completedAt.timeIntervalSinceReferenceDate.isFinite,
              issuedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              observedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else { return false }
        if verification == .observed {
            guard observedAt != nil else { return false }
        } else if observedAt != nil { return false }
        switch outcome {
        case .succeeded:
            return (verification == .observed || verification == .acceptedBySystem)
                && failureCode == nil && failureMessage == nil
        case .failed:
            return verification == nil && failureCode != nil && failureMessage != nil
        case .uncertain:
            return verification != nil && failureCode != nil && failureMessage != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, command, targetWorkID, catalogID, verification, outcome
        case issuedAt, completedAt, observedAt, originEntryID, failureCode, failureMessage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        command = try values.decode(MusicPlaybackCommand.self, forKey: .command)
        targetWorkID = try values.decodeIfPresent(WorkID.self, forKey: .targetWorkID)
        catalogID = try values.decodeIfPresent(String.self, forKey: .catalogID)
        verification = try values.decodeIfPresent(MusicPlaybackReceipt.Verification.self, forKey: .verification)
        outcome = try values.decode(Outcome.self, forKey: .outcome)
        issuedAt = try values.decodeIfPresent(Date.self, forKey: .issuedAt)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        observedAt = try values.decodeIfPresent(Date.self, forKey: .observedAt)
        originEntryID = try values.decodeIfPresent(String.self, forKey: .originEntryID)
        failureCode = try values.decodeIfPresent(MusicPlaybackFailure.Code.self, forKey: .failureCode)
        failureMessage = try values.decodeIfPresent(String.self, forKey: .failureMessage)
        guard isConsistent else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Contradictory playback operation receipt"))
        }
    }
}
