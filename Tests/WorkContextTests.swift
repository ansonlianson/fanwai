import XCTest
@testable import Pianwai

/// Exercises the real URLSession routes, decoding, identity checks and cache.
/// Fixture prose is test data; live source checks are separately gated.
@MainActor
final class WorkContextTests: XCTestCase {
    func testReadingExcerptOmitsOpeningAliasButPreservesVerbatimSourceAndStoredText() throws {
        let source = Source(title: "维基百科 · 驾驶我的车", detail: "导语摘录 · CC BY-SA 4.0",
                            url: "https://zh.wikipedia.org/w/index.php?oldid=876543")
        let raw = "《驾驶我的车》（日语：ドライブ・マイ・カー，英语：Drive My Car）是一部日本电影。"
        let context = WorkContext(qid: "Q107107865", introduction: raw, language: "zh", introductionSource: source)
        XCTAssertEqual(context.readingExcerpt, "《驾驶我的车》是一部日本电影。")
        XCTAssertEqual(context.introduction, raw)
        XCTAssertEqual(context.introductionSource, source)
        let reloaded = try JSONDecoder().decode(WorkContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(reloaded.introduction, raw, "Shortening the first screen must not rewrite the stored source excerpt")
        XCTAssertEqual(reloaded.introductionSource, source)
        XCTAssertEqual(reloaded.readingExcerpt, context.readingExcerpt)

        let english = WorkContext(qid: "Q100", introduction: "A Book (Japanese: 本, Hepburn: Hon) is a novel.")
        XCTAssertEqual(english.readingExcerpt, "A Book is a novel.")
    }

    func testReadingExcerptPreservesStoryParenthesesAndAliasesOutsideOpening() {
        for raw in [
            "主人公（失去妻子的演员）接受了一个舞台角色。",
            "主人公（在日本生活，日语：日常使用的语言）开始了一段旅程。",
            "主人公（演员）在片中读了一本书（日语：本）。",
            String(repeating: "序", count: 90) + "（日语：別名）之后的内容。"
        ] {
            XCTAssertEqual(WorkContext(qid: "Q100", introduction: raw).readingExcerpt, raw)
        }
    }

    func testReadingExcerptRequiresCompleteBalancedGlossAndOmitsOnlyOne() {
        for raw in ["《作品》（日语：未闭合的别名", "A Book (Japanese: Hon (romanization)"] {
            XCTAssertEqual(WorkContext(qid: "Q100", introduction: raw).readingExcerpt, raw)
        }
        let nested = "《作品》（日语：別名（読み：べつめい））讲述了一段旅程（由真实经历改编）。"
        XCTAssertEqual(WorkContext(qid: "Q100", introduction: nested).readingExcerpt,
                       "《作品》讲述了一段旅程（由真实经历改编）。")
        let englishNested = "A Book (Japanese: Hon (romanization)) is a novel (English: a later alias)."
        XCTAssertEqual(WorkContext(qid: "Q100", introduction: englishNested).readingExcerpt,
                       "A Book is a novel (English: a later alias).")
    }

    func testExactItemSitelinkAndArticleIdentityProduceRevisionBoundSource() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")),
            .article("Exact Film", contextArticle("Q100", title: "Resolved Film Title", text: "A source introduction.", revision: 876543)),
            .display(876543, contextDisplay("Resolved Film Title", revision: 876543))
        ]); defer { h.close() }
        let result = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(result.qid, "Q100")
        XCTAssertEqual(result.introduction, "A source introduction.")
        XCTAssertEqual(result.language, "zh")
        XCTAssertFalse(result.introductionUnavailable)
        XCTAssertEqual(result.article, WikiArticleIdentity(qid: "Q100", title: "Resolved Film Title", language: "zh", pageID: 1234, revision: 876543))
        let source = try XCTUnwrap(result.introductionSource)
        XCTAssertEqual(source.title, "维基百科 · Resolved Film Title")
        XCTAssertEqual(source.url, "https://zh.wikipedia.org/w/index.php?oldid=876543")
        XCTAssertTrue(source.detail.contains("CC BY-SA"))
        XCTAssertEqual(h.parameters(at: 0)["ids"], "Q100")
        XCTAssertEqual(h.parameters(at: 0)["props"], "labels|claims|sitelinks")
        XCTAssertEqual(h.parameters(at: 1)["titles"], "Exact Film")
        XCTAssertEqual(h.parameters(at: 1)["ppprop"], "wikibase_item|disambiguation")
        XCTAssertNil(h.parameters(at: 1)["search"], "Titles come from the exact item's sitelink, not a search")
        let duration = try XCTUnwrap(result.facts.first { $0.label == "时长" })
        XCTAssertEqual(duration.value, "180 分钟")
        XCTAssertEqual(URLComponents(string: duration.source.url)?.fragment, contextStatementID("Q100"))
    }

    func testInvalidQIDNeverReachesTransport() async throws {
        let h = try WorkContextHarness(plans: []); defer { h.close() }
        for qid in ["", "Q", "Q0", "Q01", "q100", "Q100|Q200", "Q１００", "Q100&ids=Q200"] {
            do { _ = try await h.service.fetch(qid: qid); XCTFail("Accepted invalid QID: \(qid)") }
            catch WorkContextError.invalidIdentity { }
        }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testMismatchedEntityIdentityIsRejectedBeforeArticleRequest() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q999", claims: [:], article: "Same Title"))
        ]); defer { h.close() }
        do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Accepted a different item under the requested key") }
        catch WorkContextError.invalidResponse { }
        XCTAssertEqual(h.requests.count, 1)
    }

    func testWrongMissingOrDisambiguationArticleCannotAttachItsText() async throws {
        let cases: [[String: Any]] = [
            contextArticle("Q999", title: "Exact Film", text: "Wrong item's introduction."),
            contextArticle("Q100", title: "Exact Film", text: "Disambiguation text.", extras: ["pageprops": ["wikibase_item": "Q100", "disambiguation": ""]]),
            contextArticle("Q100", title: "Exact Film", text: "Missing page text.", extras: ["missing": true]),
            contextArticle("Q100", title: "Exact Film", text: "Talk page text.", extras: ["ns": 1]),
            ["query": ["pages": []]]
        ]
        for article in cases {
            let h = try WorkContextHarness(plans: [
                .entity("Q100", contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")),
                .article("Exact Film", article)
            ]); defer { h.close() }
            let result = try await h.service.fetch(qid: "Q100")
            XCTAssertNil(result.introduction)
            XCTAssertNil(result.introductionSource)
            XCTAssertTrue(result.introductionUnavailable)
            XCTAssertFalse(result.facts.isEmpty)
            XCTAssertFalse(result.destinations.isEmpty)
        }
    }

    func testMissingExcerptOrRevisionIsExplicitlyUnavailable() async throws {
        let cases = [
            contextArticle("Q100", title: "Exact Film", text: "  \n "),
            contextArticle("Q100", title: "Exact Film", text: "An unattributable excerpt.", revision: 0),
            contextArticle("Q100", title: "Exact Film", text: "An unattributable excerpt.", extras: ["lastrevid": NSNull()])
        ]
        for (index, article) in cases.enumerated() {
            var plans: [WorkContextPlan] = try [
                .entity("Q100", contextEntity("Q100", claims: [:], article: "Exact Film")),
                .article("Exact Film", article)
            ]
            if index == 0 { plans.append(try .display(12345, contextDisplay("Exact Film", revision: 12345))) }
            let h = try WorkContextHarness(plans: plans); defer { h.close() }
            let result = try await h.service.fetch(qid: "Q100")
            XCTAssertTrue(result.introductionUnavailable)
            XCTAssertNil(result.introduction)
            XCTAssertNil(result.introductionSource)
        }
    }

    func testNameQualifiedMovieDestinationAndIMDbTitleKeepExactStatementSources() async throws {
        let qid = "Q100"
        var namedDouban = contextExternal(qid, "3541415")
        namedDouban["qualifiers"] = ["P1810": [contextSnak(datatype: "string", value: "数据库显示名")]]
        var restrictedDouban = contextExternal(qid, "9999999")
        restrictedDouban["qualifiers"] = ["P580": [contextSnak(datatype: "time", value: contextTime(2020))]]
        let claims = [
            "P31": [contextItem(qid, "Q11424")],
            "P4529": [namedDouban, namedDouban, restrictedDouban, contextExternal(qid, "03541415")],
            "P345": [contextExternal(qid, "tt14039582"), contextExternal(qid, "nm0123456")]
        ]
        let h = try WorkContextHarness(plans: [.entity(qid, contextEntity(qid, claims: claims))]); defer { h.close() }
        let result = try await h.service.fetch(qid: qid)
        XCTAssertEqual(Set(result.destinations.map(\.url)), ["https://movie.douban.com/subject/3541415/", "https://www.imdb.com/title/tt14039582/"])
        XCTAssertEqual(result.destinations.count, 2, "Identical destination URLs are not repeated")
        for destination in result.destinations {
            XCTAssertEqual(URLComponents(string: destination.source.url)?.fragment, contextStatementID(qid))
        }
    }

    func testBookEditionDestinationIsLabelledAsThisVersion() async throws {
        var edition = contextExternal("Q200", "27017945")
        edition["qualifiers"] = ["P1810": [contextSnak(datatype: "string", value: "某版本书名")]]
        let h = try WorkContextHarness(plans: [.entity("Q200", contextEntity("Q200", claims: [
            "P31": [contextItem("Q200", "Q571")], "P6442": [edition],
            "P4529": [contextExternal("Q200", "12345")], "P345": [contextExternal("Q200", "tt12345")]
        ]))]); defer { h.close() }
        let result = try await h.service.fetch(qid: "Q200")
        XCTAssertEqual(result.destinations.count, 1)
        XCTAssertEqual(result.destinations.first?.title, "豆瓣 · 此版本")
        XCTAssertEqual(result.destinations.first?.url, "https://book.douban.com/subject/27017945/")
        XCTAssertEqual(URLComponents(string: result.destinations.first?.source.url ?? "")?.fragment, contextStatementID("Q200"))
    }

    func testQualifiedDurationAndRegionalDateAreNotFlattenedIntoGeneralFacts() async throws {
        var duration = contextQuantity("Q100", amount: "+180", unit: "Q7727")
        duration["qualifiers"] = ["P518": [contextSnak(datatype: "wikibase-item", value: ["id": "Q123"])]]
        var date = contextDate("Q100", 2021)
        date["qualifiers"] = ["P291": [contextSnak(datatype: "wikibase-item", value: ["id": "Q17"])]]
        let h = try WorkContextHarness(plans: [.entity("Q100", contextEntity("Q100", claims: ["P2047": [duration], "P577": [date]]))]); defer { h.close() }
        let result = try await h.service.fetch(qid: "Q100")
        XCTAssertTrue(result.facts.isEmpty)
    }

    func testConflictingDurationAndYearsAreOmittedWhileEquivalentUnitsAgree() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q100", claims: [
                "P2047": [contextQuantity("Q100", amount: "+179", unit: "Q7727"), contextQuantity("Q100", amount: "+180", unit: "Q7727")],
                "P577": [contextDate("Q100", 2020), contextDate("Q100", 2021)]
            ])),
            .entity("Q200", contextEntity("Q200", claims: [
                "P2047": [contextQuantity("Q200", amount: "+180", unit: "Q7727"), contextQuantity("Q200", amount: "+10800", unit: "Q11574")],
                "P577": [contextDate("Q200", 2021), contextDate("Q200", 2021)]
            ]))
        ]); defer { h.close() }
        let conflicting = try await h.service.fetch(qid: "Q100")
        XCTAssertTrue(conflicting.facts.isEmpty)
        let matching = try await h.service.fetch(qid: "Q200")
        XCTAssertEqual(matching.facts.first { $0.label == "时长" }?.value, "180 分钟")
        XCTAssertEqual(matching.facts.first { $0.label == "发行年份" }?.value, "2021")
    }

    func testArticleHTTPFailureRetainsIndependentFactsAndDestinations() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")),
            .article("Exact Film", [:], status: 503)
        ]); defer { h.close() }
        let result = try await h.service.fetch(qid: "Q100")
        XCTAssertTrue(result.introductionUnavailable)
        XCTAssertNil(result.introduction)
        XCTAssertEqual(result.facts.first { $0.label == "发行年份" }?.value, "2021")
        XCTAssertEqual(result.destinations.first?.url, "https://movie.douban.com/subject/3541415/")
    }

    func testNoSupportedSitelinkIsAbsentRatherThanFailedAndEnglishUsesExactMapping() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q100", claims: [:])),
            .entity("Q200", contextEntity("Q200", claims: [:], article: "Exact Book", language: "en")),
            .article("Exact Book", contextArticle("Q200", title: "Exact Book", text: "An English source excerpt."), language: "en")
        ]); defer { h.close() }
        let absent = try await h.service.fetch(qid: "Q100")
        XCTAssertNil(absent.introduction)
        XCTAssertFalse(absent.introductionUnavailable)
        let english = try await h.service.fetch(qid: "Q200")
        XCTAssertEqual(english.language, "en")
        XCTAssertEqual(URLComponents(string: english.introductionSource?.url ?? "")?.host, "en.wikipedia.org")
    }

    func testStoreReloadsFreshVerifiedCacheWithoutAnotherRequest() async throws {
        let h = try WorkContextHarness(plans: [
            .entity("Q100", contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")),
            .article("Exact Film", contextArticle("Q100", title: "Exact Film", text: "A cached introduction.", revision: 101)),
            .display(101, contextDisplay("Exact Film", revision: 101))
        ]); defer { h.close() }
        let store = WorkContextStore(service: h.service, directory: h.directory)
        await store.load("Q100")
        await store.loadDisplayTitle("Q100")
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertNil(store.errors["Q100"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("Q100.json").path))
        let reloaded = WorkContextStore(service: h.service, directory: h.directory)
        await reloaded.load("Q100")
        XCTAssertEqual(reloaded.values["Q100"]?.introduction, "A cached introduction.")
        XCTAssertEqual(reloaded.values["Q100"]?.introductionSource, store.values["Q100"]?.introductionSource)
        XCTAssertEqual(reloaded.values["Q100"]?.facts.map(\.id), store.values["Q100"]?.facts.map(\.id))
        XCTAssertEqual(reloaded.values["Q100"]?.destinations.map(\.url), store.values["Q100"]?.destinations.map(\.url))
        XCTAssertEqual(reloaded.values["Q100"]?.displayTitle, "测试电影")
        XCTAssertEqual(reloaded.values["Q100"]?.displayTitleSource, store.values["Q100"]?.displayTitleSource)
        XCTAssertEqual(h.requests.count, 3)
    }

    func testStoreRetryRetainsGoodIntroductionThroughPartialAndTotalFailureThenRecovers() async throws {
        let entity = contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")
        let h = try WorkContextHarness(plans: [
            .entity("Q100", entity), .article("Exact Film", contextArticle("Q100", title: "Exact Film", text: "Good introduction.", revision: 101)),
            .display(101, contextDisplay("Exact Film", revision: 101)),
            .entity("Q100", entity), .article("Exact Film", [:], status: 503),
            .entity("Q100", entity, status: 503),
            .entity("Q100", entity), .article("Exact Film", contextArticle("Q100", title: "Exact Film", text: "Updated introduction.", revision: 202)),
            .display(202, contextDisplay("Exact Film", revision: 202))
        ]); defer { h.close() }
        let store = WorkContextStore(service: h.service, directory: h.directory)
        await store.load("Q100")
        await store.loadDisplayTitle("Q100")
        let originalSource = store.values["Q100"]?.introductionSource
        let originalArticle = try XCTUnwrap(store.values["Q100"]?.article)
        let originalTitleSource = store.values["Q100"]?.displayTitleSource
        await store.load("Q100", retry: true)
        XCTAssertEqual(store.values["Q100"]?.introduction, "Good introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource, originalSource)
        XCTAssertEqual(store.values["Q100"]?.article, originalArticle,
                       "A partial refresh must keep the identity used to read cached background")
        XCTAssertEqual(store.values["Q100"]?.displayTitle, "测试电影")
        XCTAssertEqual(store.values["Q100"]?.displayTitleSource, originalTitleSource)
        let onDisk = try JSONDecoder().decode(WorkContext.self, from: Data(contentsOf: h.directory.appendingPathComponent("Q100.json")))
        XCTAssertEqual(onDisk.article, originalArticle)
        XCTAssertEqual(onDisk.article?.cacheKey, originalArticle.cacheKey)
        XCTAssertEqual(store.values["Q100"]?.language, "zh")
        XCTAssertEqual(store.values["Q100"]?.introductionUnavailable, true)
        XCTAssertNotNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
        await store.load("Q100")
        XCTAssertEqual(h.requests.count, 5, "A repeated page render is not an automatic retry loop")
        await store.load("Q100", retry: true)
        XCTAssertEqual(store.values["Q100"]?.introduction, "Good introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource, originalSource)
        XCTAssertFalse(store.values["Q100"]?.facts.isEmpty ?? true)
        XCTAssertFalse(store.values["Q100"]?.destinations.isEmpty ?? true)
        XCTAssertNotNil(store.errors["Q100"])
        await store.load("Q100", retry: true)
        await store.loadDisplayTitle("Q100")
        XCTAssertEqual(store.values["Q100"]?.introduction, "Updated introduction.")
        XCTAssertEqual(store.values["Q100"]?.article?.revision, 202)
        XCTAssertNotEqual(store.values["Q100"]?.article?.cacheKey, originalArticle.cacheKey,
                          "A successful new revision must use its own background cache")
        XCTAssertEqual(store.values["Q100"]?.introductionSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=202")
        XCTAssertEqual(store.values["Q100"]?.introductionUnavailable, false)
        XCTAssertNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
    }

    func testHTTP200MaxlagIsUnavailableAndStoreRetryPreservesThenRefreshesGoodContext() async throws {
        let entity = contextEntity("Q100", claims: contextFilmClaims("Q100"), article: "Exact Film")
        let maxlag = WorkContextPlan(
            host: "www.wikidata.org", identityKey: "ids", identity: "Q100", action: "wbgetentities", status: 200,
            data: try JSONSerialization.data(withJSONObject: [
                "error": ["code": "maxlag", "info": "Waiting for replication lag"], "servedby": "fixture-api"
            ])
        )
        let h = try WorkContextHarness(plans: [
            maxlag,
            .entity("Q100", entity), .article("Exact Film", contextArticle("Q100", title: "Exact Film", text: "Good introduction.", revision: 101)),
            .display(101, contextDisplay("Exact Film", revision: 101)),
            maxlag,
            .entity("Q100", entity), .article("Exact Film", contextArticle("Q100", title: "Exact Film", text: "Recovered introduction.", revision: 202)),
            .display(202, contextDisplay("Exact Film", revision: 202))
        ]); defer { h.close() }

        do {
            _ = try await h.service.fetch(qid: "Q100")
            XCTFail("An HTTP 200 API error must not publish a successful empty context")
        } catch WorkContextError.unavailable {
            // A temporary upstream API failure is distinct from malformed entity data.
        } catch {
            XCTFail("Expected unavailable rather than invalidResponse: \(error)")
        }

        let store = WorkContextStore(service: h.service, directory: h.directory)
        await store.load("Q100")
        await store.loadDisplayTitle("Q100")
        let previous = try XCTUnwrap(store.values["Q100"])
        let cachedBefore = try Data(contentsOf: h.directory.appendingPathComponent("Q100.json"))

        await store.load("Q100", retry: true)
        XCTAssertNotNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
        XCTAssertEqual(store.values["Q100"]?.introduction, previous.introduction)
        XCTAssertEqual(store.values["Q100"]?.introductionSource, previous.introductionSource)
        XCTAssertEqual(store.values["Q100"]?.facts.map(\.id), previous.facts.map(\.id))
        XCTAssertEqual(store.values["Q100"]?.destinations.map(\.url), previous.destinations.map(\.url))
        XCTAssertEqual(try Data(contentsOf: h.directory.appendingPathComponent("Q100.json")), cachedBefore,
                       "An API error must not overwrite the last good disk cache")

        await store.load("Q100")
        XCTAssertEqual(h.requests.count, 5, "A view update must not silently loop the failed API request")
        await store.load("Q100", retry: true)
        await store.loadDisplayTitle("Q100")
        XCTAssertEqual(store.values["Q100"]?.introduction, "Recovered introduction.")
        XCTAssertEqual(store.values["Q100"]?.introductionSource?.url, "https://zh.wikipedia.org/w/index.php?oldid=202")
        XCTAssertNil(store.errors["Q100"])
        XCTAssertFalse(store.loading.contains("Q100"))
    }

    func testLiveDriveMyCarContextHasAnAttributedIntroduction() async throws {
        try await assertLiveContext("Q107107865")
    }

    func testLiveMemoryPoliceContextHasAnAttributedIntroduction() async throws {
        try await assertLiveContext("Q85721227")
    }

    private func assertLiveContext(_ qid: String) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 for real work-context sources")
        XCTAssertFalse(KnowledgeAnchors.verified.values.contains(qid), "This probe must exercise a nonseeded work")
        let result = try await WorkContextService().fetch(qid: qid)
        XCTAssertEqual(result.qid, qid)
        XCTAssertFalse(result.introductionUnavailable)
        XCTAssertGreaterThan(try XCTUnwrap(result.introduction).count, 20)
        let source = try XCTUnwrap(result.introductionSource)
        let url = try XCTUnwrap(URLComponents(string: source.url))
        XCTAssertTrue(["zh.wikipedia.org", "en.wikipedia.org"].contains(url.host ?? ""))
        XCTAssertEqual(url.path, "/w/index.php")
        XCTAssertGreaterThan(Int(url.queryItems?.first { $0.name == "oldid" }?.value ?? "") ?? 0, 0)
        XCTAssertTrue(result.destinations.allSatisfy { URLComponents(string: $0.source.url)?.path == "/wiki/\(qid)" })
    }
}

private func contextStatementID(_ qid: String) -> String { qid + "$11111111-1111-1111-1111-111111111111" }
private func contextSnak(datatype: String, value: Any) -> [String: Any] {
    ["snaktype": "value", "datatype": datatype, "datavalue": ["value": value]]
}
private func contextClaim(_ qid: String, datatype: String, value: Any) -> [String: Any] {
    ["id": contextStatementID(qid), "rank": "normal", "mainsnak": contextSnak(datatype: datatype, value: value)]
}
private func contextExternal(_ qid: String, _ value: String) -> [String: Any] { contextClaim(qid, datatype: "external-id", value: value) }
private func contextItem(_ qid: String, _ target: String) -> [String: Any] { contextClaim(qid, datatype: "wikibase-item", value: ["id": target]) }
private func contextQuantity(_ qid: String, amount: String, unit: String) -> [String: Any] {
    contextClaim(qid, datatype: "quantity", value: ["amount": amount, "unit": "http://www.wikidata.org/entity/\(unit)"])
}
private func contextTime(_ year: Int) -> [String: Any] {
    ["time": "+\(year)-01-01T00:00:00Z", "precision": 11, "calendarmodel": "http://www.wikidata.org/entity/Q1985727"]
}
private func contextDate(_ qid: String, _ year: Int) -> [String: Any] { contextClaim(qid, datatype: "time", value: contextTime(year)) }
private func contextFilmClaims(_ qid: String) -> [String: [[String: Any]]] {
    ["P31": [contextItem(qid, "Q11424")], "P2047": [contextQuantity(qid, amount: "+180", unit: "Q7727")],
     "P577": [contextDate(qid, 2021)], "P4529": [contextExternal(qid, "3541415")]]
}
private func contextEntity(_ qid: String, claims: [String: [[String: Any]]], article: String? = nil, language: String = "zh") -> [String: Any] {
    var entity: [String: Any] = ["id": qid, "type": "item", "labels": ["zh-hans": ["value": "Fixture Work"]], "claims": claims]
    if let article { entity["sitelinks"] = [language + "wiki": ["site": language + "wiki", "title": article]] }
    return entity
}
private func contextArticle(_ qid: String, title: String, text: String, revision: Int = 12345, extras: [String: Any] = [:]) -> [String: Any] {
    let page: [String: Any] = ["title": title, "pageid": 1234, "ns": 0, "extract": text, "lastrevid": revision,
                               "pageprops": ["wikibase_item": qid], "fullurl": "https://untrusted.example/not-the-source"]
    return ["query": ["pages": [page.merging(extras) { _, new in new }]]]
}
private func contextDisplay(_ title: String, revision: Int) -> [String: Any] {
    ["parse": ["title": title, "pageid": 1234, "revid": revision, "displaytitle": "<span>测试电影</span>"]]
}

struct WorkContextPlan: Sendable {
    let host: String
    let identityKey: String
    let identity: String
    let action: String
    let status: Int
    let data: Data
    static func entity(_ qid: String, _ entity: [String: Any], status: Int = 200) throws -> Self {
        Self(host: "www.wikidata.org", identityKey: "ids", identity: qid, action: "wbgetentities", status: status,
             data: try JSONSerialization.data(withJSONObject: ["success": 1, "entities": [qid: entity]]))
    }
    static func article(_ title: String, _ payload: [String: Any], language: String = "zh", status: Int = 200) throws -> Self {
        Self(host: language + ".wikipedia.org", identityKey: "titles", identity: title, action: "query", status: status,
             data: try JSONSerialization.data(withJSONObject: payload))
    }
    static func display(_ revision: Int, _ payload: [String: Any], status: Int = 200) throws -> Self {
        Self(host: "zh.wikipedia.org", identityKey: "oldid", identity: String(revision), action: "parse", status: status,
             data: try JSONSerialization.data(withJSONObject: payload))
    }
    func matches(_ request: URLRequest) -> Bool {
        guard let raw = request.url, let url = URLComponents(url: raw, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == host, url.path == "/w/api.php" else { return false }
        let parameters = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        return parameters["action"] == action && parameters[identityKey] == identity
    }
}

final class WorkContextHarness: @unchecked Sendable {
    let service: WorkContextService
    let directory: URL
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: WorkContextStubState
    init(plans: [WorkContextPlan]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiContextTests-" + UUID().uuidString, isDirectory: true)
        state = WorkContextStubState(plans: plans)
        WorkContextStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkContextURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Work-Context-Test": token]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        service = WorkContextService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(at index: Int) -> [String: String] {
        guard requests.indices.contains(index), let url = requests[index].url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.remaining, 0, "Expected routes were not requested", file: file, line: line)
        XCTAssertTrue(state.unexpected.isEmpty, "Unexpected routes: \(state.unexpected)", file: file, line: line)
        session.invalidateAndCancel()
        WorkContextStubRegistry.shared.remove(token)
        try? FileManager.default.removeItem(at: directory)
    }
}
private final class WorkContextStubRegistry: @unchecked Sendable {
    static let shared = WorkContextStubRegistry()
    private let lock = NSLock()
    private var values: [String: WorkContextStubState] = [:]
    func put(_ key: String, _ value: WorkContextStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> WorkContextStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class WorkContextStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [WorkContextPlan]
    private var observed: [URLRequest] = []
    private var unmatched: [String] = []
    init(plans: [WorkContextPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return plans.count }
    var unexpected: [String] { lock.lock(); defer { lock.unlock() }; return unmatched }
    func next(_ request: URLRequest) -> WorkContextPlan? {
        lock.lock(); defer { lock.unlock() }
        observed.append(request)
        guard let index = plans.firstIndex(where: { $0.matches(request) }) else {
            unmatched.append(request.url?.absoluteString ?? "missing URL"); return nil
        }
        return plans.remove(at: index)
    }
}
private final class WorkContextURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = WorkContextStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Work-Context-Test")),
              let plan = state.next(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
