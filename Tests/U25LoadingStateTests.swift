import XCTest
@testable import Pianwai

@MainActor final class U25LoadingStateTests: XCTestCase {
    func testSavedEmptyResultCannotHideTheNextRunningLookup() async throws {
        let suite = "U25." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = WorkID(rawValue: "local:u25-cached")!
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [.init(id: id, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil)], relations: []))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog)
        let jobs = DiscoveryJobs(directory: nil)
        let research = LeadResearch(researchOperation: { _ in .init(leads: [], story: nil) },
            evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil,
            metadataRefinement: { leads, _ in leads }, jobs: jobs)
        let subject = LeadSubject(id: id.rawValue, kind: .song, title: "Song", creator: "Artist", album: "")
        await research.load(subject, library: library)
        XCTAssertEqual(research.state(subject.id), .empty)
        jobs.start(subject, userInitiated: true)
        XCTAssertEqual(research.state(subject.id), .loading)
        jobs.finish(subject.id, story: .notFound)
        XCTAssertEqual(research.state(subject.id), .empty)
    }

    func testRunningJobHasLoadingStateBeforeResultsArrive() {
        let jobs = DiscoveryJobs(directory: nil)
        let research = LeadResearch(researchOperation: { _ in .init(leads: [], story: nil) },
            evidenceCache: .init(directory: nil), diagnostics: .init(directory: nil), processedDirectory: nil, jobs: jobs)
        let subject = LeadSubject(id: "local:u25-active", kind: .song, title: "帰水空間", creator: "溝口肇", album: "Oasis")
        jobs.start(subject, userInitiated: false)
        XCTAssertEqual(research.state(subject.id), .loading)
        jobs.event(.received(0), id: subject.id)
        XCTAssertEqual(research.state(subject.id), .loading)
        jobs.fail(subject.id, reason: .network)
        XCTAssertEqual(research.state(subject.id), .failed)
        jobs.start(subject, userInitiated: true)
        XCTAssertEqual(research.state(subject.id), .loading)
        jobs.interrupt(subject.id, stopped: true)
        XCTAssertEqual(research.state(subject.id), .empty)
    }
}
