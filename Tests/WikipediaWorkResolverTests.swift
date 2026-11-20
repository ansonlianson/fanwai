import XCTest
@testable import Pianwai

final class WikipediaWorkResolverTests: XCTestCase, @unchecked Sendable {
    func testExplicitNormalizationAndRedirectRequireMatchingWikidataBacklink() async throws {
        var article = resolverArticle(title: "Exact Film", qid: "Q100")
        var query = article["query"] as! [String: Any]
        query["normalized"] = [["from": "old name", "to": "Old name"]]
        query["redirects"] = [["from": "Old name", "to": "Exact Film"]]
        article["query"] = query
        let h = try ResolverHarness(plans: [
            .json(article), .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact_Film"))
        ]); defer { h.close() }
        let result = try await h.service.resolve(.init(label: "A different display label", title: " old_name ", language: "en"))
        XCTAssertEqual(result, "Q100")
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(h.requests[0].url?.host, "en.wikipedia.org")
        XCTAssertEqual(h.parameters(at: 0)["titles"], "old name")
        XCTAssertEqual(h.parameters(at: 0)["redirects"], "1")
        XCTAssertEqual(h.parameters(at: 0)["ppprop"], "wikibase_item|disambiguation")
        XCTAssertEqual(h.requests[1].url?.host, "www.wikidata.org")
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q100")
        XCTAssertEqual(h.parameters(at: 1)["sitefilter"], "enwiki")
        XCTAssertEqual(h.parameters(at: 1)["props"], "sitelinks|claims")
        for index in h.requests.indices {
            XCTAssertNil(h.parameters(at: index)["search"])
            XCTAssertNil(h.parameters(at: index)["srsearch"])
            XCTAssertEqual(h.requests[index].url?.path, "/w/api.php")
        }
    }

    func testExactChineseTitleAndCanonicalUnicodeAreAcceptedWithoutLabelMatching() async throws {
        for (language, title, backlink) in [("zh", "三浦透子", "三浦透子"), ("en", "Café", "Cafe\u{301}")] {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: title, qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: language + "wiki", title: backlink))
            ]); defer { h.close() }
            let result = try await h.service.resolve(.init(label: "Displayed short name", title: title, language: language))
            XCTAssertEqual(result, "Q100")
            XCTAssertEqual(h.requests[0].url?.host, language + ".wikipedia.org")
        }
    }

    func testDisambiguationAndNonArticlePagesCannotReachWikidata() async throws {
        var ambiguous = resolverPage(title: "Exact Film", qid: "Q100")
        ambiguous["pageprops"] = ["wikibase_item": "Q100", "disambiguation": ""]
        let disambiguation = try ResolverHarness(plans: [.json(["query": ["pages": [ambiguous]]])])
        defer { disambiguation.close() }
        do { _ = try await disambiguation.service.resolve(resolverReference()); XCTFail("Accepted disambiguation") }
        catch WikipediaWorkResolverError.ambiguous { }
        XCTAssertEqual(disambiguation.requests.count, 1)

        for ns in [6, 10, 14] {
            var page = resolverPage(title: "Exact Film", qid: "Q100"); page["ns"] = ns
            let h = try ResolverHarness(plans: [.json(["query": ["pages": [page]]])]); defer { h.close() }
            do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted namespace \(ns)") }
            catch WikipediaWorkResolverError.invalidResponse { }
            XCTAssertEqual(h.requests.count, 1)
        }
    }

    func testInvalidOrMissingPageQIDDoesNotBecomeAnIdentity() async throws {
        for qid in ["", "Q0", "Q01", "q100", "Q１００", "Q100|Q200"] {
            let h = try ResolverHarness(plans: [.json(resolverArticle(title: "Exact Film", qid: qid))]); defer { h.close() }
            do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted \(qid)") }
            catch WikipediaWorkResolverError.identityMismatch { }
            XCTAssertEqual(h.requests.count, 1)
        }
        var page = resolverPage(title: "Exact Film", qid: "Q100"); page.removeValue(forKey: "pageprops")
        let h = try ResolverHarness(plans: [.json(["query": ["pages": [page]]])]); defer { h.close() }
        do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted missing pageprops") }
        catch WikipediaWorkResolverError.identityMismatch { }
        XCTAssertEqual(h.requests.count, 1)
    }

    func testWrongEntityIDWrongSiteOrDifferentBackTitleRejectsThePageClaim() async throws {
        let entityVariants: [[String: Any]] = [
            ["success": 1, "entities": ["Q100": ["id": "Q200", "type": "item", "sitelinks": ["enwiki": ["site": "enwiki", "title": "Exact Film"]]]]],
            ["success": 1, "entities": ["Q100": ["id": "Q100", "type": "item", "sitelinks": ["enwiki": ["site": "zhwiki", "title": "Exact Film"]]]]],
            resolverEntity(qid: "Q100", site: "enwiki", title: "Another Film"),
            resolverEntity(qid: "Q100", site: "enwiki", title: "exact film"),
            resolverEntity(qid: "Q100", site: "zhwiki", title: "Exact Film"),
            ["success": 1, "entities": ["Q100": ["id": "Q100", "missing": ""]]],
            ["success": 1, "entities": [:]]
        ]
        for entity in entityVariants {
            let h = try ResolverHarness(plans: [.json(resolverArticle(title: "Exact Film", qid: "Q100")), .json(entity)]); defer { h.close() }
            do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted unverified backlink") }
            catch WikipediaWorkResolverError.identityMismatch { }
            XCTAssertEqual(h.requests.count, 2)
        }
    }

    func testUnexpectedPageAndAmbiguousOrCyclicRedirectsAreRejected() async throws {
        let variants: [[[String: String]]] = [
            [],
            [["from": "Exact Film", "to": "Somewhere Else"]],
            [["from": "Exact Film", "to": "Resolved Film"], ["from": "Exact Film", "to": "Other Film"]],
            [["from": "Exact Film", "to": "Middle"], ["from": "Middle", "to": "Exact Film"]]
        ]
        for redirects in variants {
            let article: [String: Any] = ["query": [
                "pages": [resolverPage(title: "Resolved Film", qid: "Q100")], "redirects": redirects
            ]]
            let h = try ResolverHarness(plans: [.json(article)]); defer { h.close() }
            do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted unrelated returned title") }
            catch WikipediaWorkResolverError.identityMismatch { }
            XCTAssertEqual(h.requests.count, 1)
        }
    }

    func testMissingAndMultiplePagesDoNotPickAnArbitraryResult() async throws {
        let missing: [String: Any] = ["query": ["pages": [["ns": 0, "title": "Exact Film", "missing": true]]]]
        let h = try ResolverHarness(plans: [.json(missing)]); defer { h.close() }
        do { _ = try await h.service.resolve(resolverReference()); XCTFail("Accepted missing page") }
        catch WikipediaWorkResolverError.notFound { }
        let multiple: [String: Any] = ["query": ["pages": [resolverPage(title: "Exact Film", qid: "Q100"), resolverPage(title: "Other", qid: "Q200")]]]
        let other = try ResolverHarness(plans: [.json(multiple)]); defer { other.close() }
        do { _ = try await other.service.resolve(resolverReference()); XCTFail("Picked an arbitrary page") }
        catch WikipediaWorkResolverError.invalidResponse { }
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(other.requests.count, 1)
    }

    func testNetworkHTTPAndAPIErrorNeverReturnAClaimedQID() async throws {
        let failures: [ResolverPlan] = [
            .failure(.notConnectedToInternet),
            try .json([:], status: 503),
            try .json(["error": ["code": "maxlag"]])
        ]
        for failure in failures {
            for failsDuringBacklink in [false, true] {
                var plans: [ResolverPlan] = []
                if failsDuringBacklink { plans.append(try .json(resolverArticle(title: "Exact Film", qid: "Q100"))) }
                plans.append(failure)
                let h = ResolverHarness(readyPlans: plans); defer { h.close() }
                do { _ = try await h.service.resolve(resolverReference()); XCTFail("Network failure yielded identity") }
                catch WikipediaWorkResolverError.unavailable { }
                XCTAssertEqual(h.requests.count, failsDuringBacklink ? 2 : 1, "Resolver must not retry or search by name")
            }
        }
    }

    func testCreativeResolverAcceptsPeopleFilmsAndSupportedCulturalWorks() async throws {
        for type in ["Q5", "Q215380", "Q11424", "Q20650540", "Q8261", "Q7725634", "Q104213567", "Q482994", "Q7366", "Q134556", "Q55850593", "Q105543609"] {
            let claims: [String: [[String: Any]]] = [
                "P31": [resolverTypeClaim(type)],
                "P106": type == "Q5" ? [resolverTypeClaim("Q36834", property: "P106")] : [],
                // Real entities carry unrelated value shapes. They must not
                // break parsing of the one property used for classification.
                "P856": [["rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "url", "datavalue": ["value": "https://example.com/"]]]],
                "P569": [["rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "time", "datavalue": ["value": ["time": "+1950-01-01T00:00:00Z"]]]]]
            ]
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: claims))
            ]); defer { h.close() }
            let result = try await h.service.resolveCreative(resolverReference())
            XCTAssertEqual(result, "Q100", type)
            XCTAssertEqual(h.parameters(at: 1)["props"], "sitelinks|claims")
            XCTAssertEqual(h.requests.count, 2)
        }
    }

    func testNonCreativeOrMissingP31ReturnsCachedNilWhileOriginalResolverKeepsItsContract() async throws {
        let variants: [[String: [[String: Any]]]?] = [
            ["P31": [resolverTypeClaim("Q900001")]], // Synthetic non-art type for a car/object.
            nil,
            [:],
            ["P31": []],
            ["P7937": [resolverTypeClaim("Q8261", property: "P7937")]]
        ]
        for claims in variants {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "SAAB 900", qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: "enwiki", title: "SAAB 900", claims: claims))
            ]); defer { h.close() }
            let reference = WikiArticleReference(label: "A car mentioned in a story", title: "SAAB 900", language: "en")
            let first = try await h.service.resolveCreative(reference)
            let again = try await h.service.resolveCreative(reference)
            let unrestricted = try await h.service.resolve(reference)
            XCTAssertNil(first)
            XCTAssertNil(again)
            XCTAssertEqual(unrestricted, "Q100", "A non-creative entity still has a verified Wikipedia identity")
            XCTAssertEqual(h.requests.count, 2, "A definite nil must not trigger requests when the view reappears")
        }
    }

    func testCreativeTypeDoesNotUseDeprecatedQualifiedOrMistypedStatements() async throws {
        var deprecated = resolverTypeClaim("Q11424"); deprecated["rank"] = "deprecated"
        var qualified = resolverTypeClaim("Q11424")
        qualified["qualifiers"] = ["P1810": [["snaktype": "value", "datatype": "string", "datavalue": ["value": "Name"]]]]
        var wrongDatatype = resolverTypeClaim("Q11424")
        wrongDatatype["mainsnak"] = ["property": "P31", "snaktype": "value", "datatype": "string", "datavalue": ["value": "Q11424"]]
        var noValue = resolverTypeClaim("Q11424")
        noValue["mainsnak"] = ["property": "P31", "snaktype": "novalue", "datatype": "wikibase-item"]
        let wrongProperty = resolverTypeClaim("Q11424", property: "P50")
        for claim in [deprecated, qualified, wrongDatatype, noValue, wrongProperty] {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: ["P31": [claim]]))
            ]); defer { h.close() }
            let result = try await h.service.resolveCreative(resolverReference())
            XCTAssertNil(result)
        }
    }

    func testPersonNeedsCreativeOccupationAndCompanyCannotUseAnOccupationToPass() async throws {
        let cases: [([String: [[String: Any]]], Bool)] = [
            (["P31": [resolverTypeClaim("Q5")]], false),
            (["P31": [resolverTypeClaim("Q5")], "P106": [resolverTypeClaim("Q82955", property: "P106")]], false),
            (["P31": [resolverTypeClaim("Q4830453")], "P106": [resolverTypeClaim("Q36834", property: "P106")]], false),
            (["P106": [resolverTypeClaim("Q36834", property: "P106")]], false),
            (["P31": [resolverTypeClaim("Q5")], "P106": [resolverTypeClaim("Q177220", property: "P106")]], true),
            (["P31": [resolverTypeClaim("Q5")], "P106": [resolverTypeClaim("Q28389", property: "P106")]], true)
        ]
        for (claims, accepted) in cases {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: claims))
            ]); defer { h.close() }
            let result = try await h.service.resolveCreative(resolverReference())
            XCTAssertEqual(result, accepted ? "Q100" : nil)
        }
    }

    func testCreativeOccupationNeedsAnUnqualifiedCurrentItemClaim() async throws {
        var deprecated = resolverTypeClaim("Q36834", property: "P106"); deprecated["rank"] = "deprecated"
        var qualified = resolverTypeClaim("Q36834", property: "P106")
        qualified["qualifiers"] = ["P580": []]
        var wrongDatatype = resolverTypeClaim("Q36834", property: "P106")
        wrongDatatype["mainsnak"] = ["property": "P106", "snaktype": "value", "datatype": "string", "datavalue": ["value": "Q36834"]]
        for claim in [deprecated, qualified, wrongDatatype, resolverTypeClaim("Q36834", property: "P31")] {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q5")], "P106": [claim]]))
            ]); defer { h.close() }
            let result = try await h.service.resolveCreative(resolverReference())
            XCTAssertNil(result)
        }
    }

    func testMusicalWorkTypeDoesNotTurnTheTypeEntityItselfIntoAWork() async throws {
        let h = try ResolverHarness(plans: [
            .json(resolverArticle(title: "Musical work", qid: "Q105543609")),
            .json(resolverEntity(qid: "Q105543609", site: "enwiki", title: "Musical work", claims: ["P279": [resolverTypeClaim("Q2188189", property: "P279")]]))
        ]); defer { h.close() }
        let result = try await h.service.resolveCreative(.init(label: "Music", title: "Musical work", language: "en"))
        XCTAssertNil(result, "Q105543609 is a type; a work must carry it in P31, not be that QID")
    }

    func testSharedIdentityCacheSurvivesLabelsAndBothPublicMethodsButHonorsCancellation() async throws {
        let h = try ResolverHarness(plans: [
            .json(resolverArticle(title: "Exact Film", qid: "Q100")),
            .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q11424")]]))
        ]); defer { h.close() }
        let unrestricted = try await h.service.resolve(resolverReference())
        let creative = try await h.service.resolveCreative(.init(label: "Another visible label", title: "Exact_Film", language: "en"))
        let again = try await h.service.resolveCreative(resolverReference())
        XCTAssertEqual(unrestricted, "Q100")
        XCTAssertEqual(creative, "Q100")
        XCTAssertEqual(again, "Q100")
        XCTAssertEqual(h.requests.count, 2)
        let service = h.service
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resolveCreative(resolverReference())
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled caller received a cached identity") }
        catch is CancellationError { }
        XCTAssertEqual(h.requests.count, 2)
    }

    func testCreativeResolverDoesNotCacheNetworkFailureOrBrokenIdentityBacklink() async throws {
        let valid = try ResolverPlan.json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q5")], "P106": [resolverTypeClaim("Q36834", property: "P106")]]))
        let failures: [ResolverPlan] = [
            .failure(.timedOut),
            try .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Unrelated Person", claims: ["P31": [resolverTypeClaim("Q5")]]))
        ]
        for failure in failures {
            let h = try ResolverHarness(plans: [
                .json(resolverArticle(title: "Exact Film", qid: "Q100")), failure,
                .json(resolverArticle(title: "Exact Film", qid: "Q100")), valid
            ]); defer { h.close() }
            do { _ = try await h.service.resolveCreative(resolverReference()); XCTFail("Failure became a creative link") }
            catch WikipediaWorkResolverError.unavailable { }
            catch WikipediaWorkResolverError.identityMismatch { }
            let retried = try await h.service.resolveCreative(resolverReference())
            let cached = try await h.service.resolveCreative(resolverReference())
            XCTAssertEqual(retried, "Q100")
            XCTAssertEqual(cached, "Q100")
            XCTAssertEqual(h.requests.count, 4, "A failed backlink cannot poison a later explicit retry")
        }
    }

    func testVerifiedRedirectIdentitySurvivesARealResolverRecreationWithoutTransport() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var article = resolverArticle(title: "Exact Film", qid: "Q100")
        var query = article["query"] as! [String: Any]
        query["redirects"] = [["from": "Old name", "to": "Exact Film"]]
        article["query"] = query
        let warm = ResolverHarness(readyPlans: [
            try .json(article), try .json(resolverCreativeEntity())
        ], directory: directory, now: { checkedAt })
        let reference = WikiArticleReference(label: "Visible label", title: "Old_name", language: "en")
        let first = try await warm.service.resolveCreative(reference)
        XCTAssertEqual(first, "Q100")
        XCTAssertEqual(warm.requests.count, 2)
        warm.close()
        let file = try resolverOnlyCacheFile(directory)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(stored["version"] as? Int, 1)
        XCTAssertEqual(stored["requestedTitle"] as? String, "Old name")
        XCTAssertEqual(stored["language"] as? String, "en")
        XCTAssertEqual(stored["resolvedTitle"] as? String, "Exact Film")
        XCTAssertEqual(stored["pageID"] as? Int, 123)
        XCTAssertEqual(stored["qid"] as? String, "Q100")
        XCTAssertEqual(stored["isCreative"] as? Bool, true)
        XCTAssertEqual(stored["checkedAt"] as? Double, checkedAt.timeIntervalSinceReferenceDate)

        // New actor and ephemeral session, with no stub responses or URLCache.
        let offline = ResolverHarness(readyPlans: [], directory: directory, now: { checkedAt.addingTimeInterval(60) })
        defer { offline.close() }
        let restored = try await offline.service.resolveCreative(.init(label: "Another label", title: "Old name", language: "en"))
        XCTAssertEqual(restored, "Q100")
        XCTAssertTrue(offline.requests.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await offline.service.resolve(reference)
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation returned a disk identity") }
        catch is CancellationError { }
        XCTAssertTrue(offline.requests.isEmpty)
    }

    func testSameTitleInDifferentLanguagesKeepsDifferentVerifiedIdentities() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let warm = ResolverHarness(readyPlans: [
            try .json(resolverArticle(title: "Exact Film", qid: "Q100")), try .json(resolverCreativeEntity()),
            try .json(resolverArticle(title: "Exact Film", qid: "Q200")),
            try .json(resolverEntity(qid: "Q200", site: "zhwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q11424")]]))
        ], directory: directory, now: { date })
        let en = try await warm.service.resolveCreative(resolverReference())
        let zh = try await warm.service.resolveCreative(.init(label: "Film", title: "Exact Film", language: "zh"))
        XCTAssertEqual(en, "Q100"); XCTAssertEqual(zh, "Q200")
        XCTAssertEqual(warm.requests.count, 4)
        warm.close()
        let offline = ResolverHarness(readyPlans: [], directory: directory, now: { date })
        defer { offline.close() }
        let restoredEn = try await offline.service.resolve(resolverReference())
        let restoredZh = try await offline.service.resolve(.init(label: "Same label", title: "Exact Film", language: "zh"))
        XCTAssertEqual(restoredEn, "Q100"); XCTAssertEqual(restoredZh, "Q200")
        XCTAssertTrue(offline.requests.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 2)
    }

    func testCorruptUnboundedOrMisidentifiedDiskEvidenceIsNeverUsed() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let warm = ResolverHarness(readyPlans: [try .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                                              try .json(resolverCreativeEntity())], directory: directory, now: { date })
        _ = try await warm.service.resolveCreative(resolverReference())
        warm.close()
        let file = try resolverOnlyCacheFile(directory)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let changes: [(String, Any)] = [
            ("version", 2), ("requestedTitle", "Another Film"), ("language", "zh"),
            ("resolvedTitle", "Unproven redirect"), ("pageID", 0), ("qid", "Q01"),
            ("checkedAt", date.addingTimeInterval(1).timeIntervalSinceReferenceDate),
            ("isCreative", false), ("typeIDs", []), ("typeIDs", ["Q11424", "Q11424"]),
            ("occupationIDs", ["bad-id"]), ("rewrites", [["from": "bad|title", "to": "Exact Film"]])
        ]
        var payloads = try changes.map { key, value -> Data in
            var changed = valid; changed[key] = value
            return try JSONSerialization.data(withJSONObject: changed)
        }
        var missing = valid; missing.removeValue(forKey: "checkedAt")
        payloads.append(try JSONSerialization.data(withJSONObject: missing))
        payloads.append(Data("{broken".utf8))
        payloads.append(Data(repeating: 32, count: 32_769))
        for data in payloads {
            try data.write(to: file)
            let offline = ResolverHarness(readyPlans: [.failure(.notConnectedToInternet)], directory: directory, now: { date })
            do { _ = try await offline.service.resolveCreative(resolverReference()); XCTFail("Invalid cache supplied an identity") }
            catch WikipediaWorkResolverError.unavailable { }
            XCTAssertEqual(offline.requests.count, 1, "Invalid disk evidence must reach the exact lookup, never guessed identity")
            XCTAssertEqual(try Data(contentsOf: file), data, "Failure must not overwrite evidence with a negative result")
            offline.close()
        }
    }

    func testMemoryAndDiskExpireAtSevenDaysAndFailureNeverReturnsOrOverwritesStaleIdentity() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = ResolverClock(checkedAt)
        let warm = ResolverHarness(readyPlans: [
            try .json(resolverArticle(title: "Exact Film", qid: "Q100")), try .json(resolverCreativeEntity()),
            .failure(.notConnectedToInternet)
        ], directory: directory, now: { clock.now })
        defer { warm.close() }
        _ = try await warm.service.resolveCreative(resolverReference())
        let file = try resolverOnlyCacheFile(directory)
        let original = try Data(contentsOf: file)
        clock.now = checkedAt.addingTimeInterval(WikipediaWorkResolver.identityLifetime - 1)
        let fresh = try await warm.service.resolveCreative(resolverReference())
        XCTAssertEqual(fresh, "Q100"); XCTAssertEqual(warm.requests.count, 2)
        clock.now = checkedAt.addingTimeInterval(WikipediaWorkResolver.identityLifetime)
        do { _ = try await warm.service.resolveCreative(resolverReference()); XCTFail("Expired memory identity became current") }
        catch WikipediaWorkResolverError.unavailable { }
        XCTAssertEqual(warm.requests.count, 3)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let offline = ResolverHarness(readyPlans: [.failure(.timedOut)], directory: directory, now: { clock.now })
        do { _ = try await offline.service.resolveCreative(resolverReference()); XCTFail("Expired disk identity became current") }
        catch WikipediaWorkResolverError.unavailable { }
        XCTAssertEqual(offline.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
        offline.close()
        let recovered = ResolverHarness(readyPlans: [
            try .json(resolverArticle(title: "Exact Film", qid: "Q200")),
            try .json(resolverEntity(qid: "Q200", site: "enwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q11424")]]))
        ], directory: directory, now: { clock.now })
        defer { recovered.close() }
        let next = try await recovered.service.resolveCreative(resolverReference())
        XCTAssertEqual(next, "Q200", "Only a complete new backlink verification can replace an expired identity")
        XCTAssertNotEqual(try Data(contentsOf: file), original)
    }

    func testTransportIdentityErrorsAndUnknownClassificationDoNotPersistNegativeEntries() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let failures: [[ResolverPlan]] = [
            [.failure(.notConnectedToInternet)],
            [.failure(.cancelled)],
            [try .json([:], status: 503)],
            [try .json(["error": ["code": "maxlag"]])],
            [try .json(resolverArticle(title: "Exact Film", qid: "Q100")), .failure(.timedOut)],
            [try .json(resolverArticle(title: "Exact Film", qid: "Q100")), try .json(resolverCreativeEntity(title: "Wrong Film"))]
        ]
        for plans in failures {
            let h = ResolverHarness(readyPlans: plans, directory: directory)
            do { _ = try await h.service.resolveCreative(resolverReference()); XCTFail("Error became a resolved negative") }
            catch WikipediaWorkResolverError.unavailable { }
            catch WikipediaWorkResolverError.identityMismatch { }
            catch is CancellationError { }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            h.close()
        }
        for claims: [String: [[String: Any]]]? in [nil, [:], ["P31": [resolverTypeClaim("Q5")]]] {
            let h = ResolverHarness(readyPlans: [
                try .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                try .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: claims))
            ], directory: directory)
            let result = try await h.service.resolveCreative(resolverReference())
            XCTAssertNil(result)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                          "Incomplete classification must not persist a negative creative result")
            h.close()
        }
        let recovered = ResolverHarness(readyPlans: [try .json(resolverArticle(title: "Exact Film", qid: "Q100")),
                                                    try .json(resolverCreativeEntity())], directory: directory)
        defer { recovered.close() }
        let result = try await recovered.service.resolveCreative(resolverReference())
        XCTAssertEqual(result, "Q100")
        XCTAssertEqual(recovered.requests.count, 2)
        _ = try resolverOnlyCacheFile(directory)
    }

    func testExplicitNonCreativeIdentityCanBeRestoredButWrongLabelCannotSelectAnotherTitle() async throws {
        let directory = try resolverCacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let warm = ResolverHarness(readyPlans: [
            try .json(resolverArticle(title: "Exact Film", qid: "Q100")),
            try .json(resolverEntity(qid: "Q100", site: "enwiki", title: "Exact Film", claims: ["P31": [resolverTypeClaim("Q4830453")]]))
        ], directory: directory)
        let result = try await warm.service.resolveCreative(resolverReference())
        XCTAssertNil(result)
        warm.close()
        let offline = ResolverHarness(readyPlans: [.failure(.notConnectedToInternet)], directory: directory)
        defer { offline.close() }
        let creative = try await offline.service.resolveCreative(resolverReference())
        let identity = try await offline.service.resolve(resolverReference())
        XCTAssertNil(creative); XCTAssertEqual(identity, "Q100")
        XCTAssertTrue(offline.requests.isEmpty)
        do {
            _ = try await offline.service.resolve(.init(label: "Exact Film", title: "Another Film", language: "en"))
            XCTFail("A visible label borrowed a cached QID")
        } catch WikipediaWorkResolverError.unavailable { }
        XCTAssertEqual(offline.requests.count, 1)
    }

    func testInvalidLanguageTitleAndCancelledCallerNeverReachTransport() async throws {
        let h = ResolverHarness(readyPlans: []); defer { h.close() }
        let invalid = [
            WikiArticleReference(label: "Name", title: "Exact Film", language: "ja"),
            .init(label: "Name", title: "Exact Film", language: "en.wikipedia.org"),
            .init(label: "Name", title: "Exact Film", language: "ZH"),
            .init(label: "Name", title: "", language: "en"),
            .init(label: "Name", title: "   ", language: "en"),
            .init(label: "Name", title: "Film|Other", language: "en"),
            .init(label: "Name", title: "Film#Plot", language: "en"),
            .init(label: "Name", title: "Film\nOther", language: "en"),
            .init(label: "Name", title: "https://example.com", language: "en"),
            .init(label: "Name", title: String(repeating: "x", count: 256), language: "en")
        ]
        for reference in invalid {
            do { _ = try await h.service.resolve(reference); XCTFail("Accepted invalid reference") }
            catch WikipediaWorkResolverError.invalidReference { }
        }
        let service = h.service
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resolve(resolverReference())
        }
        do { _ = try await task.value; XCTFail("Cancelled caller resolved identity") }
        catch is CancellationError { }
        XCTAssertTrue(h.requests.isEmpty)
    }
}

private func resolverReference() -> WikiArticleReference {
    .init(label: "Film", title: "Exact Film", language: "en")
}
private func resolverCreativeEntity(title: String = "Exact Film") -> [String: Any] {
    resolverEntity(qid: "Q100", site: "enwiki", title: title, claims: ["P31": [resolverTypeClaim("Q11424")]])
}
private func resolverCacheDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.ResolverCache.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
private func resolverOnlyCacheFile(_ directory: URL) throws -> URL {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    XCTAssertEqual(files.count, 1)
    return try XCTUnwrap(files.first)
}
private final class ResolverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
private func resolverPage(title: String, qid: String) -> [String: Any] {
    ["pageid": 123, "ns": 0, "title": title, "pageprops": ["wikibase_item": qid]]
}
private func resolverArticle(title: String, qid: String) -> [String: Any] {
    ["query": ["pages": [resolverPage(title: title, qid: qid)]]]
}
private func resolverEntity(qid: String, site: String, title: String, claims: [String: [[String: Any]]]? = nil) -> [String: Any] {
    var entity: [String: Any] = ["id": qid, "type": "item", "sitelinks": [site: ["site": site, "title": title]]]
    if let claims { entity["claims"] = claims }
    return ["success": 1, "entities": [qid: entity]]
}
private func resolverTypeClaim(_ type: String, property: String = "P31") -> [String: Any] {
    ["rank": "normal", "mainsnak": ["property": property, "snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": type]]]]
}
private struct ResolverPlan: Sendable {
    let data: Data?
    let status: Int
    let error: URLError.Code?
    static func json(_ payload: [String: Any], status: Int = 200) throws -> Self {
        Self(data: try JSONSerialization.data(withJSONObject: payload), status: status, error: nil)
    }
    static func failure(_ error: URLError.Code) -> Self { Self(data: nil, status: 0, error: error) }
}
private final class ResolverHarness: @unchecked Sendable {
    let service: WikipediaWorkResolver
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: ResolverStubState
    convenience init(plans: [ResolverPlan]) throws { self.init(readyPlans: plans) }
    init(readyPlans: [ResolverPlan], directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        state = ResolverStubState(plans: readyPlans)
        ResolverStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Wiki-Resolver-Test": token]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        service = WikipediaWorkResolver(session: session, directory: directory, now: now)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(at index: Int) -> [String: String] {
        guard requests.indices.contains(index), let url = requests[index].url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close() { session.invalidateAndCancel(); ResolverStubRegistry.shared.remove(token) }
}
private final class ResolverStubRegistry: @unchecked Sendable {
    static let shared = ResolverStubRegistry()
    private let lock = NSLock()
    private var values: [String: ResolverStubState] = [:]
    func put(_ key: String, _ value: ResolverStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> ResolverStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class ResolverStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [ResolverPlan]
    private var observed: [URLRequest] = []
    init(plans: [ResolverPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> ResolverPlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class ResolverURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = ResolverStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Wiki-Resolver-Test")),
              let plan = state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if let error = plan.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        guard let data = plan.data, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
