import Foundation

/// Only the visible answer and transport-supplied citations are retained. Never
/// store the request, authorization headers, full provider response or reasoning.
struct DiscoveryEvidenceCache: Sendable {
    struct Entry: Codable, Sendable {
        let subject: LeadSubject
        let namespace: String
        let visibleText: String
        let observedURLs: [String]
        let usage: DiscoveryUsage?
        let researchSeconds: Double
        let fetchedAt: Date
        var completed = true
        /// Provenance only: preferences never invalidate or spend cached answers.
        var writingProfileID: String? = nil
        var fingerprint: String { DiscoveryCore.digest([visibleText] + observedURLs.sorted()) }

        func decode() throws -> LeadResearchClient.Raw {
            guard completed, var result = DiscoveryResponseDecoder.decode(visibleText) else { throw LeadResearchClient.Failure.badReply }
            result.observedURLs = observedURLs
            result.transportUsage = usage
            result.searchCalls = usage?.webToolCalls
            result.outputTokens = usage?.outputTokens
            return result
        }
    }
    let directory: URL?
    static var runtime: Self { .init(directory: PianwaiRuntime.applicationDirectory("LeadEvidence")) }

    func file(_ subject: LeadSubject, namespace: String) -> URL? {
        // Processor/prompt revisions must be able to reuse the same paid answer.
        let key = DiscoveryCore.digest(["evidence-v2", namespace, subject.id, subject.kind.rawValue,
            subject.identity?.layer.rawValue ?? (subject.kind == .song ? "recording" : subject.kind.rawValue)])
        return directory?.appendingPathComponent(key + ".json")
    }
    func read(_ subject: LeadSubject, namespace: String) -> Entry? {
        func compatible(_ entry: Entry) -> Bool {
            guard entry.namespace == namespace, entry.subject.id == subject.id, entry.subject.kind == subject.kind else { return false }
            // The exact store ID survives changes to display language/credits.
            // Such changes must not spend the same search again.
            if let id = WorkID(rawValue: subject.id), id.rawValue.hasPrefix("apple:song:") { return true }
            guard LeadMatch.same(entry.subject.title, subject.title, loose: false),
                  LeadMatch.norm(entry.subject.creator) == LeadMatch.norm(subject.creator) else { return false }
            // A system-library observation can acquire its missing album later.
            return entry.subject.album == subject.album
                || subject.id.hasPrefix("local:") && (entry.subject.album.isEmpty || subject.album.isEmpty)
        }
        if let url = file(subject, namespace: namespace), let data = try? Data(contentsOf: url),
           let entry = try? JSONDecoder().decode(Entry.self, from: data), compatible(entry) { return entry }
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Entry? in
            guard let bytes = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: bytes), compatible(entry) else { return nil }
            return entry
        }.max { $0.fetchedAt < $1.fetchedAt }
    }
    func write(_ entry: Entry) {
        guard let url = file(entry.subject, namespace: entry.namespace), let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let oldData = try? Data(contentsOf: url),
           let old = try? JSONDecoder().decode(Entry.self, from: oldData),
           old.visibleText != entry.visibleText, (try? old.decode()) != nil {
            archive(old)
            try? oldData.write(to: url.deletingLastPathComponent().appendingPathComponent("last-good-" + url.lastPathComponent), options: .atomic)
        }
        archive(entry)
        try? data.write(to: url, options: .atomic)
    }
    private func answerDirectory(_ subject: LeadSubject, namespace: String) -> URL? {
        file(subject, namespace: namespace).map { $0.deletingLastPathComponent().appendingPathComponent("answers/" + $0.deletingPathExtension().lastPathComponent) }
    }
    private func archive(_ entry: Entry) {
        guard (try? entry.decode()) != nil, let folder = answerDirectory(entry.subject, namespace: entry.namespace),
              let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(entry.fingerprint + ".json")
        if !FileManager.default.fileExists(atPath: file.path) { try? data.write(to: file, options: .atomic) }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in ordered.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }
    /// Reprocess all retained distinct answers. Facts whose older answer has
    /// rotated out are left in the catalog, not silently deleted.
    func answers(_ subject: LeadSubject, namespace: String) -> [Entry] {
        var result: [String: Entry] = [:]
        if let latest = read(subject, namespace: namespace), (try? latest.decode()) != nil { result[latest.fingerprint] = latest }
        if let previous = recovery(subject, namespace: namespace) { result[previous.fingerprint] = previous }
        var files: [URL] = []
        for folder in [directory, answerDirectory(subject, namespace: namespace)].compactMap({ $0 }) {
            files += (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        }
        for file in files {
                guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      entry.subject.id == subject.id, entry.subject.kind == subject.kind, entry.namespace == namespace,
                      subject.id.hasPrefix("apple:song:") || (LeadMatch.same(entry.subject.title, subject.title, loose: false)
                        && LeadMatch.norm(entry.subject.creator) == LeadMatch.norm(subject.creator)
                        && (entry.subject.album == subject.album || subject.id.hasPrefix("local:") && (entry.subject.album.isEmpty || subject.album.isEmpty))),
                      (try? entry.decode()) != nil else { continue }
                result[entry.fingerprint] = entry
        }
        return Array(result.values.sorted { $0.fetchedAt < $1.fetchedAt }.suffix(5))
    }
    /// A malformed newer answer must not destroy an older paid, readable answer.
    /// Uses the same identity compatibility rules, never another provider call.
    func recovery(_ subject: LeadSubject, namespace: String) -> Entry? {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Entry? in
            guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.namespace == namespace, entry.subject.id == subject.id, entry.subject.kind == subject.kind,
                  (try? entry.decode()) != nil else { return nil }
            if !subject.id.hasPrefix("apple:song:") {
                guard LeadMatch.same(entry.subject.title, subject.title, loose: false),
                      LeadMatch.norm(entry.subject.creator) == LeadMatch.norm(subject.creator),
                      entry.subject.album == subject.album else { return nil }
            }
            return entry
        }.max { $0.fetchedAt < $1.fetchedAt }
    }
    func save(_ raw: LeadResearchClient.Raw, subject: LeadSubject, namespace: String, seconds: Double) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        write(.init(subject: subject, namespace: namespace, visibleText: String(decoding: data, as: UTF8.self),
            observedURLs: raw.observedURLs ?? [], usage: raw.transportUsage, researchSeconds: seconds, fetchedAt: Date()))
    }
}
