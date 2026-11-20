import Foundation
import Observation

enum NowState: String, CaseIterable {
    case ready, prep, sparse, `switch`, idle
    static func requested(in arguments: [String]) -> Self {
        guard let index = arguments.firstIndex(of: "-nowState"), arguments.indices.contains(index + 1) else { return .ready }
        return Self(rawValue: arguments[index + 1]) ?? .ready
    }
}

@Observable @MainActor
final class NowSession {
    private(set) var state: NowState
    private(set) var entityID: String
    private(set) var pendingID: String?
    private(set) var visibleRelations: Int
    private(set) var arrivedRelations: Int
    private(set) var stationLimit = 3
    private(set) var stations: [NowStation] = []
    var previewPlaying = true
    private(set) var liveEntity: SeedGraph.Entity?
    private(set) var pendingLiveEntity: SeedGraph.Entity?
    private var receivedLivePlayback = false
    var pendingEntity: SeedGraph.Entity? { pendingLiveEntity ?? pendingID.flatMap(SeedNowContent.entity) }
    static var usesPreviewPlayback: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-nowState")
        #else
        false
        #endif
    }
    private let defaults: UserDefaults
    private let freeze: Bool
    private var appeared = Set<String>()
    var entity: SeedGraph.Entity { liveEntity ?? SeedNowContent.entity(entityID)! }
    var visibleStations: [NowStation] { Array(stations.prefix(stationLimit)) }

    init(arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults? = nil) {
        let requested = arguments.contains("-nowState") ? NowState.requested(in: arguments) : .idle
        let preferences = defaults ?? Self.preferences(arguments)
        state = requested
        self.defaults = preferences
        freeze = arguments.contains("-freezeNowState")
        switch requested {
        case .idle:
            let saved = preferences.string(forKey: "redesign.lastEntity") ?? (arguments.contains("-nowState") ? "utada" : "pool")
            if let data = preferences.data(forKey: "redesign.lastLiveEntity"),
               let cached = try? JSONDecoder().decode(SeedGraph.Entity.self, from: data), cached.id == saved {
                liveEntity = cached; entityID = cached.id
            } else { entityID = SeedNowContent.entity(saved) != nil ? saved : "pool" }
            appeared = ["pool", "film", "jane"]
        case .sparse: entityID = "actor"
        default: entityID = "pool"
        }
        visibleRelations = requested == .prep ? 0 : .max
        arrivedRelations = requested == .prep ? 0 : .max
        pendingID = requested == .switch ? "jane" : nil
        previewPlaying = requested != .idle
        rebuildStations()
    }
    private static func preferences(_ arguments: [String]) -> UserDefaults {
        if let raw = arguments.first(where: { $0.hasPrefix("--ui-state=") }) {
            let name = String(raw.dropFirst(11))
            if !name.isEmpty, name.count <= 80, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
               let suite = UserDefaults(suiteName: "Pianwai.UIReview." + name) { return suite }
        }
        return .standard
    }
    func loadMore() { stationLimit = min(stations.count, stationLimit + 3) }
    func receiveTrack(_ id: String) {
        guard SeedNowContent.entity(id) != nil else { return }
        pendingLiveEntity = nil
        pendingID = id == entityID ? nil : id
    }
    /// Playback metadata is separate from the object the reader has open. The
    /// first observation initializes the page; subsequent tracks offer a switch.
    func receiveLiveTrack(_ track: SeedGraph.Entity?, preserveReading: Bool = false) {
        guard let track else { if !receivedLivePlayback { state = .idle }; return }
        if !receivedLivePlayback && !preserveReading {
            receivedLivePlayback = true
            liveEntity = track; entityID = track.id; state = .ready
            visibleRelations = .max; arrivedRelations = .max
            pendingID = nil; pendingLiveEntity = nil
            remember(track.id); rebuildStations()
        } else {
            receivedLivePlayback = true
            if track.id == entityID {
                liveEntity = track; pendingID = nil; pendingLiveEntity = nil
            } else { pendingID = track.id; pendingLiveEntity = track }
        }
    }
    /// Swiped away: keep reading; the next track change offers itself again.
    func dismissPending() { pendingID = nil; pendingLiveEntity = nil }
    /// The player was tapped: go to the song that is playing, even after its offer was swiped away.
    func showLive(_ track: SeedGraph.Entity) {
        guard track.id != entityID else { return }
        pendingID = track.id; pendingLiveEntity = track
        acceptPending()
    }
    func acceptPending() {
        guard let pendingID else { return }
        appeared.insert(entityID)
        entityID = pendingID
        liveEntity = pendingLiveEntity
        pendingLiveEntity = nil
        self.pendingID = nil
        state = .ready
        visibleRelations = .max
        arrivedRelations = .max
        stationLimit = 3
        remember(entityID)
        rebuildStations()
    }
    /// QQ 音乐 / 网易云 users bring a song in (paste or search): it becomes 此刻,
    /// the record on the counter, since those apps never report what is playing.
    func bring(_ track: SeedGraph.Entity) {
        if track.id != entityID { appeared.insert(entityID) }
        liveEntity = track; entityID = track.id
        pendingID = nil; pendingLiveEntity = nil
        state = .ready; visibleRelations = .max; arrivedRelations = .max; stationLimit = 3
        remember(track.id); rebuildStations()
    }
    /// True once a real song (played or brought in) is on the counter, not the bundled placeholder.
    var holdsRecord: Bool { liveEntity != nil }
    func remember(_ id: String) {
        guard SeedNowContent.entity(id) != nil || liveEntity?.id == id else { return }
        defaults.set(id, forKey: "redesign.lastEntity")
        if let liveEntity, liveEntity.id == id, let data = try? JSONEncoder().encode(liveEntity) {
            defaults.set(data, forKey: "redesign.lastLiveEntity")
        }
    }
    func prepare() async {
        guard state == .prep else { return }
        if freeze { visibleRelations = 1; arrivedRelations = 3; return }
        do {
            try await Task.sleep(for: .milliseconds(700))
            for count in 1...max(1, CrateInventory.items(for: entityID).count) {
                arrivedRelations = count
                try await Task.sleep(for: .milliseconds(560))
                visibleRelations = count
            }
            state = .ready
        } catch { /* Cancel preparation when playback's page is replaced. */ }
    }
    private func rebuildStations() {
        stations = SeedGraph.bundled[entityID] == nil ? [] : NextStationSequence.make(graph: .bundled, root: entityID, excluding: appeared)
    }
}
