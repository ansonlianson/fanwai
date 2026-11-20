import XCTest
@testable import Pianwai

@MainActor final class SearchSessionTests: XCTestCase {
    func testReopeningCompletedSearchKeepsResultsSubmissionAndPosition() throws {
        let state = SearchSessionState()
        let key = key("Joe Hisaishi")
        let results: [WorkID] = [.pool, .jane, .distance]
        let token = try XCTUnwrap(state.begin(key))
        XCTAssertTrue(state.complete(token, results: results))
        let position = SearchListPosition(offset: 840.5, anchor: .jane)
        state.rememberPosition(position, for: key)
        state.cancelRequest()
        state.activate(key)

        XCTAssertEqual(state.activeKey, key)
        XCTAssertEqual(state.snapshot.results, results)
        XCTAssertEqual(state.snapshot.position, position)
        XCTAssertTrue(state.snapshot.submitted)
        XCTAssertFalse(state.searching)
        XCTAssertNil(state.snapshot.error)
    }

    func testQueryTypeCountryAndRecordingProvenanceKeepSeparateSnapshots() throws {
        let state = SearchSessionState()
        let variants = [
            key("Lotus"),
            key("Lotus", kind: .album),
            key("Lotus", country: "us"),
            key("Lotus", context: context(sourceID: "wikidata:Q100")),
            key("Lotus", context: context(sourceID: "wikidata:Q101")),
            key("Another song")
        ]
        let results: [WorkID] = [.pool, .poolAlbum, .jane, .distance, .ourFilm, .slow]
        for (index, variant) in variants.enumerated() {
            state.activate(variant)
            XCTAssertTrue(state.snapshot.results.isEmpty)
            XCTAssertFalse(state.snapshot.submitted)
            XCTAssertEqual(state.snapshot.position, SearchListPosition())
            let token = try XCTUnwrap(state.begin(variant))
            XCTAssertTrue(state.complete(token, results: [results[index]]))
            state.rememberPosition(SearchListPosition(offset: Double(index * 120), anchor: results[index]), for: variant)
        }

        for (index, variant) in variants.enumerated().reversed() {
            state.activate(variant)
            XCTAssertEqual(state.snapshot.results, [results[index]])
            XCTAssertEqual(state.snapshot.position, SearchListPosition(offset: Double(index * 120), anchor: results[index]))
            XCTAssertTrue(state.snapshot.submitted)
        }
    }

    func testLateCompletionAndFailureCannotOverwriteAChangedQuery() throws {
        let state = SearchSessionState()
        let older = try XCTUnwrap(state.begin(key("Old query")))
        let current = try XCTUnwrap(state.begin(key("New query")))
        XCTAssertFalse(state.complete(older, results: [.film]))
        XCTAssertFalse(state.fail(older, message: "Old failure"))
        XCTAssertTrue(state.searching)
        XCTAssertTrue(state.snapshot.results.isEmpty)
        XCTAssertNil(state.snapshot.error)
        XCTAssertTrue(state.complete(current, results: [.jane]))
        XCTAssertEqual(state.snapshot.results, [.jane])
        XCTAssertFalse(state.searching)
    }

    func testClearingQueryInvalidatesRequestAndDoesNotResurrectItsResults() throws {
        let state = SearchSessionState()
        let previous = key("Lotus")
        let token = try XCTUnwrap(state.begin(previous))
        let empty = key("  \n")
        state.activate(empty)
        XCTAssertFalse(state.complete(token, results: [.pool]))
        XCTAssertFalse(state.fail(token, message: "Late error"))
        state.rememberPosition(SearchListPosition(offset: 900, anchor: .pool), for: previous)
        XCTAssertEqual(state.snapshot, SearchSessionSnapshot())
        XCTAssertFalse(state.searching)
        XCTAssertNil(state.begin(empty))
        state.activate(previous)
        XCTAssertEqual(state.snapshot, SearchSessionSnapshot(), "The cancelled request is not a completed empty search")
    }

    func testIMETextCallbackForSubmittedQueryKeepsTheRequestAlive() throws {
        let state = SearchSessionState()
        let submitted = key("千与千寻")
        let request = try XCTUnwrap(state.begin(submitted))
        // The field's onChange can follow its Return/onSubmit callback.
        state.activate(key("  千与千寻\n"))
        XCTAssertTrue(state.searching)
        XCTAssertTrue(state.complete(request, results: [.film]))
        XCTAssertEqual(state.snapshot.results, [.film])
        XCTAssertTrue(state.snapshot.submitted)
    }

    func testRetryRejectsEarlierRequestForTheSameKeyAndResetsItsPosition() throws {
        let state = SearchSessionState()
        let key = key("Lotus")
        let first = try XCTUnwrap(state.begin(key))
        state.rememberPosition(SearchListPosition(offset: 700, anchor: .pool), for: key)
        let second = try XCTUnwrap(state.begin(key))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(state.snapshot.position, SearchListPosition())
        XCTAssertFalse(state.complete(first, results: [.pool]))
        XCTAssertFalse(state.fail(first, message: "Stale failure"))
        XCTAssertTrue(state.fail(second, message: "Current failure"))
        state.cancelRequest()
        state.activate(key)
        XCTAssertEqual(state.snapshot.error, "Current failure")
        XCTAssertTrue(state.snapshot.submitted)
        XCTAssertFalse(state.searching)

        let retry = try XCTUnwrap(state.begin(key))
        XCTAssertNil(state.snapshot.error)
        XCTAssertTrue(state.complete(retry, results: [.jane]))
        XCTAssertEqual(state.snapshot.results, [.jane])
    }

    func testClosingAnUnfinishedSearchAllowsResubmissionWithoutFalseEmptyState() throws {
        let state = SearchSessionState()
        let key = key("Joe Hisaishi")
        let request = try XCTUnwrap(state.begin(key))
        state.cancelRequest()
        state.activate(key)
        XCTAssertFalse(state.searching)
        XCTAssertFalse(state.snapshot.submitted)
        XCTAssertNil(state.snapshot.error)
        XCTAssertFalse(state.complete(request, results: [.pool]))
        let retry = try XCTUnwrap(state.begin(key))
        XCTAssertTrue(state.complete(retry, results: []))
        XCTAssertTrue(state.snapshot.submitted, "A completed empty search differs from an interrupted request")
    }

    func testPositionFromAnotherContextOrInvalidGeometryCannotPolluteCurrentList() throws {
        let state = SearchSessionState()
        let key = key("Lotus")
        let token = try XCTUnwrap(state.begin(key))
        XCTAssertTrue(state.complete(token, results: [.pool]))
        let saved = SearchListPosition(offset: 125, anchor: .pool)
        state.rememberPosition(saved, for: key)
        state.rememberPosition(SearchListPosition(offset: 800, anchor: .jane), for: self.key("Other"))
        state.rememberPosition(SearchListPosition(offset: .infinity, anchor: .jane), for: key)
        state.rememberPosition(SearchListPosition(offset: .nan, anchor: .jane), for: key)
        XCTAssertEqual(state.snapshot.position, saved)
        state.rememberPosition(SearchListPosition(offset: -20, anchor: .pool), for: key)
        XCTAssertEqual(state.snapshot.position.offset, 0)
    }

    private func key(_ query: String, kind: CatalogSearchKind = .song, country: String = "jp",
                     context: RecordingSearchContext? = nil) -> SearchSessionKey {
        SearchSessionKey(query: query, kind: kind, country: country, recordingContext: context)
    }

    private func context(sourceID: String) -> RecordingSearchContext {
        let source = Work(id: WorkID(rawValue: sourceID)!, title: "Lotus", creator: "平泽进",
                          kind: "音乐作品", art: "", detail: "", url: nil)
        return RecordingSearchContext(source: source, creators: [], release: nil, query: "Lotus", kind: .song)
    }
}
