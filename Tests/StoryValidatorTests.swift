import XCTest
@testable import Pianwai

final class StoryValidatorTests: XCTestCase {
    private let validator = StoryValidator()
    // Independently transcribed from SPEC §5.4, including spaces and punctuation.
    static let examples: [(String, String, String, String)] = [
        ("pool", "两年前，它是先导片没用上的 B 方案", "2023 年做《蕾塞篇》先导 PV 时，牛尾宪辅准备的 B 方案就是这首，私下叫它「我们的歌」。后来它被放进电次和蕾塞在泳池的那场戏。", "https://realsound.jp/2025/10/post-2167153_2.html"),
        ("pool", "说好拆成几段，最后还是一整首", "和导演商量时，原计划是把它切成几段短曲分开用。做到最后，它还是作为一整首组曲留在了电影里。", "https://realsound.jp/2025/10/post-2167153_2.html"),
        ("jane", "写到一半，米津玄师觉得只能请宇多田光来唱", "开始写时他没想好请谁唱。歌声放进来的那一刻，他说自己倒吸了一口气。", "https://www.thefirsttimes.jp/news/0000668201/"),
        ("actor", "写《Actor》时，几田莉拉想到的是她妈妈", "她说妈妈一直努力演好「母亲」这个角色。她由此觉得，扮演也可以是出于爱。", "https://lilasikuta.jp/laugh/"),
        ("utada", "EVA 四部新剧场版的主题曲，都是她唱的", "从 2007 年的《Beautiful World》到 2021 年的《One Last Kiss》，十四年里庵野秀明的四部新剧场版一直用她的歌收尾。", "https://www.evangelion.jp/news/shin_themesong/"),
        ("olkmv", "《终》上映当晚，庵野秀明亲自导演的 MV 首播", "20 天播放量破 2000 万，是宇多田光所有 MV 里最快的一支。", "https://natalie.mu/music/news/419206")
    ]
    static let rejectedDrafts = [
        "《in the pool》本来要拆成几段，牛尾宪辅却把它写成了一首完整组曲。",
        "米津玄师与宇多田光的世纪合作，两种截然不同的声线交织出蕾塞篇最动人的余韵。",
        "几田莉拉在《Actor》中探讨了每个人在日常生活中扮演的角色，以及角色背后对重要之人的牵挂。"
    ]

    func testSixUnmodifiedSpecExamplesPassAndThreeAIDraftTitlesFail() throws {
        for (index, row) in Self.examples.enumerated() {
            let story = try XCTUnwrap(SeedNowContent.stories(for: row.0).first { $0.title == row.1 })
            XCTAssertEqual(story.body, row.2); XCTAssertEqual(story.source.url, row.3)
            let result = validator.validate(story, context: .preset(row.0))
            XCTAssertTrue(result.isValid, "\(story.id): \(result.issues)")
            print("BRIDGE7_CASE \(index + 1) \(story.id) title=\(StoryValidator.visualWidth(story.title)) body=\(StoryValidator.visualWidth(story.body)) sentences=\(StoryValidator.sentences(story.body).count) PASS")
        }
        for (index, title) in Self.rejectedDrafts.enumerated() {
            let story = sample(title: title)
            let result = validator.validate(story, context: .preset("pool"))
            XCTAssertTrue(result.issues.contains { $0.rule == .titleWidth })
            if index == 1 { XCTAssertTrue(result.issues.contains { $0.detail == "交织" }) }
            print("BRIDGE7_CASE \(index + 7) title=\(StoryValidator.visualWidth(title)) REJECT \(result.issues)")
        }
    }

    func testEveryBlockedExpressionAndConcreteNounRule() {
        let words = ["背后的故事", "不为人知", "娓娓道来", "交织", "诠释", "承载", "灵魂", "宛如", "仿佛", "值得一提的是", "令人动容"]
        for word in words {
            XCTAssertTrue(validator.validate(sample(body: "牛尾宪辅说\(word)。"), context: .preset("pool")).issues.contains { $0.rule == .blockedExpression && $0.detail == word }, word)
        }
        for (text, hit) in [("不仅是配乐，更是主角", "不仅……更是"), ("一场从东京到京都的旅程", "一场……的旅程"), ("《Actor》 的创作背景", "XX 的创作背景式标题")] {
            XCTAssertTrue(validator.validate(sample(title: text), context: .preset("pool")).issues.contains { $0.detail == hit })
        }
        let anonymous = StoryContext(entityID: "pool", entityName: "")
        XCTAssertTrue(validator.validate(sample(title: "最后还是留下了", body: "他写好了。"), context: anonymous).issues.contains { $0.rule == .concreteNoun })
        // Same literal text passes when its attached entity supplies the name.
        XCTAssertTrue(validator.validate(sample(title: "最后还是留下了", body: "他写好了。"), context: .preset("pool")).isValid)
        for text in ["《Actor》", "2025 年", "「我们的歌」"] {
            XCTAssertTrue(validator.validate(sample(title: text), context: anonymous).isValid)
        }
        XCTAssertTrue(validator.validate(sample(body: "先导片不仅有配乐。后来更是改用了另一首。"), context: .preset("pool")).isValid, "Construction matching must not cross sentences")
    }

    func testVisualWidthSentenceLimitsAndSourceRequirements() {
        XCTAssertEqual(StoryValidator.visualWidth("《Beautiful World》"), 10)
        XCTAssertEqual(StoryValidator.visualWidth("A B 2023，ABC"), 7)
        XCTAssertEqual(StoryValidator.visualWidth("ＡＢ１２"), 4)
        XCTAssertTrue(validator.validate(sample(title: String(repeating: "字", count: 24), body: String(repeating: "字", count: 90)), context: .preset("pool")).isValid)
        let tooLong = validator.validate(sample(title: String(repeating: "字", count: 25), body: String(repeating: "字", count: 91)), context: .preset("pool"))
        XCTAssertEqual(Set(tooLong.issues.map(\.rule)), [.titleWidth, .bodyWidth])
        XCTAssertTrue(validator.validate(sample(body: "第一句。第二句！第三句？第四句"), context: .preset("pool")).issues.contains { $0.rule == .sentenceCount })
        XCTAssertEqual(StoryValidator.sentences("他说「留下它。」").count, 1)
        let missing = Story(id: "missing", entityID: "pool", title: "留下它", body: "", source: Source(title: "", url: ""))
        XCTAssertEqual(Set(validator.validate(missing, context: .preset("pool")).issues.map(\.rule)), [.source, .sourceURL])
        XCTAssertTrue(validator.validate(sample(source: Source(title: "访谈", url: "relative/path")), context: .preset("pool")).issues.contains { $0.rule == .sourceURL })
        let suite = SeedNowContent.stories(for: "pool")[1]
        XCTAssertLessThan(validator.titleSpecificity(suite, context: .preset("pool")), 2)
        XCTAssertTrue(validator.validate(suite, context: .preset("pool")).isValid)
    }

    func testNewMetaphorAndReviewExpressionsAreRejected() {
        let cases = [
            ("牛尾宪辅的配乐像潮水般涌来。", "像……般"),
            ("这首曲子完美呼应了结尾。", "完美呼应"),
            ("这个安排极具巧思。", "极具巧思"),
            ("恰恰是这一刻最让人难忘。", "恰恰是……最……")
        ]
        for (body, expression) in cases {
            XCTAssertTrue(validator.validate(sample(body: body), context: .preset("pool")).issues.contains {
                $0.rule == .blockedExpression && $0.detail == expression
            }, expression)
        }
        XCTAssertTrue(validator.validate(sample(body: "他说不像。一般只录两遍。"), context: .preset("pool")).isValid)
        XCTAssertTrue(validator.validate(sample(body: "他说恰恰是这首。最后仍然保留。"), context: .preset("pool")).isValid)
    }

    func testUnifiedStoryRoundTripsAndOldCatalogShapeStillDecodes() throws {
        let original = SeedNowContent.stories(for: "pool")[0]
        XCTAssertEqual(try JSONDecoder().decode(Story.self, from: JSONEncoder().encode(original)), original)
        let legacy = #"{"id":"old","workID":"pool","title":"留下它","body":"2023 年。","entityLinks":{"电影":"film"},"source":{"title":"访谈","detail":"原位置","url":"https://example.com/interview"}}"#
        let decoded = try JSONDecoder().decode(Story.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.entityID, "pool"); XCTAssertEqual(decoded.relatedEntityIDs, ["film"])
        XCTAssertEqual(decoded.source.detail, "原位置"); XCTAssertNil(decoded.source.publishedAt)
    }

    private func sample(title: String = "牛尾宪辅留下了这首曲子", body: String = "", source: Source = .interview) -> Story {
        Story(id: "sample", entityID: "pool", title: title, body: body, source: source)
    }
}
