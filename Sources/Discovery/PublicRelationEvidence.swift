import Foundation

struct CatalogTrackIdentity: Codable, Equatable, Sendable {
    let albumID: String
    let artistID: String
    let disc: Int
    let track: Int
    let trackCount: Int
    let milliseconds: Int
}

struct PublicIdentityHop: Codable, Sendable {
    let subject: String
    let field: String
    let level: String
    let region: String?
    let candidates: [String]
    let verified: Bool
    let source: Source
    let fetchedAt: Date
}

struct PublicRelationReport: Codable, Sendable {
    var version = 5
    var snapshot = CatalogSnapshot(works: [], relations: [])
    var hops: [PublicIdentityHop] = []
    var failures: [String] = []
    var recordingID: String?
    var verifiedArtistAliases: [WorkID: WorkID]? = nil
    var storyCredits: [StoryStructuredCredit]? = nil
}

/// Release, recording and composition are distinct identities even when their
/// labels coincide. Decoding never imports prose, lyrics or audio.
struct PublicMBRelease: Decodable, Sendable {
    let id: String
    let media: [Medium]
    let relations: [PublicMBRelation]?
    struct Medium: Decodable, Sendable {
        let position: Int
        let count: Int
        let tracks: [Track]
        enum CodingKeys: String, CodingKey { case position, tracks; case count = "track-count" }
    }
    struct Track: Decodable, Sendable {
        let position: Int
        let title: String?
        let length: Int?
        let recording: PublicMBRecording
    }
    func matchingRecording(_ work: Work) -> PublicMBRecording? {
        guard let expected = work.catalogTrack,
              relations?.contains(where: { relation in
                  guard let raw = relation.url?.resource, let url = ITunesCatalogPayload.validStoreURL(raw),
                        url.pathComponents.contains("album") else { return false }
                  return url.lastPathComponent.replacingOccurrences(of: "id", with: "") == expected.albumID
              }) == true else { return nil }
        let matches = media.filter { $0.position == expected.disc && $0.count == expected.trackCount && $0.tracks.count == $0.count }
            .flatMap(\.tracks).filter {
                $0.position == expected.track && abs(($0.length ?? $0.recording.length ?? -100_000) - expected.milliseconds) <= 2_000 &&
                ($0.title ?? $0.recording.title).precomposedStringWithCanonicalMapping.lowercased() == work.title.precomposedStringWithCanonicalMapping.lowercased()
            }
        guard matches.count == 1, UUID(uuidString: matches[0].recording.id) != nil else { return nil }
        return matches[0].recording
    }
}
struct PublicMBRecording: Decodable, Sendable {
    let id: String
    let title: String
    let length: Int?
    let isrcs: [String]?
    let relations: [PublicMBRelation]?
}
struct PublicMBRelation: Decodable, Sendable {
    struct Artist: Decodable, Sendable { let id: String; let name: String }
    struct Work: Decodable, Sendable { let id: String; let title: String; let relations: [PublicMBRelation]? }
    struct Link: Decodable, Sendable { let resource: String }
    struct Release: Decodable, Sendable { let id: String }
    struct Recording: Decodable, Sendable { let id: String; let title: String }
    let type: String
    let direction: String?
    let attributes: [String]?
    let recording: Recording?
    let artist: Artist?
    let work: Work?
    let url: Link?
    let release: Release?
}
struct PublicBangumiRelation: Decodable, Sendable {
    let id: Int
    let name: String
    let name_cn: String?
    let type: Int
    let staff: String?
    let relation: String?
    var title: String { name }
    var kind: String { switch type { case 1: "书籍"; case 2: "动画"; case 3: "专辑"; default: "作品" } }
}
