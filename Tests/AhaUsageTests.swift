import XCTest
@testable import Pianwai

/// 设置 › 用量 (0.5.26): every paid lookup is written down, for any service whose price is known.
@MainActor final class AhaUsageTests: XCTestCase {
    private func entry(_ title: String, _ date: Date, cost: Double?, kind: UsageEntry.Kind = .lookup, id: String = "apple:song:1") -> UsageEntry {
        .init(date: date, subjectID: id, title: title, kind: kind, provider: "DeepSeek", model: "deepseek-flash",
              inputTokens: 20_000, outputTokens: 900, searches: 6, cost: cost)
    }

    func testPricesAreNotTiedToOneService() throws {
        XCTAssertEqual(ModelPrice.published(model: "deepseek-flash")?.cost(inputTokens: 20_000, outputTokens: 900, searches: 6) ?? 0, 0.0772, accuracy: 0.0001)
        XCTAssertNil(ModelPrice.published(model: "mimo-v2.6-flash"))
        let suite = "AhaUsage." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), chain = StoryModelKeychain(service: suite)
        defer { defaults.removePersistentDomain(forName: suite); try? chain.remove("openai") }
        let offline = StoryModelHTTP { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        let settings = StoryModelSettings(defaults: defaults, keychain: chain, http: offline)
        settings.selectProvider("openai"); settings.saveKey("offline-only")
        XCTAssertNil(settings.price, "no published price on file for this service")
        XCTAssertNil(settings.configuration()?.price)
        // Its owner enters what it costs: lookups and 深挖 are then quoted in money like any other.
        settings.setPrice(input: 1.5, output: 6)
        XCTAssertEqual(settings.configuration()?.price, .init(input: 1.5, output: 6))
        XCTAssertEqual(settings.configuration()?.providerName, "OpenAI")
        let reopened = StoryModelSettings(defaults: defaults, keychain: chain, http: offline)
        XCTAssertEqual(reopened.enteredPrice, .init(input: 1.5, output: 6))
        // One number alone is no price.
        reopened.setPrice(input: 2, output: nil)
        XCTAssertNil(reopened.enteredPrice)
        // DeepSeek has a published price, which the owner may still replace.
        try? chain.remove("deepseek"); defer { try? chain.remove("deepseek") }
        reopened.selectProvider("deepseek"); reopened.saveKey("offline-only"); reopened.selectModel("deepseek-flash")
        XCTAssertEqual(reopened.price, .init(input: 2, output: 8, search: 0.005)); XCTAssertNil(reopened.enteredPrice)
        reopened.setPrice(input: 1, output: 4)
        XCTAssertEqual(reopened.price, .init(input: 1, output: 4, search: 0.005))
    }

    func testTheLedgerKeepsEachLookupAndAddsUpTodayAndThisMonth() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AhaUsage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = UsageLedger(directory: folder)
        let now = Date(), calendar = Calendar.current
        let today = calendar.startOfDay(for: now), month = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        ledger.record(entry("去年的歌", calendar.date(byAdding: .month, value: -2, to: now)!, cost: 0.5))
        ledger.record(entry("くるみ", now.addingTimeInterval(-60), cost: 0.074))
        ledger.record(entry("没有单价的服务", now.addingTimeInterval(-30), cost: nil, id: "apple:song:2"))
        ledger.record(entry("くるみ", now, cost: 0.31, kind: .deep))
        XCTAssertEqual(ledger.entries.map(\.title).first, "くるみ")
        let sum = ledger.total(since: today)
        XCTAssertEqual(sum.count, 3); XCTAssertEqual(sum.unpriced, 1); XCTAssertEqual(sum.cost, 0.384, accuracy: 0.0001)
        XCTAssertEqual(sum.text, "¥0.38 · 3 次")
        XCTAssertGreaterThanOrEqual(ledger.total(since: month).count, 3)
        XCTAssertEqual(ledger.latest(for: "apple:song:1")?.kind, .deep)
        XCTAssertEqual(UsageLedger.amount(ledger.latest(for: "apple:song:2")!), "2.1 万 token")
        XCTAssertEqual(UsageLedger.amount(entry("x", now, cost: 0.074)), "¥0.074")
        XCTAssertEqual(UsageLedger.Total().text, "还没有")
        await ledger.waitForWrites()
        let reopened = UsageLedger(directory: folder)
        XCTAssertEqual(reopened.entries.count, 4)
        XCTAssertEqual(reopened.entries.first?.cost, 0.31)
    }
}
