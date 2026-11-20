import XCTest
@testable import Pianwai

final class WorkPresentationTests: XCTestCase {
    func testVerifiedRegionalDisplayNameDoesNotReplaceTheStoredIdentity() {
        let work = film()
        let context = verifiedContext()
        XCTAssertEqual(WorkPresentation.title(for: work, context: context), "偶然与想像")
        XCTAssertEqual(work.title, "偶然與想象之輪")
        XCTAssertEqual(work.id.rawValue, "wikidata:Q105481082")
        XCTAssertEqual(context.article?.title, "偶然與想像")
    }

    func testDifferentEntityAndMissingSourceCannotSupplyDisplayName() {
        var context = verifiedContext(qid: "Q100")
        XCTAssertEqual(WorkPresentation.title(for: film(), context: context), film().title)
        context = verifiedContext(); context.displayTitleSource = nil
        XCTAssertEqual(WorkPresentation.title(for: film(), context: context), film().title)
        context = verifiedContext(); context.displayTitle = "  "
        XCTAssertEqual(WorkPresentation.title(for: film(), context: context), film().title)
    }

    func testAppleRecordingsAndCuratedNamesKeepTheirOwnTitles() {
        for id in ["apple:song:1234", "editorial:film"] {
            let work = Work(id: WorkID(rawValue: id)!, title: "Original edition title", creator: "", kind: "歌曲", art: "", detail: "Live", url: nil, knowledgeID: "Q105481082")
            XCTAssertEqual(WorkPresentation.title(for: work, context: verifiedContext()), work.title)
            XCTAssertEqual(WorkPresentation.detail(for: work), "Live")
        }
    }

    func testEnglishDatabaseGlossFallsBackToVerifiedTypeWithoutInventingTranslation() {
        XCTAssertEqual(WorkPresentation.detail(for: film()), "电影")
        let chinese = Work(id: film().id, title: "Title", creator: "", kind: "电影", art: "", detail: "2021年日本電影", url: nil)
        XCTAssertEqual(WorkPresentation.detail(for: chinese), chinese.detail)
    }

    private func film() -> Work {
        Work(id: WorkID(rawValue: "wikidata:Q105481082")!, title: "偶然與想象之輪", creator: "", kind: "电影", art: "", detail: "2021 film directed by Ryūsuke Hamaguchi", url: nil, knowledgeID: "Q105481082")
    }

    private func verifiedContext(qid: String = "Q105481082") -> WorkContext {
        var context = WorkContext(qid: qid)
        context.article = WikiArticleIdentity(qid: qid, title: "偶然與想像", language: "zh", pageID: 7606247, revision: 100)
        context.displayTitle = "偶然与想像"
        context.displayTitleSource = Source(title: "维基百科 · 偶然與想像", detail: "中文显示标题", url: "https://zh.wikipedia.org/w/index.php?oldid=100&variant=zh-cn")
        return context
    }
}
