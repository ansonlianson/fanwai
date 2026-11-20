import XCTest
@testable import Pianwai

final class StoryEvidenceGuardTests: XCTestCase {
    @MainActor func testNameTableUsesOnlyGraphNodesAndVerifiedIDNames() {
        let catalog = CatalogStore(cacheURL: nil)
        let nodes = StoryNameGraph.nodes(catalog: catalog)
        let table = StoryNameTable(nodes: nodes, verifiedNames: StoryNameTable.bundledAliases())
        for original in ["宇多田ヒカル", "Hikaru Utada"] {
            XCTAssertTrue(table.payload.contains { $0["original"] == original && $0["app"] == "宇多田光" })
        }
        XCTAssertTrue(table.payload.contains { $0["original"] == "チェンソーマン レゼ篇" && $0["app"] == "电锯人 蕾塞篇" })
        XCTAssertFalse(table.payload.contains { $0["original"] == "川辺ヒロシ" })
        XCTAssertTrue(table.payload.allSatisfy { row in nodes.contains { $0.id == row["entity_id"] } })
    }
    private let source = Source(title: "原文", url: "https://example.org/interview")
    private var names: StoryNameTable {
        .init(nodes: [.init(id: "film", name: "电锯人 蕾塞篇", kind: .work),
                      .init(id: "utada", name: "宇多田光", kind: .person, aliases: ["宇多田ヒカル", "Hikaru Utada"])])
    }
    func testRecordedMisspellingsAndClaudeReportedDateAreRejected() throws {
        struct Regression: Decodable { let provenance: String; let candidate: StoryCandidate; let facts: [StoryFact]; let expectedToken: String }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "quality-regressions", withExtension: "json"))
        let cases = try JSONDecoder().decode([Regression].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 2)
        for item in cases {
            let issues = StoryEvidenceGuard().check(item.candidate, facts: item.facts, entityInfo: [], names: names)
            XCTAssertTrue(issues.contains { $0.token.contains(item.expectedToken) }, item.expectedToken + ": " + String(describing: issues))
        }
    }
    func testNumbersNormalizeAndCannotBorrowAnotherCandidatesFact() {
        let quote = "2025年10月2日，共1,200次、三天、２万、二亿。"
        let fact = StoryFact(id: "f1", text: quote, source: source, evidence: .passage(id: "p1", location: "段落 1", quote: quote), statements: [], contrast: 0, linkedEntityIDs: [])
        func check(_ text: String, facts: [StoryFact] = []) -> [StoryEvidenceIssue] {
            let story = Story(id: "s", entityID: "pool", title: text, body: "", source: source)
            return StoryEvidenceGuard().check(.init(story: story, factIDs: ["f1"]), facts: [fact] + facts, entityInfo: [], names: names)
        }
        XCTAssertTrue(check("２０２５年１０月２日，1200次、3天、20,000、200000000").isEmpty)
        let other = StoryFact(id: "f2", text: "99次", source: source, evidence: .passage(id: "p2", location: "段落 2", quote: "99次"), statements: [], contrast: 0, linkedEntityIDs: [])
        XCTAssertTrue(check("99次", facts: [other]).contains { $0.rule == .number })
        XCTAssertTrue(check("2025年10月1日").contains { $0.rule == .number && $0.token.contains("2025年10月1日") })
        XCTAssertTrue(check("十一天").contains { $0.rule == .number })
        XCTAssertTrue(check("一起公布，一并宣布，一同演唱").isEmpty)
        XCTAssertTrue(check("另一个请求，一部组曲").isEmpty, "Bare Chinese 一 follows SPEC §9")
        XCTAssertTrue(check("第一次演唱").contains { $0.rule == .number })
        XCTAssertTrue(check("二〇二五年十月二日").isEmpty)
    }
    func testTemplateNamesAndNumbersCannotBorrowCatalogDateOrMetadataIDs() {
        let text = "《IRIS OUT》的发布日期是2025-09-15。"
        let fact = StoryFact(id: "wd", text: text, source: source,
            evidence: .passage(id: "wd", location: "Q123 · P577", quote: "P577 = +2025-09-15T00:00:00Z"),
            statements: [text], contrast: 0, linkedEntityIDs: [],
            structured: .init(category: "WD", subjectID: "Q123", level: "item", relation: "P577"))
        func check(_ title: String) -> [StoryEvidenceIssue] {
            StoryEvidenceGuard().check(.init(story: .init(id: "s", entityID: "iris", title: title, body: "", source: source), factIDs: ["wd"]),
                                      facts: [fact], entityInfo: ["2099-12-31"], names: .init())
        }
        XCTAssertTrue(check("《IRIS OUT》于2025年9月15日发布").isEmpty)
        XCTAssertTrue(check("2099年12月31日发布").contains { $0.rule == .number })
        XCTAssertTrue(check("577天").contains { $0.rule == .number })
        XCTAssertTrue(check("《凭空的新歌》").contains { $0.rule == .name })
    }

    func testOnlyApprovedFirstOrdinalsInteroperate() {
        for original in ["初の", "初めて", "首次", "first", "1st", "第一次"] {
            XCTAssertEqual(StoryEvidenceGuard.numbers(original).map(\.normalized), ["ordinal:1"])
        }
        func check(sourceText: String, candidate: String) -> [StoryEvidenceIssue] {
            let fact = StoryFact(id: "f", text: sourceText, source: source,
                evidence: .passage(id: "p", location: "1", quote: sourceText), statements: [], contrast: 0, linkedEntityIDs: [])
            return StoryEvidenceGuard().check(.init(story: .init(id: "s", entityID: "pool", title: candidate, body: "", source: source), factIDs: ["f"]), facts: [fact], entityInfo: [], names: names)
        }
        XCTAssertTrue(check(sourceText: "初の全国ツアー", candidate: "第一次全国巡演").isEmpty)
        XCTAssertTrue(check(sourceText: "1 首歌曲", candidate: "第一次全国巡演").contains { $0.token == "第一次" })
        XCTAssertTrue(check(sourceText: "全国ツアー", candidate: "首次全国巡演").contains { $0.rule == .number })
        XCTAssertTrue(check(sourceText: "初の全国ツアー", candidate: "第二次全国巡演").contains { $0.rule == .number })
        XCTAssertFalse(StoryEvidenceGuard.numbers("firstborn").contains { $0.normalized == "ordinal:1" })
    }

    func testLiteralNamesAndQuotedWordsMustBelongToReferencedFactsOrGraph() {
        let quote = "川辺ヒロシと石野卓球に相談。"
        let fact = StoryFact(id: "f1", text: quote, source: source, evidence: .passage(id: "p1", location: "1", quote: quote), statements: [], contrast: 0, linkedEntityIDs: [], people: ["川辺ヒロシ", "石野卓球"])
        func check(_ text: String) -> [StoryEvidenceIssue] {
            StoryEvidenceGuard().check(.init(story: .init(id: "s", entityID: "pool", title: text, body: "", source: source), factIDs: ["f1"]), facts: [fact], entityInfo: [], names: names)
        }
        XCTAssertTrue(check("宇多田光与川辺ヒロシ").isEmpty)
        XCTAssertTrue(check("《电锯人 蕾塞篇》").isEmpty)
        XCTAssertTrue(check("《 电锯人 蕾塞篇 》").isEmpty)
        XCTAssertFalse(check("《无依据的新作》").isEmpty)
        XCTAssertFalse(check("石野卓求说").isEmpty)
        XCTAssertTrue(names.payload.allSatisfy { $0["original"] != "石野卓球" }, "A source mention must not create a graph node")
    }
    func testNativeEditorialCopyDoesNotConfuseChineseGrammarWithNumbersOrJapaneseNames() {
        let quote = "牛尾：この曲がデンジとレゼのプールのシーンで使われた曲ですね。2023年のティザーPV制作時のB案としてあった「俺らの曲」です。もう少し曲自体を細切れのトラックにしようかと話していたんですが、繋がって組曲とした方が美しいかな、と思って作った。"
        let fact = StoryFact(id: "f1", text: "", source: source,
            evidence: .passage(id: "p1", location: "1", quote: quote), statements: [], contrast: 2, linkedEntityIDs: [], people: ["牛尾"])
        let table = StoryNameTable(nodes: [.init(id: "pool", name: "in the pool", kind: .song)])
        func check(_ body: String) -> [StoryEvidenceIssue] {
            StoryEvidenceGuard().check(.init(story: .init(id: "s", entityID: "pool", title: "", body: body, source: source), factIDs: ["f1"]),
                facts: [fact], entityInfo: [], names: table)
        }
        let actual = "牛尾原本与导演及演出团队讨论，要把《in the pool》切成更零碎的音轨，后来觉得连成组曲更美，便自行做成了组曲。这首用于デンジ与レゼ泳池场景的音乐，也是 2023 年制作先导 PV 时的 B 方案，当时被称作「俺らの曲」（我们的曲子）。"
        XCTAssertTrue(check(actual).isEmpty)
        XCTAssertTrue(check(actual.replacingOccurrences(of: "牛尾原本与", with: "牛尾与")).isEmpty)
        XCTAssertTrue(check("牛尾觉得连成「组曲」更美。").isEmpty)
        XCTAssertTrue(check("《组曲》").contains { $0.rule == .name }, "A work title still needs exact evidence")
        XCTAssertTrue(check(actual.replacingOccurrences(of: "2023", with: "2024")).contains { $0.rule == .number })
        XCTAssertTrue(check(actual.replacingOccurrences(of: "レゼ", with: "レゾ")).contains { $0.rule == .name })
        XCTAssertTrue(check("用了零个音轨。").contains { $0.rule == .number }, "Actual zero quantities remain checked")
    }
    func testEvidencedJapaneseNameCanTouchChineseNarrationWithoutAuthorizingMisspellings() {
        let quote = "浅野いにお コメント：原作者のわがままを聞いてくださったプロデューサーに感謝です。SHINSEKAIより。"
        let fact = StoryFact(id: "f1", text: "浅野いにを希望亲自作曲", source: source,
            evidence: .passage(id: "p1", location: "1", quote: quote), statements: [], contrast: 2, linkedEntityIDs: [], people: ["浅野いにお", "浅野いにを"])
        let table = StoryNameTable(nodes: [.init(id: "song", name: "SHINSEKAIより", kind: .song)])
        func check(_ body: String, mention: String = "浅野いにお") -> [StoryEvidenceIssue] {
            StoryEvidenceGuard().check(.init(story: .init(id: "s", entityID: "song", title: "", body: body, source: source, mentions: [mention]), factIDs: ["f1"]),
                facts: [fact], entityInfo: [], names: table)
        }
        for body in ["浅野いにお提出作曲。", "浅野いにお还希望亲自作曲。", "《SHINSEKAIより》的词曲出自原作者浅野いにお。"] {
            XCTAssertTrue(check(body).isEmpty, body)
        }
        XCTAssertTrue(check("浅野いにを还希望亲自作曲。", mention: "浅野いにを").contains { $0.rule == .name }, "An extractor or mention cannot authorize its own misspelling")
        XCTAssertTrue(check("浅野いにおお提出作曲。").contains { $0.rule == .name }, "Do not remove a known name from a longer Kana spelling")
        XCTAssertTrue(check("浅野いにお称作「我们两人」。").contains { $0.rule == .name && $0.token == "我们两人" })
        XCTAssertTrue(check("浅野いにお在 2025 年提出作曲。").contains { $0.rule == .number })
    }

}
private struct NoStoryRequests: StoryModelClient {
    func models() -> [String] { [] }
    func complete(system: String, user: String, maxTokens: Int) throws -> StoryModelReply { throw StoryModelError.connection }
}
