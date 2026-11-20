import XCTest
@testable import Pianwai

@MainActor
final class WorkDisplayNameTests: XCTestCase {
    func testRegionalDisplayTitleKeepsExactArticleIdentityAndPinnedSources() async throws {
        let h = try WorkContextHarness(plans: displayNamePlans("<span lang=\"zh-Hans-CN\"><span class=\"mw-page-title-main\">偶然与想像</span></span>"))
        defer { h.close() }
        let result = try await h.service.fetch(qid: "Q105481082")

        XCTAssertEqual(result.displayTitle, "偶然与想像")
        XCTAssertEqual(result.displayTitleState, .available)
        XCTAssertEqual(result.article?.title, "偶然與想像", "Presentation must not rewrite the exact source title")
        XCTAssertEqual(result.article?.qid, "Q105481082")
        XCTAssertEqual(result.article?.pageID, 7606247)
        XCTAssertEqual(result.article?.revision, 92804669)
        XCTAssertEqual(result.introduction, "一部由三个短篇故事组成的电影。")
        XCTAssertEqual(result.introductionSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=92804669")
        XCTAssertEqual(result.displayTitleSource?.title, "维基百科 · 偶然與想像")
        XCTAssertEqual(result.displayTitleSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=92804669&variant=zh-cn")
        XCTAssertEqual(result.contentVersion, 3)
        XCTAssertFalse(result.introductionUnavailable)
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertEqual(h.parameters(at: 2)["action"], "parse")
        XCTAssertEqual(h.parameters(at: 2)["oldid"], "92804669")
        XCTAssertEqual(h.parameters(at: 2)["prop"], "displaytitle")
        XCTAssertEqual(h.parameters(at: 2)["variant"], "zh-cn")
        XCTAssertEqual(h.parameters(at: 2)["formatversion"], "2")
        XCTAssertNil(h.parameters(at: 2)["page"])
        XCTAssertNil(h.parameters(at: 2)["search"])
    }

    func testWrongPageRevisionOrCanonicalTitleCannotAttachDisplayTitle() async throws {
        for change: [String: Any] in [
            ["pageid": 1], ["revid": 92804670], ["title": "另一个条目"],
            ["pageid": NSNull()], ["revid": NSNull()]
        ] {
            let response = displayNamePayload("偶然与想像", changes: change)
            let h = try WorkContextHarness(plans: displayNamePlans(response: response))
            defer { h.close() }
            let result = try await h.service.fetch(qid: "Q105481082")
            XCTAssertNil(result.displayTitle)
            XCTAssertNil(result.displayTitleSource)
            XCTAssertEqual(result.displayTitleState, .failed)
            XCTAssertEqual(result.introduction, "一部由三个短篇故事组成的电影。")
            XCTAssertFalse(result.introductionUnavailable)
            XCTAssertEqual(result.article?.title, "偶然與想像")
        }
    }

    func testEnglishEmptyOrOversizedTitlesAreAbsentWithoutTranslation() async throws {
        for html in ["   \n ", "Wheel of Fortune and Fantasy", String(repeating: "名", count: 241),
                     "<script>伪标题</script><span>Wheel of Fortune and Fantasy</span>"] {
            let h = try WorkContextHarness(plans: displayNamePlans(html))
            defer { h.close() }
            let result = try await h.service.fetch(qid: "Q105481082")
            XCTAssertNil(result.displayTitle)
            XCTAssertNil(result.displayTitleSource)
            XCTAssertEqual(result.displayTitleState, html.count > 240 ? .failed : .absent)
            XCTAssertNotNil(result.introduction)
            XCTAssertFalse(result.introductionUnavailable)
        }
    }

    func testDisplayHTMLBecomesPlainTextAndDoesNotExposeMarkupOrScripts() async throws {
        let h = try WorkContextHarness(plans: displayNamePlans("<style>伪标题</style><span><b>偶然与想像</b> &amp; 音乐</span><script>另一个伪标题</script>"))
        defer { h.close() }
        let result = try await h.service.fetch(qid: "Q105481082")
        XCTAssertEqual(result.displayTitle, "偶然与想像 & 音乐")
    }

    func testOptionalHTTPAPIOrDecodingFailureKeepsVerifiedIntroductionAndFacts() async throws {
        let failures = [
            try WorkContextPlan.display(92804669, [:], status: 503),
            try WorkContextPlan.display(92804669, ["error": ["code": "maxlag"]]),
            WorkContextPlan(host: "zh.wikipedia.org", identityKey: "oldid", identity: "92804669", action: "parse", status: 200,
                            data: Data("not-json".utf8))
        ]
        for failure in failures {
            var plans = try displayNameInitialPlans()
            plans.append(failure)
            let h = try WorkContextHarness(plans: plans)
            defer { h.close() }
            let result = try await h.service.fetch(qid: "Q105481082")
            XCTAssertNil(result.displayTitle)
            XCTAssertNil(result.displayTitleSource)
            XCTAssertEqual(result.displayTitleState, .failed)
            XCTAssertEqual(result.introduction, "一部由三个短篇故事组成的电影。")
            XCTAssertEqual(result.facts.first { $0.label == "发行年份" }?.value, "2021")
            XCTAssertFalse(result.introductionUnavailable)
        }
    }

    func testEnglishArticleDoesNotRequestChineseDisplayTitle() async throws {
        let h = try WorkContextHarness(plans: displayNameInitialPlans(language: "en", title: "Wheel of Fortune and Fantasy"))
        defer { h.close() }
        let result = try await h.service.fetch(qid: "Q105481082")
        XCTAssertEqual(result.article?.language, "en")
        XCTAssertNil(result.displayTitle)
        XCTAssertNil(result.displayTitleSource)
        XCTAssertEqual(h.requests.count, 2)
    }

    func testOldContextsDecodeWithoutPresentationFieldsOrVersion() throws {
        let original = WorkContext(qid: "Q105481082", contentVersion: 2, introduction: "已有简介。", language: "zh")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "displayTitle")
        payload.removeValue(forKey: "displayTitleSource")
        let previous = try JSONDecoder().decode(WorkContext.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(previous.contentVersion, 2)
        XCTAssertEqual(previous.introduction, "已有简介。")
        XCTAssertNil(previous.displayTitle)
        XCTAssertNil(previous.displayTitleSource)
        XCTAssertNil(previous.displayTitleState)
        XCTAssertNil(previous.displayTitleAttemptedAt)

        payload.removeValue(forKey: "contentVersion")
        let unversioned = try JSONDecoder().decode(WorkContext.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(unversioned.contentVersion, "An old record cannot accidentally look like a fresh v3 cache")
        XCTAssertEqual(unversioned.introduction, "已有简介。")
    }

    func testVersionTwoCacheRefreshesAndVersionThreeRestoresDisplayEvidence() async throws {
        let h = try WorkContextHarness(plans: displayNamePlans("偶然与想像"))
        defer { h.close() }
        let previous = WorkContext(qid: "Q105481082", contentVersion: 2, introduction: "已有简介。", language: "zh")
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(previous).write(to: h.directory.appendingPathComponent("Q105481082.json"))

        let store = WorkContextStore(service: h.service, directory: h.directory)
        await store.load("Q105481082")
        await store.loadDisplayTitle("Q105481082")
        XCTAssertEqual(store.values["Q105481082"]?.contentVersion, 3)
        XCTAssertEqual(store.values["Q105481082"]?.displayTitle, "偶然与想像")
        XCTAssertNil(store.errors["Q105481082"])
        XCTAssertEqual(h.requests.count, 3)

        let reloaded = WorkContextStore(service: h.service, directory: h.directory)
        await reloaded.load("Q105481082")
        XCTAssertEqual(reloaded.values["Q105481082"]?.displayTitle, "偶然与想像")
        XCTAssertEqual(reloaded.values["Q105481082"]?.displayTitleSource, store.values["Q105481082"]?.displayTitleSource)
        XCTAssertEqual(reloaded.values["Q105481082"]?.article, store.values["Q105481082"]?.article)
        XCTAssertEqual(h.requests.count, 3, "A verified v3 presentation cache must not be fetched again")
    }
}

private func displayNameInitialPlans(language: String = "zh", title: String = "偶然與想像") throws -> [WorkContextPlan] {
    let entity: [String: Any] = [
        "id": "Q105481082", "type": "item",
        "labels": ["zh-hans": ["value": "偶然與想象之輪"]],
        "sitelinks": [language + "wiki": ["site": language + "wiki", "title": title]],
        "claims": ["P577": [[
            "id": "Q105481082$11111111-1111-1111-1111-111111111111", "rank": "normal",
            "mainsnak": ["snaktype": "value", "datatype": "time", "datavalue": ["value": [
                "time": "+2021-01-01T00:00:00Z", "precision": 9,
                "calendarmodel": "http://www.wikidata.org/entity/Q1985727"
            ]]]
        ]]]
    ]
    let article: [String: Any] = ["query": ["pages": [[
        "title": title, "pageid": 7606247, "ns": 0, "lastrevid": 92804669,
        "pageprops": ["wikibase_item": "Q105481082"], "extract": "一部由三个短篇故事组成的电影。"
    ]]]]
    return try [.entity("Q105481082", entity), .article(title, article, language: language)]
}

private func displayNamePayload(_ html: String, changes: [String: Any] = [:]) -> [String: Any] {
    let parse: [String: Any] = ["title": "偶然與想像", "pageid": 7606247, "revid": 92804669, "displaytitle": html]
    return ["parse": parse.merging(changes) { _, new in new }]
}

private func displayNamePlans(_ html: String) throws -> [WorkContextPlan] {
    try displayNamePlans(response: displayNamePayload(html))
}

private func displayNamePlans(response: [String: Any]) throws -> [WorkContextPlan] {
    var plans = try displayNameInitialPlans()
    plans.append(try .display(92804669, response))
    return plans
}
