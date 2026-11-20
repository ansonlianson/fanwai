#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit XCTest-only playback data. The production adapter remains unchanged
/// and continues to report that real MusicKit playback needs a physical device.
@MainActor final class SimulatorPlaybackFixture: MusicPlaybackClient {
    enum Mode: String { case unidentified, accepted, uncertain, failed, poolJP, jane, diver, version, shaira, farAway, goodWeather; case libraryArtwork = "library-artwork" }
    let mode: Mode
    private(set) var snapshot: MusicPlaybackSnapshot
    var commandInFlight: MusicPlaybackCommand? { nil }
    private(set) var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?

    /// `track` (catalog ID, title, artist) reviews any real catalogue song.
    init(mode: Mode, track: (String, String, String)? = nil) {
        self.mode = mode
        let recovery: (String, String, String)? = track ?? (mode == .shaira ? ("6819922345", "シャイラ", "m/lue.")
            : mode == .farAway ? ("1821131917", "遠くを想像するように", "m/lue.")
            : mode == .goodWeather ? ("6821806877", "いい天気", "伊藤尚毅") : nil)
        let metadata = recovery.map { MusicNowPlayingMetadata(id: "fixture-" + mode.rawValue, catalogID: $0.0,
            title: $0.1, artist: $0.2, albumTitle: nil, artworkURL: nil, duration: 230, source: .musicKit) } ?? (mode == .jane ? MusicNowPlayingMetadata(
            id: "fixture-jane", catalogID: "1840081736", title: "JANE DOE", artist: "米津玄師, 宇多田ヒカル",
            albumTitle: nil, artworkURL: nil, duration: 236, source: .musicKit) : mode == .poolJP || mode == .diver || mode == .version ? MusicNowPlayingMetadata(
            id: "fixture-real-" + mode.rawValue, catalogID: mode == .poolJP ? "1840141274" : mode == .version ? "6803304740" : "6803304739",
            title: mode == .poolJP ? "in the pool" : mode == .version ? "Diver (Korean ver.)" : "DIVER", artist: mode == .poolJP ? "牛尾憲輔" : "sis",
            albumTitle: nil, artworkURL: nil, duration: mode == .poolJP ? 245.44 : 202.12, source: .musicKit) : mode == .libraryArtwork ? MusicNowPlayingMetadata(
            id: "fixture-actor", catalogID: "1857886409", title: "Actor", artist: "幾田りら", albumTitle: "Laugh",
            artworkURL: URL(string: "musicKit://artwork/library/TEST-FIXTURE/800x800?aat=Music211%2Fcover.jpg&mt=music"),
            duration: 229, source: .musicKit) : mode == .unidentified ? nil : MusicNowPlayingMetadata(
            id: "fixture-pool", catalogID: WorkID.pool.work.catalogRecordingID,
            title: "in the pool", artist: "牛尾宪辅", albumTitle: "summer’s end",
            artworkURL: nil, duration: 540, source: .musicKit))
        snapshot = .init(availability: .ready, authorization: .authorized,
            subscription: .available(.init(canPlayCatalogContent: true, canBecomeSubscriber: false, hasCloudLibraryEnabled: true)),
            nowPlaying: metadata, status: .playing, elapsedTime: 120, capturedAt: Date(),
            currentEntryID: mode == .unidentified ? nil : "fixture-pool-occurrence")
    }

    func startObserving() { isObserving = true; onSnapshot?(snapshot) }
    func stopObserving() { isObserving = false }
    func refresh() async { onSnapshot?(snapshot) }
    func requestAuthorization() async -> MusicPlaybackActionResult { result(.requestAuthorization) }
    func pause() async -> MusicPlaybackActionResult { result(.pause) }
    func resume() async -> MusicPlaybackActionResult { result(.resume) }
    func skipToNext() async -> MusicPlaybackActionResult { result(.skipToNext) }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { result(.insertNext, catalogID) }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { result(.playNow, catalogID) }
    func playCollection(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult { result(.playNow, selections.first?.catalogID) }
    func insertCollectionNext(_ selections: [MusicQueueSelection]) async -> MusicPlaybackActionResult { result(.insertNext, selections.first?.catalogID) }

    private func result(_ command: MusicPlaybackCommand, _ catalogID: String? = nil) -> MusicPlaybackActionResult {
        let arguments = ProcessInfo.processInfo.arguments
        let review = arguments.contains("--ui-u18-direct-play") ? ("U18-direct-play", "PIANWAI_U18_PLAYBACK_OUTPUT")
            : arguments.contains("--ui-u19-original-recording") ? ("U19-original-recording", "PIANWAI_U19_PLAYBACK_OUTPUT")
            : arguments.contains("--ui-u20-first-take") ? ("U20-first-take", "PIANWAI_U20_PLAYBACK_OUTPUT") : nil
        if arguments.contains("--ui-isolate-data"), let review,
           let path = ProcessInfo.processInfo.environment[review.1],
           path.hasSuffix("/Design/review/" + review.0 + "/playback-commands.json") {
            let file = URL(fileURLWithPath: path)
            var rows = (try? JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: file))) ?? []
            rows.append(["command": command.rawValue, "catalogID": catalogID ?? ""])
            if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file, options: .atomic) }
        }
        switch mode {
        case .accepted, .libraryArtwork, .poolJP, .jane, .diver, .version, .shaira, .farAway, .goodWeather:
            if command == .skipToNext, ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"),
               let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-reader-next-track=") }) {
                let parts = value.dropFirst("--ui-reader-next-track=".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 {
                    let next = MusicNowPlayingMetadata(id: "fixture-reader-next", catalogID: parts[0], title: parts[1], artist: parts[2],
                        albumTitle: nil, artworkURL: nil, duration: 240, source: .musicKit)
                    snapshot = .init(availability: snapshot.availability, authorization: snapshot.authorization, subscription: snapshot.subscription,
                        nowPlaying: next, status: .playing, elapsedTime: 0, capturedAt: Date(), currentEntryID: "fixture-reader-next-occurrence")
                    onSnapshot?(snapshot)
                }
            }
            if command == .pause || command == .resume {
                snapshot = .init(availability: snapshot.availability, authorization: snapshot.authorization,
                                 subscription: snapshot.subscription, nowPlaying: snapshot.nowPlaying,
                                 status: command == .pause ? .paused : .playing, elapsedTime: snapshot.elapsedTime,
                                 capturedAt: Date(), currentEntryID: snapshot.currentEntryID)
                onSnapshot?(snapshot)
            }
            return .success(.init(command: command, catalogID: catalogID, verification: .acceptedBySystem))
        case .uncertain:
            return .uncertain(.init(command: command, catalogID: catalogID, verification: .unconfirmed),
                .init(.notConfirmed, "尚未确认，请先查看 Apple Music 的播放队列。"))
        case .failed:
            return .failure(.init(.catalogUnavailable, "这首歌暂时无法播放。可以先加入稍后听。"))
        case .unidentified:
            return .failure(.init(.nothingPlaying, "播放信息暂未同步。"))
        }
    }
}
#endif
