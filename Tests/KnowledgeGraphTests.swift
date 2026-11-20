import XCTest
@testable import Pianwai

final class KnowledgeGraphTests: XCTestCase, @unchecked Sendable {
    func testForwardExpansionFetchesTargetsInOneBatch() async throws {
        let h = try forwardHarness(); defer { h.close() }
        let result = try await h.service.expand(qid: "Q100")
        XCTAssertEqual(result.snapshot.works.count, 3)
        XCTAssertEqual(result.snapshot.relations.count, 2)
        XCTAssertEqual(h.requests.count, 2)
        XCTAssertEqual(Set(h.parameters(at: 1)["ids"]!.split(separator: "|").map(String.init)), ["Q200", "Q300"])
    }

    func testDeprecatedUnknownAndQualifiedClaimsDoNotBecomeEdges() async throws {
        var qualified = claim("Q100", "Q400")
        qualified["qualifiers"] = ["P580": [["snaktype": "value", "datatype": "time", "datavalue": ["value": ["time": "+2020-01-01T00:00:00Z"]]]]]
        var deprecated = claim("Q100", "Q500"); deprecated["rank"] = "deprecated"
        let unknown: [String: Any] = ["id": "unknown", "rank": "normal", "mainsnak": ["snaktype": "somevalue", "datatype": "wikibase-item"]]
        let h = KnowledgeHarness(plans: [try response([entity("Q100", claims: ["P57": [claim("Q100", "Q200"), qualified, deprecated, unknown]])]), try response([entity("Q200")])])
        defer { h.close() }
        let result = try await h.service.expand(qid: "Q100")
        XCTAssertEqual(result.snapshot.relations.count, 1)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(h.parameters(at: 1)["ids"], "Q200")
    }

    func testVerifiedAnchorPreservesCuratedIdentityAndPresentation() async throws {
        let h = try forwardHarness(); defer { h.close() }
        let anchor = Work(id: WorkID(rawValue: "editorial:film")!, title: "手工校对的标题", creator: "导演", kind: "电影", art: "verified-cover", detail: "2025", url: "https://example.org/official", linkedCreatorIDs: [])
        let result = try await h.service.expand(qid: "Q100", anchors: ["Q100": anchor])
        let work = try XCTUnwrap(result.snapshot.works.first { $0.id == anchor.id })
        XCTAssertEqual(work.title, anchor.title)
        XCTAssertEqual(work.kind, anchor.kind)
        XCTAssertEqual(work.art, anchor.art)
        XCTAssertEqual(work.url, anchor.url)
        XCTAssertEqual(work.knowledgeID, "Q100")
        XCTAssertTrue(result.snapshot.relations.allSatisfy { $0.from == anchor.id })
    }

    func testSourceLinksToExactStatementWithoutInventingPrimaryEvidence() async throws {
        let h = try forwardHarness(); defer { h.close() }
        let result = try await h.service.expand(qid: "Q100")
        for edge in result.snapshot.relations {
            XCTAssertTrue(edge.source.title.hasPrefix("Wikidata · "))
            XCTAssertEqual(URLComponents(string: edge.source.url)?.fragment, "Q100$11111111-1111-1111-1111-111111111111")
            XCTAssertEqual(edge.source.detail, "社区维护的结构化资料")
        }
        XCTAssertTrue(result.snapshot.stories.isEmpty)
    }

    func testValidatedResponsesAreCached() async throws {
        let h = try forwardHarness(); defer { h.close() }
        let first = try await h.service.expand(qid: "Q100")
        let second = try await h.service.expand(qid: "Q100")
        XCTAssertEqual(first.snapshot.relations.map(\.id), second.snapshot.relations.map(\.id))
        XCTAssertEqual(h.requests.count, 2)
    }

    func testInvalidIdentifierIsRejectedBeforeTransport() async throws {
        let h = KnowledgeHarness(plans: []); defer { h.close() }
        for value in ["Q0", "Q01", "Q100&ids=Q200", "q100", "P57", "Q"] {
            do { _ = try await h.service.expand(qid: value); XCTFail("Accepted \(value)") }
            catch KnowledgeError.invalidIdentifier { }
        }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testNotableWorkNeedsAnActualWorkLevelCredit() async throws {
        let h = KnowledgeHarness(plans: [
            try response([entity("Q200", type: "Q5", claims: ["P800": [claim("Q200", "Q100"), claim("Q200", "Q300")]])]),
            try response([entity("Q100", claims: ["P86": [claim("Q100", "Q200")]]), entity("Q300")])
        ]); defer { h.close() }
        let result = try await h.service.expand(qid: "Q200")
        XCTAssertEqual(result.snapshot.relations.count, 1)
        XCTAssertEqual(result.snapshot.relations.first?.from.rawValue, "wikidata:Q100")
        XCTAssertEqual(result.snapshot.relations.first?.to.rawValue, "wikidata:Q200")
        XCTAssertEqual(result.snapshot.relations.first?.inverseLabel, "作曲作品")
        XCTAssertTrue(result.limited)
    }

    func testAmbiguousSearchCandidatesRemainDistinct() async throws {
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": [
            ["id": "Q104086895", "label": "One Last Kiss", "description": "EP"],
            ["id": "Q108033774", "label": "One Last Kiss", "description": "single"]
        ]])]); defer { h.close() }
        let values = try await h.service.searchCandidates("One Last Kiss")
        XCTAssertEqual(values.map(\.qid), ["Q104086895", "Q108033774"])
        XCTAssertEqual(values.map(\.detail), ["EP", "single"])
    }

    func testOriginalNonemptySearchKeepsLiteralQueryAndDoesNotRequestScriptVariants() async throws {
        let original = "龍与鸟 / Björk + A&B? #1"
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": [
            ["id": "Q100", "label": "An independently supplied label", "description": "A candidate"],
            ["id": "Q101", "label": "An independently supplied label", "description": "Another identity"]
        ]])]); defer { h.close() }
        let values = try await h.service.searchCandidates("  " + original + "\n")
        XCTAssertEqual(values.map(\.qid), ["Q100", "Q101"])
        XCTAssertEqual(values.map(\.title), ["An independently supplied label", "An independently supplied label"])
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.parameters(at: 0)["search"], original)
    }

    func testSuccessfulEmptyPureScriptSearchTriesOnlyTheOppositeScript() async throws {
        for (original, opposite) in [("龙与鸟", "龍與鳥"), ("龍與鳥", "龙与鸟")] {
            let h = KnowledgeHarness(plans: [
                try plan(["success": 1, "search": []]),
                try plan(["success": 1, "search": [["id": "Q100", "label": "Provider's exact label", "description": "候选资料"]]])
            ]); defer { h.close() }
            let values = try await h.service.searchCandidates(original)
            XCTAssertEqual(values.map(\.qid), ["Q100"])
            XCTAssertEqual(values.first?.title, "Provider's exact label", "Script conversion cannot rewrite a returned identity or label")
            XCTAssertEqual(values.first?.detail, "候选资料")
            XCTAssertEqual(h.requests.count, 2)
            XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, [original, opposite])
            XCTAssertTrue((0..<h.requests.count).allSatisfy { h.parameters(at: $0)["language"] == "zh" })
            XCTAssertTrue((0..<h.requests.count).allSatisfy { h.parameters(at: $0)["uselang"] == "zh-hans" })
        }
    }

    func testMixedScriptEmptySearchUsesAtMostThreeDistinctLiteralForms() async throws {
        let h = KnowledgeHarness(plans: try (0..<3).map { _ in try plan(["success": 1, "search": []]) })
        defer { h.close() }
        let values = try await h.service.searchCandidates("龍与鸟 / Björk")
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(h.requests.count, 3)
        let terms = (0..<h.requests.count).compactMap { h.parameters(at: $0)["search"] }
        XCTAssertEqual(terms, ["龍与鸟 / Björk", "龍與鳥 / Björk", "龙与鸟 / Björk"])
        XCTAssertEqual(Set(terms).count, 3)
        XCTAssertTrue(h.requests.allSatisfy { $0.url?.host == "www.wikidata.org" })
    }

    func testMixedScriptSearchStopsAsSoonAsTheFirstVariantReturnsCandidates() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]),
            try plan(["success": 1, "search": [["id": "Q100", "label": "龍與鳥"]]])
        ]); defer { h.close() }
        let values = try await h.service.searchCandidates("龍与鸟")
        XCTAssertEqual(values.map(\.qid), ["Q100"])
        XCTAssertEqual(h.requests.count, 2, "Do not append another script's candidates after a successful result")
        XCTAssertEqual(h.parameters(at: 1)["search"], "龍與鳥")
    }

    func testLatinPunctuationAndEmptyQueriesDoNotCreateDuplicateFallbackRequests() async throws {
        let literal = "Björk / One Last Kiss + A&B? #1"
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": []])]); defer { h.close() }
        let values = try await h.service.searchCandidates(literal)
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(h.requests.count, 1)
        XCTAssertEqual(h.parameters(at: 0)["search"], literal)
        for blank in ["", " \n\t "] {
            let empty = try await h.service.searchCandidates(blank)
            XCTAssertTrue(empty.isEmpty)
        }
        XCTAssertEqual(h.requests.count, 1, "Blank queries must not contact the service")
    }

    func testScriptVariantsRespectTheExistingTwoHundredCharacterQueryBound() async throws {
        let sent = String(repeating: "A", count: 200)
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": []])]); defer { h.close() }
        let values = try await h.service.searchCandidates(sent + "龍与鸟")
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(h.requests.count, 1, "Text beyond the transmitted query cannot create phantom variant requests")
        XCTAssertEqual(h.parameters(at: 0)["search"], sent)
    }

    func testNonemptyFilteredPayloadDoesNotMasqueradeAsSuccessfulEmptySearch() async throws {
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": [
            ["id": "Q0", "label": "invalid identifier"], ["id": "Q100", "label": "   "]
        ]])]); defer { h.close() }
        do { _ = try await h.service.searchCandidates("龍与鸟"); XCTFail("Malformed candidates became a successful empty search") }
        catch KnowledgeError.invalidResponse { }
        XCTAssertEqual(h.requests.count, 1, "Fallback requires an actual empty provider result, not client-side filtering")
    }

    func testInvalidOnlyOriginalAndVariantPayloadsAreRejectedBeforeCaching() async throws {
        let invalidItems: [[String: Any]] = [
            [:], ["id": "Q100"], ["label": "Missing identity"],
            ["id": "Q0", "label": "Zero"], ["id": "Q01", "label": "Leading zero"],
            ["id": "Q100&ids=Q200", "label": "Invalid identity"],
            ["id": "Q100", "label": " \n\t "]
        ]
        for failsOnVariant in [false, true] {
            for item in invalidItems {
                let initial = failsOnVariant ? [try plan(["success": 1, "search": []])] : []
                let malformed = try plan(["success": 1, "search": [item]])
                let h = KnowledgeHarness(plans: initial + [malformed, malformed,
                    try plan(["success": 1, "search": [["id": "Q100", "label": "Recovered identity"]]])
                ]); defer { h.close() }
                for attempt in 1...2 {
                    do { _ = try await h.service.searchCandidates("龍与鸟"); XCTFail("Malformed payload was accepted") }
                    catch KnowledgeError.invalidResponse { }
                    XCTAssertEqual(h.requests.count, attempt + (failsOnVariant ? 1 : 0),
                                   "An invalid-only payload must be retried, never cached or followed by another script")
                }
                let recovered = try await h.service.searchCandidates("龍与鸟")
                XCTAssertEqual(recovered.map(\.qid), ["Q100"])
                XCTAssertEqual(h.requests.count, failsOnVariant ? 4 : 3)
                let expected = failsOnVariant ? ["龍与鸟", "龍與鳥", "龍與鳥", "龍與鳥"] : ["龍与鸟", "龍与鸟", "龍与鸟"]
                XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, expected)
            }
        }
    }

    func testPartiallyValidProviderPayloadKeepsExactDeduplicatedCandidatesAcrossCacheHits() async throws {
        let h = KnowledgeHarness(plans: [try plan(["success": 1, "search": [
            ["id": "Q0", "label": "Invalid"], ["id": "Q100", "label": " "],
            ["id": "Q100", "label": "  Provider title  ", "description": "  Film  "],
            ["id": "Q100", "label": "Duplicate with another title"],
            ["id": "Q101", "label": "Provider title"], ["label": "Missing identity"]
        ]])]); defer { h.close() }
        for _ in 0..<2 {
            let result = try await h.service.searchCandidates("龍与鸟")
            XCTAssertEqual(result.map(\.qid), ["Q100", "Q101"])
            XCTAssertEqual(result.map(\.title), ["Provider title", "Provider title"])
            XCTAssertEqual(result.map(\.detail), ["Film", ""])
        }
        XCTAssertEqual(h.requests.count, 1, "Valid cached payloads still filter malformed rows and deduplicate exact QIDs")
        XCTAssertEqual(h.parameters(at: 0)["search"], "龍与鸟")
    }

    func testRejectedPayloadCanRetryIntoGenuineEmptyThenUseScriptFallback() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": [["id": "Q100", "label": " "]]]),
            try plan(["success": 1, "search": []]),
            try plan(["success": 1, "search": [["id": "Q100", "label": "Valid variant"]]])
        ]); defer { h.close() }
        do { _ = try await h.service.searchCandidates("龙与鸟"); XCTFail("Invalid response became empty") }
        catch KnowledgeError.invalidResponse { }
        XCTAssertEqual(h.requests.count, 1)
        for _ in 0..<2 {
            let result = try await h.service.searchCandidates("龙与鸟")
            XCTAssertEqual(result.map(\.qid), ["Q100"])
        }
        XCTAssertEqual(h.requests.count, 3, "The valid empty original and valid variant can both be reused after recovery")
        XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, ["龙与鸟", "龙与鸟", "龍與鳥"])
    }

    func testProviderOnlyCancellationIsRetryableAndDoesNotTriggerScriptFallback() async throws {
        let h = KnowledgeHarness(plans: [
            KnowledgePlan(status: 200, data: Data(), transportFailure: .cancelled),
            try plan(["success": 1, "search": [["id": "Q100", "label": "Recovered identity"]]])
        ]); defer { h.close() }
        XCTAssertFalse(Task.isCancelled)
        do { _ = try await h.service.searchCandidates("龍与鸟"); XCTFail("Provider cancellation became successful empty") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertFalse(Task.isCancelled, "The provider cancelled its request, not its caller")
        XCTAssertEqual(h.requests.count, 1)
        let result = try await h.service.searchCandidates("龍与鸟")
        XCTAssertEqual(result.map(\.qid), ["Q100"])
        XCTAssertEqual(h.requests.count, 2, "Cancelled provider responses must not be cached")
        XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, ["龍与鸟", "龍与鸟"])
    }

    func testProviderOnlyVariantCancellationRetainsValidEmptyCacheAndRetriesFailedForm() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]),
            KnowledgePlan(status: 200, data: Data(), transportFailure: .cancelled),
            try plan(["success": 1, "search": [["id": "Q100", "label": "Recovered variant"]]])
        ]); defer { h.close() }
        do { _ = try await h.service.searchCandidates("龍与鸟"); XCTFail("Provider cancellation became successful empty") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(h.requests.count, 2, "Failure of one variant must not query the third script")
        let result = try await h.service.searchCandidates("龍与鸟")
        XCTAssertEqual(result.map(\.qid), ["Q100"])
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, ["龍与鸟", "龍與鳥", "龍與鳥"])
    }

    @MainActor func testProviderOnlyHydrationCancellationCannotPublishAnUnverifiedWorkAndCanRecover() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": [["id": "Q100", "label": "A film"]]]),
            KnowledgePlan(status: 200, data: Data(), transportFailure: .cancelled),
            try response([entity("Q100")])
        ]); defer { h.close() }
        let store = CatalogStore(cacheURL: nil, service: AppleCatalogService(session: h.session), knowledgeService: h.service)
        let id = WorkID(rawValue: "wikidata:Q100")!
        do { _ = try await store.search("A film", country: "jp", kind: .movie); XCTFail("Unverified work escaped failed hydration") }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertFalse(Task.isCancelled)
        XCTAssertNil(store.works[id])
        let results = try await store.search("A film", country: "jp", kind: .movie)
        XCTAssertEqual(results, [id])
        XCTAssertEqual(store.work(id).knowledgeID, "Q100")
        XCTAssertEqual(h.requests.count, 3, "Search candidates remain cached; exact entity hydration must retry")
        XCTAssertEqual(h.parameters(at: 1)["action"], "wbgetentities")
        XCTAssertEqual(h.parameters(at: 2)["action"], "wbgetentities")
    }

    func testRealTaskCancellationDuringTransportCannotPublishOrCacheAndRetryStartsFresh() async throws {
        let started = expectation(description: "Provider request started")
        let h = KnowledgeHarness(plans: [
            KnowledgePlan(status: 200, data: Data(), waitForCancellation: true, onStart: { started.fulfill() }),
            try plan(["success": 1, "search": [["id": "Q100", "label": "Fresh retry"]]])
        ]); defer { h.close() }
        let service = h.service
        let cancelled = Task { try await service.searchCandidates("龍与鸟") }
        await fulfillment(of: [started], timeout: 2)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A genuinely cancelled caller published results") }
        catch is CancellationError { }
        XCTAssertEqual(h.requests.count, 1, "Task cancellation must not continue to a script variant")
        XCTAssertFalse(Task.isCancelled)
        let result = try await service.searchCandidates("龍与鸟")
        XCTAssertEqual(result.map(\.qid), ["Q100"])
        XCTAssertEqual(h.requests.count, 2)
    }

    func testProviderOnlyDirectoryCancellationKeepsVerifiedWorkBranchesAndAllowsRetry() async throws {
        let artistClaim: [String: Any] = [
            "id": "Q200$22222222-2222-2222-2222-222222222222", "rank": "normal",
            "mainsnak": ["snaktype": "value", "datatype": "external-id", "datavalue": ["value": "485456501"]]
        ]
        let h = KnowledgeHarness(plans: [
            try response([entity("Q200", type: "Q5", claims: ["P800": [claim("Q200", "Q100")], "P2850": [artistClaim]])]),
            try response([entity("Q100", claims: ["P86": [claim("Q100", "Q200")]])]),
            KnowledgePlan(status: 200, data: Data(), transportFailure: .cancelled),
            try plan(["query": ["searchinfo": ["totalhits": 1], "search": [["title": "Q200"]]]])
        ]); defer { h.close() }
        let first = try await h.service.expand(qid: "Q200")
        XCTAssertNotNil(first.retryableFailure)
        XCTAssertTrue(first.snapshot.works.contains { $0.id.rawValue == "wikidata:Q100" })
        XCTAssertFalse(first.snapshot.works.contains { $0.id.rawValue == "apple:artist:485456501" })
        XCTAssertTrue(first.snapshot.relations.contains { $0.from.rawValue == "wikidata:Q100" && $0.to.rawValue == "wikidata:Q200" })
        let recovered = try await h.service.expand(qid: "Q200")
        XCTAssertNil(recovered.retryableFailure)
        XCTAssertTrue(recovered.snapshot.works.contains { $0.id.rawValue == "apple:artist:485456501" })
        XCTAssertEqual(h.requests.count, 4, "Verified entities remain cached; only the failed directory identity request retries")
    }

    func testOriginalAndVariantTransportOrAPIFailuresNeverBecomeEmptySearchResults() async throws {
        let failures = [
            KnowledgePlan(status: 200, data: Data(), transportFailure: .notConnectedToInternet),
            KnowledgePlan(status: 500, data: Data()),
            try plan(["error": ["code": "maxlag"]]),
            try plan(["success": 0, "search": []]),
            KnowledgePlan(status: 200, data: Data("{malformed".utf8))
        ]
        for failsOnVariant in [false, true] {
            for failure in failures {
                let initial = failsOnVariant ? [try plan(["success": 1, "search": []])] : []
                let h = KnowledgeHarness(plans: initial + [failure]); defer { h.close() }
                do {
                    _ = try await h.service.searchCandidates("龍与鸟")
                    XCTFail("An unsuccessful request was returned as a successful empty search")
                } catch { }
                XCTAssertEqual(h.requests.count, failsOnVariant ? 2 : 1,
                               "A failed form must not trigger another query or consume a later result")
            }
        }
    }

    func testFailedVariantCanRecoverWithoutRepeatingACachedSuccessfulEmptyOriginal() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]), KnowledgePlan(status: 500, data: Data()),
            try plan(["success": 1, "search": [["id": "Q100", "label": "龍與鳥"]]])
        ]); defer { h.close() }
        do { _ = try await h.service.searchCandidates("龙与鸟"); XCTFail("Failure became an empty result") }
        catch KnowledgeError.unavailable { }
        let values = try await h.service.searchCandidates("龙与鸟")
        XCTAssertEqual(values.map(\.qid), ["Q100"])
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertEqual((0..<h.requests.count).map { h.parameters(at: $0)["search"] }, ["龙与鸟", "龍與鳥", "龍與鳥"])
    }

    func testVariantMediaSearchStillHydratesExactTypesAndDoesNotMergeSameNamedWorks() async throws {
        let candidates: [[String: Any]] = [
            ["id": "Q100", "label": "龍與鳥", "description": "小说"],
            ["id": "Q101", "label": "龍與鳥", "description": "电影"],
            ["id": "Q102", "label": "龍與鳥", "description": "电影"]
        ]
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]), try plan(["success": 1, "search": candidates]),
            try response([entity("Q100"), entity("Q101", type: "Q7725634"), entity("Q102", type: "Q5")])
        ]); defer { h.close() }
        let films = try await h.service.searchWorks("龙与鸟", kind: .movie)
        let books = try await h.service.searchWorks("龙与鸟", kind: .ebook)
        XCTAssertEqual(films.results.map(\.rawValue), ["wikidata:Q100"])
        XCTAssertEqual(books.results.map(\.rawValue), ["wikidata:Q101"])
        XCTAssertTrue(Set(films.results).isDisjoint(with: books.results))
        XCTAssertEqual(films.snapshot.works.first?.knowledgeID, "Q100")
        XCTAssertNil(films.snapshot.works.first?.catalogID)
        XCTAssertEqual(books.snapshot.works.first?.kind, "文学作品")
        XCTAssertTrue(films.snapshot.relations.isEmpty)
        XCTAssertTrue(books.snapshot.relations.isEmpty)
        XCTAssertEqual(h.requests.count, 3, "Two search forms plus one shared exact-identity hydration, never inferred graph edges")
        XCTAssertEqual(Set(h.parameters(at: 2)["ids"]!.split(separator: "|").map(String.init)), ["Q100", "Q101", "Q102"])
    }

    func testVariantCandidateCannotBypassMismatchedEntityIdentity() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]),
            try plan(["success": 1, "search": [["id": "Q100", "label": "龍與鳥"]]]),
            try plan(["success": 1, "entities": ["Q100": entity("Q999")]])
        ]); defer { h.close() }
        do { _ = try await h.service.searchWorks("龙与鸟", kind: .movie); XCTFail("Search spelling substituted for identity verification") }
        catch KnowledgeError.invalidResponse { }
        XCTAssertEqual(h.requests.count, 3)
    }

    func testCancelledCallerCannotPublishCachedVariantCandidates() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": []]),
            try plan(["success": 1, "search": [["id": "Q100", "label": "龍與鳥"]]])
        ]); defer { h.close() }
        _ = try await h.service.searchCandidates("龙与鸟")
        let service = h.service
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.searchCandidates("龙与鸟")
        }
        do { _ = try await cancelled.value; XCTFail("A cancelled caller published cached results") }
        catch is CancellationError { }
        XCTAssertEqual(h.requests.count, 2)
    }

    func testMalformedJSONIsNotCached() async throws {
        let h = KnowledgeHarness(plans: [KnowledgePlan(status: 200, data: Data("{\"entities\":".utf8)), try response([entity("Q100")])]); defer { h.close() }
        do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Accepted malformed response") }
        catch KnowledgeError.invalidResponse { }
        _ = try await h.service.expand(qid: "Q100")
        XCTAssertEqual(h.requests.count, 2)
    }

    func testMismatchedResponseIdentityIsNotCached() async throws {
        let invalid = try plan(["entities": ["Q100": entity("Q999")]])
        let h = KnowledgeHarness(plans: [invalid, invalid]); defer { h.close() }
        for _ in 0..<2 {
            do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Accepted mismatched identity") }
            catch KnowledgeError.invalidResponse { }
        }
        XCTAssertEqual(h.requests.count, 2)
    }

    func testHTTP200MaxlagIsAnErrorAndUsesRetryAfter() async throws {
        var failure = try plan(["error": ["code": "maxlag"]]); failure.headers["Retry-After"] = "120"
        let h = KnowledgeHarness(plans: [failure]); defer { h.close() }
        do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Accepted maxlag") }
        catch KnowledgeError.throttled(let retry) { XCTAssertEqual(retry, 120) }
        do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Ignored backoff") }
        catch KnowledgeError.throttled { }
        XCTAssertEqual(h.requests.count, 1)
    }

    func testHTTP429HonorsRetryAfterWithoutPublishingEmptyGraph() async throws {
        let h = KnowledgeHarness(plans: [KnowledgePlan(status: 429, data: Data(), headers: ["Retry-After": "30"])]); defer { h.close() }
        do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Accepted 429") }
        catch KnowledgeError.throttled(let retry) { XCTAssertEqual(retry, 30) }
        do { _ = try await h.service.expand(qid: "Q100"); XCTFail("Ignored backoff") }
        catch KnowledgeError.throttled { }
        XCTAssertEqual(h.requests.count, 1)
    }

    func testCancelledCallerCannotPublishExistingCachedGraph() async throws {
        let h = try forwardHarness(); defer { h.close() }
        _ = try await h.service.expand(qid: "Q100")
        let service = h.service
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.expand(qid: "Q100")
        }
        do { _ = try await task.value; XCTFail("Cancelled caller published data") }
        catch is CancellationError { }
        XCTAssertEqual(h.requests.count, 2)
    }

    func testMusicalGroupCanExpandVerifiedReversePerformerCredits() async throws {
        let empty = try plan(["query": ["searchinfo": ["totalhits": 0], "search": []]])
        let h = KnowledgeHarness(plans: [
            try response([entity("Q44190", type: "Q215380")]), empty, empty, empty,
            try plan(["query": ["searchinfo": ["totalhits": 1], "search": [["title": "Q300"]]]]),
            try response([entity("Q300", type: "Q482994", claims: ["P175": [claim("Q300", "Q44190")]])])
        ]); defer { h.close() }
        let result = try await h.service.expand(qid: "Q44190")
        XCTAssertEqual(result.snapshot.works.first { $0.knowledgeID == "Q44190" }?.kind, "创作者")
        XCTAssertEqual(result.snapshot.relations.first?.from.rawValue, "wikidata:Q300")
        XCTAssertEqual(result.snapshot.relations.first?.label, "表演者")
        XCTAssertEqual(result.snapshot.relations.first?.inverseLabel, "参与作品")
        XCTAssertEqual(h.parameters(at: 4)["srsearch"], "haswbstatement:P175=Q44190")
        XCTAssertEqual(h.requests.count, 6)
    }

    func testExpansionCapAndUnknownTypesRemainExplicit() async throws {
        let ids = (200...212).map { "Q\($0)" }
        let h = KnowledgeHarness(plans: [try response([entity("Q100", claims: ["P144": ids.map { claim("Q100", $0) }])]), try response(ids.prefix(12).map { entity($0, type: "Q99999999") })]); defer { h.close() }
        let result = try await h.service.expand(qid: "Q100")
        XCTAssertEqual(result.snapshot.relations.count, 12)
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.snapshot.works.filter { $0.knowledgeID != "Q100" }.allSatisfy { $0.kind == "作品" && $0.art.isEmpty })
    }

    func testFilmSoundtrackAndThemeMusicKeepExactStatementScopeAndSeparateIdentities() async throws {
        let soundtrack = claim("Q950100", "Q950200")
        var theme = claim("Q950100", "Q950300")
        theme["id"] = "Q950100$22222222-2222-2222-2222-222222222222"
        let h = KnowledgeHarness(plans: [
            try response([entity("Q950100", claims: ["P406": [soundtrack], "P942": [theme]])]),
            try response([entity("Q950200", type: "Q482994"), entity("Q950300", type: "Q134556")])
        ]); defer { h.close() }
        let result = try await h.service.expand(qid: "Q950100")
        let release = try XCTUnwrap(result.snapshot.relations.first { $0.predicate == .soundtrackRelease })
        XCTAssertEqual(release.from.rawValue, "wikidata:Q950100")
        XCTAssertEqual(release.to.rawValue, "wikidata:Q950200")
        XCTAssertEqual(release.label, "原声")
        XCTAssertEqual(release.inverseLabel, "原声来自")
        XCTAssertEqual(URLComponents(string: release.source.url)?.fragment, soundtrack["id"] as? String)
        let music = try XCTUnwrap(result.snapshot.relations.first { $0.predicate == .themeMusic })
        XCTAssertEqual(music.label, "主题音乐")
        XCTAssertEqual(music.inverseLabel, "主题音乐来自")
        XCTAssertEqual(URLComponents(string: music.source.url)?.fragment, theme["id"] as? String)
        XCTAssertEqual(result.snapshot.works.first { $0.id == release.to }?.kind, "专辑")
        XCTAssertEqual(result.snapshot.works.first { $0.id == music.to }?.kind, "音乐作品")
        XCTAssertTrue(result.snapshot.works.allSatisfy { $0.catalogID == nil })
        XCTAssertFalse(result.snapshot.relations.contains { $0.predicate == .endingOf }, "P942 does not establish an ending/ED placement")
    }

    func testMusicalCompositionKeepsItsIdentityAndOffersRecordingSearchWithoutPlaybackIdentity() async throws {
        let h = KnowledgeHarness(plans: [try response([entity("Q114562491", type: "Q105543609")])])
        defer { h.close() }
        let result = try await h.service.expand(qid: "Q114562491")
        let composition = try XCTUnwrap(result.snapshot.works.first)
        XCTAssertEqual(composition.id.rawValue, "wikidata:Q114562491")
        XCTAssertEqual(composition.knowledgeID, "Q114562491")
        XCTAssertEqual(composition.kind, "音乐作品")
        XCTAssertFalse(composition.isSong, "A composition is not itself an audio recording")
        XCTAssertNil(composition.catalogID)
        XCTAssertNil(composition.catalogRecordingID)
        XCTAssertFalse(composition.hasCatalogRecording)
        XCTAssertTrue(composition.canFindCatalogVersion)
        XCTAssertEqual(composition.catalogVersionSearchKind, .song)
        XCTAssertEqual(composition.catalogVersionSearchTitle, "查找录音")
        XCTAssertEqual(composition.url, "https://www.wikidata.org/wiki/Q114562491")
        XCTAssertTrue(result.snapshot.relations.isEmpty, "Classification must not invent a recording or playback edge")
    }

    func testSameNameCompositionAndRecordingRemainDistinctKnowledgeEntities() async throws {
        var composition = entity("Q114562491", type: "Q105543609")
        var recording = entity("Q136085088", type: "Q55850593")
        composition["labels"] = ["zh": ["value": "KICK BACK"]]
        recording["labels"] = ["zh": ["value": "KICK BACK"]]
        let h = KnowledgeHarness(plans: [try response([composition]), try response([recording])])
        defer { h.close() }
        let workResult = try await h.service.expand(qid: "Q114562491")
        let trackResult = try await h.service.expand(qid: "Q136085088")
        let work = try XCTUnwrap(workResult.snapshot.works.first)
        let track = try XCTUnwrap(trackResult.snapshot.works.first)
        XCTAssertEqual(work.title, track.title)
        XCTAssertNotEqual(work.id, track.id)
        XCTAssertNotEqual(work.knowledgeID, track.knowledgeID)
        XCTAssertEqual(work.kind, "音乐作品")
        XCTAssertEqual(track.kind, "歌曲")
        XCTAssertNil(work.catalogID)
        XCTAssertNil(track.catalogID)
        XCTAssertNil(work.catalogRecordingID)
        XCTAssertNil(track.catalogRecordingID, "Even a knowledge recording needs a verified catalog identity before playback")
        XCTAssertTrue(workResult.snapshot.relations.isEmpty)
        XCTAssertTrue(trackResult.snapshot.relations.isEmpty)
    }

    @MainActor
    func testCachedGenericKnowledgeWorkRefinesAfterReopeningWithoutMergingARecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeKind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let id = try XCTUnwrap(WorkID(rawValue: "wikidata:Q114562491"))
        var previous = Work(id: id, title: "KICK BACK", creator: "", kind: "作品", art: "", detail: "", url: "https://www.wikidata.org/wiki/Q114562491")
        previous.knowledgeID = "Q114562491"
        let h = KnowledgeHarness(plans: [try response([entity("Q114562491", type: "Q105543609")])])
        defer { h.close() }
        let oldStore = CatalogStore(cacheURL: file, knowledgeService: h.service)
        try oldStore.merge(CatalogSnapshot(works: [previous], relations: []))
        await oldStore.flushPendingWrites()
        let reopened = CatalogStore(cacheURL: file, knowledgeService: h.service)
        XCTAssertEqual(reopened.work(id).kind, "作品", "This is a genuine older persisted generic record")

        await reopened.expandKnowledge(id)

        let updated = reopened.work(id)
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.knowledgeID, "Q114562491")
        XCTAssertEqual(updated.kind, "音乐作品")
        XCTAssertTrue(updated.canFindCatalogVersion)
        XCTAssertNil(updated.catalogID)
        XCTAssertNil(updated.catalogRecordingID)
        XCTAssertNil(reopened.knowledgeErrors[id])
        XCTAssertEqual(h.requests.count, 1, "Knowledge-loaded state must not suppress reclassification after reopening")
        await reopened.flushPendingWrites()
        let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.works.first { $0.id == id }?.kind, "音乐作品")
    }

    func testLiteratureStaysDistinctUnlessAVerifiedNovelFormRefinesIt() async throws {
        let valid = claim("Q951100", "Q8261")
        var deprecated = valid; deprecated["rank"] = "deprecated"
        var qualified = valid; qualified["qualifiers"] = ["P518": [["snaktype": "value", "datatype": "wikibase-item"]]]
        var wrongOwner = valid; wrongOwner["id"] = "Q951200$11111111-1111-1111-1111-111111111111"
        let cases: [([[String: Any]], String)] = [([], "文学作品"), ([valid], "书籍"), ([deprecated], "文学作品"), ([qualified], "文学作品"), ([wrongOwner], "文学作品")]
        for (forms, expected) in cases {
            let h = KnowledgeHarness(plans: [try response([entity("Q951100", type: "Q7725634", claims: ["P7937": forms])])])
            defer { h.close() }
            let result = try await h.service.expand(qid: "Q951100")
            XCTAssertEqual(result.snapshot.works.first?.kind, expected)
            XCTAssertEqual(result.snapshot.works.first?.id.rawValue, "wikidata:Q951100")
            XCTAssertTrue(result.snapshot.relations.isEmpty, "Classification does not invent a reading destination or credit")
        }
    }

    func testLightNovelSeriesRemainsLiteratureInsteadOfAnInventedAnimeIdentity() async throws {
        let h = KnowledgeHarness(plans: [try response([entity("Q48751907", type: "Q104213567")])])
        defer { h.close() }
        let result = try await h.service.expand(qid: "Q48751907")
        XCTAssertEqual(result.snapshot.works.first?.kind, "文学作品")
        XCTAssertTrue(result.snapshot.relations.isEmpty)
    }

    @MainActor func testMediaSearchUsesVerifiedWorkTypesAndKeepsSameNameEntitiesSeparate() async throws {
        let candidates: [[String: Any]] = [
            ["id": "Q100", "label": "同名作品", "description": "电影"],
            ["id": "Q101", "label": "同名作品", "description": "小说"],
            ["id": "Q102", "label": "同名作品", "description": "电影导演"],
            ["id": "Q103", "label": "同名作品", "description": "电影"]
        ]
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": candidates]),
            try response([entity("Q100"), entity("Q101", type: "Q7725634"), entity("Q102", type: "Q5"), entity("Q103", type: "Q4167410")])
        ]); defer { h.close() }
        let store = CatalogStore(cacheURL: nil, service: AppleCatalogService(session: h.session), knowledgeService: h.service)
        let film = try await store.search("同名作品", country: "jp", kind: .movie)
        let book = try await store.search("同名作品", country: "us", kind: .ebook)
        XCTAssertEqual(film.map(\.rawValue), ["wikidata:Q100"])
        XCTAssertEqual(book.map(\.rawValue), ["wikidata:Q101"])
        XCTAssertEqual(store.work(film[0]).knowledgeID, "Q100")
        XCTAssertNil(store.work(film[0]).catalogID)
        XCTAssertEqual(store.work(book[0]).kind, "文学作品")
        XCTAssertTrue(store.work(book[0]).creatorIDs.isEmpty)
        XCTAssertEqual(h.requests.count, 2, "One search and one batch identity request; no speculative graph expansion")
        XCTAssertTrue(h.requests.allSatisfy { $0.url?.host == "www.wikidata.org" })
    }

    func testMediaSearchKeepsCachedMetadataButRetriesFailedIdentityHydration() async throws {
        let h = KnowledgeHarness(plans: [
            try plan(["success": 1, "search": [["id": "Q100", "label": "A film"]]]),
            KnowledgePlan(status: 500, data: Data()),
            try response([entity("Q100")])
        ]); defer { h.close() }
        do { _ = try await h.service.searchWorks("A film", kind: .movie); XCTFail("Failure became no results") }
        catch KnowledgeError.unavailable { }
        let values = try await h.service.searchWorks("A film", kind: .movie)
        XCTAssertEqual(values.results.map(\.rawValue), ["wikidata:Q100"])
        XCTAssertEqual(h.requests.count, 3)
    }

    func testLiveMediaSearchSeparatesNorwegianWoodNovelAndFilm() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1")
        let service = KnowledgeGraphService()
        let books = try await service.searchWorks("挪威的森林", kind: .ebook)
        let films = try await service.searchWorks("挪威的森林", kind: .movie)
        XCTAssertTrue(books.results.contains(WorkID(rawValue: "wikidata:Q751348")!))
        XCTAssertTrue(films.results.contains(WorkID(rawValue: "wikidata:Q1066749")!))
        XCTAssertTrue(Set(books.results).isDisjoint(with: films.results))
        XCTAssertTrue(books.snapshot.works.allSatisfy { CatalogSearchKind.ebook.includes(workKind: $0.kind) })
        XCTAssertTrue(films.snapshot.works.allSatisfy { $0.knowledgeID != nil && $0.catalogID == nil })
    }

    private func forwardHarness() throws -> KnowledgeHarness {
        KnowledgeHarness(plans: [try response([entity("Q100", claims: ["P57": [claim("Q100", "Q200")], "P144": [claim("Q100", "Q300")]])]), try response([entity("Q200", type: "Q5"), entity("Q300", type: "Q571")])])
    }
}

private func claim(_ from: String, _ to: String) -> [String: Any] {
    ["id": from + "$11111111-1111-1111-1111-111111111111", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": to]]]]
}
private func entity(_ id: String, type: String = "Q11424", claims: [String: Any] = [:]) -> [String: Any] {
    var values = claims; values["P31"] = [claim(id, type)]
    return ["id": id, "type": "item", "labels": ["zh": ["value": "作品 " + id]], "claims": values]
}
private func response(_ entities: [[String: Any]]) throws -> KnowledgePlan {
    try plan(["success": 1, "entities": Dictionary(uniqueKeysWithValues: entities.map { ($0["id"] as! String, $0) })])
}
private func plan(_ object: [String: Any]) throws -> KnowledgePlan { KnowledgePlan(status: 200, data: try JSONSerialization.data(withJSONObject: object)) }
private struct KnowledgePlan: Sendable {
    let status: Int
    let data: Data
    var headers: [String: String] = ["Content-Type": "application/json"]
    var transportFailure: URLError.Code? = nil
    var waitForCancellation = false
    var onStart: (@Sendable () -> Void)? = nil
}

/// Each test owns an isolated URLSession token; unmatched requests fail locally.
private final class KnowledgeHarness: @unchecked Sendable {
    let service: KnowledgeGraphService
    let session: URLSession
    private let token = UUID().uuidString
    private let state: KnowledgeStubState
    init(plans: [KnowledgePlan]) {
        state = KnowledgeStubState(plans: plans)
        KnowledgeStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KnowledgeURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Knowledge-Test": token]
        session = URLSession(configuration: configuration)
        service = KnowledgeGraphService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(at index: Int) -> [String: String] {
        guard requests.indices.contains(index), let url = requests[index].url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close() { session.invalidateAndCancel(); KnowledgeStubRegistry.shared.remove(token) }
}
private final class KnowledgeStubRegistry: @unchecked Sendable {
    static let shared = KnowledgeStubRegistry()
    private let lock = NSLock()
    private var values: [String: KnowledgeStubState] = [:]
    func put(_ key: String, _ value: KnowledgeStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> KnowledgeStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class KnowledgeStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [KnowledgePlan]
    private var observed: [URLRequest] = []
    init(plans: [KnowledgePlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> KnowledgePlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class KnowledgeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = KnowledgeStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Knowledge-Test")),
              let plan = state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        plan.onStart?()
        if plan.waitForCancellation { return }
        if let failure = plan.transportFailure {
            client?.urlProtocol(self, didFailWithError: URLError(failure)); return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: plan.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
