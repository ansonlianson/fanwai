import XCTest
@testable import Pianwai

final class WorkLinksTests: XCTestCase {
    private func work(kind: String = "歌曲", url: String? = nil, catalogID: String? = nil, knowledgeID: String? = nil) -> Work {
        Work(id: WorkID(rawValue: "test:link")!, title: "Example", creator: "", kind: kind,
             art: "", detail: "", url: url, catalogID: catalogID, knowledgeID: knowledgeID)
    }

    func testKnowledgeSongDoesNotAdvertiseAppleMusicOrPlayback() {
        let song = work(url: "https://www.wikidata.org/wiki/Q123")
        XCTAssertEqual(song.externalLinkTitle, "作品来源")
        XCTAssertFalse(song.hasCatalogRecording)
    }

    func testMusicDestinationPreservesExactTrackAndRejectsWrongEntity() {
        let original = "https://itunes.apple.com/jp/album/example/id123?i=456&app=itunes&uo=4"
        let song = work(url: original, catalogID: "456")
        XCTAssertEqual(song.appleMusicURL?.absoluteString, "https://music.apple.com/jp/album/example/123?i=456")
        XCTAssertEqual(song.url, original)
        XCTAssertNil(song.iTunesStoreURL)
        XCTAssertNil(work(url: original, catalogID: "789").appleMusicURL, "A mismatched ID must not play a different recording")
        XCTAssertNil(work(kind: "专辑", url: original).appleMusicURL)
        XCTAssertNil(work(url: "https://music.apple.com/jp").appleMusicURL)
        XCTAssertNil(work(url: "https://music.apple.com/jp/artist/example/123").appleMusicURL)
        XCTAssertNil(work(url: "https://music.apple.com@evil.example/jp/song/456").appleMusicURL)
        XCTAssertEqual(work(kind: "专辑", url: "https://music.apple.com/jp/album/example/123?app=itunes").appleMusicURL?.absoluteString,
                       "https://music.apple.com/jp/album/example/123")
        XCTAssertNotNil(work(kind: "创作者", url: "https://music.apple.com/jp/artist/example/123").appleMusicURL)
    }

    func testDestinationLabelUsesExactProviderInsteadOfWorkKind() {
        XCTAssertEqual(work(kind: "创作者", url: "https://music.apple.com/us/artist/example/123").externalLinkTitle, "在 Apple Music 中查看")
        XCTAssertEqual(work(kind: "电影", url: "https://itunes.apple.com/us/movie/example/id123").externalLinkTitle, "在 iTunes 中查看")
        XCTAssertEqual(work(kind: "书籍", url: "https://books.apple.com/us/book/example/id123").externalLinkTitle, "在 Apple Books 中查看")
        for raw in ["https://music.apple.com.example.org/us/song/123", "https://music.apple.com@evil.example/us/song/123", "file:///music.apple.com/us/song/123"] {
            XCTAssertEqual(work(url: raw).externalLinkTitle, "作品来源")
            XCTAssertFalse(work(url: raw).hasCatalogRecording)
        }
    }

    func testCatalogIdentifierMustBeASongAndValidDecimal() {
        XCTAssertEqual(work(catalogID: " 12345 ").catalogRecordingID, "12345")
        for value in ["", "0", "000", "i.12345", "-123", "１２３", "1.2", String(repeating: "1", count: 31)] {
            XCTAssertFalse(work(catalogID: value).hasCatalogRecording, value)
        }
        XCTAssertFalse(work(kind: "专辑", catalogID: "12345").hasCatalogRecording)
        XCTAssertFalse(work(kind: "创作者", catalogID: "12345").hasCatalogRecording)
    }

    func testSongURLAndSelectedAlbumTrackResolveRecording() {
        XCTAssertEqual(work(url: "https://music.apple.com/us/song/example/12345").catalogRecordingID, "12345")
        XCTAssertEqual(work(url: "https://itunes.apple.com/us/album/example/id123?i=456").catalogRecordingID, "456")
    }

    func testAlbumURLCannotPretendToBeASongRecording() {
        XCTAssertFalse(work(url: "https://music.apple.com/us/album/example/12345").hasCatalogRecording)
        XCTAssertFalse(work(url: "https://music.apple.com/us/album/example/12345?i=0").hasCatalogRecording)
    }

    func testInvalidStoredIdentifierCanFallBackToVerifiedSongURL() {
        XCTAssertEqual(work(url: "https://music.apple.com/us/song/12345", catalogID: "i.67890").catalogRecordingID, "12345")
    }

    func testMusicWorkCanFindRecordingWithoutAcquiringRecordingIdentity() {
        let single = work(kind: "音乐作品", url: "https://www.wikidata.org/wiki/Q108033774", knowledgeID: "Q108033774")
        XCTAssertTrue(single.canFindCatalogVersion)
        XCTAssertEqual(single.catalogVersionSearchKind, .song)
        XCTAssertEqual(single.catalogVersionSearchTitle, "查找录音")
        XCTAssertFalse(single.isSong)
        XCTAssertFalse(single.hasCatalogRecording)
        XCTAssertNil(single.catalogRecordingID)
        XCTAssertFalse(work(kind: "音乐作品", catalogID: "12345").hasCatalogRecording,
                       "A numeric ID alone cannot turn a musical work into a recording")
    }

    func testKnowledgeAlbumFindsReleasesWhileCatalogAlbumKeepsExistingActions() {
        let album = work(kind: "专辑", url: "https://www.wikidata.org/wiki/Q3894905", knowledgeID: "Q3894905")
        XCTAssertEqual(album.catalogVersionSearchKind, .album)
        XCTAssertEqual(album.catalogVersionSearchTitle, "查找发行")
        XCTAssertFalse(album.hasCatalogRecording)
        XCTAssertFalse(work(kind: "专辑", catalogID: "12345", knowledgeID: "Q3894905").canFindCatalogVersion)
        XCTAssertFalse(work(kind: "专辑", url: "https://music.apple.com/us/album/example/12345", knowledgeID: "Q3894905").canFindCatalogVersion)
        XCTAssertFalse(work(kind: "专辑", url: "https://music.apple.com/us/album/example/12345").canFindCatalogVersion)
    }

    func testRecordingLookupDoesNotBecomeAnActionForUnrelatedMedia() {
        for kind in ["电影", "书籍", "创作者", "作品", "演奏视频"] {
            XCTAssertNil(work(kind: kind, knowledgeID: "Q123").catalogVersionSearchKind, kind)
        }
        XCTAssertEqual(work(knowledgeID: "Q123").catalogVersionSearchKind, .song)
        XCTAssertNil(work(catalogID: "12345", knowledgeID: "Q123").catalogVersionSearchKind)
    }
}
