import XCTest
@testable import Pianwai

final class U20LatestCompatibilityTests: XCTestCase {
    func testRecognitionCannotEnableAnExtraPaidRelationshipCall() {
        let root = WorkID(rawValue: "apple:song:1")!, book = WorkID(rawValue: "local:novel")!
        let result = DatabaseDiscoveryResult(snapshot: .init(works: [
            Work(id: root, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil),
            Work(id: book, title: "Novel", creator: "", kind: "小说", art: "", detail: "", url: nil)
        ], relations: [.init(from: root, to: book, predicate: .adaptedFrom, label: "改编自", inverseLabel: "改编作品",
            source: .init(title: "Source", url: "https://example.org/novel"), researchRoot: root)]))
        XCTAssertTrue(DatabaseDiscoveryResult.isVersion("Song - From THE FIRST TAKE"))
        XCTAssertEqual(result.needsRelationships(root: root, title: "Song - From THE FIRST TAKE"), result.needsRelationships(root: root, title: "Song"))
        XCTAssertFalse(result.needsRelationships(root: root, title: "Song - From THE FIRST TAKE"))
    }
    func testGroundingKeepsSameArtistStudioOriginalWithVersionMarker() throws {
        let quote = "LiSAの「紅蓮華」は2019年に発売された。THE FIRST TAKEでは同曲をセルフカバーした。"
        let packet = ResearchMaterialPacket(topic: .init(id: "apple:song:1", title: "紅蓮華 - From THE FIRST TAKE", creator: "LiSA", album: "", layer: "recording"), queries: [],
            sources: [.init(id: "S1", url: "https://example.org/lisa", title: "LiSA 紅蓮華", publisher: "Offline", text: quote, purposes: [.lineage])],
            fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 0, fetches: 0)
        let reply: [String: Any] = ["leads": [["ref": "n1", "name": "紅蓮華", "target_type": "recording", "creator": "LiSA", "release_title": "紅蓮華"]],
            "relations": [["from": "current", "to": "n1", "relation": "original_recording_of", "source_id": "S1", "quote": quote, "why": "原版录音"]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self)
        let kept = try ResearchWriter.groundRelations(text, packet: packet).relations
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["from"] as? String, "current")
        XCTAssertEqual(kept.first?["relation"] as? String, "original_recording_of")
        XCTAssertEqual(DiscoveryRelation.originalRecordingOf.predicate, .coverOf)
        XCTAssertTrue(ResearchProofRules.carriesVersionMark(packet.topic.title, unlike: "紅蓮華"))
    }
}
