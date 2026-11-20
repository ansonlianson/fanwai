import XCTest
@testable import Pianwai
final class SongTitlePresentationTests: XCTestCase {
    func testLiveLongVersion() {
        let value = SongTitlePresentation("もう少しだけ (YOASOBI 5th ANNIVERSARY DOME LIVE 2024 “超現実”)")
        XCTAssertEqual(value.title, "もう少しだけ")
        XCTAssertEqual(value.version, "YOASOBI 5th ANNIVERSARY DOME LIVE 2024 “超現実”")
        XCTAssertEqual(value.identity(creator: "YOASOBI"), "YOASOBI 5th ANNIVERSARY DOME LIVE 2024 “超現実” · YOASOBI")
    }
    func testTVSizeAndDashRemix() {
        XCTAssertEqual(SongTitlePresentation("xxx (TV size)").title, "xxx")
        XCTAssertEqual(SongTitlePresentation("xxx (TV size)").version, "TV size")
        XCTAssertEqual(SongTitlePresentation("xxx - Remix").version, "Remix")
        XCTAssertEqual(SongTitlePresentation("xxx（TV size）").version, "TV size")
    }
    func testVersionAlbumIsNotRepeated() {
        let value = SongTitlePresentation("xxx (Live in Tokyo)")
        XCTAssertEqual(value.identity(creator: "Artist", album: "Live in Tokyo"), "Live in Tokyo · Artist")
        XCTAssertEqual(value.identity(creator: "Artist", album: "Another album"), "Live in Tokyo · Artist · Another album")
    }
    func testNonVersionParenthesesAndAlbumsStayIntact() {
        for title in ["Love (a story)", "Music (for a film)", "Song (feat. Artist)", "冬（作品名）", "Song - The Story", "Song (Original)"] {
            XCTAssertEqual(SongTitlePresentation(title).title, title)
            XCTAssertNil(SongTitlePresentation(title).version)
        }
        XCTAssertNil(SongTitlePresentation("Live (Remix)", isSong: false).version)
    }
    func testLanguageVersionAndNestedLiveVenue() {
        XCTAssertEqual(SongTitlePresentation("Diver (Korean ver.)").identity(creator: "sis"), "Korean ver. · sis")
        XCTAssertEqual(SongTitlePresentation("Song (Live at Arena (Tokyo))").title, "Song")
    }
}
