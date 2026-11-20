import Foundation

/// Safe, bounded diagnostics for the stage that failed. Error bodies, URLs,
/// prompts, credentials and provider headers are deliberately never serialized.
struct DiscoveryDiagnostics: Sendable {
    struct Entry: Codable, Sendable {
        let date: Date
        let processor: String
        let phase: String
        let outcome: String
        let seconds: Double
        let reusedEvidence: Bool
        let facts: Int
        let hasStory: Bool
        var consecutiveFailures: Int?
        var subjectKey: String?
        var namespace: String?
        var contract: String?
        var observedSources: Int?
        var newLegalFacts: Int?
        var replayRemoved: Int?
    }
    let directory: URL?
    static var runtime: Self { .init(directory: PianwaiRuntime.applicationDirectory("DiscoveryDiagnostics")) }
    private func file(_ subject: LeadSubject, namespace: String?) -> URL? {
        directory?.appendingPathComponent(DiscoveryCore.digest([namespace ?? "shared", subject.id, subject.kind.rawValue]) + ".json")
    }
    func read(_ subject: LeadSubject, namespace: String? = nil) -> Entry? {
        guard let url = file(subject, namespace: namespace), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
    func suppressesAutomaticQuery(_ subject: LeadSubject, namespace: String? = nil, now: Date = Date()) -> Bool {
        guard let last = read(subject, namespace: namespace), let failures = last.consecutiveFailures, failures > 0 else { return false }
        return failures > 1 || now.timeIntervalSince(last.date) < 30 * 60
    }
    static func category(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? LeadResearchClient.Failure {
            return switch failure { case .noAccess: "access"; case .badReply: "format"; case .http(let code): "http-" + String(code) }
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? "timeout" : error.code == .cancelled ? "cancelled" : "network-" + String(error.code.rawValue)
        }
        if error is DecodingError { return "format" }
        if let error = error as? StoryModelError { return "model-" + String(describing: error) }
        return "processing"
    }
    func write(_ entry: Entry, subject: LeadSubject) {
        var entry = entry
        entry.subjectKey = DiscoveryCore.digest([subject.id, subject.kind.rawValue])
        entry.contract = DiscoveryCore.contractVersion
        guard let directory, let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let url = file(subject, namespace: entry.namespace) else { return }
        try? data.write(to: url, options: .atomic)
        let history = directory.appendingPathComponent("discovery-attempts.jsonl")
        let previous = ((try? Data(contentsOf: history)) ?? Data()).split(separator: 10).suffix(49)
        var lines = Data()
        for line in previous { lines.append(contentsOf: line); lines.append(10) }
        lines.append(data); lines.append(10)
        try? lines.write(to: history, options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = files.filter { $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in ordered.dropFirst(64) { try? FileManager.default.removeItem(at: old) }
    }
}
