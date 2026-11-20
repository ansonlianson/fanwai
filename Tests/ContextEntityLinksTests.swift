import XCTest
@testable import Pianwai

final class ContextEntityLinksTests: XCTestCase {
    func testFilmTitleCannotLinkToItsSameNamedNovelWhileAuthorStillLinks() {
        let film = work("film", title: "挪威的森林", kind: "电影")
        let novel = work("novel", title: "挪威的森林", kind: "书籍")
        let author = work("author", title: "村上春树", kind: "创作者")

        let links = ContextEntityLinks.make(current: film, neighbors: [novel, author])

        XCTAssertNil(links["挪威的森林"], "A film's opening self-reference must not open the novel")
        XCTAssertEqual(links["村上春树"], author.id)
        XCTAssertEqual(film.id.rawValue, "test:film")
        XCTAssertEqual(novel.id.rawValue, "test:novel")
        XCTAssertNotEqual(film.id, novel.id)
        XCTAssertEqual(novel.title, "挪威的森林")
    }

    func testNormalizedCurrentNameIsExcludedAcrossWidthCaseAccentsAndSpacing() {
        let current = work("film", title: "Café Society", kind: "电影")
        let neighbor = work("recording", title: "  ＣＡＦＥ\u{3000}ＳＯＣＩＥＴＹ  ", kind: "歌曲")
        let spaced = work("book", title: "cafe\n  society", kind: "书籍")

        for candidate in [neighbor, spaced] {
            XCTAssertTrue(ContextEntityLinks.make(current: current, neighbors: [candidate]).isEmpty)
        }
    }

    func testTwoDifferentNeighborsWithTheSameNameAreNotLinked() {
        let current = work("film", title: "Another film", kind: "电影")
        let author = work("author", title: "Alex Kim", kind: "创作者")
        let performer = work("performer", title: "Alex Kim", kind: "创作者")
        let director = work("director", title: "陈英雄", kind: "创作者")

        let links = ContextEntityLinks.make(current: current, neighbors: [author, performer, director])

        XCTAssertNil(links["Alex Kim"])
        XCTAssertEqual(links["陈英雄"], director.id)
    }

    func testNormalizedNameCollisionBetweenDifferentNeighborsIsAlsoAmbiguous() {
        let current = work("film", title: "Another film", kind: "电影")
        let first = work("first", title: "Alex Kim", kind: "创作者")
        let second = work("second", title: "ＡＬＥＸ\u{3000}ＫＩＭ", kind: "创作者")

        XCTAssertTrue(ContextEntityLinks.make(current: current, neighbors: [first, second]).isEmpty)
    }

    func testRepeatedEdgesToTheSameAuthorPreserveOneUnchangedIdentity() {
        let current = work("film", title: "Another film", kind: "电影")
        let author = work("author", title: "村上春树", kind: "创作者")

        let links = ContextEntityLinks.make(current: current, neighbors: [author, author])

        XCTAssertEqual(links, ["村上春树": author.id])
        XCTAssertEqual(author.id.rawValue, "test:author")
        XCTAssertEqual(author.title, "村上春树")
    }

    func testCurrentEntityAndEmptyNamesDoNotBecomeInlineLinks() {
        let current = work("film", title: "Another film", kind: "电影")
        let empty = work("unknown", title: " \n ", kind: "作品")

        XCTAssertTrue(ContextEntityLinks.make(current: current, neighbors: [current, empty]).isEmpty)
    }

    private func work(_ id: String, title: String, kind: String) -> Work {
        Work(id: WorkID(rawValue: "test:\(id)")!, title: title, creator: "", kind: kind,
             art: "", detail: "", url: nil)
    }
}
