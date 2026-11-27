import XCTest
import UIKit
@testable import Pianwai

@MainActor final class U21FeedbackTests: XCTestCase {
    private let chinese = "负责中森明菜宣传工作的富岡信夫回忆，专辑先由「少女Ａ」带动销量，宣传工作当时主要围绕单曲展开。他反对接着把「キャンセル！」作为第三张单曲，却认为将它放在序曲之后很成功，并支持选择「セカンド・ラブ」，以展现明菜的唱功和她对作品概念的重视。"
    private func savedReport() throws -> LeadReport {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/U21/japanese-album-report.json")
        return try JSONDecoder().decode(LeadReport.self, from: Data(contentsOf: file))
    }

    func testChineseNarrationAllowsJapaneseNamesButRejectsForeignParagraphs() throws {
        XCTAssertTrue(StoryNarrationLanguage.isChinese(chinese))
        XCTAssertTrue(StoryNarrationLanguage.isChinese("竹内まりや在录音时先尝试了另一种唱法，再和乐队一起调整节奏。制作人希望保留最初的情绪，因此没有重录已经完成的段落。"), "A missing optional mention list must not reject a Japanese person's name in Chinese narration")
        let bad = try XCTUnwrap(savedReport().story)
        XCTAssertFalse(StoryNarrationLanguage.isChinese(bad.text, names: bad.mentions ?? []))
        let correctedURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/U21/chinese-album-report.json")
        let corrected = try JSONDecoder().decode(LeadReport.self, from: Data(contentsOf: correctedURL))
        XCTAssertTrue(StoryNarrationLanguage.isChinese(try XCTUnwrap(corrected.story).text, names: corrected.story?.mentions ?? []))
        XCTAssertNotNil(LeadResearch.withChineseNarration(corrected).story)
        XCTAssertFalse(StoryNarrationLanguage.isChinese(chinese + "The producer chose a different single to show the singer's vocal range."))
        XCTAssertFalse(StoryNarrationLanguage.isChinese(chinese + "アルバムのイントロダクションに続く一曲目にしたのは大成功だったと語る。"))
        XCTAssertFalse(StoryNarrationLanguage.isChinese("이 앨범의 첫 번째 곡은 프로듀서가 직접 선택했으며 녹음 과정에서 다양한 악기를 사용했다."))
    }

    func testGroundingChecksBothSongAndWiderStoriesBeforeDroppingAnySentence() throws {
        let bad = try XCTUnwrap(savedReport().story)
        let topic = ResearchTopic(id: "apple:song:903280858", title: "(イントロダクション) [2022 Lacquer Master Sound]", creator: "中森明菜", album: "バリエーション〈変奏曲〉", layer: "recording")
        let quote = "富岡自身は「少女Ａ」の路線を引き継ぐシングルとしての「キャンセル！」には最初から大反対だった"
        let source = ResearchSource(id: "S1", url: bad.url, title: "バリエーション〈変奏曲〉", publisher: "イザ！", text: quote + bad.text, purposes: [.story])
        let packet = ResearchMaterialPacket(topic: topic, queries: [], sources: [source], fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 0, fetches: 0)
        func reply(_ body: String) throws -> String {
            let rows = body.components(separatedBy: "。").filter { !$0.isEmpty }.map { ["text": $0 + "。", "evidence": [["source_id": "S1", "quote": quote]]] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["story": ["subject": "album", "subject_name": "バリエーション〈変奏曲〉", "sentences": rows]]), as: UTF8.self)
        }
        for wider in [false, true] {
            XCTAssertNil(ResearchWriter.groundStory(try reply(bad.text), packet: packet, wider: wider))
            XCTAssertNotNil(ResearchWriter.groundStory(try reply(chinese), packet: packet, wider: wider))
        }
        let auditReply = String(decoding: try JSONSerialization.data(withJSONObject: ["subject_ref": "current", "sentences": [["text": bad.text, "source_id": "S1", "quote": quote]]]), as: UTF8.self)
        let audited = try ResearchStoryWriter.audit(auditReply, subjects: [.init(ref: "current", name: topic.title, layer: "recording")], sources: [source])
        XCTAssertEqual(audited.rejection, "notChinese")
        let raw = LeadResearchClient.Raw(leads: [], story: .init(text: bad.text, subject: "album", url: bad.url, source: bad.source))
        XCTAssertNil(LeadResearch.sourcedStory(raw, mentions: bad.mentions ?? []))
    }

    func testBadCachedStoryKeepsRelationsAndDiskWithoutCallingTheModel() async throws {
        let token = "U21." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: token))
        defer { defaults.removePersistentDomain(forName: token) }
        let settings = StoryModelSettings(defaults: defaults, keychain: StoryModelKeychain(service: token), http: .init { _ in throw URLError(.notConnectedToInternet) })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = LeadSubject(id: "apple:song:903280858", kind: .song, title: "(イントロダクション) [2022 Lacquer Master Sound]", creator: "中森明菜", album: "バリエーション〈変奏曲〉")
        let report = try savedReport()
        let file = directory.appendingPathComponent(settings.researchNamespace + "-" + DiscoveryCore.contractVersion + "-" + DiscoveryCore.processorVersion + "-" + subject.cacheKey + ".json")
        let original = try JSONEncoder().encode(report); try original.write(to: file)
        let library = Library(defaults: defaults, arguments: [], catalog: CatalogStore(cacheURL: nil))
        let research = LeadResearch(researchOperation: { _ in XCTFail("Opening an old foreign story must not spend another request"); throw URLError(.notConnectedToInternet) }, evidenceCache: .init(directory: nil), processedDirectory: directory, modelSettings: settings)
        await research.load(subject, library: library)
        await research.load(subject, library: library)
        XCTAssertNil(research.story(for: subject.id, library: library))
        XCTAssertEqual(research.leads(subject.id).map(\.id), report.leads.map(\.id))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(LeadResearch.withChineseNarration(report).relations, report.relations)
    }

    func testMasteringSuffixIsSearchDecorationAndDoesNotBecomeACover() {
        let title = "(イントロダクション) [2022 Lacquer Master Sound]"
        XCTAssertEqual(SongTitlePresentation(title).title, "(イントロダクション)")
        XCTAssertEqual(SongTitlePresentation(title).version, "2022 Lacquer Master Sound")
        XCTAssertEqual(RecordingVersion.searchTitle(title), "(イントロダクション)")
        XCTAssertTrue(DatabaseTitleKeys.keys(title).contains("(イントロダクション)"))
        XCTAssertEqual(ResearchMaterials.versionParts(title).origin, "")
        XCTAssertEqual(RecordingVersion.searchTitle("(イントロダクション)"), "(イントロダクション)")
        XCTAssertFalse(RecordingVersion.isDerivative(title))
    }

    func testOneCoverSurvivesSourceChangesButNeverLeaksIntoTheNextSong() async throws {
        let a = URL(string: "https://example.org/u21-a.jpg")!, b = URL(string: "https://example.org/u21-b.jpg")!
        let cache = ArtworkImageCache(directory: nil) { _ in XCTFail("An already shown cover needs no replacement download"); throw URLError(.notConnectedToInternet) }
        let first = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let second = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        cache.remember(first, for: a)
        let presentation = ArtworkPresentation(cache: cache)
        await presentation.load(a.absoluteString, for: "song-a")
        // Four layers, metadata arriving in stages, and an absent/failed alternative.
        for source in [b.absoluteString, nil, b.absoluteString] {
            for _ in 0..<4 { XCTAssertTrue(presentation.image(for: "song-a", source: source) === first) }
            await presentation.load(source, for: "song-a")
        }
        XCTAssertNil(presentation.image(for: "song-b", source: b.absoluteString))
        cache.remember(second, for: b)
        await presentation.load(b.absoluteString, for: "song-b")
        XCTAssertTrue(presentation.image(for: "song-b", source: b.absoluteString) === second)
    }

    func testSystemArtworkComesFirstAndMissingLocalFileCanUseItsVerifiedAlbum() throws {
        let album = Work(id: WorkID(rawValue: "local:u21-album")!, title: "Album", creator: "", kind: "专辑", art: "https://example.org/u21-album.jpg", detail: "", url: nil)
        let observed = ObservedArtwork.key("u21-recording")
        let song = Work(id: WorkID(rawValue: "local:u21-song")!, title: "Song", creator: "", kind: "歌曲", art: observed, detail: "", url: nil, linkedAlbumID: album.id)
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [album, song], relations: []))
        XCTAssertEqual(ArtworkLocation.displayValue(for: song, catalog: catalog), observed)
        XCTAssertEqual(ArtworkLocation.displayValue(for: song, catalog: catalog, excluding: [observed]), album.art)
        XCTAssertNil(ArtworkLocation.displayValue(for: song, catalog: catalog, excluding: [observed, album.art]))
    }

    func testLateOldDownloadCannotOverwriteNewSong() async throws {
        let a = URL(string: "https://example.org/u21-slow.jpg")!, b = URL(string: "https://example.org/u21-ready.jpg")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let started = expectation(description: "Old request started")
        let cache = ArtworkImageCache(directory: nil) { request in
            started.fulfill(); try await Task.sleep(for: .milliseconds(100))
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        cache.remember(image, for: b)
        let presentation = ArtworkPresentation(cache: cache)
        let old = Task { await presentation.load(a.absoluteString, for: "song-a") }
        await fulfillment(of: [started], timeout: 2)
        await presentation.load(b.absoluteString, for: "song-b")
        await old.value
        XCTAssertEqual(presentation.identity, "song-b")
        XCTAssertTrue(presentation.image(for: "song-b", source: b.absoluteString) === image)
        let cancelled = Task { await presentation.load(a.absoluteString, for: "song-a") }
        cancelled.cancel(); await cancelled.value
        XCTAssertEqual(presentation.identity, "song-b", "A cancelled old layer must not reset the current song before its first suspension")
    }
}
