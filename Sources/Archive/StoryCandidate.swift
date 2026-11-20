import Foundation

/// Literal evidence validation input shared by reviewed and saved stories.
struct StoryCandidate: Codable, Equatable, Sendable {
    let story: Story
    let factIDs: [String]
}
