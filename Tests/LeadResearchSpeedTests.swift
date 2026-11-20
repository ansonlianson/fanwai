import XCTest
@testable import Pianwai

@MainActor final class LeadResearchSpeedTests: XCTestCase {
    /// One real internal request, followed by the ordinary cover/ID resolution.
    /// Explicit opt-in only. No provider change or new credential is involved.
    func testOneRealResearchTiming() async throws {
        guard ProcessInfo.processInfo.environment["PIANWAI_P29_LIVE"] == "1" else {
            throw XCTSkip("Bounded live timing requires explicit opt-in")
        }
        let suite = "P29.speed."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogStore(cacheURL: nil)
        let id = WorkID(rawValue: "apple:song:1840081736")!
        try catalog.merge(CatalogSnapshot(works: [Work(id: id, title: "JANE DOE", creator: "米津玄師, 宇多田ヒカル", kind: "歌曲", art: "jane", detail: "", url: "https://music.apple.com/jp/song/1840081736", catalogID: "1840081736", storeCountry: "jp")], relations: []))
        let library = Library(defaults: defaults, catalog: catalog)
        let subject = LeadSubject(id: id.rawValue, kind: .song, title: "JANE DOE", creator: "米津玄師, 宇多田ヒカル", album: "")
        let research = LeadResearch()
        await research.load(subject, library: library, force: true)
        let report = try XCTUnwrap(research.reports[id.rawValue])
        let timing = try XCTUnwrap(report.timing)
        struct Measurement: Encodable {
            let song: String
            let totalSeconds: Double
            let timing: LeadTiming
            let leadCount: Int
            let hasStory: Bool
        }
        let value = Measurement(song: subject.title, totalSeconds: report.seconds, timing: timing,
            leadCount: report.leads.count, hasStory: report.story != nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "P29-real-timing"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["PIANWAI_P29_TIMING"] { try data.write(to: URL(fileURLWithPath: path)) }
        XCTAssertGreaterThan(report.leads.count, 0)
        XCTAssertGreaterThan(timing.researchSeconds, 0)
    }
}
