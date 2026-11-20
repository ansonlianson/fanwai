import XCTest
@testable import Pianwai

@MainActor final class PerformancePageTests: XCTestCase {
    func testReturningFromMapRequiresANewAppearanceCompletion() {
        let appearances = ShopPageAppearanceGeneration()
        let first = appearances.value(for: "work:A")
        XCTAssertEqual(appearances.value(for: "work:A"), first)
        let map = appearances.value(for: "map:A")
        let returned = appearances.value(for: "work:A")
        XCTAssertNotEqual(first, map)
        XCTAssertNotEqual(first, returned)
        XCTAssertEqual(appearances.value(for: "work:A"), returned)
    }
    private func snapshot(elapsed: Double, at: Double, entry: String = "first", status: MusicPlaybackStatus = .playing) -> MusicPlaybackSnapshot {
        .init(availability: .ready, authorization: .authorized, subscription: .unknown,
              nowPlaying: .init(id: "song", catalogID: "123", title: "Song", artist: "Artist",
                                albumTitle: nil, artworkURL: nil, duration: 100, source: .musicKit),
              status: status, elapsedTime: elapsed, capturedAt: Date(timeIntervalSince1970: at), currentEntryID: entry)
    }
    func testClockTicksStayOutOfContentButCompletionAndSeekStillArrive() {
        XCTAssertFalse(MusicPlaybackPublication.needsContentDelivery(from: snapshot(elapsed: 10, at: 10), to: snapshot(elapsed: 11, at: 11)))
        let terminal = snapshot(elapsed: 99, at: 99)
        XCTAssertTrue(MusicPlaybackPublication.needsContentDelivery(from: snapshot(elapsed: 98, at: 98), to: terminal))
        let next = snapshot(elapsed: 0, at: 100, entry: "second")
        XCTAssertTrue(MusicPlaybackPublication.needsContentDelivery(from: terminal, to: next))
        XCTAssertTrue(MusicPlaybackCompletion.finished(terminal, next))
        let seek = snapshot(elapsed: 20, at: 100)
        XCTAssertTrue(MusicPlaybackPublication.needsContentDelivery(from: terminal, to: seek))
        XCTAssertFalse(MusicPlaybackCompletion.finished(seek, next))
    }
    func testLegacyReaderDecodesOnlyTheRequestedDraft() throws {
        let suite = "PerfPage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = Story(id: "old", entityID: "pool", title: "", body: "保留原文。", source: .init(title: "Source", url: "https://example.com/source"))
        let encoded = try JSONEncoder().encode(["requested": [draft]])
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        archive["unrelated-legacy-format"] = ["format": "an unrelated old record"]
        defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: "redesign.generatedStories.v5")
        defaults.set(["pool": "requested"], forKey: "redesign.storyDisplayKeys.v5")
        let reader = OnDemandStories(defaults: defaults, provider: { _ in [] })
        reader.load("pool")
        XCTAssertEqual(reader.story(for: "pool"), draft)
    }
    func testInterestsKeepTheMostRecent500AndReuseMemory() throws {
        let suite = "PerfInterests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = (0..<501).map { InterestEvent(entityID: "item-\($0)", fromEntityID: "root", relation: "关系", at: Date(timeIntervalSince1970: Double($0))) }
        defaults.set(try JSONEncoder().encode(history), forKey: "redesign.interests")
        let exploration = CrateExploration(defaults: defaults)
        XCTAssertEqual(exploration.interests.count, 500)
        XCTAssertEqual(exploration.interests.first?.entityID, "item-1")
        let item = CrateItem(entity: SeedNowContent.entity("pool")!, relation: "关系", path: ["root", "pool"])
        exploration.record(item, from: "root")
        XCTAssertEqual(exploration.interests.last?.entityID, "pool")
        XCTAssertEqual(CrateExploration(defaults: defaults).interests.count, 500)
    }
}
