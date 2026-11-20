import XCTest
@testable import Pianwai

final class NextStationSequenceTests: XCTestCase {
    func testAuthoredJourneyAndPaginationHaveNoRepeatedEntities() throws {
        let graph = try SeedGraph.load(bundle: Bundle(for: Library.self))
        let stations = NextStationSequence.make(graph: graph, root: "pool")
        XCTAssertEqual(Array(stations.prefix(2)).map(\.id), ["jane", "utada"])
        XCTAssertEqual(stations.first?.reason, "同一部电影的片尾曲")
        XCTAssertEqual(stations.dropFirst().first?.reason, "同一位歌手")
        XCTAssertEqual(Set(stations.map(\.id)).count, stations.count)
        XCTAssertEqual(stations.count, graph.entities.count - 1)
        XCTAssertTrue(stations.allSatisfy { $0.path.first == "pool" && $0.path.last == $0.id })
        XCTAssertEqual(Array(stations.prefix(3)).count, 3)
        XCTAssertEqual(Array(stations.prefix(6)).count, 6)
        let fromUtada = NextStationSequence.make(graph: graph, root: "utada")
        XCTAssertTrue(fromUtada.contains { $0.id == "olkmv" && $0.reason == "同一首歌的 MV" })
    }
}
