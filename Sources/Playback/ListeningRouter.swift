import SwiftUI

@MainActor @Observable final class ListeningRouter {
    struct Choice: Identifiable {
        let id: UUID
        let work: Work
        let platform: PlaybackPlatform
        let candidates: [PlatformRecording]
        let query: String
    }
    struct Handoff: Identifiable {
        let id = UUID()
        let platform: PlaybackPlatform
        let url: URL
    }
    struct Receipt {
        let id = UUID()
        let platform: PlaybackPlatform
        let url: URL
        let accepted: Bool
    }
    var choice: Choice?
    var handoff: Handoff?
    private(set) var lastReceipt: Receipt?
    private(set) var busy = false
    private let store: ListeningDestinationStore
    private let catalog: DomesticMusicCatalog
    private var ticket = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    init(defaults: UserDefaults, catalog: DomesticMusicCatalog) {
        store = .init(defaults: defaults); self.catalog = catalog
    }
    func cancel() {
        ticket = UUID(); task?.cancel(); busy = false; choice = nil; handoff = nil
    }
    static func exactDestination(_ work: Work, platform: PlaybackPlatform, stored: ListeningDestination?) -> URL? {
        if let stored, stored.platform == platform, stored.evidence == .userConfirmed, stored.valid { return stored.url }
        if let original = work.platformRecording, original.platform == platform,
           PlatformSongLink.parse(original.url).map(original.matches) == true { return original.url }
        return nil
    }
    func begin(_ work: Work, platform: PlaybackPlatform, apple: @escaping @MainActor () async -> URL?) {
        cancel(); let current = ticket
        if platform != .apple, let url = Self.exactDestination(work, platform: platform, stored: store.destination(work.id, platform: platform)) {
            handoff = .init(platform: platform, url: url); return
        }
        busy = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if platform == .apple {
                let url = await apple()
                guard !Task.isCancelled, current == ticket else { return }
                busy = false
                if let url { handoff = .init(platform: platform, url: url) }
                return
            }
            let query = [work.title, work.creator].filter { !$0.isEmpty }.joined(separator: " ")
            let candidates = (try? await catalog.search(query, platform: platform)) ?? []
            guard !Task.isCancelled, current == ticket else { return }
            busy = false
            let ranked = candidates.filter { $0.platform == platform && PlatformRecording.ranking(work, candidate: $0) > 0 }
                .sorted { PlatformRecording.ranking(work, candidate: $0) > PlatformRecording.ranking(work, candidate: $1) }
            choice = .init(id: current, work: work, platform: platform, candidates: Array(ranked.prefix(3)), query: query)
        }
    }
    func choose(_ recording: PlatformRecording, from request: Choice) {
        guard request.id == ticket, request.platform == recording.platform,
              request.candidates.contains(recording) else { return }
        store.confirm(recording, for: request.work.id)
        choice = nil; handoff = .init(platform: request.platform, url: recording.url)
    }
    func search(_ request: Choice) {
        guard request.id == ticket else { return }
        choice = nil; handoff = .init(platform: request.platform, url: request.platform.searchURL(request.query))
    }
    func retry(_ request: Choice) {
        guard request.id == ticket else { return }
        begin(request.work, platform: request.platform, apple: { nil })
    }
    func received(_ request: Handoff, accepted: Bool) {
        lastReceipt = .init(platform: request.platform, url: request.url, accepted: accepted)
    }
}

extension Library {
    func listen(_ rawID: WorkID) {
        let source = catalog.work(catalog.canonicalID(for: rawID))
        let id = RecordingVersionsStore.shared.preferredRecording(for: source, library: self) ?? source.id
        let work = catalog.work(id)
        listening.begin(work, platform: playbackPlatform) { [weak self] in
            guard let self else { return nil }
            if await playLinkedMusic(id) { return nil }
            return work.appleMusicURL
        }
    }
    func importMusicShare(_ text: String) async throws -> WorkID {
        guard let url = PlatformSongLink.importURL(in: text) else { throw CatalogError.invalidLink }
        if PlatformSongLink.parse(url) != nil || PlatformSongLink.isShort(url) {
            let recording = try await domesticCatalog.importSong(url)
            try catalog.merge(.init(works: [recording.work], relations: []))
            return recording.work.id
        }
        return try await catalog.importLink(url.absoluteString, country: country)
    }
}

struct ListeningDestinationPresenter: ViewModifier {
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    func body(content: Content) -> some View {
        @Bindable var router = library.listening
        content
            .onChange(of: router.handoff?.id) { _, _ in
                guard let request = router.handoff else { return }
                router.handoff = nil
                openURL(request.url) { accepted in router.received(request, accepted: accepted) }
            }
            .sheet(item: $router.choice) { request in
                NavigationStack {
                    List {
                        ForEach(request.candidates) { recording in
                            Button([recording.title, recording.artists.joined(separator: "、"), recording.album].joined(separator: " · ")) {
                                router.choose(recording, from: request)
                            }.accessibilityIdentifier("listening-version-" + recording.id)
                        }
                        Button(request.platform.searchTitle) { router.search(request) }
                            .accessibilityIdentifier("listening-platform-search")
                        Button("重试") { router.retry(request) }
                    }
                    .navigationTitle("选择版本").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { router.cancel() } } }
                }
            }
    }
}
