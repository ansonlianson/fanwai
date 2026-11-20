import Foundation

struct StoryMaterial: Codable, Equatable, Sendable {
    let id: String
    let source: Source
    let text: String
    let location: String
}

struct StoryFact: Codable, Equatable, Sendable {
    enum Evidence: Codable, Equatable, Sendable {
        // An approved preset is not a fetched primary-source quotation.
        case reviewedPreset(storyID: String)
        case passage(id: String, location: String, quote: String)
    }
    let id: String
    let text: String
    let source: Source
    let evidence: Evidence
    let statements: [String]
    let contrast: Int
    let linkedEntityIDs: [String]
    var people: [String]? = nil
    struct Structured: Codable, Equatable, Sendable {
        let category: String
        let subjectID: String
        let level: String
        let relation: String
        var targetID: String? = nil
        var recordingID: String? = nil
    }
    var structured: Structured? = nil
}
