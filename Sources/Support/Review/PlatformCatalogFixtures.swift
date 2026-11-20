import Foundation

/// Explicit native UI replay of public responses. No account or playback state.
enum PlatformCatalogFixtures {
    static func http() -> PublicDatabaseHTTP? {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains("--ui-platform-fixtures"),
              let root = ProcessInfo.processInfo.environment["PIANWAI_PLATFORM_FIXTURES"],
              root.hasSuffix("/Design/review/E14-music-search-entry/platform-preference") else { return nil }
        return .init(directory: nil, paced: false, loader: { request in
            guard let url = request.url else { throw CatalogError.invalidLink }
            let name: String
            if url.host == "c.y.qq.com" { name = url.path.contains("single_song") ? "detail-qq-003d5zeF2C0zOc.json" : "qq-pool.json" }
            else if url.host == "music.163.com" { name = url.path.contains("song/detail") ? "detail-netease-3372716764.json" : "netease-pool.json" }
            else { throw CatalogError.invalidLink }
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name))
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        })
        #else
        return nil
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor final class NoApplePlatformFixture: MusicPlaybackClient {
    let snapshot = MusicPlaybackSnapshot(availability: .authorizationRequired, authorization: .notDetermined,
        subscription: .available(.init(canPlayCatalogContent: false, canBecomeSubscriber: true, hasCloudLibraryEnabled: false)),
        nowPlaying: nil, status: .stopped, elapsedTime: 0, capturedAt: Date())
    var commandInFlight: MusicPlaybackCommand? { nil }
    private(set) var isObserving = false
    private(set) var authorizationRequests = 0
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    func startObserving() { isObserving = true; onSnapshot?(snapshot) }
    func stopObserving() { isObserving = false }
    func refresh() async { onSnapshot?(snapshot) }
    private var unavailable: MusicPlaybackActionResult { .failure(.init(.authorizationRequired, "")) }
    func requestAuthorization() async -> MusicPlaybackActionResult { authorizationRequests += 1; return unavailable }
    func pause() async -> MusicPlaybackActionResult { unavailable }
    func resume() async -> MusicPlaybackActionResult { unavailable }
    func skipToNext() async -> MusicPlaybackActionResult { unavailable }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { unavailable }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { unavailable }
}
#endif
