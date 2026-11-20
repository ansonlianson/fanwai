import Foundation

struct ReadingCheckpoint: Codable, Equatable {
    var workID: WorkID
    var offset: Double
    var updatedAt: Date
    var backgroundExpanded: Bool? = nil
    /// Optional for existing checkpoints. This is a source excerpt identity,
    /// not generated text or a relationship inferred from that excerpt.
    var backgroundSecondExcerptID: String? = nil
}

struct GraphTrailEntry: Codable, Equatable {
    var id: WorkID
    var page: Int
    var filter: Int
}

struct GraphCheckpoint: Codable, Equatable {
    var center: WorkID
    var history: [GraphTrailEntry]
    var page: Int
    var filter: Int
    var presentation: Int
    var network: RelationNetworkState? = nil
}

struct LibraryNavigationSnapshot: Codable, Equatable {
    var tab: AppTab
    var focus: WorkID
    var reading: WorkID
    var path: [Route]
    var collectionPath: [Route]
}

/// An unresolved mutation guard, independent of the bounded receipt history.
/// Restoring it prevents a duplicate command; it never issues a command itself.
struct UnresolvedPlaybackOperation: Codable, Equatable {
    let command: MusicPlaybackCommand
    var targetWorkID: WorkID?
    let message: String
    var originTrack: WorkID?
    let originEntryID: String?
}

struct LibrarySnapshot: Codable, Equatable {
    var version = 1
    var saved: [WorkID] = []
    var listenLater: [WorkID] = []
    var watchLater: [WorkID] = []
    var recent: [WorkID] = []
    var checkpoints: [String: ReadingCheckpoint] = [:]
    var lastWork: WorkID?
    var startedBrowsing = false
    var country = "jp"
    var navigation: LibraryNavigationSnapshot? = nil
    var graphCheckpoints: [String: GraphCheckpoint]? = nil
    /// Optional for compatibility with snapshots written before watch completion.
    /// This is completion history, independent of the pending watch-later list.
    var watchedIDs: [WorkID]? = nil
    /// Historical command receipts only. Never restore these as a live queue.
    var playbackOperations: [PlaybackOperationRecord]? = nil
    var unresolvedPlaybackOperations: [UnresolvedPlaybackOperation]? = nil
    /// Upload identity and an optional starting point; never observed progress.
    var watchLaterEntries: [WatchLaterEntry]? = nil
    /// Optional for older snapshots. Unknown values decode to the works section
    /// without discarding saved items, either navigation stack, or pending media.
    var collectionSection: CollectionSection? = nil
    var listenedIDs: [WorkID]? = nil
    var collectionOrigins: [String: String]? = nil
}

enum PersistenceRecoveryError: Error, LocalizedError {
    case backupFailed, unreadable, saveFailed
    var errorDescription: String? {
        switch self {
        case .backupFailed: "原记录备份失败，已停止覆盖。本机原记录和已有备份均保留。"
        case .unreadable: "本机记录暂时读不到，原记录已备份。"
        case .saveFailed: "这次记录暂时没有保存到本机。"
        }
    }
}

@MainActor
struct LibraryPersistence {
    let defaults: UserDefaults
    let key: String
    private let catalog: CatalogStore?
    var backupKey: String { key + ".unreadable-backup" }

    init(defaults: UserDefaults = .standard, key: String = "pianwai.library.v1", catalog: CatalogStore? = nil) {
        self.defaults = defaults; self.key = key; self.catalog = catalog
    }

    func load() throws -> LibrarySnapshot {
        guard let original = defaults.object(forKey: key) else {
            // Legacy keys are preserved; only their known identities are normalized.
            return canonicalized(LibrarySnapshot(saved: (defaults.stringArray(forKey: "savedWorks") ?? []).compactMap(WorkID.init), listenLater: (defaults.stringArray(forKey: "listenLaterWorks") ?? []).compactMap(WorkID.init), watchLater: (defaults.stringArray(forKey: "laterWorks") ?? []).compactMap(WorkID.init)))
        }
        do { return canonicalized(try decode(original)) }
        catch {
            try preserveUnreadable(original)
            throw PersistenceRecoveryError.unreadable
        }
    }

    func save(_ state: LibrarySnapshot) throws {
        guard state.version == 1 else { throw CatalogError.invalidData }
        let data = try JSONEncoder().encode(canonicalized(state))
        if let original = defaults.object(forKey: key), (try? decode(original)) == nil {
            try preserveUnreadable(original)
        }
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw PersistenceRecoveryError.saveFailed }
    }

    private func decode(_ original: Any) throws -> LibrarySnapshot {
        guard let data = original as? Data else { throw CatalogError.invalidData }
        let state = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
        guard state.version == 1 else { throw CatalogError.invalidData }
        return state
    }

    private func preserveUnreadable(_ original: Any) throws {
        if defaults.object(forKey: backupKey) == nil { defaults.set(original, forKey: backupKey) }
        guard let backup = defaults.object(forKey: backupKey),
              let object = original as? NSObject, object.isEqual(backup),
              defaults.synchronize() else { throw PersistenceRecoveryError.backupFailed }
    }

    private func canonicalized(_ state: LibrarySnapshot) -> LibrarySnapshot {
        let catalog = catalog ?? CatalogStore.shared
        var result = state
        result.saved = catalog.canonicalIDs(state.saved)
        result.listenLater = catalog.canonicalIDs(state.listenLater)
        result.watchLater = catalog.canonicalIDs(state.watchLater)
        if let entries = state.watchLaterEntries {
            result.watchLaterEntries = WatchLaterEntry.normalized(entries, catalog: catalog)
            result.watchLater = catalog.canonicalIDs(result.watchLaterEntries!.map(\.workID))
        }
        result.watchedIDs = state.watchedIDs.map { catalog.canonicalIDs($0) }
        result.listenedIDs = state.listenedIDs.map { catalog.canonicalIDs($0) }
        result.playbackOperations = state.playbackOperations.map {
            PlaybackOperationRecord.retained($0).map { record in
                record.remappingTarget(to: record.targetWorkID.map { catalog.canonicalID(for: $0) })
            }
        }
        result.unresolvedPlaybackOperations = state.unresolvedPlaybackOperations.map { operations in
            operations.filter { $0.command != .requestAuthorization }.map { operation in
                var mapped = operation
                mapped.targetWorkID = operation.targetWorkID.map { catalog.canonicalID(for: $0) }
                mapped.originTrack = operation.originTrack.map { catalog.canonicalID(for: $0) }
                return mapped
            }
        }
        result.recent = catalog.canonicalIDs(state.recent)
        result.lastWork = state.lastWork.map { catalog.canonicalID(for: $0) }
        if var navigation = state.navigation {
            navigation.focus = catalog.canonicalID(for: navigation.focus)
            navigation.reading = catalog.canonicalID(for: navigation.reading)
            func remap(_ route: Route) -> Route {
                switch route {
                case .work(let id): .work(catalog.canonicalID(for: id))
                case .connections(let id): .connections(catalog.canonicalID(for: id))
                }
            }
            // A missing offline catalog record is not proof that saved navigation is invalid.
            navigation.path = navigation.path.suffix(40).map(remap)
            navigation.collectionPath = navigation.collectionPath.suffix(40).map(remap)
            result.navigation = navigation
        }
        result.checkpoints = [:]
        // Keep the complete newest checkpoint, including its optional expansion
        // and chosen excerpt, if two historical aliases converge.
        for key in state.checkpoints.keys.sorted() {
            guard var checkpoint = state.checkpoints[key] else { continue }
            checkpoint.workID = catalog.canonicalID(for: checkpoint.workID)
            let key = checkpoint.workID.rawValue
            if let existing = result.checkpoints[key], existing.updatedAt >= checkpoint.updatedAt { continue }
            result.checkpoints[key] = checkpoint
        }
        if let graphStates = state.graphCheckpoints {
            var normalized: [String: GraphCheckpoint] = [:]
            for (raw, original) in graphStates.sorted(by: { $0.key < $1.key }).prefix(40) {
                guard let root = WorkID(rawValue: raw) else { continue }
                var checkpoint = original
                checkpoint.center = catalog.canonicalID(for: checkpoint.center)
                checkpoint.page = min(999, max(0, checkpoint.page))
                checkpoint.filter = min(2, max(0, checkpoint.filter))
                checkpoint.presentation = min(1, max(0, checkpoint.presentation))
                checkpoint.history = original.history.suffix(40).map {
                    GraphTrailEntry(id: catalog.canonicalID(for: $0.id), page: min(999, max(0, $0.page)), filter: min(2, max(0, $0.filter)))
                }
                normalized[catalog.canonicalID(for: root).rawValue] = checkpoint
            }
            result.graphCheckpoints = normalized
        }
        return result
    }
}
