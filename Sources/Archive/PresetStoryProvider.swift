import Foundation

struct PresetStoryProvider {
    private let fixtures: @Sendable (String) -> [Story]
    init(fixtures: @escaping @Sendable (String) -> [Story] = SeedNowContent.stories(for:)) { self.fixtures = fixtures }
    func stories(for id: String) -> [Story] {
        let context = StoryContext.preset(id), validator = StoryValidator()
        return fixtures(id).filter { validator.validate($0, context: context).isValid }.map { story in
            Story(id: story.id, entityID: story.entityID, title: story.title, body: story.body,
                  relatedEntityIDs: story.relatedEntityIDs, source: story.source,
                  score: Double(validator.titleSpecificity(story, context: context)), entityLinks: story.entityLinks,
                  additionalSources: story.additionalSources, mentions: story.mentions)
        }
    }
}

extension StoryContext {
    static func preset(_ id: String) -> Self {
        let entity = SeedNowContent.entity(id)
        let nearby = [entity].compactMap { $0 } + SeedNowContent.connections(id).map(\.entity)
        return Self(entityID: id, entityName: entity?.title ?? "",
                    people: nearby.filter { $0.kind == .person }.map(\.title),
                    works: nearby.filter { $0.kind != .person }.map(\.title))
    }
}
