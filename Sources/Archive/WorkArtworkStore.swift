import Foundation
import Observation

/// Stores source and image-location metadata only. Image bodies remain the
/// responsibility of the image loader, outside this cache.
@MainActor @Observable
final class WorkArtworkStore {
    static let shared = WorkArtworkStore()
    private(set) var values: [String: WorkArtworkResponse] = [:]
    private(set) var loading = Set<String>()
    private(set) var errors: [String: String] = [:]
    /// iTunes artist ID → Apple artist photo URL ("" when the artist has none).
    private(set) var appleArtists: [String: String] = [:]
    private(set) var officialWorks: [WorkID: WorkArtwork] = [:]
    private(set) var representativeWorks: [WorkID: WorkArtwork] = [:]
    @ObservationIgnored private var workTasks: [WorkID: Task<Void, Never>] = [:]
    @ObservationIgnored private var workDates: [WorkID: Date] = [:]
    @ObservationIgnored private var workIdentities: [WorkID: String] = [:]
    @ObservationIgnored private let officialService: OfficialWorkArtwork
    @ObservationIgnored private var appleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let service: any WorkArtworkFetching
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var failed: [String: Date] = [:]

    init(service: any WorkArtworkFetching = WorkArtworkService(),
         directory: URL? = PianwaiRuntime.cacheDirectory("PianwaiArtwork"),
         officialService: OfficialWorkArtwork = OfficialWorkArtwork()) {
        self.service = service
        self.directory = directory
        self.officialService = officialService
    }

    func metadata(for work: Work) -> WorkArtwork? {
        representativeWorks[work.id] ?? officialWorks[work.id] ?? work.knowledgeID.flatMap { values[$0]?.artwork }
    }

    func useRepresentative(_ cover: String, for work: WorkID, recording: WorkID, source: URL) {
        representativeWorks[work] = .init(id: "representative:" + recording.rawValue, fileTitle: "专辑封面",
            thumbnailURL: cover, sourcePageURL: source.absoluteString, articleURL: source.absoluteString,
            artist: nil, credit: "选取版本的专辑封面", licenseName: nil, licenseURL: nil, isNonFree: nil,
            width: 600, height: 600, rawMetadata: ["recordingID": recording.rawValue])
    }

    /// Caller has verified the video's own title, not just a citing article.
    func useVerifiedVideo(_ source: URL, for work: WorkID) {
        guard let frame = LeadArtwork.videoFrame(source.absoluteString) else { return }
        officialWorks[work] = .init(id: "video:" + source.absoluteString, fileTitle: "视频缩略图",
            thumbnailURL: frame, sourcePageURL: source.absoluteString, articleURL: source.absoluteString,
            artist: nil, credit: "视频页面缩略图", licenseName: nil, licenseURL: nil, isNonFree: nil, width: 480, height: 360)
    }

    func loadWork(_ work: Work, primaryFailed: Bool = false, retry: Bool = false) async {
        guard work.art.isEmpty || primaryFailed else { return }
        let identity = [work.knowledgeID ?? "", work.appleArtistID ?? "", work.bangumiID ?? "", OfficialWorkArtwork.publisherPage(work)?.absoluteString ?? "", work.discovery?.identitySource ?? "", work.title, String(primaryFailed)].joined(separator: "|")
        if let task = workTasks[work.id] {
            await task.value
            if workIdentities[work.id] == identity { return }
        }
        if !retry, workIdentities[work.id] == identity, let date = workDates[work.id],
           Date().timeIntervalSince(date) < (metadata(for: work) == nil ? 300 : 86_400 * 7) { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.workTasks[work.id] = nil; self.workDates[work.id] = Date(); self.workIdentities[work.id] = identity }
            if let id = work.appleArtistID {
                await self.loadAppleArtist(id)
                if self.appleArtists[id]?.isEmpty == false { return }
            }
            let publisher = OfficialWorkArtwork.publisherPage(work) != nil
            let officialEligible = !work.isPerson && (publisher || work.bangumiID != nil || work.knowledgeID != nil)
            let file = self.directory?.appendingPathComponent("official-work-" + DiscoveryCore.digest([work.id.rawValue, work.discovery?.identitySource ?? ""]) + ".json")
            if let file, let data = try? Data(contentsOf: file),
               let cached = try? JSONDecoder().decode(StoredOfficial.self, from: data),
               cached.workID == work.id, cached.title == work.title, cached.identity == identity, officialEligible,
               (0..<86_400 * 7).contains(Date().timeIntervalSince(cached.fetchedAt)) {
                self.officialWorks[work.id] = cached.artwork; return
            }
            if officialEligible {
                let official = self.officialService
                var sources: [@Sendable () async -> WorkArtwork?] = [{ try? await official.fetch(work) }]
                if let qid = work.knowledgeID {
                    sources.append { @MainActor [weak self] in
                        guard let self else { return nil }
                        await self.load(qid, retry: retry)
                        return self.values[qid]?.artwork
                    }
                }
                if let art = await MetadataDeadline.first(seconds: 8, operations: sources), !Task.isCancelled {
                    self.officialWorks[work.id] = art
                    if let directory = self.directory, let file {
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        if let data = try? JSONEncoder().encode(StoredOfficial(workID: work.id, title: work.title, artwork: art, fetchedAt: Date(), identity: identity)) {
                            try? data.write(to: file, options: .atomic)
                        }
                    }
                    return
                }
            }
            if !officialEligible, let qid = work.knowledgeID { await self.load(qid, retry: retry) }
        }
        workTasks[work.id] = task
        await task.value
    }

    private struct StoredOfficial: Codable {
        let workID: WorkID; let title: String; let artwork: WorkArtwork; let fetchedAt: Date
        var identity: String? = nil
    }

    func load(_ qid: String, retry: Bool = false) async {
        guard WorkContextService.validQID(qid) else { return }
        if let task = tasks[qid] { await task.value; return }
        // A failed optional source waits five minutes or an explicit retry,
        // instead of repeatedly requesting it whenever a view reappears.
        if !retry, let date = failed[qid], Date().timeIntervalSince(date) < 300 { return }
        let file = directory?.appendingPathComponent(qid + ".json")
        if values[qid] == nil, let file, let data = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode(StoredArtwork.self, from: data),
            [1, 2, 3, 4].contains(cached.version), cached.response.qid == qid {
            values[qid] = cached.response
            // Old empty results predate broader discovery and fallback. Keep
            // successful images, but refresh v1/v2 empty results immediately.
            if cached.version == 4 || cached.response.artwork != nil {
                fetchedAt[qid] = cached.fetchedAt
            }
        }
        if !retry, values[qid] != nil, let date = fetchedAt[qid] {
            let age = Date().timeIntervalSince(date)
            if age >= 0, age < (values[qid]?.artwork == nil ? 300 : 86_400 * 7) { return }
        }
        loading.insert(qid)
        errors[qid] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.loading.remove(qid); self.tasks[qid] = nil }
            do {
                let response = try await self.boundedArtwork(qid)
                try Task.checkCancellation()
                guard response.qid == qid else { throw WorkArtworkError.identityMismatch }
                let date = Date()
                self.values[qid] = response
                self.fetchedAt[qid] = date
                self.failed[qid] = nil
                // A cache write failure must never discard a visible result.
                if let directory = self.directory, let file {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(StoredArtwork(response: response, fetchedAt: date)) {
                        try? data.write(to: file, options: .atomic)
                    }
                }
            } catch is CancellationError {
                self.failed[qid] = nil
            } catch {
                self.errors[qid] = "图片资料暂未载入"
                self.failed[qid] = Date()
            }
        }
        tasks[qid] = task
        await task.value
    }

    private func boundedArtwork(_ qid: String) async throws -> WorkArtworkResponse {
        let service = service
        guard let result = await MetadataDeadline.value(seconds: 8, operation: { try? await service.fetch(qid: qid) }) else { throw WorkArtworkError.invalidResponse }
        return result
    }

    func loadAppleArtist(_ artistID: String) async {
        guard !artistID.isEmpty, artistID.allSatisfy(\.isNumber) else { return }
        if appleArtists[artistID] != nil { return }
        if let task = appleTasks[artistID] { await task.value; return }
        struct Stored: Codable { let url: String; let fetchedAt: Date }
        let file = directory?.appendingPathComponent("apple-artist-" + artistID + ".json")
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
           Date().timeIntervalSince(stored.fetchedAt) < 86_400 * 7 {
            appleArtists[artistID] = stored.url; return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.appleTasks[artistID] = nil }
            guard let url = try? await self.service.appleArtistPhoto(artistID: artistID) else { return }
            self.appleArtists[artistID] = url ?? ""
            if let directory = self.directory, let file, let data = try? JSONEncoder().encode(Stored(url: url ?? "", fetchedAt: Date())) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
        appleTasks[artistID] = task
        await task.value
    }

    private struct StoredArtwork: Codable {
        var version = 4
        let response: WorkArtworkResponse
        let fetchedAt: Date
    }
}
