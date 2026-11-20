import Foundation

/// A credit remains attached to the MB object on which it was asserted. This
/// payload is produced only after the catalog resolver verifies the recording.
struct StoryStructuredCredit: Codable, Equatable, Sendable {
    let recordingID: String
    let subjectID: String
    let subjectName: String
    let level: String
    let relation: String
    let role: String
    let targetID: String
    let targetName: String
    var targetEntityID: String? = nil
    var attributes: [String] = []

    func fact(names: StoryNameTable) -> StoryFact {
        let title = names.name(for: subjectID, fallback: subjectName)
        let person = names.name(for: targetID, fallback: targetName)
        let text = "《\(title)》（\(level == "recording" ? "录音" : "作品")）的\(role)是\(person)。"
        let location = level + " · " + subjectID + " · " + relation + " → " + targetID
            + (attributes.isEmpty ? "" : " · " + attributes.joined(separator: ","))
        let source = Source(title: "MusicBrainz · " + subjectName, detail: level,
                            url: "https://musicbrainz.org/" + level + "/" + subjectID)
        let id = "MB:" + StoryGenerationFingerprint.hash(location)
        let quote = "\(level)/\(subjectID) · \(relation) → \(targetID) · \(targetName)"
            + (attributes.isEmpty ? "" : " · attributes=" + attributes.joined(separator: ","))
        return .init(id: id, text: text, source: source, evidence: .passage(id: id, location: location, quote: quote),
                     statements: [text], contrast: 0, linkedEntityIDs: [targetEntityID].compactMap { $0 }, people: [person],
                     structured: .init(category: "MB", subjectID: subjectID, level: level,
                                       relation: relation, targetID: targetID, recordingID: recordingID))
    }
}

enum StoryMusicBrainzCredits {
    private struct Release: Decodable { struct Medium: Decodable { struct Track: Decodable { let recording: Recording }; let tracks: [Track] }; let media: [Medium] }
    private struct Recording: Decodable { let id: String; let title: String; let relations: [Relation]? }
    private struct Relation: Decodable {
        struct Artist: Decodable { let id: String; let name: String }
        struct Work: Decodable { let id: String; let title: String; let relations: [Relation]? }
        let type: String
        let artist: Artist?
        let work: Work?
        let attributes: [String]?
    }
    static func fromRelease(_ data: Data, verifiedRecordingID: String) -> [StoryStructuredCredit] {
        guard UUID(uuidString: verifiedRecordingID) != nil,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return [] }
        let matches = release.media.flatMap(\.tracks).map(\.recording).filter { $0.id == verifiedRecordingID }
        guard matches.count == 1, let recording = matches.first else { return [] }
        func credits(_ relations: [Relation], subject: String, title: String, level: String) -> [StoryStructuredCredit] {
            relations.compactMap { relation in
                guard let artist = relation.artist, UUID(uuidString: artist.id) != nil else { return nil }
                let roles = ["composer": "作曲", "lyricist": "作词", "arranger": "编曲", "producer": "制作", "vocal": "演唱"]
                guard var role = roles[relation.type] else { return nil }
                let attributes = relation.attributes ?? []
                if relation.type == "vocal" {
                    if attributes.contains("guest") { role = "客座演唱" }
                    else if attributes.contains("background vocals") { role = "演唱（和声）" }
                }
                return .init(recordingID: recording.id, subjectID: subject, subjectName: title,
                             level: level, relation: relation.type, role: role, targetID: artist.id,
                             targetName: artist.name, attributes: attributes)
            }
        }
        var result = credits(recording.relations ?? [], subject: recording.id, title: recording.title, level: "recording")
        for relation in recording.relations ?? [] where relation.type == "performance" {
            guard let work = relation.work, UUID(uuidString: work.id) != nil else { continue }
            result += credits(work.relations ?? [], subject: work.id, title: work.title, level: "work")
        }
        var seen = Set<String>()
        return result.filter { seen.insert([$0.level, $0.subjectID, $0.relation, $0.targetID, $0.attributes.joined(separator: ",")].joined(separator: ":")).inserted }
    }
}

extension StoryNameTable {
    func name(for externalID: String, fallback: String) -> String {
        let matches = nodes.filter { $0.externalIDs.contains(externalID) }
        let values = Set(matches.map(\.name))
        return values.count == 1 ? values.first! : fallback
    }
}
