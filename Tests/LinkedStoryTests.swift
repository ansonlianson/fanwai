import XCTest
@testable import Pianwai

final class LinkedStoryTests: XCTestCase {
    func testRepeatedOverlappingNamesAndUnboundNamesNeverGuessIdentity() throws {
        let story = Story(id: "sample", entityID: "song", title: "《Actor》与 actors",
            body: "米津玄师邀宇多田光。宇多田光与未知创作者。Lotus 与 LOTUS-2。",
            source: .init(title: "访谈", url: "https://example.org/interview"),
            entityLinks: ["Actor": WorkID(rawValue: "actor")!, "宇多田光": .utada,
                          "米津玄师": .yonezu, "Lotus": WorkID(rawValue: "lotus")!],
            mentions: ["未知创作者"])
        let links = StoryTextLinks(story: story)
        XCTAssertEqual(links.spans(in: story.title).map(\.name), ["Actor"])
        // 0.5.24: a Latin-script name the writer did not list (LOTUS-2) can be opened too, as an
        // unbound name of its own; it is never taken for Lotus.
        XCTAssertEqual(links.spans(in: story.body).map(\.name), ["米津玄师", "宇多田光", "宇多田光", "未知创作者", "Lotus", "LOTUS-2"])
        XCTAssertNil(links.targets.first { $0.name == "LOTUS-2" }?.entityID)
        let unknown = try XCTUnwrap(links.targets.first { $0.name == "未知创作者" })
        XCTAssertNil(unknown.entityID); XCTAssertEqual(links.target(for: unknown.url), unknown)
        XCTAssertNil(links.target(for: URL(string: "pianwai-story://name?text=伪造名称")!))
        let ambiguous = StoryNameTable(nodes: [.init(id: "a", name: "Actor", kind: .song), .init(id: "b", name: "Actor", kind: .work)])
        XCTAssertTrue(StoryTextLinks.verifiedLinks(title: "Actor", body: "", names: ambiguous).isEmpty)
        let roundtrip = try JSONDecoder().decode(Story.self, from: JSONEncoder().encode(story))
        XCTAssertEqual(roundtrip, story)
    }

    @MainActor func testReviewedStoriesAreExactAndExcludeCreditOnlyPresets() throws {
        let catalog = CatalogStore(cacheURL: nil)
        let pool = try XCTUnwrap(SeedNowContent.entity("pool"))
        let story = try XCTUnwrap(NowStoryContent.stories(for: pool, catalog: catalog).first)
        XCTAssertTrue(story.title.isEmpty)
        XCTAssertTrue(story.body.contains("in the pool"))
        XCTAssertEqual(story.entityLinks["蕾塞篇"], .film)
        XCTAssertEqual(story.entityLinks["牛尾宪辅"], .ushio)
        let other = SeedGraph.Entity(id: "apple:song:999999", kind: .song, title: pool.title,
            subtitle: pool.subtitle, artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: [])
        XCTAssertTrue(NowStoryContent.stories(for: other, catalog: catalog).isEmpty, "Same title cannot reuse another recording's story")
        for id in ["film", "ushio", "yonezu", "utada", "olkmv"] {
            XCTAssertTrue(NowStoryContent.stories(for: try XCTUnwrap(SeedNowContent.entity(id)), catalog: catalog).isEmpty)
        }
        let narrative = try XCTUnwrap(catalog.stories.first { $0.id == "editorial:story-kon-lotus-reference" })
        XCTAssertTrue(StoryValidator().validate(narrative, context: .init(entityID: narrative.entityID, entityName: "平泽进"), reviewedLongForm: true).isValid)
    }

    func testReferencePageRetainsPronounParagraphAfterExactAnchorAndSkipsEmptyAdArticle() throws {
        let html = """
        <html><head><meta charset="Shift_JIS"><title>JANE DOE 制作インタビュー</title></head><body>
        <article class="advertisement"></article><article><h1>JANE DOE</h1>
        <p>JANE DOE の制作について。</p><p>この曲は最初、別の形を考えていました。</p></article>
        <footer><p>別の記事。</p></footer></body></html>
        """
        let data = try XCTUnwrap(html.data(using: .shiftJIS))
        let decoded = try XCTUnwrap(StorySourceDocument.decode(data))
        let url = URL(string: "https://example.org/interview")!
        let doc = try StorySourceDocument.parse(html: decoded, url: url, names: ["JANE DOE"], neighbors: [], pageAnchored: true)
        XCTAssertEqual(doc.paragraphs.count, 2)
        XCTAssertTrue(doc.paragraphs[1].text.hasPrefix("この曲"))
        let unrelated = try StorySourceDocument.parse(html: decoded, url: url, names: ["IRIS OUT"], neighbors: [], pageAnchored: true)
        XCTAssertTrue(unrelated.paragraphs.isEmpty)
        let index = try StorySourceDocument.parse(html: decoded, url: url, names: ["JANE DOE"], neighbors: [])
        XCTAssertEqual(index.paragraphs.count, 1, "Artist/index pages keep paragraph gating")
    }
}
