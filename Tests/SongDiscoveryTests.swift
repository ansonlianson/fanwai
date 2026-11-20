import XCTest
@testable import Pianwai

@MainActor final class SongDiscoveryTests: XCTestCase {
    private let article = WikiArticleIdentity(qid: "Q96711898", title: "幾田莉拉", language: "zh", pageID: 7678817, revision: 94635036)

    func testRealArtistTableFindsActorAnimeWithoutBorrowingAnotherSongsLinks() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "song-discovery-ikuta-zh", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parsed = try XCTUnwrap(payload["parse"] as? [String: Any])
        let html = try XCTUnwrap(parsed["text"] as? String)
        let results = try SongDiscoveryService.candidates(html: html, title: "Actor", article: article)
        XCTAssertEqual(results.map(\.reference.title), ["SPY×FAMILY間諜家家酒 (動畫)"])
        XCTAssertTrue(results[0].source.detail.contains("Actor"))
        XCTAssertEqual(results[0].source.url, "https://zh.wikipedia.org/w/index.php?oldid=94635036")
        XCTAssertTrue(try SongDiscoveryService.candidates(html: html, title: "Actor (Live)", article: article).isEmpty)
        XCTAssertTrue(try SongDiscoveryService.candidates(html: html, title: "Act", article: article).isEmpty)
        let other = try SongDiscoveryService.candidates(html: html, title: "百花繚乱", article: article)
        XCTAssertEqual(other.map(\.reference.title), ["藥師少女的獨語"])
    }

    func testUnrelatedSectionAmbiguousCellAndMergedRowsCannotCreateAConnection() throws {
        let table = "<table class='wikitable'><tr><th>作品名稱</th><th>歌曲名稱</th></tr><tr><td><a href='/wiki/Film'>Film</a></td><td>Actor</td></tr></table>"
        XCTAssertTrue(try SongDiscoveryService.candidates(html: "<h3>唱片列表</h3>" + table, title: "Actor", article: article).isEmpty)
        let valid = "<h3>動畫主題曲</h3>" + table
        XCTAssertEqual(try SongDiscoveryService.candidates(html: valid, title: "ＡＣＴＯＲ", article: article).count, 1)
        let ambiguous = valid.replacingOccurrences(of: "</a>", with: "</a><a href='/wiki/Other'>Other</a>")
        XCTAssertTrue(try SongDiscoveryService.candidates(html: ambiguous, title: "Actor", article: article).isEmpty)
        let merged = valid.replacingOccurrences(of: "<td>", with: "<td rowspan='2'>")
        XCTAssertTrue(try SongDiscoveryService.candidates(html: merged, title: "Actor", article: article).isEmpty)
        let external = valid.replacingOccurrences(of: "/wiki/Film", with: "https://unrelated.example/wiki/Film")
        XCTAssertTrue(try SongDiscoveryService.candidates(html: external, title: "Actor", article: article).isEmpty)
    }

    func testReviewedContextRequiresExactRecordingAndArtistAndKeepsSeparateRecordings() throws {
        let pack = try editorial()
        let first = song("1839387171"), second = song("1857886409")
        let a = try XCTUnwrap(pack.snapshot(for: first, artistIDs: ["1489581870"]))
        let b = try XCTUnwrap(pack.snapshot(for: second, artistIDs: ["1489581870"]))
        XCTAssertEqual(a.relations.count, 2)
        XCTAssertEqual(a.stories.count, 1)
        XCTAssertEqual(a.stories.first?.workID, first.id)
        XCTAssertEqual(b.stories.first?.workID, second.id)
        XCTAssertNotEqual(a.stories.first?.id, b.stories.first?.id)
        XCTAssertNil(pack.snapshot(for: song("999999"), artistIDs: ["1489581870"]))
        XCTAssertNil(pack.snapshot(for: first, artistIDs: ["999999"]))
        XCTAssertNil(pack.snapshot(for: first, artistIDs: []))
        XCTAssertTrue(a.stories.allSatisfy { $0.body.count < 160 })
    }

    func testProviderFailureKeepsReviewedStoryAndAllowsRetryWithoutDuplicatingIt() async throws {
        let service = SongDiscoveryStub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(cacheURL: directory.appendingPathComponent("catalog.json"), songDiscoveryService: service)
        let recording = song("1839387171")
        try store.merge(.init(works: [artist(), recording], relations: []))
        await store.discoverSong(recording.id)
        XCTAssertNotNil(store.songDiscoveryErrors[recording.id])
        XCTAssertEqual(store.stories.filter { $0.workID == recording.id }.count, 1)
        XCTAssertEqual(store.edges.filter { $0.from == recording.id }.count, 2)
        XCTAssertNil(store.work(recording.id).knowledgeID, "Never merge a recording with its artist or theme work")
        await store.discoverSong(recording.id, retry: true)
        XCTAssertNil(store.songDiscoveryErrors[recording.id])
        XCTAssertFalse(store.songDiscoveryLoading.contains(recording.id))
        XCTAssertEqual(store.stories.filter { $0.workID == recording.id }.count, 1)
        XCTAssertEqual(store.edges.filter { $0.from == recording.id }.count, 2)
        await store.flushPendingWrites()
        let restored = CatalogStore(cacheURL: directory.appendingPathComponent("catalog.json"), songDiscoveryService: service)
        XCTAssertEqual(restored.stories.filter { $0.workID == recording.id }.count, 1)
        XCTAssertEqual(restored.work(recording.id).catalogRecordingID, "1839387171")
        let titles = await service.requestedTitles
        XCTAssertEqual(titles, ["Actor", "Actor"])
    }

    private func editorial() throws -> SongEditorialCatalog {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "song-editorial", withExtension: "json"))
        return try JSONDecoder().decode(SongEditorialCatalog.self, from: Data(contentsOf: url))
    }
    private func artist() -> Work {
        Work(id: WorkID(rawValue: "apple:artist:1489581870")!, title: "幾田りら", creator: "", kind: "创作者", art: "", detail: "", url: "https://music.apple.com/jp/artist/1489581870", catalogID: "1489581870")
    }
    private func song(_ number: String) -> Work {
        Work(id: WorkID(rawValue: "apple:song:" + number)!, title: "Actor", creator: "幾田りら", kind: "歌曲", art: "", detail: "", url: "https://music.apple.com/jp/song/" + number, linkedCreatorIDs: [artist().id], catalogID: number)
    }
}

private actor SongDiscoveryStub: SongDiscoveryFetching {
    private(set) var requestedTitles: [String] = []
    func discover(title: String, artistIDs: [String]) async throws -> SongDiscoveryResult {
        requestedTitles.append(title)
        if requestedTitles.count == 1 { throw URLError(.cancelled) }
        return SongDiscoveryResult()
    }
}
