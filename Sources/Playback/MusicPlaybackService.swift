import Foundation
import Observation
import Combine
// MusicPlayer/Queue in the installed SDK predate Swift concurrency annotations.
// Keep every app-side access on MainActor and serialize mutations; this import
// bridges Apple's legacy async API without declaring its reference types Sendable.
@preconcurrency import MusicKit
import MediaPlayer
import UIKit

enum MusicAuthorizationState: String, Sendable, Equatable {
    case notDetermined, denied, restricted, authorized, unknown
}

enum MusicPlaybackAvailability: String, Sendable, Equatable {
    case simulatorUnsupported, authorizationRequired, authorizationDenied, authorizationRestricted, ready
}

enum MusicPlaybackStatus: String, Sendable, Equatable {
    case stopped, playing, paused, interrupted, seekingForward, seekingBackward, unknown
}

struct MusicSubscriptionInfo: Sendable, Equatable {
    let canPlayCatalogContent: Bool
    let canBecomeSubscriber: Bool
    let hasCloudLibraryEnabled: Bool
}

enum MusicSubscriptionState: Sendable, Equatable {
    case unknown, checking
    case available(MusicSubscriptionInfo)
    case failed(MusicPlaybackFailure)
}

/// Values copied from public system APIs, never a match inferred from a title.
/// A local file or radio stream may legitimately have no catalog ID or artwork URL.
struct MusicNowPlayingMetadata: Sendable, Equatable, Identifiable {
    enum Source: String, Sendable { case musicKit, mediaPlayer }
    enum Kind: String, Sendable { case song, musicVideo, unknown }
    let id: String
    let catalogID: String?
    let title: String
    let artist: String
    let albumTitle: String?
    let artworkURL: URL?
    let duration: TimeInterval?
    let source: Source
    var kind: Kind = .song
    var releaseDate: String? = nil
    var editorialNotes: [StoryMaterial]? = nil
    var artworkAsset: String? = nil
}

struct MusicPlaybackSnapshot: Sendable, Equatable {
    let availability: MusicPlaybackAvailability
    let authorization: MusicAuthorizationState
    let subscription: MusicSubscriptionState
    let nowPlaying: MusicNowPlayingMetadata?
    let status: MusicPlaybackStatus
    let elapsedTime: TimeInterval
    let capturedAt: Date
    /// A MusicKit queue occurrence, not a catalog ID or MediaPlayer persistent ID.
    /// Missing entry means metadata can be displayed but Play Next cannot be offered.
    var currentEntryID: String? = nil
    /// Present only on the last queued track of a collected album/record.
    var collectionEnd: MusicQueueSelection? = nil

    /// Subscription is deliberately not required to control an existing/local track.
    var canControlPlayback: Bool { availability == .ready && nowPlaying != nil }
    var canPlayCatalog: Bool {
        guard availability == .ready, case let .available(info) = subscription else { return false }
        return info.canPlayCatalogContent
    }
    var canQueueNext: Bool { canPlayCatalog && currentEntryID != nil }
}

enum MusicPlaybackCommand: String, Codable, Sendable, Equatable {
    case requestAuthorization, pause, resume, skipToNext, insertNext, playNow
}

struct MusicPlaybackFailure: Error, LocalizedError, Sendable, Equatable {
    enum Code: String, Codable, Sendable {
        case simulatorUnsupported, authorizationRequired, authorizationDenied, authorizationRestricted
        case configuration, busy, cancelled, nothingPlaying, invalidCatalogID, subscriptionUnavailable
        case catalogUnavailable, notPlayable, systemError, notConfirmed, queueChanged, timedOut
    }
    let code: Code
    let message: String
    /// Diagnostic information for logs; show `message` in the product UI.
    let diagnostic: String?
    var errorDescription: String? { message }

    init(_ code: Code, _ message: String, diagnostic: String? = nil) {
        self.code = code
        self.message = message
        self.diagnostic = diagnostic
    }
}

struct MusicPlaybackReceipt: Sendable, Equatable {
    enum Verification: String, Codable, Sendable {
        /// The requested state/track was read back from the public player API.
        case observed
        /// The async system mutation returned successfully. Full system queue is not exposed.
        case acceptedBySystem
        /// A mutation was attempted, but its outcome could not be confirmed.
        case unconfirmed
    }
    let command: MusicPlaybackCommand
    let catalogID: String?
    let verification: Verification
    /// Local time when this result was produced, not a server-side queue timestamp.
    let completedAt: Date
    /// Time of the read-back that supports `.observed`; acceptance alone has none.
    let observedAt: Date?

    init(command: MusicPlaybackCommand, catalogID: String?, verification: Verification,
         completedAt: Date = Date(), observedAt: Date? = nil) {
        self.command = command
        self.catalogID = catalogID
        self.verification = verification
        self.completedAt = completedAt
        self.observedAt = verification == .observed ? observedAt ?? completedAt : nil
    }
}

enum MusicPlaybackActionResult: Sendable, Equatable {
    case success(MusicPlaybackReceipt)
    case failure(MusicPlaybackFailure)
    /// Do not automatically retry: the system queue/playback may already have changed.
    case uncertain(MusicPlaybackReceipt, MusicPlaybackFailure)
}

/// A narrow injectable boundary for app orchestration. Test clients cannot turn
/// the production simulator adapter into a fake successful system player.
@MainActor
protocol MusicPlaybackClient: AnyObject {
    var snapshot: MusicPlaybackSnapshot { get }
    var commandInFlight: MusicPlaybackCommand? { get }
    var isObserving: Bool { get }
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)? { get set }
    func startObserving()
    func stopObserving()
    func refresh() async
    func requestAuthorization() async -> MusicPlaybackActionResult
    func pause() async -> MusicPlaybackActionResult
    func resume() async -> MusicPlaybackActionResult
    func skipToNext() async -> MusicPlaybackActionResult
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult
    func playNow(catalogID: String) async -> MusicPlaybackActionResult
    func playStoreSelection(_ selection: MusicQueueSelection) async -> MusicPlaybackActionResult
    func playCollection(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult
    func insertCollectionNext(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult
}

struct MusicQueueSelection: Equatable, Sendable {
    enum Kind: Sendable { case song, album }
    let catalogID: String
    let kind: Kind
}

extension MusicPlaybackClient {
    func playStoreSelection(_ selection: MusicQueueSelection) async -> MusicPlaybackActionResult {
        if selection.kind == .song { return await playNow(catalogID: selection.catalogID) }
        return await playCollection([selection])
    }
    func playCollection(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        .failure(.init(.configuration, "暂时无法播放整箱唱片"))
    }
    func insertCollectionNext(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        .failure(.init(.configuration, "暂时无法安排这张唱片"))
    }
}

/// The small playback observer receives every clock tick. Catalog/page consumers
/// need identity/state changes, completion boundaries and genuine seeks only.
enum MusicPlaybackPublication {
    static func needsContentDelivery(from prior: MusicPlaybackSnapshot, to value: MusicPlaybackSnapshot) -> Bool {
        let contentChanged = prior.availability != value.availability
            || prior.authorization != value.authorization || prior.subscription != value.subscription
            || prior.nowPlaying != value.nowPlaying || prior.status != value.status
            || prior.currentEntryID != value.currentEntryID || prior.collectionEnd != value.collectionEnd
        let duration = value.nowPlaying?.duration ?? .infinity
        let nearEnd = value.elapsedTime >= duration - 1.5 || prior.elapsedTime >= duration - 1.5
        let expectedAdvance = prior.status == .playing ? value.capturedAt.timeIntervalSince(prior.capturedAt) : 0
        let seeked = abs(value.elapsedTime - prior.elapsedTime - expectedAdvance) > 1.5
        return contentChanged || nearEnd || seeked
    }
}

enum MusicPlaybackCompletion {
    static func finished(_ before: MusicPlaybackSnapshot, _ after: MusicPlaybackSnapshot) -> Bool {
        guard before.status == .playing, let duration = before.nowPlaying?.duration,
              duration.isFinite, duration > 0, before.elapsedTime >= max(0, duration-1.5),
              before.currentEntryID != nil else { return false }
        if MusicPlaybackConfirmation.didAdvance(from: before, to: after) { return true }
        return after.availability == .ready && after.status == .stopped
            && before.currentEntryID == after.currentEntryID && after.elapsedTime >= duration-0.25
    }
}

/// Read-back policy shared by the real adapter and deterministic contract tests.
/// A matching catalog ID alone cannot prove that a new occurrence started.
enum MusicPlaybackConfirmation {
    static func isPlaying(entryID: String, in snapshot: MusicPlaybackSnapshot) -> Bool {
        snapshot.availability == .ready && snapshot.status == .playing && snapshot.currentEntryID == entryID
    }

    static func didAdvance(from before: MusicPlaybackSnapshot, to after: MusicPlaybackSnapshot) -> Bool {
        guard after.availability == .ready else { return false }
        if let beforeID = before.currentEntryID, let afterID = after.currentEntryID {
            return beforeID != afterID
        }
        // Reaching an observed empty stopped queue is a terminal advance. A
        // temporarily missing entry while metadata remains is not confirmation.
        if before.nowPlaying != nil, after.currentEntryID == nil,
           after.nowPlaying == nil, after.status == .stopped { return true }
        guard let old = before.nowPlaying, let new = after.nowPlaying,
              old.source == new.source, old.kind == new.kind else { return false }
        if let oldID = old.catalogID, let newID = new.catalogID { return oldID != newID }
        return old.source == .mediaPlayer && !old.id.isEmpty && !new.id.isEmpty && old.id != new.id
    }
}

/// Bounds the caller's wait without assuming that cancellation stops a MusicKit
/// request. An expired read cannot later write, and an expired write keeps the
/// mutation gate until its SDK call actually returns. No result is retried.
@MainActor
final class MusicPlaybackCommandExecutor {
    typealias Deadline = @MainActor @Sendable () async throws -> Void

    @MainActor
    final class Context {
        let command: MusicPlaybackCommand
        let catalogID: String?
        private(set) var mutationAttempted = false
        private(set) var verification: MusicPlaybackReceipt.Verification = .unconfirmed
        fileprivate var isActive = true
        fileprivate var continuation: CheckedContinuation<MusicPlaybackActionResult, Never>?
        fileprivate var worker: Task<Void, Never>?
        fileprivate var deadline: Task<Void, Never>?

        fileprivate init(command: MusicPlaybackCommand, catalogID: String?) {
            self.command = command
            self.catalogID = catalogID
        }

        /// Call after an await and immediately before every additional side effect.
        func checkCancellation() throws {
            guard isActive, !Task.isCancelled else { throw CancellationError() }
        }

        func beginMutation() throws {
            try checkCancellation()
            mutationAttempted = true
        }

        func mutationAccepted() { verification = .acceptedBySystem }

        fileprivate func result(for failure: MusicPlaybackFailure) -> MusicPlaybackActionResult {
            guard mutationAttempted else { return .failure(failure) }
            return .uncertain(.init(command: command, catalogID: catalogID, verification: verification), failure)
        }
    }

    private let waitForDeadline: Deadline
    private var active: Context?
    var hasUnsettledOperation: Bool { active != nil }

    init(waitForDeadline: @escaping Deadline = { try await Task.sleep(for: .seconds(15)) }) {
        self.waitForDeadline = waitForDeadline
    }

    func run(_ command: MusicPlaybackCommand, catalogID: String? = nil,
             operation: @escaping @MainActor (Context) async throws -> MusicPlaybackActionResult) async -> MusicPlaybackActionResult {
        guard active == nil else {
            return .failure(.init(.busy, "上一项播放操作尚未结束，请先查看 Apple Music"))
        }
        guard !Task.isCancelled else { return .failure(Self.cancelled) }
        let context = Context(command: command, catalogID: catalogID)
        active = context
        // A structured task-group race would wait for a cancelled SDK child that
        // ignores cancellation. These tasks instead settle one caller continuation.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.continuation = continuation
                context.worker = Task { @MainActor [self, context] in
                    let result: MusicPlaybackActionResult
                    do {
                        try context.checkCancellation()
                        result = try await operation(context)
                    } catch {
                        let failure = error is CancellationError ? Self.cancelled :
                            MusicPlaybackFailure(.systemError, "未能完成播放操作，请查看 Apple Music", diagnostic: String(describing: error))
                        result = context.result(for: failure)
                    }
                    complete(context, result: result)
                }
                context.deadline = Task { @MainActor [self, context] in
                    guard !Task.isCancelled else { return }
                    do { try await waitForDeadline() } catch { return }
                    guard !Task.isCancelled else { return }
                    interrupt(context, failure: .init(.timedOut, context.mutationAttempted ?
                        "Apple Music 响应超时，请先确认播放或队列" : "Apple Music 响应超时，请稍后再试"))
                }
                if Task.isCancelled { interrupt(context, failure: Self.cancelled) }
            }
        } onCancel: {
            Task { @MainActor [self, context] in interrupt(context, failure: Self.cancelled) }
        }
    }

    private func interrupt(_ context: Context, failure: MusicPlaybackFailure) {
        guard context.isActive else { return }
        context.isActive = false
        context.worker?.cancel()
        context.deadline?.cancel()
        context.deadline = nil
        let continuation = context.continuation
        context.continuation = nil
        // A read may keep running, but its expired context cannot begin a write.
        // A write may still complete; even a user acknowledgment cannot bypass it.
        if !context.mutationAttempted, active === context { active = nil }
        continuation?.resume(returning: context.result(for: failure))
    }

    private func complete(_ context: Context, result: MusicPlaybackActionResult) {
        context.isActive = false
        context.deadline?.cancel()
        context.deadline = nil
        context.worker = nil
        if active === context { active = nil }
        let continuation = context.continuation
        context.continuation = nil
        // A late SDK result only releases its own gate. It cannot overwrite the
        // delivered timeout, resume a continuation twice, or finish a newer call.
        continuation?.resume(returning: result)
    }

    private static let cancelled = MusicPlaybackFailure(.cancelled, "操作已取消；如已提交，请先查看 Apple Music")
}

/// Apple Music's existing system player. The service never replaces its queue.
///
/// Integration:
/// - Retain one instance on the main actor. Observe `snapshot`, or set `onSnapshot`.
/// - Call `startObserving()` once; `stopObserving()` releases subscriptions.
/// - Only a user action should call `requestAuthorization()` or a playback command.
/// - `playNow` is destructive to the current listening moment: confirm in the UI first.
/// - All state is ephemeral; the caller owns app collections and reading/navigation state.
///
/// Requires NSAppleMusicUsageDescription and an Apple Music capable signed App ID.
/// The simulator reports `.simulatorUnsupported`; it never simulates successful playback.
@MainActor @Observable
final class MusicPlaybackService: MusicPlaybackClient {
    private(set) var snapshot: MusicPlaybackSnapshot
    private(set) var commandInFlight: MusicPlaybackCommand?
    private(set) var isObserving = false
    @ObservationIgnored var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?

    @ObservationIgnored private var player: SystemMusicPlayer?
    @ObservationIgnored private var mediaPlayer: MPMusicPlayerController?
    @ObservationIgnored private var lifecycleObservers: Set<AnyCancellable> = []
    @ObservationIgnored private var playerObservers: Set<AnyCancellable> = []
    @ObservationIgnored private var queueObserver: AnyCancellable?
    @ObservationIgnored private var observedQueue: ObjectIdentifier?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var subscriptionUpdates: Task<Void, Never>?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var subscriptionRefresh: Task<Void, Never>?
    @ObservationIgnored private var artworkLookup: Task<Void, Never>?
    @ObservationIgnored private var artworkLookupID: String?
    @ObservationIgnored private var artworkURLs: [String: URL] = [:]
    @ObservationIgnored private var collectionEnds: [String: MusicQueueSelection] = [:]
    @ObservationIgnored private var attemptedArtworkIDs: Set<String> = []
    @ObservationIgnored private var subscriptionState: MusicSubscriptionState = .unknown
    @ObservationIgnored private var subscriptionGeneration = 0
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var bridgeIsGeneratingNotifications = false
    @ObservationIgnored private let commandExecutor: MusicPlaybackCommandExecutor

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    init(commandExecutor: MusicPlaybackCommandExecutor = .init()) {
        self.commandExecutor = commandExecutor
        let authorization = Self.authorizationState
        snapshot = .init(
            availability: Self.availability(for: authorization), authorization: authorization,
            subscription: .unknown, nowPlaying: nil, status: .stopped, elapsedTime: 0,
            capturedAt: Date()
        )
    }

    isolated deinit {
        ticker?.cancel()
        subscriptionUpdates?.cancel()
        scheduledRefresh?.cancel()
        subscriptionRefresh?.cancel()
        artworkLookup?.cancel()
        if bridgeIsGeneratingNotifications { mediaPlayer?.endGeneratingPlaybackNotifications() }
    }

    /// Reads current authorization without presenting a permission dialog.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        appIsActive = UIApplication.shared.applicationState != .background
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isObserving else { return }
                    self.appIsActive = true
                    self.beginTicker()
                    await self.refresh()
                }
            }.store(in: &lifecycleObservers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.appIsActive = false
                    self?.ticker?.cancel()
                    self?.ticker = nil
                }
            }.store(in: &lifecycleObservers)
        captureSnapshot()
        beginTicker()
        scheduledRefresh = Task { @MainActor [weak self] in await self?.refresh() }
    }

    func stopObserving() {
        isObserving = false
        ticker?.cancel(); ticker = nil
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        lifecycleObservers.removeAll()
        detachPlayerObservers()
        subscriptionUpdates?.cancel(); subscriptionUpdates = nil
        subscriptionGeneration += 1
        subscriptionRefresh?.cancel(); subscriptionRefresh = nil
        artworkLookup?.cancel(); artworkLookup = nil; artworkLookupID = nil
        if case .checking = subscriptionState { subscriptionState = .unknown }
    }

    /// Safe on launch and on foreground return. Does not authorize, play or change queue.
    func refresh() async {
        // Explicit refresh/foreground return permits retrying a previously failed art lookup.
        attemptedArtworkIDs.removeAll()
        captureSnapshot()
        guard snapshot.availability == .ready else { return }
        await refreshSubscription()
        captureSnapshot()
    }

    /// This is the only call site of MusicAuthorization.request().
    func requestAuthorization() async -> MusicPlaybackActionResult {
        let command = MusicPlaybackCommand.requestAuthorization
        if let failure = begin(command, requiringAuthorization: false) { return .failure(failure) }
        defer { commandInFlight = nil }
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String
        guard let usage, !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.init(.configuration, "Apple Music 连接尚未配置完成", diagnostic: "Missing NSAppleMusicUsageDescription"))
        }
        if MusicAuthorization.currentStatus == .notDetermined {
            _ = await MusicAuthorization.request()
        }
        captureSnapshot()
        if let failure = accessFailure() { return .failure(failure) }
        // Authorization is already observed. A slow subscription lookup must not
        // keep the connection action pending after the permission dialog closes.
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
        return .success(receipt(command, verification: .observed))
    }

    func pause() async -> MusicPlaybackActionResult {
        let command = MusicPlaybackCommand.pause
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        return await commandExecutor.run(command) { [self] context in
            guard let player, snapshot.nowPlaying != nil else { return .failure(nothingPlaying) }
            if snapshot.status == .paused { return .success(receipt(command, verification: .observed)) }
            try context.beginMutation()
            player.pause()
            return await confirm(command) { $0.status == .paused || $0.status == .stopped }
        }
    }

    func resume() async -> MusicPlaybackActionResult {
        let command = MusicPlaybackCommand.resume
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        return await commandExecutor.run(command) { [self] context in
            guard let player, snapshot.nowPlaying != nil else { return .failure(nothingPlaying) }
            if snapshot.status == .playing { return .success(receipt(command, verification: .observed)) }
            try context.beginMutation()
            do { try await player.play() }
            catch {
                try context.checkCancellation()
                return uncertain(command, error: error)
            }
            context.mutationAccepted()
            try context.checkCancellation()
            return await confirm(command) { $0.status == .playing }
        }
    }

    func skipToNext() async -> MusicPlaybackActionResult {
        let command = MusicPlaybackCommand.skipToNext
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        return await commandExecutor.run(command) { [self] context in
            guard let player, snapshot.nowPlaying != nil else { return .failure(nothingPlaying) }
            let previous = snapshot
            try context.beginMutation()
            do { try await player.skipToNextEntry() }
            catch {
                try context.checkCancellation()
                return uncertain(command, error: error)
            }
            context.mutationAccepted()
            try context.checkCancellation()
            return await confirm(command) { MusicPlaybackConfirmation.didAdvance(from: previous, to: $0) }
        }
    }

    /// MusicKit catalogue requests need a developer token, which only a paid team with the MusicKit
    /// App Service gets. Until the app is signed by such a team, 下一首播放 / 现在播放 / 全部播放 and the
    /// crate's queue buttons go through the system Music app by store ID, which needs no token
    /// (anson 2026-11-18: those buttons only ever said 「暂时无法播放」).
    static let queuesByStoreID = true

    /// Adds one catalog song after whatever is current at insertion time. Never starts playback.
    /// Multiple simultaneous requests are rejected, including double taps on the same song.
    /// MusicKit cannot enumerate SystemMusicPlayer's queue, so this does not claim global deduplication.
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult {
        if Self.queuesByStoreID { return await storeQueue([.init(catalogID: catalogID, kind: .song)], playImmediately: false) }
        return await insertCatalogSong(catalogID: catalogID, playImmediately: false)
    }

    /// Insert and select the exact entry, preserving the rest of the user's queue.
    /// The caller must obtain the user's explicit intent to interrupt current playback.
    func playNow(catalogID: String) async -> MusicPlaybackActionResult {
        if Self.queuesByStoreID { return await playStoreSelection(.init(catalogID: catalogID, kind: .song)) }
        return await insertCatalogSong(catalogID: catalogID, playImmediately: true)
    }

    /// Uses the user's signed-in system Music app, without a MusicKit catalogue
    /// request or developer token. Only the explicit Play button calls this.
    func playStoreSelection(_ selection: MusicQueueSelection) async -> MusicPlaybackActionResult {
        guard Self.validCatalogID(selection.catalogID) != nil else {
            return .failure(.init(.invalidCatalogID, "这首歌还没有 Apple Music 链接"))
        }
        if let failure = begin(.playNow) { return .failure(failure) }
        defer { commandInFlight = nil }
        return await commandExecutor.run(.playNow, catalogID: selection.catalogID) { [self] context in
            let bridge = MPMusicPlayerController.systemMusicPlayer
            try context.beginMutation()
            bridge.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: [selection.catalogID]))
            let error: Error? = await withCheckedContinuation { continuation in
                bridge.prepareToPlay { continuation.resume(returning: $0) }
            }
            try context.checkCancellation()
            if let error { return uncertain(.playNow, catalogID: selection.catalogID, error: error) }
            let preparedID = bridge.nowPlayingItem?.playbackStoreID
            bridge.play(); context.mutationAccepted()
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                try context.checkCancellation()
                let actual = bridge.nowPlayingItem?.playbackStoreID
                let matches = selection.kind == .song ? actual == selection.catalogID :
                    (preparedID?.isEmpty == false && actual == preparedID)
                if bridge.playbackState == .playing && matches {
                    captureSnapshot()
                    return .success(receipt(.playNow, catalogID: selection.catalogID,
                                            verification: selection.kind == .song ? .observed : .acceptedBySystem))
                }
            }
            return .uncertain(receipt(.playNow, catalogID: selection.catalogID, verification: .acceptedBySystem),
                              .init(.notConfirmed, "未能确认播放，正在打开 Apple Music。"))
        }
    }

    /// Resolve the whole box first, then insert one ordered group. A missing
    /// record cannot leave a silently partial queue. Albums keep track order.
    func playCollection(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        if Self.queuesByStoreID { return await storeQueue(selections, playImmediately: true) }
        return await enqueueCollection(selections, playImmediately: true)
    }

    func insertCollectionNext(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult {
        if Self.queuesByStoreID { return await storeQueue(selections, playImmediately: false) }
        return await enqueueCollection(selections, playImmediately: false)
    }

    /// The token-free queue: the system Music app resolves the store IDs itself (songs keep their
    /// order; an album expands to its tracks). 全部播放 replaces the queue, as playing a list in
    /// Apple Music does; 下一首播放 puts the items right after the current song.
    private func storeQueue(_ selections: [MusicQueueSelection], playImmediately: Bool) async -> MusicPlaybackActionResult {
        let command: MusicPlaybackCommand = playImmediately ? .playNow : .insertNext
        guard let first = selections.first, selections.allSatisfy({ Self.validCatalogID($0.catalogID) != nil }) else {
            return .failure(.init(.invalidCatalogID, "这首歌还没有 Apple Music 链接"))
        }
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        return await commandExecutor.run(command, catalogID: first.catalogID) { [self] context in
            let bridge = MPMusicPlayerController.systemMusicPlayer
            let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: selections.map(\.catalogID))
            if !playImmediately, bridge.nowPlayingItem != nil {
                try context.beginMutation()
                bridge.prepend(descriptor)
                context.mutationAccepted()
                return .success(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem))
            }
            try context.beginMutation()
            bridge.setQueue(with: descriptor)
            let error: Error? = await withCheckedContinuation { continuation in
                bridge.prepareToPlay { continuation.resume(returning: $0) }
            }
            try context.checkCancellation()
            if let error { return uncertain(command, catalogID: first.catalogID, error: error) }
            // Nothing was playing: the songs wait in the queue, ready to play; nothing starts by itself.
            guard playImmediately else {
                context.mutationAccepted()
                return .success(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem))
            }
            let preparedID = bridge.nowPlayingItem?.playbackStoreID
            bridge.play(); context.mutationAccepted()
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                try context.checkCancellation()
                let actual = bridge.nowPlayingItem?.playbackStoreID
                let matches = first.kind == .song ? actual == first.catalogID : (preparedID?.isEmpty == false && actual == preparedID)
                if bridge.playbackState == .playing && matches {
                    captureSnapshot()
                    return .success(receipt(command, catalogID: first.catalogID, verification: first.kind == .song ? .observed : .acceptedBySystem))
                }
            }
            return .uncertain(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem),
                              .init(.notConfirmed, "未能确认播放，请看一下 Apple Music。"))
        }
    }

    private func enqueueCollection(_ selections: [MusicQueueSelection], playImmediately: Bool) async -> MusicPlaybackActionResult {
        let command: MusicPlaybackCommand = playImmediately ? .playNow : .insertNext
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        guard let first = selections.first, selections.allSatisfy({ Self.validCatalogID($0.catalogID) != nil }) else {
            return .failure(.init(.invalidCatalogID, "箱子里有唱片还没有 Apple Music 链接"))
        }
        return await commandExecutor.run(command, catalogID: first.catalogID) { [self] context in
            if !playImmediately, player?.queue.currentEntry == nil { return .failure(nothingPlaying) }
            if case .available = subscriptionState {} else { await refreshSubscription() }
            try context.checkCancellation()
            captureSnapshot()
            if let failure = accessFailure() { return .failure(failure) }
            guard snapshot.canPlayCatalog else { return .failure(.init(.subscriptionUnavailable, "当前 Apple Music 账户无法播放曲库歌曲")) }
            var entries: [MusicKit.MusicPlayer.Queue.Entry] = []
            var ends: [String: MusicQueueSelection] = [:]
            for selection in selections {
                let group: [MusicKit.MusicPlayer.Queue.Entry]
                switch selection.kind {
                case .song:
                    let response = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(selection.catalogID)).response()
                    try context.checkCancellation()
                    guard let song = response.items.first, song.id.rawValue == selection.catalogID, song.playParameters != nil else {
                        return .failure(.init(.catalogUnavailable, "箱子里有唱片暂时无法在当前账户播放"))
                    }
                    group = [MusicPlayer.Queue.Entry(song)]
                case .album:
                    let response = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(selection.catalogID)).response()
                    try context.checkCancellation()
                    guard let album = response.items.first, album.id.rawValue == selection.catalogID else {
                        return .failure(.init(.catalogUnavailable, "当前地区没有找到这张专辑"))
                    }
                    let expanded = try await album.with([.tracks])
                    try context.checkCancellation()
                    guard var tracks = expanded.tracks else {
                        return .failure(.init(.notPlayable, "这张专辑的曲目暂时无法完整播放"))
                    }
                    while tracks.hasNextBatch {
                        guard let next = try await tracks.nextBatch() else {
                            return .failure(.init(.notPlayable, "这张专辑的曲目暂时无法完整播放"))
                        }
                        try context.checkCancellation()
                        tracks += next
                    }
                    guard !tracks.isEmpty, tracks.allSatisfy({ $0.playParameters != nil }) else {
                        return .failure(.init(.notPlayable, "这张专辑的曲目暂时无法完整播放"))
                    }
                    group = tracks.map { MusicPlayer.Queue.Entry($0) }
                }
                entries += group
                if let last = group.last { ends[last.id] = selection }
            }
            try context.checkCancellation()
            captureSnapshot()
            if let failure = accessFailure() { return .failure(failure) }
            guard let player, let firstEntry = entries.first else { return .failure(nothingPlaying) }
            let queue = player.queue
            let anchorID = queue.currentEntry?.id
            if !playImmediately, anchorID == nil { return .failure(nothingPlaying) }
            // Queue.Entry exposes immutable values but the SDK's generic insert
            // lacks Sendable annotations. Freeze this batch, then await its sole
            // consumer before using the first entry. The command gate prevents
            // overlapping mutations; no shared mutable collection crosses it.
            nonisolated(unsafe) let frozenEntries = entries
            try context.beginMutation()
            do { try await queue.insert(frozenEntries, position: queue.currentEntry == nil ? .tail : .afterCurrentEntry) }
            catch { try context.checkCancellation(); return uncertain(command, catalogID: first.catalogID, error: error) }
            context.mutationAccepted()
            try context.checkCancellation()
            guard player.queue == queue else {
                return .uncertain(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem), .init(.queueChanged, "Apple Music 的队列已变化，请先查看播放列表"))
            }
            collectionEnds.merge(ends) { _, new in new }
            if !playImmediately {
                guard queue.currentEntry?.id == anchorID else {
                    return .uncertain(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem), .init(.queueChanged, "歌曲已提交，当前播放已变化，请查看 Apple Music 队列"))
                }
                return .success(receipt(command, catalogID: first.catalogID, verification: .acceptedBySystem))
            }
            try context.beginMutation()
            player.state.shuffleMode = .off
            queue.currentEntry = firstEntry
            do { try await player.play() }
            catch { try context.checkCancellation(); return uncertain(command, catalogID: first.catalogID, error: error) }
            try context.checkCancellation()
            return await confirm(command, catalogID: first.catalogID) { MusicPlaybackConfirmation.isPlaying(entryID: firstEntry.id, in: $0) }
        }
    }

    private func insertCatalogSong(catalogID rawID: String, playImmediately: Bool) async -> MusicPlaybackActionResult {
        let command: MusicPlaybackCommand = playImmediately ? .playNow : .insertNext
        if let failure = begin(command) { return .failure(failure) }
        defer { commandInFlight = nil }
        guard let catalogID = Self.validCatalogID(rawID) else {
            return .failure(.init(.invalidCatalogID, "这首歌还没有 Apple Music 链接"))
        }
        return await commandExecutor.run(command, catalogID: catalogID) { [self] context in
            try await performInsertCatalogSong(catalogID: catalogID, playImmediately: playImmediately, context: context)
        }
    }

    private func performInsertCatalogSong(catalogID: String, playImmediately: Bool,
                                         context: MusicPlaybackCommandExecutor.Context) async throws -> MusicPlaybackActionResult {
        let command = context.command
        if !playImmediately, player?.queue.currentEntry == nil {
            return .failure(.init(.nothingPlaying, "先在 Apple Music 中播放一首歌"))
        }
        if case .available = subscriptionState {} else { await refreshSubscription() }
        try context.checkCancellation()
        captureSnapshot()
        if let failure = accessFailure() { return .failure(failure) }
        guard snapshot.canPlayCatalog else {
            if case let .failed(failure) = subscriptionState { return .failure(failure) }
            return .failure(.init(.subscriptionUnavailable, "当前 Apple Music 账户无法播放曲库歌曲"))
        }

        let song: Song
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            request.limit = 1
            let response = try await request.response()
            try context.checkCancellation()
            guard let found = response.items.first, found.id.rawValue == catalogID else {
                return .failure(.init(.catalogUnavailable, "当前地区的 Apple Music 中没有找到这首歌"))
            }
            song = found
        } catch {
            return .failure(Self.failure(error, message: "暂时无法读取这首歌，请稍后再试"))
        }
        guard song.playParameters != nil else {
            return .failure(.init(.notPlayable, "这首歌暂时无法在当前账户播放"))
        }
        try context.checkCancellation()
        captureSnapshot()
        if let failure = accessFailure() { return .failure(failure) }
        guard let player else { return .failure(nothingPlaying) }
        let queue = player.queue
        let anchorID = queue.currentEntry?.id
        if !playImmediately, anchorID == nil { return .failure(nothingPlaying) }
        let entry = MusicPlayer.Queue.Entry(song)

        // From this point onward, errors/cancellation can be ambiguous. Never retry automatically.
        try context.beginMutation()
        do {
            try await queue.insert(entry, position: anchorID == nil ? .tail : .afterCurrentEntry)
        } catch {
            try context.checkCancellation()
            return uncertain(command, catalogID: catalogID, error: error)
        }
        context.mutationAccepted()
        try context.checkCancellation()
        captureSnapshot()
        if let failure = accessFailure() {
            return .uncertain(receipt(command, catalogID: catalogID, verification: .acceptedBySystem), failure)
        }
        guard player.queue == queue else {
            return .uncertain(receipt(command, catalogID: catalogID, verification: .acceptedBySystem),
                              .init(.queueChanged, "Apple Music 的队列已变化，请先查看播放列表"))
        }
        if !playImmediately {
            guard queue.currentEntry?.id == anchorID else {
                return .uncertain(receipt(command, catalogID: catalogID, verification: .acceptedBySystem),
                                  .init(.queueChanged, "歌曲已提交，当前播放已变化，请查看 Apple Music 队列"))
            }
            return .success(receipt(command, catalogID: catalogID, verification: .acceptedBySystem))
        }
        // No queue assignment and no skip race: choose the Entry that was just inserted.
        try context.beginMutation()
        queue.currentEntry = entry
        try context.beginMutation()
        do { try await player.play() }
        catch {
            try context.checkCancellation()
            return uncertain(command, catalogID: catalogID, error: error)
        }
        try context.checkCancellation()
        return await confirm(command, catalogID: catalogID) {
            MusicPlaybackConfirmation.isPlaying(entryID: entry.id, in: $0)
        }
    }

    private func begin(_ command: MusicPlaybackCommand, requiringAuthorization: Bool = true) -> MusicPlaybackFailure? {
        if commandInFlight != nil { return .init(.busy, "上一项播放操作还在处理中") }
        if commandExecutor.hasUnsettledOperation { return .init(.busy, "上一项播放操作尚未结束，请先查看 Apple Music") }
        if Self.isSimulator { return .init(.simulatorUnsupported, "模拟器无法连接 Apple Music 播放器") }
        if Task.isCancelled { return cancelled }
        captureSnapshot()
        if requiringAuthorization, let failure = accessFailure() { return failure }
        commandInFlight = command
        return nil
    }

    private func accessFailure() -> MusicPlaybackFailure? {
        switch snapshot.availability {
        case .ready: nil
        case .simulatorUnsupported: .init(.simulatorUnsupported, "模拟器无法连接 Apple Music 播放器")
        case .authorizationRequired: .init(.authorizationRequired, "连接 Apple Music 后即可使用")
        case .authorizationDenied: .init(.authorizationDenied, "请在系统设置中允许访问 Apple Music")
        case .authorizationRestricted: .init(.authorizationRestricted, "这台设备限制了 Apple Music 访问")
        }
    }

    private var nothingPlaying: MusicPlaybackFailure { .init(.nothingPlaying, "Apple Music 当前没有可控制的歌曲") }
    private var cancelled: MusicPlaybackFailure { .init(.cancelled, "操作已取消；如已提交，请先查看 Apple Music") }

    private func receipt(_ command: MusicPlaybackCommand, catalogID: String? = nil,
                         verification: MusicPlaybackReceipt.Verification) -> MusicPlaybackReceipt {
        .init(command: command, catalogID: catalogID, verification: verification,
              observedAt: verification == .observed ? snapshot.capturedAt : nil)
    }

    private func uncertain(_ command: MusicPlaybackCommand, catalogID: String? = nil, error: Error) -> MusicPlaybackActionResult {
        captureSnapshot()
        return .uncertain(receipt(command, catalogID: catalogID, verification: .unconfirmed),
                          Self.failure(error, message: "未能确认播放操作，请先查看 Apple Music"))
    }

    private func confirm(_ command: MusicPlaybackCommand, catalogID: String? = nil,
                         matches: @MainActor (MusicPlaybackSnapshot) -> Bool) async -> MusicPlaybackActionResult {
        // Read-back is bounded. A timeout is not treated as a definite failure or retried.
        for attempt in 0..<16 {
            if Task.isCancelled {
                return .uncertain(receipt(command, catalogID: catalogID, verification: .unconfirmed), cancelled)
            }
            captureSnapshot()
            if let failure = accessFailure() {
                return .uncertain(receipt(command, catalogID: catalogID, verification: .unconfirmed), failure)
            }
            if matches(snapshot) { return .success(receipt(command, catalogID: catalogID, verification: .observed)) }
            if attempt < 15 {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return .uncertain(receipt(command, catalogID: catalogID, verification: .unconfirmed), cancelled) }
            }
        }
        return .uncertain(receipt(command, catalogID: catalogID, verification: .unconfirmed),
                          .init(.notConfirmed, "Apple Music 尚未确认操作，请稍后查看"))
    }

    private static func failure(_ error: Error, message: String) -> MusicPlaybackFailure {
        if error is CancellationError { return .init(.cancelled, "操作已取消；如已提交，请先查看 Apple Music") }
        let nsError = error as NSError
        return .init(.systemError, message, diagnostic: "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
    }

    private func refreshSubscription() async {
        guard !Self.isSimulator, Self.authorizationState == .authorized else { return }
        if let existing = subscriptionRefresh { await existing.value; return }
        subscriptionState = .checking
        captureSnapshot()
        subscriptionGeneration += 1
        let generation = subscriptionGeneration
        let task = Task { @MainActor [weak self] in
            do {
                let value = try await MusicSubscription.current
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation,
                      Self.authorizationState == .authorized else { return }
                self.applySubscription(value)
            } catch {
                guard let self, self.subscriptionGeneration == generation else { return }
                self.subscriptionState = Task.isCancelled ? .unknown : .failed(Self.failure(error, message: "暂时无法确认 Apple Music 订阅状态"))
                self.captureSnapshot()
            }
        }
        subscriptionRefresh = task
        await task.value
        if subscriptionGeneration == generation { subscriptionRefresh = nil }
    }

    private func applySubscription(_ subscription: MusicSubscription) {
        guard Self.authorizationState == .authorized else { return }
        subscriptionState = .available(.init(
            canPlayCatalogContent: subscription.canPlayCatalogContent,
            canBecomeSubscriber: subscription.canBecomeSubscriber,
            hasCloudLibraryEnabled: subscription.hasCloudLibraryEnabled
        ))
        captureSnapshot()
    }

    private func attachPlayerObservers() {
        guard isObserving, let player, playerObservers.isEmpty else { return }
        player.state.objectWillChange.sink { @Sendable [weak self] in self?.scheduleCapture() }.store(in: &playerObservers)
        // This bridge is read-only. It fills the public now-playing metadata gap when a
        // system queue entry has no Song/MusicVideo item (e.g. playback begun in Music).
        if let mediaPlayer {
            mediaPlayer.beginGeneratingPlaybackNotifications()
            bridgeIsGeneratingNotifications = true
            for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                         Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange] {
                NotificationCenter.default.publisher(for: name, object: mediaPlayer)
                    .sink { @Sendable [weak self] _ in self?.scheduleCapture() }.store(in: &playerObservers)
            }
        }
        subscriptionUpdates = Task { @MainActor [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                guard !Task.isCancelled, self?.isObserving == true else { break }
                self?.applySubscription(subscription)
            }
        }
        attachQueueObserver()
    }

    private func attachQueueObserver() {
        guard isObserving, let queue = player?.queue else { return }
        let identity = ObjectIdentifier(queue)
        guard observedQueue != identity else { return }
        queueObserver = queue.objectWillChange.sink { @Sendable [weak self] in self?.scheduleCapture() }
        observedQueue = identity
    }

    private func detachPlayerObservers() {
        playerObservers.removeAll()
        queueObserver = nil
        observedQueue = nil
        if bridgeIsGeneratingNotifications {
            mediaPlayer?.endGeneratingPlaybackNotifications()
            bridgeIsGeneratingNotifications = false
        }
    }

    /// Combine may deliver on a non-main executor. Hop explicitly; objectWillChange
    /// precedes the mutation, so read after yielding rather than in its callback.
    nonisolated private func scheduleCapture() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isObserving else { return }
            self.captureSnapshot()
        }
    }

    private func beginTicker() {
        guard isObserving, appIsActive, ticker == nil, !Self.isSimulator else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard !Task.isCancelled, self?.isObserving == true else { break }
                self?.captureSnapshot()
            }
        }
    }

    private func captureSnapshot() {
        let authorization = Self.authorizationState
        let availability = Self.availability(for: authorization)
        if availability == .ready {
            if player == nil { player = SystemMusicPlayer.shared }
            if mediaPlayer == nil { mediaPlayer = MPMusicPlayerController.systemMusicPlayer }
            attachPlayerObservers()
            attachQueueObserver()
        } else {
            detachPlayerObservers()
            subscriptionUpdates?.cancel(); subscriptionUpdates = nil
            subscriptionGeneration += 1
            subscriptionRefresh?.cancel(); subscriptionRefresh = nil
            subscriptionState = .unknown
            artworkLookup?.cancel(); artworkLookup = nil; artworkLookupID = nil
            artworkURLs.removeAll()
            attemptedArtworkIDs.removeAll()
            player = nil
            mediaPlayer = nil
        }
        let entry = player?.queue.currentEntry
        let metadata = currentMetadata(entry: entry)
        let elapsed = player?.playbackTime ?? 0
        let value = MusicPlaybackSnapshot(
            availability: availability, authorization: authorization, subscription: subscriptionState,
            nowPlaying: metadata, status: currentStatus(),
            elapsedTime: elapsed.isFinite ? max(0, elapsed) : 0, capturedAt: Date(), currentEntryID: entry?.id,
            collectionEnd: entry.flatMap { collectionEnds[$0.id] }
        )
        let prior = snapshot
        if prior.nowPlaying?.artworkURL != metadata?.artworkURL || prior.nowPlaying?.artworkAsset != metadata?.artworkAsset {
            ArtworkTint.shared.prewarm(metadata?.artworkAsset ?? metadata?.artworkURL?.absoluteString)
        }
        snapshot = value
        if MusicPlaybackPublication.needsContentDelivery(from: prior, to: value) { onSnapshot?(value) }
        // MusicKit catalog investigation is paused (2026-11-05). Retain the
        // resolver for a later explicit resumption, but observation must not
        // start an automatic catalog/token request. Existing artwork still shows.
    }

    private func currentMetadata(entry: MusicKit.MusicPlayer.Queue.Entry?) -> MusicNowPlayingMetadata? {
        guard player != nil else { return nil }
        if let entry, let item = entry.item {
            switch item {
            case .song(let song):
                let catalogID = Self.validCatalogID(song.id.rawValue)
                return .init(id: entry.id, catalogID: catalogID,
                             title: song.title, artist: song.artistName, albumTitle: song.albumTitle,
                             artworkURL: ArtworkLocation.remoteURL(song.artwork?.url(width: 800, height: 800)) ?? catalogID.flatMap { artworkURLs[$0] },
                             duration: Self.validDuration(song.duration), source: .musicKit,
                             releaseDate: song.releaseDate?.ISO8601Format(),
                             editorialNotes: StoryMaterial.appleEditorial(text: song.editorialNotes?.standard ?? song.editorialNotes?.short, url: song.url, title: song.title, location: "song.editorialNotes")
                                + (song.albums?.flatMap { StoryMaterial.appleEditorial(text: $0.editorialNotes?.standard ?? $0.editorialNotes?.short, url: $0.url, title: $0.title, location: "album.editorialNotes") } ?? []),
                             artworkAsset: matchingBridgeArtwork(catalogID: catalogID, title: song.title, artist: song.artistName,
                                album: song.albumTitle, duration: song.duration))
            case .musicVideo(let video):
                return .init(id: entry.id, catalogID: Self.validCatalogID(video.id.rawValue),
                             title: video.title, artist: video.artistName, albumTitle: video.albumTitle,
                             artworkURL: ArtworkLocation.remoteURL(video.artwork?.url(width: 800, height: 800)),
                             duration: Self.validDuration(video.duration), source: .musicKit, kind: .musicVideo)
            @unknown default: break
            }
        }
        // Do not attach a bridge ID to a MusicKit title by fuzzy/name matching. Copy
        // the complete bridge observation as one unit, or leave catalogID unknown.
        if let entry {
            // Prefer the queue's own identity while it materializes. A bridge
            // notification may still describe the previous song; never splice it
            // into, or replace, this authoritative current queue observation.
            return .init(id: entry.id, catalogID: nil, title: entry.title, artist: entry.subtitle ?? "",
                         albumTitle: nil, artworkURL: ArtworkLocation.remoteURL(entry.artwork?.url(width: 800, height: 800)),
                         duration: nil, source: .musicKit, kind: .unknown)
        }
        return bridgeMetadata()
    }

    private func bridgeMetadata() -> MusicNowPlayingMetadata? {
        guard let item = mediaPlayer?.nowPlayingItem else { return nil }
        let kind: MusicNowPlayingMetadata.Kind = item.mediaType.contains(.musicVideo) ? .musicVideo : item.mediaType.contains(.music) ? .song : .unknown
        let catalogID = kind == .unknown ? nil : Self.validCatalogID(item.playbackStoreID)
        let observationID = "media:\(item.persistentID):\(catalogID ?? "local")"
        let artwork = ObservedArtwork.remember(identity: [observationID, item.title ?? "", item.artist ?? "", item.albumTitle ?? ""].joined(separator: "|")) {
            item.artwork?.image(at: CGSize(width: 800, height: 800))
        }
        return .init(id: observationID,
                     catalogID: catalogID, title: item.title ?? "", artist: item.artist ?? "",
                     albumTitle: item.albumTitle, artworkURL: catalogID.flatMap { artworkURLs[$0] },
                     duration: Self.validDuration(item.playbackDuration), source: .mediaPlayer, kind: kind, artworkAsset: artwork)
    }

    private func matchingBridgeArtwork(catalogID: String?, title: String, artist: String, album: String?, duration: TimeInterval?) -> String? {
        guard let item = mediaPlayer?.nowPlayingItem else { return nil }
        let observedID = Self.validCatalogID(item.playbackStoreID)
        let exactID = catalogID != nil && catalogID == observedID
        let exactMetadata = item.title == title && item.artist == artist && album?.isEmpty == false
            && item.albumTitle == album && duration.map { abs($0 - item.playbackDuration) < 2 } == true
        guard exactID || exactMetadata else { return nil }
        return ObservedArtwork.remember(identity: ["media:\(item.persistentID):\(observedID ?? "local")", item.title ?? "", item.artist ?? "", item.albumTitle ?? ""].joined(separator: "|")) {
            item.artwork?.image(at: CGSize(width: 800, height: 800))
        }
    }

    /// MediaPlayer exposes artwork as an image, not a URL. Resolve only its exact
    /// public playbackStoreID in MusicKit; no search-by-title or private artwork URLs.
    private func enrichArtworkIfNeeded(_ metadata: MusicNowPlayingMetadata?) {
        guard isObserving, appIsActive, snapshot.availability == .ready else { return }
        guard let metadata, metadata.kind == .song, metadata.artworkURL == nil, let catalogID = metadata.catalogID else {
            artworkLookup?.cancel(); artworkLookup = nil; artworkLookupID = nil
            return
        }
        guard artworkLookupID != catalogID, !attemptedArtworkIDs.contains(catalogID) else { return }
        artworkLookup?.cancel()
        artworkLookupID = catalogID
        // Bound per-session bookkeeping while keeping the active request deduplicated.
        if attemptedArtworkIDs.count >= 128 { attemptedArtworkIDs.removeAll() }
        attemptedArtworkIDs.insert(catalogID)
        artworkLookup = Task { @MainActor [weak self] in
            var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            request.limit = 1
            let response = try? await request.response()
            guard let self, !Task.isCancelled, self.artworkLookupID == catalogID else { return }
            self.artworkLookupID = nil
            self.artworkLookup = nil
            guard Self.authorizationState == .authorized, let song = response?.items.first,
                  song.id.rawValue == catalogID,
                  let url = ArtworkLocation.remoteURL(song.artwork?.url(width: 800, height: 800)) else { return }
            if self.artworkURLs.count >= 128 { self.artworkURLs.removeAll() }
            self.artworkURLs[catalogID] = url
            if self.snapshot.nowPlaying?.catalogID == catalogID { self.captureSnapshot() }
        }
    }

    private func currentStatus() -> MusicPlaybackStatus {
        guard let player else { return .stopped }
        switch player.state.playbackStatus {
        case .stopped: return .stopped
        case .playing: return .playing
        case .paused: return .paused
        case .interrupted: return .interrupted
        case .seekingForward: return .seekingForward
        case .seekingBackward: return .seekingBackward
        @unknown default: return .unknown
        }
    }

    private static var authorizationState: MusicAuthorizationState {
        switch MusicAuthorization.currentStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .unknown
        }
    }

    private static func availability(for authorization: MusicAuthorizationState) -> MusicPlaybackAvailability {
        if isSimulator { return .simulatorUnsupported }
        switch authorization {
        case .authorized: return .ready
        case .denied: return .authorizationDenied
        case .restricted: return .authorizationRestricted
        case .notDetermined, .unknown: return .authorizationRequired
        }
    }

    /// Catalog IDs are ASCII decimal identifiers. Library IDs (such as i.*), zero,
    /// URLs and arbitrary input are never passed off as catalog identities.
    private static func validCatalogID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 30,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              value.contains(where: { $0 != "0" }) else { return nil }
        return value
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }
}
