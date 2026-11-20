import Foundation
import Observation

/// Read-only compatibility display for reviewed presets and saved pre-ARCH2 drafts.
@MainActor @Observable final class OnDemandStories {
    private(set) var storiesByEntity: [String: [Story]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let provider: (String) -> [Story]
    init(defaults: UserDefaults? = nil, provider: @escaping (String) -> [Story] = { PresetStoryProvider().stories(for: $0) }) {
        self.defaults = RelationTrailStore(defaults: defaults).defaults
        self.provider = provider
    }
    func load(_ id: String, reviewedStories: [Story]? = nil, collectMaterials: Bool = false) {
        guard storiesByEntity[id] == nil else { return }
        let keys = defaults.dictionary(forKey: "redesign.storyDisplayKeys.v5") as? [String: String]
            ?? defaults.dictionary(forKey: "redesign.storyDisplayKeys.v4") as? [String: String] ?? [:]
        let cache = defaults.data(forKey: "redesign.generatedStories.v5")
            ?? defaults.data(forKey: "redesign.generatedStories.v4")
        // Decode only this entity's legacy value. The old archive may contain
        // hundreds of unrelated drafts; none are materialized for a page push.
        let drafts = keys[id].flatMap { key in
            cache.flatMap { data -> [Story]? in
                let decoder = JSONDecoder()
                decoder.userInfo[.requestedStoryKey] = key
                return try? decoder.decode(RequestedStories.self, from: data).stories
            }
        }
        let presets = reviewedStories ?? provider(id)
        if let drafts, !drafts.isEmpty,
           drafts.allSatisfy({ $0.entityID == id }),
           StoryValidator.visualWidth(drafts[0].body) >= (presets.first.map { StoryValidator.visualWidth($0.body) } ?? 0) {
            storiesByEntity[id] = drafts
        } else { storiesByEntity[id] = presets }
    }
    func setCurrentRoot(_ id: String) {}
    func story(for id: String) -> Story? { storiesByEntity[id]?.first }
    func isLoading(_ id: String) -> Bool { false }
    func scopeCaption(for id: String) -> String? { nil }
}

private extension CodingUserInfoKey {
    static let requestedStoryKey = CodingUserInfoKey(rawValue: "requestedStoryKey")!
}
private struct RequestedStories: Decodable {
    let stories: [Story]
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard let key = decoder.userInfo[.requestedStoryKey] as? String else { stories = []; return }
        stories = try values.decodeIfPresent([Story].self, forKey: Key(stringValue: key)!) ?? []
    }
}
