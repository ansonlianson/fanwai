import Foundation
import Observation

/// A catalogue candidate is a selectable version, never a new performance
/// fact. The picker, representative cover and one-hop prefetch share this cache.
@MainActor @Observable
final class RecordingVersionsStore {
    static let shared = RecordingVersionsStore()
    struct Versions: Sendable {
        var known: [WorkID] = []
        var candidates: [WorkID] = []
    }
    private(set) var revision = 0
    @ObservationIgnored private var saved: [String: Saved] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL?
    init(directory: URL? = PianwaiRuntime.cacheDirectory("RecordingVersions-v1")) { self.directory = directory }

    func versions(for work: Work, library: Library) -> Versions {
        let work = RecordingCatalogMatch.source(work, catalog: library.catalog)
        let catalog = library.catalog, id = catalog.canonicalID(for: work.id)
        let edges = catalog.relations(touching: id).filter { $0.to == id && $0.predicate == .performanceOf }
        var known = Array(Set(edges.map { catalog.canonicalID(for: $0.from) }))
            .filter { catalog.work($0).appleMusicURL != nil }.sorted { order(catalog.work($0), catalog.work($1)) }
        if work.appleMusicURL != nil, !known.contains(id) { known.insert(id, at: 0) }
        let cached = saved[key(work, country: library.country)]?.ids ?? []
        let artists = Set(saved[key(work, country: library.country)]?.artistIDs ?? [])
        // Existing exact store results can already be available from another
        // page or a prior picker. Reuse without another network request.
        let local = catalog.works.values.filter {
            $0.isSong && $0.appleMusicURL != nil && RecordingCatalogMatch.matchesCandidate($0, source: work)
                && credited($0, source: work, artists: artists)
        }
            .sorted(by: order).map(\.id)
        var seen = Set(known)
        let candidates = (cached + local).map { catalog.canonicalID(for: $0) }.filter {
            seen.insert($0).inserted && catalog.work($0).appleMusicURL != nil
                && RecordingCatalogMatch.matchesCandidate(catalog.work($0), source: work)
                && credited(catalog.work($0), source: work, artists: artists)
        }
        return Versions(known: Array(known.prefix(5)), candidates: Array(candidates.prefix(max(0, 5 - known.count))))
    }

    /// The card's credit, or (for a song) the artist number the US store gives that credit:
    /// the Japanese store writes The Who as ザ・フー.
    private func credited(_ candidate: Work, source: Work, artists: Set<String>) -> Bool {
        if source.isMusicWork { return Self.qualifiesAsRepresentative(candidate, source: source) }
        if ScriptFold.sameCredits(candidate.creator, source.creator) { return true }
        guard let artist = candidate.catalogTrack?.artistID else { return false }
        return artists.contains(artist)
    }

    func restore(_ work: Work, library: Library) {
        let work = RecordingCatalogMatch.source(work, catalog: library.catalog)
        let key = key(work, country: library.country)
        guard saved[key] == nil, let file = file(key), let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Saved.self, from: data), entry.key == key,
              Date().timeIntervalSince(entry.date) >= 0,
              Date().timeIntervalSince(entry.date) < (entry.ids.isEmpty ? 86_400 : 7 * 86_400) else { return }
        try? library.catalog.merge(.init(works: entry.works, relations: []), persist: false)
        saved[key] = entry; revision += 1
        publishCover(work, library: library)
    }

    func load(_ work: Work, library: Library, prefetch: Bool = false, force: Bool = false) async {
        let work = RecordingCatalogMatch.source(work, catalog: library.catalog)
        guard work.isSong || work.isMusicWork else { return }
        restore(work, library: library)
        publishCover(work, library: library)
        if work.isSong, work.appleMusicURL != nil { return }
        let key = key(work, country: library.country)
        if let task = tasks[key] { await task.value; return }
        if !force, let entry = saved[key], Date().timeIntervalSince(entry.date) < (entry.ids.isEmpty ? 86_400 : 7 * 86_400) { return }
        let before = versions(for: work, library: library)
        if before.known.count >= 5 { return }
        if prefetch, !PrefetchQueryBudget.charge() { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[key] = nil }
            do {
                let ids = try await library.catalog.search(RecordingCatalogMatch.query(for: work), country: library.country,
                    kind: .song, persist: false, candidateOnly: true)
                try Task.checkCancellation()
                let credited: @MainActor (WorkID, Set<String>) -> Bool = { id, artists in
                    let candidate = library.catalog.work(id)
                    return candidate.appleMusicURL != nil && RecordingCatalogMatch.matchesCandidate(candidate, source: work)
                        && self.credited(candidate, source: work, artists: artists)
                }
                var artists = Set<String>()
                var matches = ids.filter { credited($0, []) }
                if matches.isEmpty, work.isSong, ArtistStoreNames.needsBridge(creator: work.creator, country: library.country),
                   ids.contains(where: { RecordingCatalogMatch.matchesCandidate(library.catalog.work($0), source: work) }) {
                    artists = await ArtistStoreNames.artistIDs(named: work.creator, title: work.discovery?.canonicalTitle ?? work.title, country: library.country)
                    try Task.checkCancellation()
                    matches = ids.filter { credited($0, artists) }
                }
                let selected = Array(matches.sorted { self.order(library.catalog.work($0), library.catalog.work($1)) }.prefix(5))
                var records = selected.map { library.catalog.work($0) }
                records += Set(records.compactMap(\.albumID)).map { library.catalog.work($0) }
                let entry = Saved(key: key, ids: selected, works: records, date: Date(), artistIDs: artists.isEmpty ? nil : artists.sorted())
                self.saved[key] = entry; self.revision += 1
                if let file = self.file(key), let data = try? JSONEncoder().encode(entry) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                self.publishCover(work, library: library)
            } catch { /* A cancellation or transport error is not a cached absence. */ }
        }
        tasks[key] = task
        await task.value
    }

    /// Playback follows the recording whose cover is already on the page.
    /// A merely similar picker result never becomes a default recording.
    func preferredRecording(for work: Work, library: Library) -> WorkID? {
        _ = revision
        let work = RecordingCatalogMatch.source(work, catalog: library.catalog)
        guard work.isMusicWork else { return nil }
        let records = representativeRecordings(work, library: library)
        if let raw = WorkArtworkStore.shared.representativeWorks[work.id]?.rawMetadata?["recordingID"],
           let id = WorkID(rawValue: raw),
           let matching = records.first(where: { $0.id == library.catalog.canonicalID(for: id) }) {
            return matching.id
        }
        return records.first?.id
    }

    private func representativeRecordings(_ work: Work, library: Library) -> [Work] {
        let versions = versions(for: work, library: library), catalog = library.catalog
        let exact = versions.known.map { catalog.work($0) }.filter { representative($0, source: work, sourced: true) }
        let candidates = versions.candidates.map { catalog.work($0) }.filter { representative($0, source: work, sourced: false) }
        return (exact.isEmpty ? candidates : exact).sorted(by: order)
    }

    private func publishCover(_ work: Work, library: Library) {
        guard work.isMusicWork, work.art.isEmpty else { return }
        for record in representativeRecordings(work, library: library) {
            let album = record.albumID.map { library.catalog.work($0) }
            let cover = [record.art, album?.art ?? ""].first { ArtworkLocation.remoteURL(URL(string: $0)) != nil }
                ?? (!record.art.isEmpty ? record.art : nil)
            guard let cover, let url = record.appleMusicURL else { continue }
            WorkArtworkStore.shared.useRepresentative(cover, for: work.id, recording: record.id, source: url)
            return
        }
    }

    static func qualifiesAsRepresentative(_ candidate: Work, source: Work, sourced: Bool = false) -> Bool {
        guard source.isMusicWork, RecordingCatalogMatch.matchesCandidate(candidate, source: source) else { return false }
        let credit = source.discovery?.composer.isEmpty == false ? source.discovery!.composer : source.creator
        if !sourced && !ScriptFold.sameCredits(candidate.creator, credit) { return false }
        let derivative = #"(?i)\blive\b|\bremix\b|\bcover\b|\bpiano\b|\bacoustic\b|\barrange(?:ment)?\b|现场|現場|ライブ|混音|翻唱|钢琴|鋼琴|ピアノ|アレンジ"#
        let candidateIsDerived = candidate.title.range(of: derivative, options: .regularExpression) != nil
        let sourceIsDerived = (source.title + " " + (source.discovery?.edition ?? "")).range(of: derivative, options: .regularExpression) != nil
        return !candidateIsDerived || sourceIsDerived
    }
    private func representative(_ item: Work, source: Work, sourced: Bool) -> Bool {
        Self.qualifiesAsRepresentative(item, source: source, sourced: sourced)
    }
    private func order(_ a: Work, _ b: Work) -> Bool {
        let left = a.releaseDate ?? "9999", right = b.releaseDate ?? "9999"
        return left == right ? a.id.rawValue < b.id.rawValue : left < right
    }
    private func key(_ work: Work, country: String) -> String {
        DiscoveryCore.digest([work.id.rawValue, country, work.discovery?.canonicalTitle ?? work.title,
            work.discovery?.composer.isEmpty == false ? work.discovery!.composer : work.creator,
            work.discovery?.catalogue ?? "", work.discovery?.layer.rawValue ?? work.kind, work.discovery?.edition ?? "",
            (work.discovery?.aliases ?? []).map(LeadMatch.norm).sorted().joined(separator: "|"),
            "credit-v2"])
    }
    private func file(_ key: String) -> URL? { directory?.appendingPathComponent(key + ".json") }
    private struct Saved: Codable {
        let key: String; let ids: [WorkID]; let works: [Work]; let date: Date
        /// Artist numbers the US store gives the card's credit (when the local store renames the artist).
        var artistIDs: [String]? = nil
    }
}
