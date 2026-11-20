import Foundation

/// Reviewed primary-source material is explicitly bound to known recordings.
/// It is not a title-search result or runtime-generated copy.
struct SongEditorialCatalog: Decodable, Sendable {
    let version: Int
    let entries: [Entry]
    struct Entry: Decodable, Sendable {
        let recordingIDs: [String]
        let artistID: String
        let works: [Work]
        let connections: [Connection]
        let stories: [Story]
        private enum CodingKeys: String, CodingKey { case recordingIDs, artistID, works, connections, stories }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            recordingIDs = try c.decode([String].self, forKey: .recordingIDs)
            artistID = try c.decode(String.self, forKey: .artistID)
            works = try c.decode([Work].self, forKey: .works)
            connections = try c.decode([Connection].self, forKey: .connections)
            guard let recordingID = recordingIDs.first else {
                throw DecodingError.dataCorruptedError(forKey: .recordingIDs, in: c, debugDescription: "Missing recording")
            }
            var values = try c.nestedUnkeyedContainer(forKey: .stories)
            var decoded: [Story] = []
            while !values.isAtEnd {
                decoded.append(try Story(from: values.superDecoder(), boundEntityID: "apple:song:" + recordingID))
            }
            stories = decoded
        }
    }
    struct Connection: Decodable, Sendable {
        let target: WorkID
        let predicate: RelationKind
        let label: String
        let inverseLabel: String
        let source: Source
    }

    func snapshot(for song: Work, artistIDs: [String]) -> CatalogSnapshot? {
        guard version == 1, song.isSong, let recordingID = song.catalogRecordingID,
              let entry = entries.first(where: {
                  $0.recordingIDs.contains(recordingID) && artistIDs.contains($0.artistID)
              }) else { return nil }
        return CatalogSnapshot(works: entry.works, relations: entry.connections.map {
            RelationEdge(from: song.id, to: $0.target, predicate: $0.predicate,
                         label: $0.label, inverseLabel: $0.inverseLabel, source: $0.source)
        }, stories: entry.stories.map {
            EditorialStory(id: $0.id + ":" + recordingID, workID: song.id, title: $0.title,
                           body: $0.body, entityLinks: $0.entityLinks, source: $0.source, additionalSources: $0.additionalSources, relatedEntityIDs: $0.relatedEntityIDs, score: $0.score)
        })
    }
}
