import XCTest
@testable import Pianwai

@MainActor final class BackgroundContinuationSelectionTests: XCTestCase {
    func testAlternativeRequiresANewCreativeIdentityAndKeepsSourceOrder() async {
        let resolver = ContinuationResolverStub(answers: [
            "concept": [.value(nil)], "company": [.value(nil)],
            "current": [.value("Q1")], "neighbor": [.value("Q2")],
            "neighbor alias": [.value("Q2")], "new artist": [.value("Q3")],
            "later work": [.value("Q4")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        let request = request(candidates: [
            excerpt("alternative", ["concept", "company", "current", "neighbor", "neighbor alias", "new artist"]),
            excerpt("later", ["later work"])
        ], excluded: ["Q1", "Q2"])
        await selection.prepare(request)
        XCTAssertEqual(selection.preparedSecondID, "alternative")
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertFalse(calls.contains("zh:later work"), "The first verified continuation is sufficient")
        XCTAssertEqual(request.first.id, "first")
        XCTAssertEqual(request.second.id, "second")
    }

    func testANewRouteInTheFirstAccountPreservesTheOriginalSecond() async {
        let resolver = ContinuationResolverStub(answers: ["first artist": [.value("Q10")], "other": [.value("Q20")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(first: excerpt("first", ["first artist"]),
                                        second: excerpt("second", ["other"]),
                                        candidates: [excerpt("alternative", ["other"])]))
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasPrepared)
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:first artist"], "Do not spend more requests or replace an already useful pair")
    }

    func testANewRouteInTheOriginalSecondIsNotReplacedByAnotherCandidate() async {
        let resolver = ContinuationResolverStub(answers: [
            "concept": [.value(nil)], "second work": [.value("Q10")], "other": [.value("Q20")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(first: excerpt("first", ["concept"]),
                                        second: excerpt("second", ["second work"]),
                                        candidates: [excerpt("alternative", ["other"])]))
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasPrepared)
        let calls = await resolver.calls
        XCTAssertFalse(calls.contains("zh:other"))
    }

    func testUnverifiedAnchorsCannotDisplaceReadableAccounts() async {
        let resolver = ContinuationResolverStub(answers: [
            "concept": [.value(nil)], "company": [.value(nil)], "missing": [.failure]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [excerpt("alternative", ["concept", "company", "missing"])]))
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertTrue(selection.hasFailures, "A source outage must remain distinguishable from verified noncreative articles")
        XCTAssertFalse(selection.isLoading)
    }

    func testFailedCandidateCanBeRetriedWithoutCachingItsFailureAsEmpty() async {
        let resolver = ContinuationResolverStub(answers: ["new work": [.failure, .value("Q10")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        let input = request(candidates: [excerpt("alternative", ["new work"])])
        await selection.prepare(input)
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasFailures)
        await selection.prepare(input)
        XCTAssertEqual(selection.preparedSecondID, "alternative")
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:new work", "zh:new work"])
    }

    func testBaselineFailureDoesNotPreventAPositivelyVerifiedAlternativeOrBecomeKnownEmpty() async {
        let resolver = ContinuationResolverStub(answers: ["baseline": [.failure], "alternative": [.value("Q20")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(first: excerpt("first", ["baseline"]),
                                        candidates: [excerpt("alternative", ["alternative"])]))
        XCTAssertEqual(selection.preparedSecondID, "alternative")
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertTrue(selection.hasFailures, "Successful discovery must not erase a failed baseline lookup")
    }

    func testProviderCancellationCompletesWithFallbackAndCanBeRetried() async {
        for cancellation in [ContinuationResolverStub.Answer.cancellation, .transportCancelled] {
            let resolver = ContinuationResolverStub(answers: ["candidate": [cancellation, .value("Q20")]])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            let input = request(candidates: [excerpt("alternative", ["candidate"])])

            await selection.prepare(input)

            XCTAssertFalse(Task.isCancelled, "Only the provider request was cancelled")
            XCTAssertNil(selection.preparedSecondID)
            XCTAssertTrue(selection.hasPrepared, "A finished failed lookup must release the fallback from the preparing state")
            XCTAssertTrue(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)

            await selection.prepare(input)

            XCTAssertEqual(selection.preparedSecondID, "alternative")
            XCTAssertTrue(selection.hasPrepared)
            XCTAssertFalse(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
            let calls = await resolver.calls
            XCTAssertEqual(calls, ["zh:candidate", "zh:candidate"])
        }
    }

    func testProviderCancellationCanStillFindALaterVerifiedRouteWithoutHidingTheFailure() async {
        for cancellation in [ContinuationResolverStub.Answer.cancellation, .transportCancelled] {
            let resolver = ContinuationResolverStub(answers: [
                "baseline": [cancellation], "candidate": [.value("Q20")]
            ])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            await selection.prepare(request(first: excerpt("first", ["baseline"]),
                                            candidates: [excerpt("alternative", ["candidate"])]))
            XCTAssertEqual(selection.preparedSecondID, "alternative")
            XCTAssertTrue(selection.hasPrepared)
            XCTAssertTrue(selection.hasFailures, "The baseline was unavailable, not confirmed empty")
            XCTAssertFalse(selection.isLoading)
            let calls = await resolver.calls
            XCTAssertEqual(calls, ["zh:baseline", "zh:candidate"])
        }
    }

    func testNoDistinctAlternativeFinishesWithoutLookingUpBaselineReferences() async {
        for alternatives in [[], [excerpt("first", ["duplicate"]), excerpt("second", ["duplicate"])]] {
            let resolver = ContinuationResolverStub(answers: ["baseline": [.failure]])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            await selection.prepare(request(first: excerpt("first", ["baseline"]), candidates: alternatives))
            XCTAssertNil(selection.preparedSecondID)
            XCTAssertTrue(selection.hasPrepared)
            XCTAssertFalse(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
            let calls = await resolver.calls
            XCTAssertTrue(calls.isEmpty, "Without another account, identity work cannot improve the original second")
        }
    }

    func testExactArticleIdentityDeduplicatesAcrossAccountsButNotLanguagesOrLabels() async {
        let same = WikiArticleReference(label: "Shared label", title: "Exact title", language: "zh")
        let renamed = WikiArticleReference(label: "Another label", title: "Exact title", language: "zh")
        let english = WikiArticleReference(label: "Shared label", title: "Exact title", language: "en")
        let resolver = ContinuationResolverStub(exactAnswers: [
            "zh:Exact title": [.value(nil)], "en:Exact title": [.value("Q20")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(.init(first: excerpt("first", references: [same]),
                                      second: excerpt("second", references: [renamed]),
                                      candidates: [excerpt("alternative", references: [renamed, english])], excludedQIDs: []))
        XCTAssertEqual(selection.preparedSecondID, "alternative")
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:Exact title", "en:Exact title"])
    }

    func testTotalBudgetCountsUniqueAttemptedArticlesIncludingFailures() async {
        let first = (1...6).map { "article-\($0)" }
        let second = (7...12).map { "article-\($0)" }
        let remaining = ["article-1"] + (13...17).map { "article-\($0)" }
        let resolver = ContinuationResolverStub(answers: ["article-3": [.failure], "article-17": [.value("Q17")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(first: excerpt("first", first), second: excerpt("second", second),
                                        candidates: [excerpt("alternative", remaining)]))
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertTrue(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls.count, 16)
        XCTAssertEqual(Set(calls).count, 16)
        XCTAssertEqual(calls.last, "zh:article-16")
        XCTAssertFalse(calls.contains("zh:article-17"))
    }

    func testPerAccountAndCandidateLimitsCannotBeBypassedByOversizedInput() async {
        let nine = (1...9).map { "article-\($0)" }
        let resolver = ContinuationResolverStub(answers: ["article-9": [.value("Q9")], "fifth": [.value("Q50")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [
            excerpt("one", nine), excerpt("two", []), excerpt("three", []), excerpt("four", []),
            excerpt("five", ["fifth"])
        ]))
        XCTAssertNil(selection.preparedSecondID)
        XCTAssertTrue(selection.hasPrepared)
        let calls = await resolver.calls
        XCTAssertEqual(calls, (1...8).map { "zh:article-\($0)" })
    }

    func testRepeatedExcerptIDsCannotSelectTheFirstOrReplaceASourceWithAnotherPayload() async {
        let resolver = ContinuationResolverStub(answers: [
            "unexpected first": [.value("Q1")], "concept": [.value(nil)],
            "unexpected replacement": [.value("Q2")], "valid": [.value("Q3")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [
            excerpt("first", ["unexpected first"]), excerpt("same", ["concept"]),
            excerpt("same", ["unexpected replacement"]), excerpt("valid", ["valid"])
        ]))
        XCTAssertEqual(selection.preparedSecondID, "valid")
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:concept", "zh:valid"])
    }

    func testFocusedSentenceWinsWhenOmittedAnchorsAreOnlyConceptsOrExcludedIdentities() async {
        let pair = focusedFamily(included: ["band"], original: ["producer concept", "band", "credits concept", "neighbor"])
        let resolver = ContinuationResolverStub(answers: [
            "band": [.value("Q10")], "producer concept": [.value(nil)],
            "credits concept": [.value(nil)], "neighbor": [.value("Q2")], "later": [.value("Q30")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [pair.focus, excerpt("later", ["later"])], excluded: ["Q2"],
                                        originals: [pair.original]))
        XCTAssertEqual(selection.preparedSecondID, pair.focus.id)
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:band", "zh:producer concept", "zh:credits concept", "zh:neighbor"])
    }

    func testOmittedNewCreatorPreservesTheOriginalAccount() async {
        let pair = focusedFamily(included: ["band"], original: ["additional creator", "band"])
        let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")], "additional creator": [.value("Q20")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [pair.focus], originals: [pair.original]))
        XCTAssertEqual(selection.preparedSecondID, pair.original.id)
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:band", "zh:additional creator"])
    }

    func testOmittedLookupFailurePreservesOriginalWithVerifiedFocusedRoute() async {
        for error in [ContinuationResolverStub.Answer.failure, .cancellation, .transportCancelled] {
            let pair = focusedFamily(included: ["band"], original: ["unavailable creator", "band"])
            let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")], "unavailable creator": [error]])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            // This failure is already known from the baseline: it must not be
            // skipped as though a previously attempted anchor meant no route.
            await selection.prepare(request(first: excerpt("first", ["unavailable creator"]),
                                            candidates: [pair.focus], originals: [pair.original]))
            XCTAssertEqual(selection.preparedSecondID, pair.original.id)
            XCTAssertTrue(selection.hasPrepared)
            XCTAssertTrue(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
            XCTAssertFalse(Task.isCancelled)
            let calls = await resolver.calls
            XCTAssertEqual(calls, ["zh:unavailable creator", "zh:band"], "Reuse the failed exact lookup without treating it as verified empty")
        }
    }

    func testOriginalCanSupplyTheOnlyVerifiedRouteForItsFocusedFamily() async {
        let pair = focusedFamily(included: ["concept"], original: ["concept", "creator"])
        let resolver = ContinuationResolverStub(answers: ["concept": [.value(nil)], "creator": [.value("Q20")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [pair.focus], originals: [pair.original]))
        XCTAssertEqual(selection.preparedSecondID, pair.original.id)
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.hasFailures)
    }

    func testAliasesOfEveryIncludedCreativeQIDDoNotForceTheLongerAccount() async {
        let pair = focusedFamily(included: ["band", "recording"], original: ["recording alias", "band", "recording", "band alias"])
        let resolver = ContinuationResolverStub(answers: [
            "band": [.value("Q10")], "recording": [.value("Q20")],
            "recording alias": [.value("Q20")], "band alias": [.value("Q10")]
        ])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [pair.focus], originals: [pair.original]))
        XCTAssertEqual(selection.preparedSecondID, pair.focus.id,
                       "Compare verified QIDs, including later included anchors, rather than article titles or only the first route")
        XCTAssertFalse(selection.hasFailures)
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:band", "zh:recording", "zh:recording alias", "zh:band alias"])
        XCTAssertEqual(Set(calls).count, calls.count)
    }

    func testBudgetExhaustionDuringOmittedChecksKeepsOriginalWithoutExceedingSixteenLookups() async {
        let first = (1...6).map { "baseline-\($0)" }
        let second = (7...12).map { "baseline-\($0)" }
        let omitted = (1...4).map { "omitted-\($0)" }
        let pair = focusedFamily(included: ["band"], original: omitted + ["band"])
        let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")], "omitted-4": [.value("Q20")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(first: excerpt("first", first), second: excerpt("second", second),
                                        candidates: [pair.focus], originals: [pair.original]))
        XCTAssertEqual(selection.preparedSecondID, pair.original.id,
                       "An unqueried omitted anchor is unknown; the verified short route is still present in the original")
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.hasFailures, "Exhausting a finite budget is not a transport failure")
        let calls = await resolver.calls
        XCTAssertEqual(calls.count, 16)
        XCTAssertEqual(Set(calls).count, 16)
        XCTAssertEqual(calls.last, "zh:omitted-3")
        XCTAssertFalse(calls.contains("zh:omitted-4"))
    }

    func testRetainedOriginalsStayWithinTheirFamilyAndEightAnchorLimit() async {
        let omitted = (1...8).map { "omitted-\($0)" }
        let pair = focusedFamily(included: ["band"], original: ["band"] + omitted)
        let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")], "omitted-8": [.value("Q20")], "unrelated": [.value("Q30")]])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        await selection.prepare(request(candidates: [pair.focus], originals: [pair.original, excerpt("unrelated", ["unrelated"])]))
        XCTAssertEqual(selection.preparedSecondID, pair.original.id, "An oversized original has unverified omitted context")
        let calls = await resolver.calls
        XCTAssertEqual(calls, ["zh:band"] + (1...7).map { "zh:omitted-\($0)" })
        XCTAssertFalse(calls.contains("zh:unrelated"), "Retained entries are not additional alternatives")

        let noFamilyResolver = ContinuationResolverStub(answers: ["unrelated": [.value("Q30")]])
        let noFamilySelection = BackgroundContinuationSelection(resolver: noFamilyResolver)
        await noFamilySelection.prepare(request(candidates: [excerpt("candidate", [])], originals: [excerpt("unrelated", ["unrelated"])]))
        XCTAssertNil(noFamilySelection.preparedSecondID)
        XCTAssertTrue(noFamilySelection.hasPrepared)
        let unrelatedCalls = await noFamilyResolver.calls
        XCTAssertTrue(unrelatedCalls.isEmpty)
    }

    func testDerivedSentenceRequiresItsExactSameSourceOriginal() async {
        let pair = focusedFamily(included: ["band"], original: ["band"])
        let mismatches: [WorkBackgroundExcerpt?] = [
            nil,
            .init(id: pair.original.id, heading: "Music", body: pair.original.body,
                  sourceParagraph: "Another paragraph", source: pair.original.source, language: pair.original.language),
            .init(id: pair.original.id, heading: "Music", body: pair.original.body,
                  sourceParagraph: pair.original.sourceParagraph, source: pair.original.source, language: "en"),
            .init(id: pair.original.id, heading: "Music", body: pair.original.body,
                  sourceParagraph: pair.original.sourceParagraph,
                  source: .init(title: "Article", detail: "章节摘录", url: "https://zh.wikipedia.org/w/index.php?oldid=124#Music"), language: pair.original.language),
            .init(id: pair.original.id, heading: "Music", body: "The claimed original does not contain the focused sentence.",
                  sourceParagraph: pair.original.sourceParagraph, source: pair.original.source, language: pair.original.language)
        ]
        for mismatch in mismatches {
            let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")], "later": [.value("Q20")]])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            await selection.prepare(request(candidates: [pair.focus, excerpt("later", ["later"])],
                                            originals: mismatch.map { [$0] } ?? []))
            XCTAssertEqual(selection.preparedSecondID, "later")
            XCTAssertTrue(selection.hasPrepared)
            let calls = await resolver.calls
            XCTAssertEqual(calls, ["zh:later"], "An untraceable derivation cannot publish a shorter account or consume identity budget")
        }
    }

    func testExistingBaselineRouteStillWinsBeforeComparingAFocusedFamily() async {
        for useSecond in [false, true] {
            let pair = focusedFamily(included: ["band"], original: ["creator", "band"])
            let resolver = ContinuationResolverStub(answers: ["baseline": [.value("Q10")], "band": [.value("Q20")], "creator": [.value("Q30")]])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            await selection.prepare(request(first: excerpt("first", useSecond ? [] : ["baseline"]),
                                            second: excerpt("second", useSecond ? ["baseline"] : []),
                                            candidates: [pair.focus], originals: [pair.original]))
            XCTAssertNil(selection.preparedSecondID)
            XCTAssertTrue(selection.hasPrepared)
            let calls = await resolver.calls
            XCTAssertEqual(calls, ["zh:baseline"])
        }
    }

    func testCancellationWhileCheckingOmittedContextCannotPublishEitherAccount() async {
        for explicitCancel in [false, true] {
            let pair = focusedFamily(included: ["band"], original: ["band", "held omitted"])
            let resolver = ContinuationResolverStub(answers: ["band": [.value("Q10")]], held: ["held omitted"])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            let task = Task { await selection.prepare(request(candidates: [pair.focus], originals: [pair.original])) }
            await resolver.waitForCall("held omitted")
            XCTAssertNil(selection.preparedSecondID, "Do not publish the short choice before checking what it leaves out")
            XCTAssertFalse(selection.hasPrepared)
            if explicitCancel { selection.cancel() }
            else { task.cancel() }
            await resolver.release("held omitted", with: .value("Q20"))
            await task.value
            XCTAssertNil(selection.preparedSecondID)
            XCTAssertFalse(selection.hasPrepared)
            XCTAssertFalse(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
        }
    }

    func testPreparationIsIncompleteUntilTheCurrentResolverFinishes() async {
        let resolver = ContinuationResolverStub(answers: [:], held: ["held"])
        let selection = BackgroundContinuationSelection(resolver: resolver)
        let task = Task { await selection.prepare(request(candidates: [excerpt("alternative", ["held"])])) }
        await resolver.waitForCall("held")
        XCTAssertTrue(selection.isLoading)
        XCTAssertFalse(selection.hasPrepared)
        XCTAssertNil(selection.preparedSecondID)
        await resolver.release("held", with: .value("Q10"))
        await task.value
        XCTAssertTrue(selection.hasPrepared)
        XCTAssertFalse(selection.isLoading)
        XCTAssertEqual(selection.preparedSecondID, "alternative")
    }

    func testOldSuccessAndFailureCannotOverwriteANewerPreparedAccount() async {
        for oldAnswer in [ContinuationResolverStub.Answer.value("Q10"), .failure, .cancellation, .transportCancelled] {
            let resolver = ContinuationResolverStub(answers: ["new": [.value("Q20")]], held: ["old"])
            let selection = BackgroundContinuationSelection(resolver: resolver)
            let old = Task { await selection.prepare(request(candidates: [excerpt("old-account", ["old"])])) }
            await resolver.waitForCall("old")
            await selection.prepare(request(candidates: [excerpt("new-account", ["new"])]))
            await resolver.release("old", with: oldAnswer)
            await old.value
            XCTAssertEqual(selection.preparedSecondID, "new-account")
            XCTAssertTrue(selection.hasPrepared)
            XCTAssertFalse(selection.hasFailures)
            XCTAssertFalse(selection.isLoading)
        }
    }

    func testCancellationIgnoresANonCooperativeResolverAndNeverMarksAttemptPrepared() async {
        for explicitCancel in [false, true] {
            for answer in [ContinuationResolverStub.Answer.value("Q10"), .cancellation, .transportCancelled] {
                let resolver = ContinuationResolverStub(answers: [:], held: ["held"])
                let selection = BackgroundContinuationSelection(resolver: resolver)
                let task = Task { await selection.prepare(request(candidates: [excerpt("alternative", ["held"])])) }
                await resolver.waitForCall("held")
                if explicitCancel { selection.cancel() }
                else { task.cancel() }
                await resolver.release("held", with: answer)
                await task.value
                XCTAssertNil(selection.preparedSecondID)
                XCTAssertFalse(selection.hasPrepared)
                XCTAssertFalse(selection.hasFailures)
                XCTAssertFalse(selection.isLoading)
            }
        }
    }

    private func excerpt(_ id: String, _ names: [String]) -> WorkBackgroundExcerpt {
        excerpt(id, references: names.map { .init(label: $0, title: $0, language: "zh") })
    }

    private func excerpt(_ id: String, references: [WikiArticleReference]) -> WorkBackgroundExcerpt {
        .init(id: id, heading: "Music", body: "A complete attributed account of the recording.",
              sourceParagraph: "A complete attributed account of the recording.",
              source: .init(title: "Article", detail: "章节摘录", url: "https://zh.wikipedia.org/w/index.php?oldid=123#Music"),
              language: "zh", references: references)
    }

    private func focusedFamily(included: [String], original: [String]) -> (focus: WorkBackgroundExcerpt, original: WorkBackgroundExcerpt) {
        let body = "The ensemble recorded the theme song."
        let paragraph = "The production crew included other participants. " + body
        let source = Source(title: "Article", detail: "章节摘录", url: "https://zh.wikipedia.org/w/index.php?oldid=123#Music")
        let parent = WorkBackgroundExcerpt(id: "original", heading: "Music", body: paragraph, sourceParagraph: paragraph,
                                           source: source, language: "zh",
                                           references: original.map { .init(label: $0, title: $0, language: "zh") })
        var focused = WorkBackgroundExcerpt(id: "original:focus", heading: "Music", body: body, sourceParagraph: paragraph,
                                            source: source, language: "zh",
                                            references: included.map { .init(label: $0, title: $0, language: "zh") })
        focused.derivedFromExcerptID = parent.id
        return (focused, parent)
    }

    private func request(first: WorkBackgroundExcerpt? = nil, second: WorkBackgroundExcerpt? = nil,
                         candidates: [WorkBackgroundExcerpt], excluded: Set<String> = [],
                         originals: [WorkBackgroundExcerpt] = []) -> BackgroundContinuationRequest {
        .init(first: first ?? excerpt("first", []), second: second ?? excerpt("second", []),
              candidates: candidates, excludedQIDs: excluded, originalCandidates: originals)
    }
}

private enum ContinuationStubFailure: Error { case offline }

/// Held requests deliberately ignore cancellation to exercise the consumer's
/// generation guard rather than relying on a cooperative networking layer.
private actor ContinuationResolverStub: BackgroundReferenceResolving {
    enum Answer: Sendable { case value(String?), failure, cancellation, transportCancelled }
    private var answers: [String: [Answer]]
    private var held: Set<String>
    private var pending: [String: CheckedContinuation<Answer, Never>] = [:]
    private var started: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls: [String] = []

    init(answers: [String: [Answer]], held: Set<String> = []) {
        self.answers = Dictionary(uniqueKeysWithValues: answers.map { ("zh:" + $0.key, $0.value) })
        self.held = Set(held.map { "zh:" + $0 })
    }

    init(exactAnswers: [String: [Answer]]) {
        answers = exactAnswers
        held = []
    }

    func resolveCreative(_ reference: WikiArticleReference) async throws -> String? {
        let key = reference.id
        calls.append(key)
        for continuation in started.removeValue(forKey: key) ?? [] { continuation.resume() }
        let answer: Answer
        if held.contains(key) { answer = await withCheckedContinuation { pending[key] = $0 } }
        else if var sequence = answers[key], !sequence.isEmpty {
            answer = sequence.removeFirst()
            answers[key] = sequence
        } else { answer = .value(nil) }
        switch answer {
        case .value(let qid): return qid
        case .failure: throw ContinuationStubFailure.offline
        case .cancellation: throw CancellationError()
        case .transportCancelled: throw URLError(.cancelled)
        }
    }

    func waitForCall(_ title: String) async {
        let key = "zh:" + title
        if calls.contains(key) { return }
        await withCheckedContinuation { started[key, default: []].append($0) }
    }

    func release(_ title: String, with answer: Answer) {
        let key = "zh:" + title
        held.remove(key)
        pending.removeValue(forKey: key)?.resume(returning: answer)
    }
}
