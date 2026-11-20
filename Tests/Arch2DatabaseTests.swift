import XCTest
@testable import Pianwai

@MainActor final class Arch2DatabaseTests: XCTestCase {
    func testConcurrentDistinctDatabaseRequestsRespectMusicBrainzSpacing() async throws {
        actor Starts {
            var values: [Date] = []
            func add(_ date: Date) { values.append(date) }
        }
        let starts = Starts()
        let http = PublicDatabaseHTTP(directory: nil) { request in
            let began = Date()
            await starts.add(began)
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for index in 0..<4 {
                group.addTask { try await http.get(URL(string: "https://musicbrainz.org/ws/2/recording/spacing-\(index)")!) }
            }
            for try await _ in group {}
        }
        let values = await starts.values.sorted()
        XCTAssertEqual(values.count, 4)
        for (previous, next) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.timeIntervalSince(previous), 1.0)
        }
    }

    func testShareExpansionAndMetadataUseTheSameHostClock() async throws {
        actor Starts {
            var values: [Date] = []
            func add(_ date: Date) { values.append(date) }
        }
        let starts = Starts()
        let http = PublicDatabaseHTTP(directory: nil) { request in
            await starts.add(Date())
            let short = request.url!.path.contains("/u")
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: short ? 302 : 200,
                httpVersion: nil, headerFields: short ? ["Location": "https://y.qq.com/n/ryqq/songDetail/000aHhpF3Lndjw"] : nil)!)
        }
        async let metadata = http.get(URL(string: "https://c.y.qq.com/metadata")!)
        async let share = http.expandSongLink(URL(string: "https://c.y.qq.com/base/fcgi-bin/u?__=offline")!)
        _ = try await (metadata, share)
        let values = await starts.values.sorted()
        XCTAssertEqual(values.count, 2)
        XCTAssertGreaterThanOrEqual(values[1].timeIntervalSince(values[0]), 0.5)
    }

    func testNoModelStillPublishesDatabaseCardsBeforeCompletion() async throws {
        let suite = "Arch2.Database." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil), root = WorkID(rawValue: "local:arch2-db")!, target = WorkID(rawValue: "local:arch2-game")!
        let song = Work(id: root, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil)
        let game = Work(id: target, title: "Game", creator: "", kind: "游戏", art: "", detail: "", url: nil)
        try catalog.merge(.init(works: [song], relations: []))
        let library = Library(defaults: defaults, catalog: catalog)
        let settings = StoryModelSettings(defaults: defaults)
        let result = DatabaseDiscoveryResult(snapshot: .init(works: [song, game], relations: [.init(from: root, to: target, predicate: .soundtrackOf,
            label: "出自", inverseLabel: "音乐", source: .init(title: "TouhouDB", url: "https://touhoudb.com/S/1"), researchRoot: root)]))
        var observed = false
        let research = LeadResearch(evidenceCache: .init(directory: nil), processedDirectory: nil, modelSettings: settings,
            databaseOperation: { _, _, partial in await partial(result); return result })
        await research.load(.init(id: root.rawValue, kind: .song, title: song.title, creator: song.creator, album: ""), library: library)
        observed = research.navigationLeads(root.rawValue, library: library).map(\.id) == [target.rawValue]
        XCTAssertTrue(observed); XCTAssertEqual(research.state(root.rawValue), .ready)
        XCTAssertNil(research.reports[root.rawValue]?.story)
        let graph = PublicCrateInventory.leadGraph(root: root.rawValue, expanding: [root.rawValue], library: library)
        XCTAssertTrue(graph.relations.contains { $0.from == root.rawValue && $0.to == target.rawValue })
    }

    func testDatabaseGapAndMultipleOriginalsRules() {
        let root = WorkID(rawValue: "local:gap")!, target = WorkID(rawValue: "local:source")!
        var result = DatabaseDiscoveryResult(snapshot: .init(works: [
            .init(id: root, title: "录音", creator: "", kind: "歌曲", art: "", detail: "", url: nil),
            .init(id: target, title: "原曲", creator: "", kind: "音乐作品", art: "", detail: "", url: nil)], relations: [
                .init(from: root, to: target, predicate: .adaptedFrom, label: "改编自", inverseLabel: "改编版本", source: .init(title: "MusicBrainz", url: "https://musicbrainz.org"))]))
        // AHA-PLAN §3.2: an arrangement edge alone leaves the 原作 slot open, so the model still runs.
        XCTAssertTrue(result.needsRelationships(root: root))
        result.multipleOriginals = true; XCTAssertTrue(result.needsRelationships(root: root))
        result.multipleOriginals = false; result.snapshot.relations = []; XCTAssertTrue(result.needsRelationships(root: root))
    }

    func testISRCRecordingRelationsAndCompositionLevelRelationsKeepTheirSubjects() async throws {
        let root = WorkID(rawValue: "local:mb-isrc")!
        let loader: PublicDatabaseHTTP.Loader = { request in
            let path = request.url!.path
            let body: String
            if path.contains("isrc") { body = #"{"recordings":[{"id":"00000000-0000-0000-0000-000000000001","title":"Recording","length":200000}]}"# }
            else if path.contains("/recording/") { body = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Recording","isrcs":["JPAAA2200001"],"relations":[{"type":"performance","work":{"id":"00000000-0000-0000-0000-000000000002","title":"Composition"}},{"type":"samples material","recording":{"id":"00000000-0000-0000-0000-000000000004","title":"Sample"},"direction":"forward"}]}"# }
            else if path.contains("/work/") { body = #"{"relations":[{"type":"arrangement","direction":"backward","work":{"id":"00000000-0000-0000-0000-000000000003","title":"Original"}}]}"# }
            else { body = #"{"items":[],"data":[]}"# }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = DatabaseDiscovery(http: .init(directory: nil, paced: false, loader: loader), exact: nil)
        let work = Work(id: root, title: "Recording", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil, publicIdentifiers: .init(isrc: "JPAAA2200001"))
        let result = await service.resolve(work, known: [work])
        XCTAssertEqual(result.snapshot.relations.count, 3)
        XCTAssertTrue(result.snapshot.relations.contains { $0.from.rawValue.hasSuffix("0002") && $0.to.rawValue.hasSuffix("0003") && $0.predicate == .adaptedFrom })
        XCTAssertFalse(result.snapshot.relations.contains { $0.from == root && $0.to.rawValue.hasSuffix("0003") })
    }
}
