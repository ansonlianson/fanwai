import SwiftUI

@main
struct PianwaiApp: App {
    @State private var library = Self.libraryForLaunch()
    @State private var sourceAvailabilityService = Self.sourceAvailabilityForLaunch()

    private static func libraryForLaunch() -> Library {
        // Covers fetched once stay on the device (see LeadArtwork.warm).
        URLCache.shared = URLCache(memoryCapacity: 48 << 20, diskCapacity: 512 << 20)
        let preferences = preferencesForLaunch()
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if preferences !== UserDefaults.standard, arguments.contains("--ui-isolate-data"), arguments.contains("--ui-platform-fixtures") {
            return Library(defaults: preferences, music: NoApplePlatformFixture())
        }
        // Isolated visual failure cases, never real playback or user storage.
        if preferences !== UserDefaults.standard, arguments.contains("--ui-isolate-data"),
           let raw = arguments.first(where: { $0.hasPrefix("--ui-artwork=") }),
           ["missing", "failed"].contains(String(raw.dropFirst(13))) {
            let mode = String(raw.dropFirst(13))
            let library = Library(defaults: preferences)
            let id = WorkID(rawValue: "local:artwork-" + mode)!
            let work = Work(id: id, title: "封面检查", creator: "", kind: "歌曲",
                            art: mode == "failed" ? "https://127.0.0.1:9/unavailable.jpg" : "",
                            detail: "", url: nil, linkedCreatorIDs: [])
            try? library.catalog.merge(CatalogSnapshot(works: [work], relations: []))
            library.explore(id)
            return library
        }
        // 0.3 review: any catalogue song, as "--ui-track=<catalog id>|<title>|<artist>".
        if preferences !== UserDefaults.standard,
           let raw = arguments.first(where: { $0.hasPrefix("--ui-track=") }) {
            let parts = raw.dropFirst(11).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 {
                let library = Library(defaults: preferences, music: SimulatorPlaybackFixture(mode: .poolJP, track: (parts[0], parts[1], parts[2])))
                DiscoveryReviewReplay.preload(library.catalog)
                return library
            }
        }
        // Both opt-in flags are required; no fixture ever uses real preferences.
        if preferences !== UserDefaults.standard,
           let raw = arguments.first(where: { $0.hasPrefix("--ui-playback=") }),
           let mode = SimulatorPlaybackFixture.Mode(rawValue: String(raw.dropFirst(14))) {
            let playback = SimulatorPlaybackFixture(mode: mode)
            let library = Library(defaults: preferences, music: playback)
            if arguments.contains("--ui-reset") {
                if mode == .libraryArtwork {
                    library.receivePlayback(playback.snapshot)
                    library.explore(WorkID(rawValue: "apple:song:1857886409")!)
                } else {
                    library.explore(.pool)
                    library.open(mode == .unidentified ? .film : .jane)
                }
            }
            return library
        }
        #endif
        return Library(defaults: preferences)
    }

    private static func preferencesForLaunch() -> UserDefaults {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let suite = isolatedUISuite(arguments), let preferences = UserDefaults(suiteName: suite) {
            if arguments.contains("--ui-reset") { preferences.removePersistentDomain(forName: suite) }
            if arguments.contains("--ui-isolate-data"),
               let raw = arguments.first(where: { $0.hasPrefix("--ui-platform=") }),
               let platform = PlaybackPlatform(rawValue: String(raw.dropFirst("--ui-platform=".count))) {
                preferences.set(platform.rawValue, forKey: "playback.platform.v1")
            }
            return preferences
        }
        #endif
        return .standard
    }

    private static func isolatedUISuite(_ arguments: [String]) -> String? {
        guard let argument = arguments.first(where: { $0.hasPrefix("--ui-state=") }) else { return nil }
        let name = String(argument.dropFirst(11))
        guard !name.isEmpty, name.count <= 80,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return "Pianwai.UIReview." + name
    }

    private static func sourceAvailabilityForLaunch() -> SourceAvailabilityService {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        // An independent valid preferences suite and explicit response mode are
        // both required. This does not reset preferences a second time or alter
        // the original source, claim, URL, or external-opening action.
        if let suite = isolatedUISuite(arguments), UserDefaults(suiteName: suite) != nil,
           let raw = arguments.first(where: { $0.hasPrefix("--ui-source-response=") }) {
            let mode = String(raw.dropFirst("--ui-source-response=".count))
            if ["404", "403", "timeout"].contains(mode) {
                return SourceAvailabilityService(loadResponse: { request in
                    try Task.checkCancellation()
                    if mode == "timeout" { throw URLError(.timedOut) }
                    guard let url = request.url, let status = Int(mode),
                          let response = HTTPURLResponse(url: url, statusCode: status,
                                                         httpVersion: "HTTP/1.1", headerFields: nil) else {
                        throw URLError(.badServerResponse)
                    }
                    return response
                })
            }
        }
        #endif
        return .shared
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-designGallery") {
                    DesignGallery()
                } else { RootView() }
                #else
                RootView()
                #endif
            }
                .environment(library)
                .environment(\.sourceAvailabilityService, sourceAvailabilityService)
                .tint(library.visualDirection.accent)
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("-designGallery") { return }
                    #endif
                    library.startServices()
                }
        }
    }
}
