import Foundation

/// Source material is independent of the writer/provider. A failed collection
/// must not replace readable evidence that was already obtained for this item.
struct ResearchMaterialStore: Sendable {
    let directory: URL?

    func read(_ topic: ResearchTopic) -> ResearchMaterialCollection? {
        guard let file = file(topic), let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(ResearchMaterialCollection.self, from: data),
              value.packet.version == 1, value.packet.topic.key == topic.key,
              !value.packet.sources.isEmpty else { return nil }
        return value
    }

    @discardableResult func write(_ value: ResearchMaterialCollection) -> Bool {
        guard !value.packet.sources.isEmpty, let file = file(value.packet.topic),
              let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch { return false }
    }

    private func file(_ topic: ResearchTopic) -> URL? { directory?.appendingPathComponent(topic.key + ".json") }
}
