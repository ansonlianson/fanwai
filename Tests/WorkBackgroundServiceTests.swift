import XCTest
@testable import Pianwai

final class WorkBackgroundServiceTests: XCTestCase, @unchecked Sendable {
    func testRealPinnedMovieSectionProducesShortAttributedParagraphs() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try fixture("Q107107865-zh-sections")),
            .init(section: "4", data: try fixture("Q107107865-zh-section-4"))
        ]); defer { h.close() }
        let article = WikiArticleIdentity(qid: "Q107107865", title: "驾驶我的车", language: "zh", pageID: 7761498, revision: 94442484)
        let response = try await h.service.fetch(article: article)
        XCTAssertEqual(response.article, article)
        XCTAssertEqual(response.excerpts.count, 2)
        XCTAssertTrue(response.excerpts[0].body.contains("SAAB 900"), "Prefer the complete short production account over the truncated location timeline")
        XCTAssertTrue(response.excerpts[1].body.contains("三浦透子"))
        XCTAssertTrue(response.excerpts[1].body.contains("駕駛執照"))
        XCTAssertEqual(response.excerpts[1].references?.map(\.title), ["三浦透子", "偶然與想像"], "Use only actual anchors present in the source paragraph")
        XCTAssertEqual(response.excerpts[1].references?.map(\.label), ["三浦透子", "偶然與想像"])
        XCTAssertFalse(response.excerpts[1].references?.contains { $0.label == "濱口" } ?? true, "Do not infer a director link from an unlinked name")
        for excerpt in response.excerpts {
            XCTAssertEqual(excerpt.heading, "制作花絮")
            XCTAssertLessThanOrEqual(excerpt.body.count, 140)
            XCTAssertEqual(excerpt.body, excerpt.sourceParagraph, "Both short accounts must retain their complete source paragraphs")
            XCTAssertFalse(excerpt.body.contains("cite_note"))
            XCTAssertFalse(excerpt.body.contains("[1]"))
            XCTAssertTrue(excerpt.source.detail.contains("原始引文未独立核验"))
            let parts = try XCTUnwrap(URLComponents(string: excerpt.source.url))
            XCTAssertEqual(parts.fragment, "制作花絮")
            XCTAssertEqual(parts.queryItems?.first?.value, "94442484")
        }
        XCTAssertEqual(h.requests.count, 2)
        for request in h.requests {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "oldid" }?.value, "94442484")
            XCTAssertNil(items.first { $0.name == "page" || $0.name == "titles" || $0.name == "search" })
        }
    }

    func testRealMusicSectionDoesNotExposeIsolatedReferenceErrors() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try fixture("Q108033774-zh-sections")),
            .init(section: "2", data: try fixture("Q108033774-zh-section-2")),
            .init(section: "3", data: try fixture("Q108033774-zh-section-3")),
            .init(section: "8", data: try fixture("Q108033774-zh-section-8"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(article: .init(qid: "Q108033774", title: "One Last Kiss (歌曲)", language: "zh", pageID: 7600319, revision: 94012122))
        XCTAssertEqual(response.excerpts.count, 2)
        XCTAssertEqual(response.excerpts.map(\.heading), ["創作與製作", "背景與概念"])
        XCTAssertTrue(response.excerpts[0].body.contains("混音"), "Audible recording details take priority")
        XCTAssertTrue(response.excerpts[1].body.contains("遠端執導"), "The full pool can also select the later music-video production account")
        XCTAssertTrue(response.excerpts.allSatisfy { $0.body.count <= 140 && $0.sourceParagraph.hasPrefix($0.body) })
        XCTAssertFalse(response.excerpts.contains { $0.sourceParagraph.contains("引用错误") || $0.sourceParagraph.contains("Cite error") })
        XCTAssertTrue(response.excerpts.allSatisfy {
            URLComponents(string: $0.source.url)?.queryItems?.first?.value == "94012122"
        })
        XCTAssertEqual(h.requests.count, 4, "Read the three safe leaf sections, never release, reception, or credits")
    }

    func testSilentVoiceMusicAccountPrecedesTheEarlierAdaptationAnnouncement() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try fixture("Q23925035-zh-sections")),
            .init(section: "3", data: try fixture("Q23925035-zh-section-3")),
            .init(section: "4", data: try fixture("Q23925035-zh-section-4"))
        ]); defer { h.close() }
        let article = WikiArticleIdentity(qid: "Q23925035", title: "電影版 聲之形", language: "zh", pageID: 5625635, revision: 95124741)
        let response = try await h.service.fetch(article: article)
        let first = try XCTUnwrap(response.excerpts.first)
        XCTAssertEqual(response.excerpts.count, 2)
        XCTAssertEqual(first.heading, "音樂", "The previous section-order selection led with adaptation announcement dates")
        XCTAssertEqual(first.body, first.sourceParagraph)
        XCTAssertTrue(first.body.contains("我這一代"))
        XCTAssertTrue(first.body.contains("何許人合唱團"))
        XCTAssertEqual(first.references?.map(\.title), ["牛尾憲輔", "波麗佳音", "Aiko", "何許人合唱團", "My Generation (歌曲)"],
                       "Keep later source candidates so company filtering cannot consume the final navigation slots")
        XCTAssertEqual(URLComponents(string: first.source.url)?.queryItems?.first?.value, "95124741")
        XCTAssertEqual(h.requests.count, 3)
    }

    func testLizReadsTheMusicSectionAndKeepsTheCompleteSchoolRecordingSentence() async throws {
        var plans = [BackgroundPlan(section: nil, data: try fixture("Q59788987-en-sections"))]
        for index in 4...7 {
            plans.append(.init(section: String(index), data: try fixture("Q59788987-en-section-\(index)")))
        }
        let h = BackgroundHarness(plans); defer { h.close() }
        let article = WikiArticleIdentity(qid: "Q59788987", title: "Liz and the Blue Bird", language: "en", pageID: 60304198, revision: 1383036815)
        let response = try await h.service.fetch(article: article)
        let first = try XCTUnwrap(response.excerpts.first)
        let expected = "To record the soundtrack, Ushio and Yamada went to the real-life school the building in the film is based on, where Ushio recorded himself tapping and using the present objects in different ways, and later included those sounds in the soundtrack; he later remembered that Yamada \"couldn't stop laughing\" while he recorded."
        XCTAssertEqual(expected.count, 322)
        XCTAssertEqual(first.heading, "Music")
        XCTAssertEqual(first.body, expected, "A complete useful sentence must not disappear for exceeding the old limit by two characters")
        XCTAssertTrue(first.sourceParagraph.hasPrefix(expected))
        XCTAssertTrue(first.sourceParagraph.contains("at the very end of this film"), "Retain the full source for inspection")
        XCTAssertFalse(first.body.contains("at the very end"), "Do not extend the short account into the later ending discussion")
        XCTAssertEqual(URLComponents(string: first.source.url)?.fragment, "Music")
        XCTAssertEqual(response.excerpts.count, 2)
        XCTAssertEqual(h.requests.count, 5, "Two available Background paragraphs must not prevent reading the fourth safe candidate, Music")
        XCTAssertTrue(response.excerpts.allSatisfy { $0.sourceParagraph.hasPrefix($0.body) && $0.body.count <= 400 })
        let continuations = try XCTUnwrap(response.continuationCandidates)
        XCTAssertLessThanOrEqual(continuations.count, 4)
        XCTAssertTrue(Set(response.excerpts.map(\.id)).isDisjoint(with: continuations.map(\.id)))
        let band = try XCTUnwrap(continuations.first { $0.references?.contains { $0.title == "Homecomings (band)" } == true })
        XCTAssertEqual(band.body, "The band Homecomings provided the theme song for the film, \"Songbirds\", which is the second song heard during the end credits.")
        XCTAssertEqual(band.body.count, 126)
        XCTAssertTrue(band.id.hasSuffix(":focus:151:126"))
        XCTAssertTrue(band.sourceParagraph.contains(band.body))
        XCTAssertFalse(band.body.contains("Saito Shigeru"))
        let retained = try XCTUnwrap(response.retainedContinuationCandidates?.first {
            $0.references?.contains { $0.title == "Homecomings (band)" } == true
        })
        XCTAssertEqual(retained.body.count, 277)
        XCTAssertTrue(retained.body.hasPrefix("The crew also included Saito Shigeru"))
        XCTAssertTrue(retained.body.hasSuffix(band.body))
        XCTAssertEqual(retained.sourceParagraph, band.sourceParagraph)
        XCTAssertFalse(retained.id.contains(":focus:"))
        XCTAssertNotEqual(retained.id, band.id, "An already-read long excerpt must keep its original identity and words")
        XCTAssertEqual(band.references?.first { $0.title == "Homecomings (band)" },
                       WikiArticleReference(label: "Homecomings", title: "Homecomings (band)", language: "en"))
        XCTAssertEqual(URLComponents(string: band.source.url)?.queryItems?.first?.value, "1383036815")
        XCTAssertEqual(URLComponents(string: band.source.url)?.fragment, "Music")
        XCTAssertTrue(band.source.detail.contains("原始引文未独立核验"))
    }

    func testFocusedContinuationPreservesChineseOriginalSentenceAndItsOwnAnchors() async throws {
        let focus = "乐队白鸟为这部电影演唱了主题曲，完整录音收录在乐队的第二张专辑中。"
        let lead = "制作团队先在当地完成录音，随后回到工作室整理材料。"
        let result = try await continuationResponse(
            "<p>\(lead)乐队<a href=\"/wiki/白鸟乐队\">白鸟</a>为这部电影演唱了主题曲，完整录音收录在乐队的第二张专辑中。\(citation)</p>", language: "zh")
        let chosen = try XCTUnwrap(result.continuationCandidates?.first)
        XCTAssertEqual(chosen.body, focus)
        XCTAssertEqual(chosen.references, [.init(label: "白鸟", title: "白鸟乐队", language: "zh")])
        XCTAssertEqual(chosen.sourceParagraph, lead + focus)
        XCTAssertEqual(result.retainedContinuationCandidates?.first?.body, lead + focus)
        XCTAssertEqual(result.excerpts.count, 2, "Focusing a continuation must not change the baseline pair")
    }

    func testFocusedContinuationDoesNotBorrowAnEarlierAnchorWithTheSameLabel() async throws {
        let paragraph = "The band <a href=\"/wiki/Band_One\">Band One</a> attended the recording session. Band One provided the theme song for the film."
        let result = try await continuationResponse("<p>\(paragraph)\(citation)</p>")
        let chosen = try XCTUnwrap(result.continuationCandidates?.first)
        XCTAssertFalse(chosen.id.contains(":focus:"))
        XCTAssertEqual(chosen.body, chosen.sourceParagraph)
        XCTAssertNil(result.retainedContinuationCandidates)
    }

    func testFocusedCandidateRetainsOtherOriginalAnchorsForCreativeIdentitySelection() async throws {
        let paragraph = "The band <a href=\"/wiki/Band_One\">Band One</a> provided the opening theme. The band <a href=\"/wiki/Band_Two\">Band Two</a> provided the ending theme."
        let result = try await continuationResponse("<p>\(paragraph)\(citation)</p>")
        let chosen = try XCTUnwrap(result.continuationCandidates?.first)
        let retained = try XCTUnwrap(result.retainedContinuationCandidates?.first)
        XCTAssertEqual(chosen.derivedFromExcerptID, retained.id)
        XCTAssertEqual(chosen.references?.map(\.title), ["Band One"])
        XCTAssertEqual(retained.references?.map(\.title), ["Band One", "Band Two"],
                       "Preparation must still be able to verify the destination outside the shorter sentence")
        XCTAssertEqual(chosen.sourceParagraph, retained.sourceParagraph)
        XCTAssertEqual(retained.body, retained.sourceParagraph)
    }

    func testFocusedContinuationDoesNotDetachAPronounOrQuotedSubjectFromItsContext() async throws {
        for sentence in [
            "They recorded the theme song with <a href=\"/wiki/Band_One\">Band One</a>.",
            "\"The band <a href=\"/wiki/Band_One\">Band One</a> provided the theme song,\" she said."
        ] {
            let result = try await continuationResponse("<p>The crew spent several days planning the session. \(sentence)\(citation)</p>")
            let chosen = try XCTUnwrap(result.continuationCandidates?.first)
            XCTAssertFalse(chosen.id.contains(":focus:"))
            XCTAssertEqual(chosen.body, chosen.sourceParagraph)
        }
    }

    private func continuationResponse(_ html: String, language: String = "en") async throws -> WorkBackgroundResponse {
        let baseline = (1...2).map { index in
            let body = language == "zh" ? "在第\(index)天的录音过程中，作曲家亲自演奏钢琴并与乐手逐一录下每个声部。"
                : "The composer recorded the piano on day \(index) with the musicians in the studio."
            return "<p>\(body)\(citation)</p>"
        }.joined()
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Music")])),
            .init(section: "1", data: try payload(html: baseline + html))
        ]); defer { h.close() }
        return try await h.service.fetch(article: identity(language: language))
    }

    func testCreativeSectionKeepsLinkedTitlePunctuationAndClosedQuotation() async throws {
        let complete = "The composer recorded the piano for Sound! Euphonium and said, \"The footsteps became part of the music. That sound mattered.\""
        let html = "<p>The composer recorded the piano for <a href=\"/wiki/Sound!_Euphonium\">Sound! Euphonium</a> and said, \"The footsteps became part of the music. That sound mattered.\"\(citation)</p>"
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.first?.body, complete)
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["Sound! Euphonium"])
        XCTAssertEqual(result.excerpts.first?.sourceParagraph, complete)
    }

    func testCreativeSectionNeverShowsAnUnfinishedQuoteAtItsReadingLimit() async throws {
        let first = "The composer recorded the piano part at home before sending it to the producer."
        let quote = " He said, \"The instruments were silent. " + String(repeating: "We kept recording every detail of that sound ", count: 10) + ".\""
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: "<p>\(first + quote)\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.first?.body, first)
        XCTAssertEqual(result.excerpts.first?.sourceParagraph, first + quote)
    }

    func testContinuationPoolIsBoundedAndRequiresCreativeDetailWithVisibleSourceAnchor() async throws {
        let baseline = (1...2).map { "<p>The composer recorded the piano on day \($0) with the musicians in the studio.\(citation)</p>" }
        let candidates = (1...6).map { "<p>The band <a href=\"/wiki/Band_\($0)\">Band \($0)</a> provided the theme song for the film.\(citation)</p>" }
        let lowValue = "<p><a href=\"/wiki/Other_Band\">Other Band</a> announced their release during the summer.\(citation)</p>"
        let noAnchor = "<p>The composer recorded the piano with a local musician on the third day.\(citation)</p>"
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Music")])),
            .init(section: "1", data: try payload(html: (baseline + [noAnchor, lowValue] + candidates).joined()))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.count, 2)
        XCTAssertTrue(result.excerpts.allSatisfy { $0.body.contains("recorded the piano on day") })
        XCTAssertEqual(result.continuationCandidates?.flatMap { $0.references?.map(\.title) ?? [] },
                       (1...4).map { "Band \($0)" })
        XCTAssertEqual(h.requests.count, 2, "A larger candidate pool must not add source requests")
    }

    func testOnlyCreativeLeavesAndCitedBodyParagraphsAreRead() async throws {
        let index = try payload(sections: [section("1", "Production", "2"), section("2", "Plot", "3"), section("3", "Recording", "3"), section("4", "Release", "2")])
        let valid = "录音时，制作团队先录下钢琴与人声，再请乐手补充其他声部。"
        let html = """
        <table><tr><td><p>表格中的错误内容。\(citation)</p></td></tr></table>
        <figure><figcaption><p>图片标题。\(citation)</p></figcaption></figure>
        <div class="references"><p>脚注正文不应被当成创作资料。\(citation)</p></div>
        <p>这个段落虽然讨论录音，但没有任何行内来源，因此不显示。</p>
        <p><span class="error">引用错误</span>错误段落。\(citation)</p>
        <p>\(String(repeating: "过长的首句", count: 40))。\(citation)</p>
        <p>\(valid)<sup class="reference"><a href="%23cite_note-1">[1]</a></sup></p>
        """
        let h = BackgroundHarness([.init(section: nil, data: index), .init(section: "3", data: try payload(html: html))]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertEqual(result.excerpts.map(\.body), [valid])
        XCTAssertEqual(result.excerpts.first?.sourceParagraph, valid)
        XCTAssertEqual(result.excerpts.first?.heading, "Recording")
        XCTAssertEqual(h.requests.count, 2, "Neither the Production parent nor Plot child may be fetched")
    }

    func testEnglishLimitRetainsFullParagraphAndNeverCutsASentence() async throws {
        let first = "The composer recorded the piano part at home before sending it to the producer."
        let full = first + " " + String(repeating: "A deliberately lengthy continuation with several words ", count: 8) + "."
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Composition") ])),
            .init(section: "1", data: try payload(html: "<p>\(full)\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.first?.body, first)
        XCTAssertEqual(result.excerpts.first?.sourceParagraph, full)
        XCTAssertLessThanOrEqual(result.excerpts.first?.body.count ?? 999, 320)
    }

    func testArticleReferencesPreserveAnchorOrderAndKeepCandidatesBeyondTheThreeVisibleSlots() async throws {
        let html = """
        <p><a href="/wiki/Ada_Composer" title="Ada Composer">Ada</a> recorded the music for
        <a href="./The_Film#Production" title="The Film">The Film</a> with
        <a href="/wiki/Ada_Composer" title="Ada Composer">the same composer</a>.
        The recording appears on <a href="https://en.wikipedia.org/wiki/The_Album" title="The Album">The Album</a>
        and includes <a href="/wiki/The_Song" title="The Song">The Song</a>.\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        let excerpt = try XCTUnwrap(result.excerpts.first)
        XCTAssertEqual(excerpt.references?.map(\.title), ["Ada Composer", "The Film", "The Album", "The Song"])
        XCTAssertEqual(excerpt.references?.map(\.label), ["Ada", "The Film", "The Album", "The Song"])
        XCTAssertTrue(excerpt.references?.allSatisfy { $0.language == "en" && excerpt.body.contains($0.label) } ?? false)
        XCTAssertEqual(excerpt.body, excerpt.sourceParagraph)
        XCTAssertTrue(excerpt.body.contains("The Song"), "The link cap must not remove or rewrite source words")
    }

    func testCandidateReferencesRemainBoundedBeforeExactIdentityResolution() async throws {
        let links = (1...10).map { "<a href=\"/wiki/Work_\($0)\">Work \($0)</a>" }.joined(separator: ", ")
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: "<p>The recording includes \(links).\(citation)</p>"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(response.excerpts.first?.references?.map(\.title), (1...8).map { "Work \($0)" })
        XCTAssertTrue(response.excerpts.first?.body.contains("Work 10") ?? false)
    }

    func testPinnedKickBackLeadRetainsCitedCreativeSentencesAndExactSourceAnchors() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try fixture("Q114562491-zh-sections")),
            .init(section: "0", data: try fixture("Q114562491-zh-section-0"))
        ]); defer { h.close() }
        let article = WikiArticleIdentity(qid: "Q114562491", title: "KICK BACK (米津玄师歌曲)", language: "zh", pageID: 8154410, revision: 94853128)
        let response = try await h.service.fetch(article: article)
        XCTAssertEqual(response.excerpts.count, 2)
        let reuse = try XCTUnwrap(response.excerpts.first)
        XCTAssertEqual(reuse.body, "經淳君同意，〈KICK BACK〉中採用了他在2002年為早安少女組。創作的〈是啊！We're ALIVE〉（そうだ! We're ALIVE）中的一句歌詞「努力／未來／A BEAUTIFUL STAR」。")
        XCTAssertEqual(reuse.body.count, 103)
        XCTAssertEqual(reuse.references?.map(\.title), ["淳君", "早安少女組。", "是啊！We're ALIVE"])
        XCTAssertEqual(reuse.references?.map(\.label), ["淳君", "早安少女組。", "是啊！We're ALIVE"])
        let arrangement = try XCTUnwrap(response.excerpts.dropFirst().first)
        XCTAssertEqual(arrangement.body, "A面曲〈KICK BACK〉是電視動畫《鏈鋸人》的片頭曲，米津玄師作詞兼作曲，米津和常田大希共同編曲。")
        XCTAssertEqual(arrangement.references?.map(\.title), ["A面與B面", "鏈鋸人", "常田大希"])
        XCTAssertFalse(arrangement.references?.contains { $0.title == "米津玄師" } ?? true,
                       "The only artist anchor is in the earlier release sentence; a repeated name is not that anchor")
        XCTAssertEqual(reuse.sourceParagraph, arrangement.sourceParagraph)
        XCTAssertEqual(reuse.sourceParagraph.count, 218)
        XCTAssertFalse(response.excerpts.contains { $0.body.contains("2022年10月12日") })
        XCTAssertTrue(response.excerpts.allSatisfy { $0.sourceParagraph.contains($0.body) && $0.body.count <= 140 })
        XCTAssertEqual(URLComponents(string: reuse.source.url)?.queryItems?.first?.value, "94853128")
        XCTAssertNil(URLComponents(string: reuse.source.url)?.fragment)
        XCTAssertTrue(reuse.source.detail.contains("导语摘录"))
        XCTAssertEqual(h.requests.count, 2)
    }

    func testPinnedKafkaMusicThemePrefixPrecedesTitleWithoutIncludingLaterAnalysis() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try fixture("Q579744-en-sections")),
            .init(section: "1", data: try fixture("Q579744-en-section-1")),
            .init(section: "3", data: try fixture("Q579744-en-section-3"))
        ]); defer { h.close() }
        let article = WikiArticleIdentity(qid: "Q579744", title: "Kafka on the Shore", language: "en", pageID: 1769858, revision: 1379925795)
        let response = try await h.service.fetch(article: article)
        let music = try XCTUnwrap(response.excerpts.first)
        let expected = "The power and beauty of music as a communicative medium is one of the central ideas of the novel—the very title comes from a song Kafka is given on a record in the library. The music of Beethoven, specifically the Archduke Trio, is also used as a redemptive metaphor."
        XCTAssertEqual(expected.count, 267)
        XCTAssertEqual(music.body, expected)
        XCTAssertEqual(music.heading, "Major themes")
        XCTAssertEqual(music.references?.map(\.title), ["Ludwig van Beethoven", "Piano Trio No. 7 (Beethoven)"])
        XCTAssertEqual(music.references?.map(\.label), ["Beethoven", "Archduke Trio"])
        XCTAssertFalse(music.body.contains("Metaphysics"))
        XCTAssertFalse(music.body.contains("prophecy"))
        XCTAssertTrue(music.sourceParagraph.hasPrefix(expected))
        XCTAssertTrue(music.sourceParagraph.contains("Metaphysics"), "Keep the entire source paragraph available for inspection")
        XCTAssertTrue(music.source.detail.contains("音乐主题短摘"))
        XCTAssertEqual(URLComponents(string: music.source.url)?.fragment, "Major_themes")
        XCTAssertEqual(URLComponents(string: music.source.url)?.queryItems?.first?.value, "1379925795")
        XCTAssertEqual(response.excerpts.dropFirst().first?.heading, "Title")
        XCTAssertEqual(h.requests.count, 3, "Only the creative Title section and bounded music-theme candidate are read")
    }

    func testMusicThemeOnlyTakesTwoCitedSentencesAtTheStartOfAParagraph() async throws {
        let first = "The music of Suite acts as a central motif in the novel."
        let second = "The music also gives the chapter its title."
        let html = """
        <p>The music of <a href="/wiki/The_Suite">Suite</a> acts as a central motif in the novel.\(citation)
        \(second)\(citation)
        The music of <a href="/wiki/Later_Suite">Suite</a> supplies another metaphor at the end.\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Themes"), section("2", "Style"), section("3", "Analysis")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.map(\.body), [first + " " + second])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["The Suite"])
        XCTAssertEqual(h.requests.count, 2, "Style and Analysis remain outside the source candidates")
    }

    func testMusicThemeCannotSkipAnUncitedOrNonmusicalFirstSentenceToReachLaterLinks() async throws {
        let html = """
        <p>The music of <a href="/wiki/Uncited_Suite">Suite</a> acts as a central motif in the novel.
        The music also gives the chapter its title.\(citation)</p>
        <p>The narrator begins a long journey through the city.\(citation)
        The music of <a href="/wiki/Later_Suite">Suite</a> acts as a redemptive metaphor.\(citation)</p>
        <p>The music of Suite acts as a central motif in the novel.\(citation)
        Metaphysics is discussed through <a href="/wiki/Metaphysics">Suite</a> and other examples.\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Major themes")])),
            .init(section: "1", data: try payload(html: html)),
            .init(section: "0", data: try payload(html: ""))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertTrue(result.excerpts.isEmpty)
    }

    func testMusicThemePrefixDoesNotExtendPastTheReadingBudget() async throws {
        let first = "The music of Suite acts as a central motif in the novel."
        let second = "The music supplies a metaphor through " + String(repeating: "a carefully described passage ", count: 10) + "."
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Themes")])),
            .init(section: "1", data: try payload(html: "<p>The music of <a href=\"/wiki/The_Suite\">Suite</a> acts as a central motif in the novel.\(citation) \(second)\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertGreaterThan((first + " " + second).count, 320)
        XCTAssertEqual(result.excerpts.map(\.body), [first])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["The Suite"])
    }

    func testMusicThemeCannotDisplaceFourExistingCreativeSectionsOrEscapeExcludedParents() async throws {
        var sections = [section("1", "Themes")]
        sections += (2...5).map { section(String($0), "Recording \($0)") }
        var plans = [BackgroundPlan(section: nil, data: try payload(sections: sections))]
        for i in 2...5 {
            plans.append(.init(section: String(i), data: try payload(html: "<p>The composer recorded the piano with a small orchestra at home.\(citation)</p>")))
        }
        let full = BackgroundHarness(plans); defer { full.close() }
        let result = try await full.service.fetch(article: identity(language: "en"))
        XCTAssertFalse(result.excerpts.isEmpty)
        XCTAssertEqual(full.requests.count, 5, "Themes cannot add a fifth section or displace established creative sections")

        let excluded = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Plot", "2"), section("2", "Major themes", "3")])),
            .init(section: "0", data: try payload(html: ""))
        ]); defer { excluded.close() }
        let noPlot = try await excluded.service.fetch(article: identity(language: "en"))
        XCTAssertTrue(noPlot.excerpts.isEmpty)
        XCTAssertEqual(excluded.requests.count, 2)
    }

    func testLeadCitationCannotApplyBackwardToAnUncitedCreativeSentence() async throws {
        let html = """
        <p><a href="/wiki/Ada">Ada</a> recorded the piano part at home before inviting other musicians.
        The single was released in November and reached the charts the following month.\(citation)</p>
        <p>The song was arranged by <a href="/wiki/Bea">Bea</a> during a session with the orchestra.</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertTrue(result.excerpts.isEmpty, "Each selected lead sentence needs its own inline citation position")
    }

    func testNoninitialLeadSentenceUsesActualAnchorRangesInsteadOfRepeatedNames() async throws {
        let body = "Ada recorded the piano part with Bea at home before arranging the strings."
        let html = """
        <p><a href="/wiki/Wrong_Ada">Ada</a> released the single in November.
        Ada recorded the piano part with <a href="/wiki/Bea_Composer">Bea</a> at home before arranging the strings.\(citation)
        <a href="/wiki/Later_Ada">Ada</a> appeared on television the next month.</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.map(\.body), [body])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["Bea Composer"])
        XCTAssertFalse(result.excerpts.first?.sourceParagraph.hasPrefix(body) ?? true)
    }

    func testLeadSentenceDoesNotBreakAtAnchorOrQuotedTitlePunctuation() async throws {
        let html = """
        <p>這張單曲於秋季發行，後來收錄於第二張專輯。\(citation)經<a href="/wiki/Composer">作曲者</a>同意，這首歌引用了<a href="/wiki/Band">音。樂團</a>演唱的〈<a href="/wiki/Original">Play!</a>〉（原題為「Play!」）中的一段歌詞，並重新編曲。\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertEqual(result.excerpts.map(\.body), ["經作曲者同意，這首歌引用了音。樂團演唱的〈Play!〉（原題為「Play!」）中的一段歌詞，並重新編曲。"])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["Composer", "Band", "Original"])
    }

    func testParentheticalTitleCannotBorrowThePreviousSentencesCitation() async throws {
        let html = """
        <p>這張單曲於秋季發行，後來收錄於第二張專輯。\(citation)經<a href="/wiki/Composer">作曲者</a>同意，這首歌引用了<a href="/wiki/Band">音。樂團</a>演唱的〈<a href="/wiki/Original">Play!</a>〉（原題為「Play!」）中的一段歌詞，並重新編曲。</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertTrue(result.excerpts.isEmpty, "Grouping an inner title with its original sentence must not expand its citation scope")
    }

    func testQuotedLeadKeepsTheOriginalSentenceAndItsTerminalAnchor() async throws {
        let body = "\"The song was recorded by Ada.\""
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: "<p>\"The song was recorded by <a href=\"/wiki/Ada\">Ada</a>.\"\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.map(\.body), [body], "Only trailing closers may be removed when calculating punctuation position")
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["Ada"])
    }

    func testCitedArtistPeriodCanEndASentenceWithoutMergingALongReleaseSentence() async throws {
        let first = "The track was recorded with fun."
        let release = "It was released " + String(repeating: "during the following year ", count: 12) + "in stores."
        XCTAssertGreaterThan((first + " " + release).count, 320)
        XCTAssertLessThanOrEqual((first + " " + release).count, 400)
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: "<p>The track was recorded with <a href=\"/wiki/Fun_(band)\">fun.</a>\(citation) \(release)\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.map(\.body), [first])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["Fun (band)"])
    }

    func testLeadDoesNotTreatReleaseOrOpeningThemeMembershipAsCreativeMaterial() async throws {
        let html = """
        <p>這首單曲於二〇二二年發行，並收錄在歌手的最新專輯中。\(citation)
        這首歌是電視動畫《<a href="/wiki/Example_Animation">某部動畫作品</a>》的片頭曲，後來也收錄於原聲專輯。\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertTrue(result.excerpts.isEmpty)
    }

    func testLeadDoesNotConfuseReceptionOrChartWordingWithRecordingActions() async throws {
        let html = """
        <p>The album received mixed reviews from music critics after its release.\(citation)
        It recorded a peak of number ten on the singles chart the following month.\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertTrue(result.excerpts.isEmpty)
    }

    func testLeadRejectsOverlongSentencesAndKeepsTheNextCompleteCitedSentence() async throws {
        let long = "这首歌的录音" + String(repeating: "持续了很长时间", count: 30) + "。"
        let short = "制作团队在工作室录下钢琴、人声与弦乐，随后完成了整首曲子的编曲。"
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: "<p>\(long)\(citation)\(short)\(citation)</p>"))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertEqual(result.excerpts.map(\.body), [short])
        XCTAssertEqual(result.excerpts.first?.sourceParagraph, long + short)
    }

    func testLeadCandidatesRetainTheEightAnchorLimitAndExistingURLRules() async throws {
        let valid = (1...10).map { "<a href=\"/wiki/Work_\($0)\">Work \($0)</a>" }.joined(separator: ", ")
        let html = """
        <p>The music was arranged by <a href="https://other.example/wiki/Bad">a visitor</a>,
        <a href="/wiki/File:Bad">an image</a>, <a class="new" href="/wiki/Missing">a missing artist</a>,
        and the artists credited as \(valid).\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), (1...8).map { "Work \($0)" })
        XCTAssertTrue(result.excerpts.first?.body.contains("Work 10") ?? false)
    }

    func testLeadWrongRevisionAndNetworkFailureAreNotSuccessfulEmpty() async throws {
        let wrong = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: try payload(html: "<p>The song was arranged by a guest composer.\(citation)</p>", revision: 999))
        ]); defer { wrong.close() }
        do { _ = try await wrong.service.fetch(article: identity(language: "en")); XCTFail("Lead changed revision") }
        catch WorkBackgroundError.invalidResponse { }

        let unavailable = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [])),
            .init(section: "0", data: Data(), status: 503)
        ]); defer { unavailable.close() }
        do { _ = try await unavailable.service.fetch(article: identity()); XCTFail("Lead failure became known-empty") }
        catch WorkBackgroundError.httpStatus(503) { }
    }

    func testReferencesExcludeCurrentPageNamespaceRedLinksAndCrossSiteTargets() async throws {
        let html = """
        <p>The material mentions <a href="/wiki/Exact_Work" title="Exact Work">itself</a>,
        <a href="/wiki/File%3ACover.jpg" title="File:Cover.jpg">cover</a>,
        <a href="./Category:Music" title="Category:Music">category</a>,
        <a href="/wiki/Draft_Song" title="Draft Song" class="new">red</a>,
        <a href="/wiki/Other_Song?redlink=1" title="Other Song">missing</a>,
        <a href="https://zh.wikipedia.org/wiki/Other" title="Other">other language</a>,
        <a href="https://example.com/wiki/Other" title="Other">another site</a>,
        and
        <a href="/wiki/The_Film" title="The Film">The Film</a>.\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["The Film"])
        XCTAssertTrue(result.excerpts.first?.body.contains("cover") ?? false, "Excluded links still remain source text")
    }

    func testChineseVariantTooltipAndMissingTooltipStillKeepExactHrefTarget() async throws {
        let html = """
        <p>三浦透子原本参加的是另一部电影《<a href="/wiki/%E5%81%B6%E7%84%B6%E8%88%87%E6%83%B3%E5%83%8F" title="偶然与想像">偶然与想像</a>》的试镜，
        后来与<a href="/wiki/%E4%B8%89%E6%B5%A6%E9%80%8F%E5%AD%90">三浦透子</a>讨论了新的拍摄安排。\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "制作")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertEqual(result.excerpts.first?.references?.map(\.title), ["偶然與想像", "三浦透子"])
        XCTAssertEqual(result.excerpts.first?.references?.map(\.label), ["偶然与想像", "三浦透子"])
    }

    func testReferenceAfterCutoffCannotBindAnEarlierUnlinkedOccurrence() async throws {
        let first = "The director consulted Ada while preparing the music for The Film."
        let html = """
        <p>The director consulted Ada while preparing the music for <a href="./The_Film" title="The Film">The Film</a>.
        <a href="/wiki/Ada_Composer" title="Ada Composer">Ada</a> \(String(repeating: "continued working on the recording with the entire production team ", count: 8)).\(citation)</p>
        """
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: html))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity(language: "en"))
        let excerpt = try XCTUnwrap(result.excerpts.first)
        XCTAssertEqual(excerpt.body, first)
        XCTAssertGreaterThan(excerpt.sourceParagraph.count, 320)
        XCTAssertEqual(excerpt.references?.map(\.title), ["The Film"])
        XCTAssertFalse(excerpt.references?.contains { $0.title == "Ada Composer" } ?? true)
    }

    func testFourCandidateRequestBudgetReturnsEmptyWithoutUncitedFillers() async throws {
        let sections = (1...6).map { section(String($0), "Recording \($0)") }
        var plans = [BackgroundPlan(section: nil, data: try payload(sections: sections))]
        for i in 1...4 { plans.append(.init(section: String(i), data: try payload(html: "<p>Uncited production prose must never fill this slot.</p>"))) }
        plans.append(.init(section: "0", data: try payload(html: "<p>An uncited lead must never fill this slot either.</p>")))
        let h = BackgroundHarness(plans); defer { h.close() }
        let response = try await h.service.fetch(article: identity())
        XCTAssertTrue(response.excerpts.isEmpty)
        XCTAssertEqual(h.requests.count, 6, "One index, at most four creative sections, then at most one lead fallback")
    }

    func testAnOverlongFirstSentenceIsStillRejectedRatherThanClippedOrRewritten() async throws {
        let tooLong = String(repeating: "The piano recording continued with the musicians in the studio ", count: 8) + "."
        let short = "The composer recorded the piano part at home before sending it to the producer."
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: "<p>\(tooLong)\(citation)</p><p>\(short)\(citation)</p>"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(article: identity(language: "en"))
        XCTAssertGreaterThan(tooLong.count, 400)
        XCTAssertEqual(response.excerpts.map(\.body), [short])
        XCTAssertEqual(response.excerpts.first?.body, response.excerpts.first?.sourceParagraph)
    }

    @MainActor
    func testPreviousSelectionCacheCannotHideTheNewSelectionPolicy() async throws {
        struct PreviousCache: Encodable {
            var version = 4
            let response: WorkBackgroundResponse
            var fetchedAt = Date()
        }
        let article = identity()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundPolicy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(article.cacheKey + ".json")
        try JSONEncoder().encode(PreviousCache(response: .init(article: article, excerpts: []))).write(to: file)
        let body = "录音时，制作团队先录下钢琴与人声，再请乐手补充其他声部。"
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: "<p>\(body)\(citation)</p>"))
        ]); defer { h.close() }
        let store = WorkBackgroundStore(service: h.service, directory: directory)
        await store.load(article)
        XCTAssertEqual(store.values[article.cacheKey]?.excerpts.map(\.body), [body])
        XCTAssertEqual(h.requests.count, 2, "Even a fresh v4 cache must be recomputed under the new policy")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 7)
    }

    func testNoEligibleSectionsIsSuccessfulEmpty() async throws {
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Plot"), section("2", "Awards")])),
            .init(section: "0", data: try payload(html: ""))
        ]); defer { h.close() }
        let result = try await h.service.fetch(article: identity())
        XCTAssertTrue(result.excerpts.isEmpty)
        XCTAssertEqual(h.requests.count, 2)
    }

    func testWrongRevisionOrPageCannotAttachText() async throws {
        for response in [try payload(sections: [], revision: 999), try payload(sections: [], pageID: 999)] {
            let h = BackgroundHarness([.init(section: nil, data: response)]); defer { h.close() }
            do { _ = try await h.service.fetch(article: identity()); XCTFail("Identity mismatch accepted") }
            catch WorkBackgroundError.invalidResponse { }
        }
        let h = BackgroundHarness([
            .init(section: nil, data: try payload(sections: [section("1", "Recording")])),
            .init(section: "1", data: try payload(html: "<p>A mismatched revision is not evidence.\(citation)</p>", revision: 999))
        ]); defer { h.close() }
        do { _ = try await h.service.fetch(article: identity()); XCTFail("Section changed revision") }
        catch WorkBackgroundError.invalidResponse { }
    }

    func testNetworkAndAPIFailureAreNotSuccessfulEmpty() async throws {
        let http = BackgroundHarness([.init(section: nil, data: Data(), status: 429)]); defer { http.close() }
        do { _ = try await http.service.fetch(article: identity()); XCTFail("HTTP failure became empty") }
        catch WorkBackgroundError.httpStatus(429) { }
        let offline = BackgroundHarness([.init(section: nil, data: Data(), failure: .notConnectedToInternet)]); defer { offline.close() }
        do { _ = try await offline.service.fetch(article: identity()); XCTFail("Offline became empty") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        let api = BackgroundHarness([.init(section: nil, data: Data(#"{"error":{"code":"missingtitle"}}"#.utf8))]); defer { api.close() }
        do { _ = try await api.service.fetch(article: identity()); XCTFail("API error became empty") }
        catch WorkBackgroundError.invalidResponse { }
    }

    func testInvalidIdentityDoesNotReachNetwork() async throws {
        let h = BackgroundHarness([]); defer { h.close() }
        for article in [identity(language: "evil.example"), WikiArticleIdentity(qid: "Q1|Q2", title: "Title", language: "zh", pageID: 10, revision: 20)] {
            do { _ = try await h.service.fetch(article: article); XCTFail("Invalid identity accepted") }
            catch WorkBackgroundError.invalidIdentity { }
        }
        XCTAssertTrue(h.requests.isEmpty)
    }

    private var citation: String { ##"<sup class="reference"><a href="#cite_note-1">[1]</a></sup>"## }
    private func identity(language: String = "zh") -> WikiArticleIdentity { .init(qid: "Q100", title: "Exact Work", language: language, pageID: 10, revision: 20) }
    private func section(_ id: String, _ title: String, _ level: String = "2") -> [String: String] { ["index": id, "line": title, "level": level, "anchor": title] }
    private func payload(sections: [[String: String]]? = nil, html: String? = nil, revision: Int = 20, pageID: Int = 10) throws -> Data {
        var parsed: [String: Any] = ["title": "Exact Work", "pageid": pageID, "revid": revision]
        if let sections { parsed["sections"] = sections }
        if let html { parsed["text"] = html }
        return try JSONSerialization.data(withJSONObject: ["parse": parsed])
    }
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "background-" + name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private struct BackgroundPlan: Sendable {
    let section: String?
    let data: Data
    var status = 200
    var failure: URLError.Code? = nil
}
private final class BackgroundHarness: @unchecked Sendable {
    let service: WorkBackgroundService
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: BackgroundState
    init(_ plans: [BackgroundPlan]) {
        state = BackgroundState(plans)
        BackgroundRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackgroundProtocol.self]
        config.httpAdditionalHeaders = ["X-Background-Test": token]
        config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        service = WorkBackgroundService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.remaining, 0, file: file, line: line)
        session.invalidateAndCancel()
        BackgroundRegistry.shared.remove(token)
    }
}
private final class BackgroundState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [BackgroundPlan]
    private var observed: [URLRequest] = []
    init(_ plans: [BackgroundPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return plans.count }
    func next(_ request: URLRequest) -> BackgroundPlan? {
        lock.lock(); defer { lock.unlock() }
        observed.append(request)
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        let section = items?.first { $0.name == "section" }?.value
        guard let first = plans.first, first.section == section else { return nil }
        return plans.removeFirst()
    }
}
private final class BackgroundRegistry: @unchecked Sendable {
    static let shared = BackgroundRegistry()
    private let lock = NSLock()
    private var states: [String: BackgroundState] = [:]
    func put(_ key: String, _ state: BackgroundState) { lock.lock(); defer { lock.unlock() }; states[key] = state }
    func get(_ key: String?) -> BackgroundState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { states[$0] } }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; states.removeValue(forKey: key) }
}
private final class BackgroundProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = BackgroundRegistry.shared.get(request.value(forHTTPHeaderField: "X-Background-Test")),
              let plan = state.next(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if let code = plan.failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
