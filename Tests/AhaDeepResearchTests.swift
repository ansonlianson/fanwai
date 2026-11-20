import XCTest
@testable import Pianwai

final class AhaDeepResearchTests: XCTestCase {
    func testPlannerQueriesAreDedupedCappedAndTyped() {
        let reply = #"{"queries":[{"purpose":"lineage","text":"星の世界 原曲 讃美歌"},{"purpose":"lineage","text":"星の世界 原曲 讃美歌"},{"purpose":"bogus","text":"planetarian OST interview"},{"text":"a"},{"purpose":"story","text":"星の世界 制作秘話"},{"purpose":"context","text":"query one"},{"purpose":"context","text":"query two"}]}"#
        let queries = DeepResearch.queries(reply)
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(queries.first?.purpose, .lineage)
        XCTAssertEqual(queries[1].purpose, .context)   // unknown purpose falls back
    }

    func testRoundsCannotShareRefs() {
        let part: (leads: [[String: Any]], relations: [[String: Any]]) = ([["ref": "n1", "name": "A"]], [["from": "current", "to": "n1", "relation": "samples"]])
        let one = DeepResearch.prefixed(part, round: 1), two = DeepResearch.prefixed(part, round: 2)
        XCTAssertEqual(one.leads.first?["ref"] as? String, "r1_n1")
        XCTAssertEqual(two.relations.first?["to"] as? String, "r2_n1")
        XCTAssertEqual(two.relations.first?["from"] as? String, "current")
    }

    func testEstimateUsesPublishedPricesOrShowsCountsOnly() {
        let flash = DeepResearch.estimate(model: "deepseek-flash", price: .published(model: "deepseek-flash"))
        XCTAssertNotNil(flash.low); XCTAssertLessThan(flash.high ?? 1, 0.6)
        XCTAssertTrue(flash.text.hasPrefix("约 ¥"))
        // A service the app has no price for is quoted in rounds and searches…
        XCTAssertNil(ModelPrice.published(model: "gpt-6-astra"))
        let unknown = DeepResearch.estimate(model: "gpt-6-astra", price: nil)
        XCTAssertNil(unknown.low); XCTAssertTrue(unknown.text.contains("最多 2 轮、18 次搜索"), unknown.text)
        // …and in money once its owner has entered what it costs (not DeepSeek alone).
        let entered = DeepResearch.estimate(model: "gpt-6-astra", price: .init(input: 10, output: 40))
        XCTAssertNotNil(entered.low); XCTAssertTrue(entered.text.hasPrefix("约 ¥"))
        let usage = DiscoveryUsage(model: "deepseek-flash", inputTokens: 100_000, cachedInputTokens: 0, outputTokens: 5_000, webToolCalls: 10)
        XCTAssertEqual(DeepResearch.cost(price: .published(model: usage.model), usage: usage) ?? 0, 0.29, accuracy: 0.001)
        XCTAssertEqual(DeepResearch.cost(price: .init(input: 10, output: 40), usage: usage) ?? 0, 1.2, accuracy: 0.001)
    }
}
