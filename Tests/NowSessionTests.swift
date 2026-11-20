import XCTest
@testable import Pianwai

@MainActor final class NowSessionTests: XCTestCase {
    func testThreeStationPagingAndReaderControlledSwitchRestoreLastVisit() throws {
        let suite = "Pianwai.Tests.NowSession." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = NowSession(arguments: ["-nowState", "switch"], defaults: defaults)
        XCTAssertEqual(session.entityID, "pool")
        XCTAssertEqual(session.visibleStations.count, 3)
        session.loadMore()
        XCTAssertEqual(session.visibleStations.count, 6)
        XCTAssertEqual(session.pendingID, "jane")
        session.receiveTrack("olk")
        XCTAssertEqual(session.entityID, "pool")
        XCTAssertEqual(session.pendingID, "olk")
        session.acceptPending()
        XCTAssertEqual(session.entityID, "olk")
        XCTAssertNil(session.pendingID)
        let idle = NowSession(arguments: ["-nowState", "idle"], defaults: defaults)
        XCTAssertEqual(idle.entityID, "olk")
        XCTAssertFalse(idle.previewPlaying)
    }
    func testLivePlaybackInitializesOnceThenPreservesReadingUntilAccepted() throws {
        let name = "Pianwai.Tests.LiveNow." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = NowSession(arguments: [], defaults: defaults)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.previewPlaying, "A normal launch must not invent active playback")
        let first = SeedGraph.Entity(id: "apple:song:111", kind: .song, title: "真实歌曲 A", subtitle: "艺人 A", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: [])
        let second = SeedGraph.Entity(id: "apple:song:222", kind: .song, title: "真实歌曲 B", subtitle: "艺人 B", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: [])
        session.receiveLiveTrack(first)
        XCTAssertEqual(session.entity, first)
        XCTAssertNil(session.pendingID)
        session.receiveLiveTrack(second)
        XCTAssertEqual(session.entity, first, "System playback changing must not replace the reading page")
        XCTAssertEqual(session.pendingEntity, second, "Non-seed songs still need a switch banner")
        session.acceptPending()
        XCTAssertEqual(session.entity, second)
        XCTAssertNil(session.pendingEntity)
        XCTAssertEqual(SeedLibraryBridge.workID(second.id).rawValue, "apple:song:222")
        XCTAssertEqual(NowSession(arguments: [], defaults: defaults).entity, second)
        session.receiveLiveTrack(first)
        session.receiveLiveTrack(second)
        XCTAssertNil(session.pendingEntity, "Returning to the read song clears the stale banner")
    }

}
