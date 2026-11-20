import Foundation
import Observation

struct SearchSessionKey: Equatable, Sendable {
    let query: String
    let kind: CatalogSearchKind
    let country: String
    let recordingContext: RecordingSearchContext?
    let platform: PlaybackPlatform

    init(query: String, kind: CatalogSearchKind, country: String,
         recordingContext: RecordingSearchContext? = nil, platform: PlaybackPlatform = .apple) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.country = country
        self.recordingContext = recordingContext
        self.platform = platform
    }
}

struct SearchListPosition: Equatable, Sendable {
    var offset: Double = 0
    var anchor: WorkID?
}

struct SearchSessionSnapshot: Equatable, Sendable {
    var results: [WorkID] = []
    var submitted = false
    var error: String?
    var position = SearchListPosition()
}

struct SearchSessionRequest: Equatable, Sendable {
    let id: UUID
    let key: SearchSessionKey
}

/// A bounded, in-memory reading session, not a persisted search history.
/// Each request can only publish into the exact context that submitted it.
@MainActor @Observable
final class SearchSessionState {
    private(set) var activeKey: SearchSessionKey?
    private(set) var snapshot = SearchSessionSnapshot()
    private(set) var searching = false
    @ObservationIgnored private var request: SearchSessionRequest?
    @ObservationIgnored private var retained: [(key: SearchSessionKey, snapshot: SearchSessionSnapshot)] = []

    func activate(_ key: SearchSessionKey) {
        // A text-change callback can arrive after IME Return submission. The
        // same normalized key must not invalidate that already-started request.
        guard activeKey != key else { return }
        cancelRequest()
        retainCurrent()
        activeKey = key
        if key.query.isEmpty {
            snapshot = SearchSessionSnapshot()
        } else if let index = retained.firstIndex(where: { $0.key == key }) {
            snapshot = retained.remove(at: index).snapshot
        } else {
            snapshot = SearchSessionSnapshot()
        }
    }

    @discardableResult
    func begin(_ key: SearchSessionKey) -> SearchSessionRequest? {
        activate(key)
        cancelRequest()
        guard !key.query.isEmpty else {
            snapshot = SearchSessionSnapshot()
            return nil
        }
        snapshot = SearchSessionSnapshot(submitted: true)
        let token = SearchSessionRequest(id: UUID(), key: key)
        request = token
        searching = true
        return token
    }

    @discardableResult
    func complete(_ token: SearchSessionRequest, results: [WorkID]) -> Bool {
        guard request == token, activeKey == token.key else { return false }
        snapshot.results = results
        snapshot.submitted = true
        snapshot.error = nil
        request = nil
        searching = false
        return true
    }

    @discardableResult
    func fail(_ token: SearchSessionRequest, message: String) -> Bool {
        guard request == token, activeKey == token.key else { return false }
        snapshot.error = message
        snapshot.submitted = true
        request = nil
        searching = false
        return true
    }

    func rememberPosition(_ position: SearchListPosition, for key: SearchSessionKey) {
        guard activeKey == key, !key.query.isEmpty, position.offset.isFinite else { return }
        snapshot.position = SearchListPosition(offset: max(0, position.offset), anchor: position.anchor)
    }

    func cancelRequest() {
        if request != nil {
            // Interrupted work is not an empty successful search. Reopening
            // lets the user submit it again instead of showing "no results".
            snapshot.submitted = false
            snapshot.error = nil
        }
        request = nil
        searching = false
    }

    private func retainCurrent() {
        guard let key = activeKey, !key.query.isEmpty,
              snapshot.submitted || !snapshot.results.isEmpty || snapshot.position.anchor != nil else { return }
        retained.removeAll { $0.key == key }
        retained.append((key, snapshot))
        if retained.count > 12 { retained.removeFirst(retained.count - 12) }
    }
}
