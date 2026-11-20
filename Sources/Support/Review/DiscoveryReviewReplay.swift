#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit replay of a paid research response, through the production resolver and
/// navigation. Never bundled, never enabled for ordinary use, and never falls through
/// to a paid query for a downstream page missing from the saved research set.
@MainActor enum DiscoveryReviewReplay {
    static var directory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains("--ui-discovery-replay"),
              let path = ProcessInfo.processInfo.environment["PIANWAI_DISCOVERY_REPLAY"] ?? ProcessInfo.processInfo.environment["PIANWAI_E06_REPLAY"],
              path.hasSuffix("/QA/E06/live") || path.hasSuffix("/QA/E07/replay")
                || path.hasSuffix("/QA/E07/replay/gpt") || path.hasSuffix("/QA/E07/replay/flash")
                || path.hasSuffix("/QA/E08/replay/gpt") || path.hasSuffix("/QA/E08/replay/flash")
                || path.hasSuffix("/QA/E09/profile-replay") || path.hasSuffix("/QA/E10/replay")
                || path.hasSuffix("/QA/E11/replay") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func raw(for subject: LeadSubject) -> LeadResearchClient.Raw {
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasSuffix("-subject.json") {
                guard let data = try? Data(contentsOf: file),
                      let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any], receipt["id"] as? String == subject.id else { continue }
                let name = file.lastPathComponent.replacingOccurrences(of: "-subject.json", with: "-raw.json")
                if let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)),
                   let raw = try? JSONDecoder().decode(LeadResearchClient.Raw.self, from: bytes) { return raw }
            }
        }
        var empty = LeadResearchClient.Raw(leads: [], story: nil); empty.relations = []; empty.observedURLs = []
        return empty
    }
    static func preload(_ catalog: CatalogStore) {
        if ProcessInfo.processInfo.arguments.contains("--ui-e11-empty-catalog") { return }
        guard let directory else { return }
        let files = [directory.appendingPathComponent("catalog.json"), directory.deletingLastPathComponent().appendingPathComponent("replay/catalog.json")]
        for file in files {
            if let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) {
                try? catalog.merge(snapshot); return
            }
        }
    }
}
#endif
