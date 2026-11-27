import Foundation
import UIKit

/// A feedback payload is built from these fields only. Never encode Library,
/// model settings, provider requests or a raw diagnostic log.
enum ResultFeedbackReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case story, relation, artwork, missing, loading, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .story: "故事有误"
        case .relation: "关联不对"
        case .artwork: "封面不对／缺图"
        case .missing: "没找到想要的"
        case .loading: "加载／使用异常"
        case .other: "其他"
        }
    }
}
struct ResultFeedbackWork: Codable, Sendable {
    let id: String
    let title: String
    let creator: String
    let album: String
    let kind: String
    let artworkURL: String
    let sourceURL: String

    @MainActor init(_ entity: SeedGraph.Entity, work: Work, catalog: CatalogStore, album: String = "") {
        id = ResultFeedbackPrivacy.text(entity.id, limit: 240)
        title = ResultFeedbackPrivacy.text(entity.title, limit: 500)
        creator = ResultFeedbackPrivacy.text(entity.subtitle, limit: 500)
        self.album = ResultFeedbackPrivacy.text(album, limit: 500)
        kind = entity.kind.rawValue
        artworkURL = ResultFeedbackPrivacy.url(ArtworkLocation.displayValue(for: work, catalog: catalog) ?? "")
        sourceURL = ResultFeedbackPrivacy.url(work.url ?? "")
    }
}
struct ResultFeedbackSource: Codable, Sendable {
    let title: String
    let url: String
    let quote: String
    init(_ source: Source) {
        title = ResultFeedbackPrivacy.text(source.title, limit: 500)
        url = ResultFeedbackPrivacy.url(source.url)
        quote = ResultFeedbackPrivacy.text(source.evidenceQuote ?? source.detail, limit: 2000)
    }
    private init(title: String, url: String, quote: String) { self.title = title; self.url = url; self.quote = quote }
    var withoutQuote: Self { .init(title: title, url: url, quote: "") }
}
struct ResultFeedbackStory: Codable, Sendable {
    let body: String
    let scope: String
    let subjectID: String
    var sources: [ResultFeedbackSource]
    init(_ snapshot: PullOutStorySnapshot) {
        body = ResultFeedbackPrivacy.text(snapshot.story.body, limit: 16000)
        scope = ResultFeedbackPrivacy.text(snapshot.scope ?? "", limit: 200)
        subjectID = ResultFeedbackPrivacy.text(snapshot.story.entityID, limit: 240)
        sources = Array(([snapshot.story.source] + (snapshot.story.additionalSources ?? [])).prefix(16)).map(ResultFeedbackSource.init)
    }
}
struct ResultFeedbackCard: Codable, Sendable {
    let work: ResultFeedbackWork
    let relation: String
    let detail: String
    let visible: Bool
    let path: [String]
    var sources: [ResultFeedbackSource]
}
struct ResultFeedbackPage: Codable, Sendable {
    let state: String
    let phase: String
    let lastEvent: String
    let storyResult: String
    let startedAt: Date?
    let elapsedSeconds: Double?
    let failures: Int
    let searches: Int?
    var readURLs: [String]
    let unconfirmedCount: Int
    let readingPinned: Bool
}
struct ResultFeedbackApp: Codable, Sendable {
    let version: String
    let build: String
    let systemVersion: String
    let processorVersion: String
    let reportVersion: Int?
    let generatedAt: Date?
    let seconds: Double?
    let model: String
}
struct ResultFeedbackDiagnostic: Codable, Sendable {
    let date: Date
    let phase: String
    let outcome: String
    let processor: String
    let contract: String
    let seconds: Double
    let reusedEvidence: Bool
    let facts: Int
    let hasStory: Bool
    init(_ entry: DiscoveryDiagnostics.Entry) {
        date = entry.date
        phase = ResultFeedbackPrivacy.text(entry.phase, limit: 80)
        outcome = ResultFeedbackPrivacy.text(entry.outcome, limit: 100)
        processor = ResultFeedbackPrivacy.text(entry.processor, limit: 120)
        contract = ResultFeedbackPrivacy.text(entry.contract ?? "", limit: 120)
        seconds = entry.seconds.isFinite ? max(0, entry.seconds) : 0
        reusedEvidence = entry.reusedEvidence; facts = entry.facts; hasStory = entry.hasStory
    }
}
struct ResultFeedbackSnapshot: Codable, Sendable {
    let capturedAt: Date
    let subject: ResultFeedbackWork
    var story: ResultFeedbackStory?
    var cards: [ResultFeedbackCard]
    var page: ResultFeedbackPage
    let app: ResultFeedbackApp
    let platform: String
    let diagnostic: ResultFeedbackDiagnostic?
    var contentTruncated: Bool

    @MainActor static func capture(entity: SeedGraph.Entity, library: Library, story: PullOutStorySnapshot?,
                                   items: [CrateItem], visibleIDs: Set<String>, research: LeadResearch,
                                   readingPinned: Bool, lookupID: String? = nil, now: Date = Date()) -> Self {
        let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id)))
        let rootID = library.catalog.canonicalID(for: SeedLibraryBridge.workID(entity.id))
        let lookup = lookupID ?? entity.id
        let report = research.reports[lookup], job = research.jobs.values[lookup]
        // A reader may still be showing an older pinned story. Do not attribute a
        // newer report's generation/timing to that text. The active job is separate.
        let matchesReport = report != nil && !readingPinned && (story == nil || report?.story?.text == story?.story.body)
        let state: String
        switch research.state(lookup) {
        case .loading: state = "loading"
        case .failed: state = "failed"
        case .empty: state = "empty"
        case .ready: state = "ready"
        case nil: state = story != nil || !items.isEmpty ? "ready" : "pending"
        }
        let info = Bundle.main.infoDictionary
        return .init(capturedAt: now,
            subject: .init(entity, work: work, catalog: library.catalog, album: work.albumID.map { library.catalog.work($0).title } ?? ""),
            story: story.map(ResultFeedbackStory.init),
            cards: items.prefix(80).map { item in
                let target = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(item.entity.id)))
                let path = item.path.prefix(16).map { library.catalog.canonicalID(for: SeedLibraryBridge.workID($0)) }
                let hops = Array(zip(path, path.dropFirst()))
                return ResultFeedbackCard(work: .init(item.entity, work: target, catalog: library.catalog),
                    relation: ResultFeedbackPrivacy.text(item.relation, limit: 120),
                    detail: ResultFeedbackPrivacy.text(item.note, limit: 1500), visible: visibleIDs.contains(item.id),
                    path: path.map { ResultFeedbackPrivacy.text($0.rawValue, limit: 240) },
                    sources: library.catalog.edges.filter { edge in
                        (edge.from == rootID && edge.to == target.id) || (edge.to == rootID && edge.from == target.id)
                        || hops.contains { (edge.from == $0.0 && edge.to == $0.1) || (edge.to == $0.0 && edge.from == $0.1) }
                    }.prefix(12).map { ResultFeedbackSource($0.source) })
            },
            page: .init(state: state, phase: job?.phase.rawValue ?? "", lastEvent: ResultFeedbackPrivacy.text(job?.lastEvent ?? "", limit: 200),
                storyResult: job?.storyResult?.rawValue ?? "", startedAt: job?.startedAt,
                elapsedSeconds: job.map { max(0, now.timeIntervalSince($0.startedAt)) }, failures: job?.failures ?? 0,
                searches: job?.searches, readURLs: Array((job?.pages ?? []).prefix(40)).map(ResultFeedbackPrivacy.url),
                unconfirmedCount: research.unconfirmedLeads(lookup).count, readingPinned: readingPinned),
            app: .init(version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info?["CFBundleVersion"] as? String ?? "unknown", systemVersion: UIDevice.current.systemVersion,
                processorVersion: matchesReport ? (report?.processorVersion ?? "") : "",
                reportVersion: matchesReport ? report?.version : nil, generatedAt: matchesReport ? report?.fetchedAt : nil,
                seconds: matchesReport ? report?.seconds : nil, model: ""),
            platform: library.playbackPlatform.rawValue,
            diagnostic: research.feedbackDiagnostic(lookup, library: library).map(ResultFeedbackDiagnostic.init),
            contentTruncated: items.count > 80)
    }

    /// Keep the entire request within the receiver's bound. Preserve the story
    /// and card identities first; mark any omitted evidence explicitly for debug.
    func boundedForDelivery() -> Self {
        var result = self
        let encoder = ResultFeedbackOutbox.encoder()
        func fits(_ snapshot: Self) -> Bool { (try? encoder.encode(snapshot).count).map { $0 <= 112 * 1024 } ?? false }
        guard !fits(result) else { return result }
        result.contentTruncated = true
        if var story = result.story { story.sources = story.sources.map(\.withoutQuote); result.story = story }
        result.cards = result.cards.map { card in var c = card; c.sources = c.sources.map(\.withoutQuote); return c }
        while !fits(result), !result.cards.isEmpty { result.cards.removeLast() }
        while !fits(result), !result.page.readURLs.isEmpty { result.page.readURLs.removeLast() }
        while !fits(result), result.story?.sources.isEmpty == false { result.story?.sources.removeLast() }
        return result
    }
}
struct ResultFeedbackDraft: Identifiable, Sendable {
    let id = UUID()
    let snapshot: ResultFeedbackSnapshot
}
struct ResultFeedbackSubmission: Codable, Sendable {
    var schemaVersion: Int { 1 }
    let id: UUID
    let installationID: UUID
    let reasons: [ResultFeedbackReason]
    let note: String
    let submittedAt: Date
    let snapshot: ResultFeedbackSnapshot
    enum CodingKeys: String, CodingKey { case schemaVersion, id, installationID, reasons, note, submittedAt, snapshot }
    init(id: UUID, installationID: UUID, reasons: [ResultFeedbackReason], note: String, submittedAt: Date, snapshot: ResultFeedbackSnapshot) {
        self.id = id; self.installationID = installationID; self.reasons = reasons; self.note = note
        self.submittedAt = submittedAt; self.snapshot = snapshot
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported feedback schema") }
        id = try c.decode(UUID.self, forKey: .id); installationID = try c.decode(UUID.self, forKey: .installationID)
        reasons = try c.decode([ResultFeedbackReason].self, forKey: .reasons); note = try c.decode(String.self, forKey: .note)
        submittedAt = try c.decode(Date.self, forKey: .submittedAt); snapshot = try c.decode(ResultFeedbackSnapshot.self, forKey: .snapshot)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(installationID, forKey: .installationID)
        try c.encode(reasons, forKey: .reasons); try c.encode(note, forKey: .note)
        try c.encode(submittedAt, forKey: .submittedAt); try c.encode(snapshot, forKey: .snapshot)
    }
}

enum ResultFeedbackPrivacy {
    private static let secret = try! NSRegularExpression(pattern: #"\b(?:sk-[a-z0-9_-]{8,}|bearer\s+[a-z0-9._~+/-]{8,}|fw_[a-z0-9_-]{12,})"#, options: .caseInsensitive)
    private static let email = try! NSRegularExpression(pattern: #"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#, options: .caseInsensitive)
    static func text(_ raw: String, limit: Int) -> String {
        var text = secret.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "[已隐去]")
        text = email.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[邮箱已隐去]")
        return String(String(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }).prefix(limit))
    }
    static func url(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false else { return "" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        let allowed: Set<String> = ["id", "v", "title", "curid", "oldid", "country", "lang", "t"]
        let safe = (parts.queryItems ?? []).filter { allowed.contains($0.name) && ($0.value?.count ?? 0) < 300 && text($0.value ?? "", limit: 300) == ($0.value ?? "") }
        parts.queryItems = safe.isEmpty ? nil : safe
        let value = parts.string ?? ""
        guard value.count <= 2048, text(parts.path, limit: 2048) == parts.path else { return "" }
        return value
    }
}
