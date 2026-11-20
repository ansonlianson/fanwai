import Foundation
import XCTest
@testable import Pianwai

@MainActor final class FlashLeadResearchClientTests: XCTestCase {
    func testCitationsReindexAfterUnknownMiddleSentenceAndKeepComplementarySources() async throws {
        let quote = "2023年のティザーPV制作時のB案としてあった曲です。"
        let suite = "細切れのトラックではなく、繋がった組曲として勝手に作りました。"
        let orchestration = "この曲の和声はロシアのピアノコンチェルトに影響を受けたものです。"
        let other = "これは別の記事にだけ書かれている、別の制作過程についての説明です。"
        let source = "https://realsound.jp/pool"
        let body = "in the pool 牛尾憲輔\n" + [quote, suite, orchestration].joined(separator: "\n") + String(repeating: "制作インタビューの本文。", count: 30)
        let searches: [[String: Any]] = [
            ["url": source + "?utm_source=test", "title": "in the pool 牛尾憲輔", "content": body],
            ["url": "https://tokion.jp/other", "title": "別の記事", "content": orchestration + String(repeating: "別の取材本文。", count: 50)]
        ]
        let draft: [String: Any] = ["leads": [
            lead("牛尾憲輔", kind: "person", label: "演绎艺人", why: "当前艺人本人。", quote: quote),
            lead("CHAINSAW MAN soundtrack", kind: "album", label: "所在专辑", why: "当前原声带。", quote: quote),
            lead("Reze", label: "同片主题曲", why: "与当前曲属于同一部电影的配乐。", quote: quote),
            lead("Invented", label: "创作参考", why: "这条引用了不存在的来源。", quote: quote, id: "S404")
        ], "story": ["subject": "song", "subject_name": "in the pool", "source": "错误的来源", "url": "https://wrong.example/",
                     "sentences": [
                        sentence("《in the pool》原本是二〇二三年先导影像制作时的B案。牛尾宪辅没有把它拆成零碎音轨，而是将音乐做成了连贯的组曲。", quote: suite),
                        sentence("这句混入未知来源，必须在交给审核前被移除。", quote: other, id: "S404"),
                        sentence("他还让泳池场景中的管弦和声受到近现代俄罗斯钢琴协奏曲的影响，用声音承接角色来自寒冷地区的背景。", quote: orchestration, id: "S2")
                     ]]]
        let audit: [String: Any] = ["lead_decisions": [["index": 0, "keep": true, "label_valid": true, "creator_ok": true]],
                                    "story_decisions": [["index": 0, "keep": true], ["index": 1, "keep": true]], "subject_valid": true]
        let harness = try FlashHarness(searches: searches, draft: draft, audit: audit)
        defer { harness.close() }
        let result = try await harness.client.research(subject())
        XCTAssertEqual(result.leads?.map(\.name), ["Reze"])
        XCTAssertEqual(result.leads?.first?.kind, "song")
        XCTAssertEqual(result.leads?.first?.creator, "牛尾憲輔")
        XCTAssertEqual(result.leads?.first?.url, source)
        let story = try XCTUnwrap(result.story)
        XCTAssertEqual(story.source, "Real Sound")
        XCTAssertEqual(story.url, source)
        XCTAssertEqual(story.additionalSources?.map(\.url), ["https://tokion.jp/other"])
        XCTAssertTrue(story.text?.contains("俄罗斯") == true)
        XCTAssertFalse(story.text?.contains("混入") == true)
        let context = try XCTUnwrap(harness.state.auditContext)
        let guarded = try XCTUnwrap(context["draft"] as? [String: Any])
        let sentences = try XCTUnwrap((guarded["story"] as? [String: Any])?["sentences"] as? [[String: Any]])
        XCTAssertEqual(sentences.compactMap { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(result.flashMetrics?.searches, 4)
        XCTAssertEqual(result.flashMetrics?.modelCalls, 2)
        XCTAssertEqual(result.flashMetrics?.inputTokens, 1000)
        XCTAssertEqual(result.flashMetrics?.outputTokens, 200)
        XCTAssertEqual(result.flashMetrics?.acceptedLeadCount, 1)
        XCTAssertTrue(harness.state.searchQueries.contains { $0.contains("影響") && $0.contains("映画") })
    }

    func testLabelConflictUnknownReferencesAndUnsupportedSentencesFailClosed() async throws {
        let quote = "2023年のティザーPV制作時のB案としてあった曲です。"
        let draft: [String: Any] = ["leads": [
            lead("Reze", label: "落选同门曲", why: "最终选中了这首作为预告曲。", quote: quote),
            lead("Unknown", label: "创作参考", why: "没有实际来源。", quote: quote, id: "S404")
        ], "story": ["subject": "song", "subject_name": "in the pool", "sentences": [
            sentence("它最初是A案，后来成为组曲，这个字母与实际原文的字母相反，所以不能显示给用户。", quote: quote),
            sentence("这句凭空添加录音事实，也不能仅凭一条不存在的引文显示给用户。", quote: "这是一条正文里根本不存在的伪造引文。")
        ]]]
        let audit: [String: Any] = ["lead_decisions": [["index": 0, "keep": true, "label_valid": false, "creator_ok": true]],
                                    "story_decisions": [], "subject_valid": true]
        let harness = try FlashHarness(searches: [["url": "https://realsound.jp/pool", "content": quote + String(repeating: "取材本文。", count: 60)]], draft: draft, audit: audit)
        defer { harness.close() }
        let result = try await harness.client.research(subject())
        XCTAssertEqual(result.leads?.count, 0)
        XCTAssertNil(result.story)
        XCTAssertEqual(harness.state.modelCalls, 2)
    }

    func testArtistFallbackNeedsAnAuditedFirstSentenceConnectingTheCurrentSong() async throws {
        let quote = "そもそもは、80年代のシンセサイザーを使ったサウンドをやりたいと樋口総監督と話をしていました。"
        let current = LeadSubject(id: "test:lilac", kind: .song, title: "Lilac", creator: "岩崎太整", album: "First Love 初恋")
        for hasBridge in [false, true] {
            let text = (hasBridge ? "《Lilac》的艺人岩崎太整，在为《ひそねとまそたん》配乐时，" : "为《ひそねとまそたん》配乐时，岩崎太整")
                + "起初与樋口真嗣讨论采用八十年代的合成器音色，随后在具体制作中重新思考声音方向。这是他为另一部作品作曲时发生的选择。"
            let value: [String: Any] = ["leads": [], "story": ["subject": "artist", "subject_name": "岩崎太整", "sentences": [sentence(text, quote: quote)]]]
            let harness = try FlashHarness(searches: [["url": "https://ure.pia.co.jp/interview", "content": quote + String(repeating: "岩崎太整の取材本文。", count: 30)]], draft: value,
                audit: ["lead_decisions": [], "story_decisions": [["index": 0, "keep": true]], "subject_valid": true])
            defer { harness.close() }
            let result = try await harness.client.research(current)
            XCTAssertEqual(result.story != nil, hasBridge)
            XCTAssertEqual(result.flashMetrics?.keptSentenceCount, 1)
            XCTAssertEqual(result.flashMetrics?.auditSubjectValid, true)
            XCTAssertEqual(result.flashMetrics?.storyRejectionReason, hasBridge ? nil : "missingCatalogBridge")
            if hasBridge { XCTAssertEqual(result.story?.subject, "artist") }
        }
    }

    func testSummaryOnlyResultIsFetchedOnceAndNeverPromotedToBodyEvidence() async throws {
        let quote = "2023年のティザーPV制作時のB案としてあった曲です。"
        let summary = "这是仅存在于搜索摘要的未经正文支持的断言。"
        let source = "https://realsound.jp/pool"
        let harness = try FlashHarness(searches: [["url": source + "?utm_campaign=example", "summary": String(repeating: summary, count: 20)]],
            fetchedBody: quote + String(repeating: "已实际读取的采访正文。", count: 30),
            draft: ["leads": [lead("Reze", label: "同片配乐", why: "具体关联来自已读正文。", quote: quote)], "story": NSNull()],
            audit: ["lead_decisions": [["index": 0, "keep": true, "label_valid": true, "creator_ok": true]], "story_decisions": [], "subject_valid": false])
        defer { harness.close() }
        let result = try await harness.client.research(subject())
        XCTAssertEqual(result.leads?.count, 1)
        XCTAssertEqual(harness.state.fetchURLs, [source])
        let context = try XCTUnwrap(harness.state.draftContext)
        let sources = try XCTUnwrap(context["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 1)
        XCTAssertFalse((sources.first?["text"] as? String)?.contains(summary) == true)
        XCTAssertEqual(result.flashMetrics?.fetches, 1)
    }

    func testChineseQueriesReserveInterviewEvidenceBeyondCatalogsAndKeepAlbumIdentity() async throws {
        let album = "泥河 (Soundtrack from the Netflix Series)"
        let current = LeadSubject(id: "test:chinese", kind: .song, title: "山鸟", creator: "周云蓬", album: album)
        let quote = "我把木吉他的节奏留空，让另一件乐器接着回答它。"
        var pages: [[String: Any]] = (0..<6).map { index in
            ["url": "https://catalog-\(index / 2).example/song-\(index)", "title": "山鸟 周云蓬 目录",
             "content": String(repeating: "山鸟 周云蓬 泥河 的目录条目和发行资料。", count: 25)]
        }
        pages += ["a", "b"].map { suffix in
            ["url": "https://interview-\(suffix).example/article", "title": "周云蓬访谈：创作与灵感",
             "content": "周云蓬访谈。\n" + quote + "\n" + String(repeating: "创作的灵感与录音方法，需要留出乐器之间的空间。", count: 20)]
        }
        let text = "《山鸟》的艺人周云蓬，在谈到一次创作时，说他把木吉他的节奏故意留空，让另一件乐器接着回答。这样的处理把两件乐器安排成轮流说话，而没有把伴奏一直铺满。"
        let value: [String: Any] = ["leads": [], "story": ["subject": "artist", "subject_name": "周云蓬",
            "sentences": [sentence(text, quote: quote, id: "S2")]]]
        let harness = try FlashHarness(searches: pages, draft: value,
            audit: ["lead_decisions": [], "story_decisions": [["index": 0, "keep": true]], "subject_valid": true])
        defer { harness.close() }
        let result = try await harness.client.research(current)
        let context = try XCTUnwrap(harness.state.draftContext)
        let sources = try XCTUnwrap(context["sources"] as? [[String: Any]])
        let titles = sources.compactMap { $0["title"] as? String }
        XCTAssertGreaterThanOrEqual(titles.filter { $0.contains("访谈") }.count, 2)
        XCTAssertTrue(titles.contains { $0.contains("目录") })
        let hosts = Dictionary(grouping: sources.compactMap { ($0["url"] as? String).flatMap { URL(string: $0)?.host } }, by: { $0 })
        XCTAssertTrue(hosts.values.allSatisfy { $0.count <= 2 })
        XCTAssertLessThanOrEqual(sources.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count }, 10_000)
        let queries = harness.state.searchQueries
        XCTAssertEqual(queries.count, 4)
        XCTAssertTrue(queries.contains { $0.contains("采访") && $0.contains("インタビュー") })
        let albumQuery = try XCTUnwrap(queries.first { $0.contains("\"泥河\"") })
        XCTAssertFalse(albumQuery.contains("Netflix"))
        XCTAssertFalse(albumQuery.contains("Soundtrack"))
        XCTAssertEqual(result.flashMetrics?.subjectAlbum, album)
        XCTAssertEqual(result.flashMetrics?.subjectTitle, "山鸟")
        XCTAssertEqual(result.flashMetrics?.guardedSentenceCount, 1)
        XCTAssertEqual(result.flashMetrics?.keptSentenceCount, 1)
        XCTAssertEqual(result.story?.subject, "artist")
    }

    func testQueryPlannerUsesNativeNameHypothesesWithoutChangingCatalogIdentity() async throws {
        let quote = "「JANE DOE」はふたりの対話をきっかけに制作された曲です。"
        let current = LeadSubject(id: "test:jane", kind: .song, title: "JANE DOE", creator: "米津玄师、宇多田光", album: "")
        let planned = [
            "\"JANE DOE\" \"米津玄師\" \"宇多田ヒカル\" インタビュー",
            "\"JANE DOE\" 制作 対談",
            "\"米津玄師\" \"宇多田ヒカル\" 合作",
            "\"JANE DOE\" 影響 参考 映画"
        ]
        let planner: [String: Any] = ["native_artist_names": ["米津玄師", "宇多田ヒカル"], "language": "ja", "queries": planned]
        let value: [String: Any] = ["leads": [], "story": ["subject": "song", "subject_name": "JANE DOE",
            "sentences": [sentence("《JANE DOE》的制作由两位音乐人的对话开始。他们围绕如何把彼此不同的表达放进同一首歌展开交流，并在这段合作中逐渐形成了实际的制作方向。", quote: quote)]]]
        let harness = try FlashHarness(searches: [["url": "https://realsound.jp/jane", "title": "JANE DOE 対談", "content": quote + String(repeating: "制作インタビューの本文。", count: 30)]],
            draft: value, audit: ["lead_decisions": [], "story_decisions": [["index": 0, "keep": true]], "subject_valid": true], planner: planner)
        defer { harness.close() }
        let result = try await harness.client.research(current)
        XCTAssertEqual(Set(harness.state.searchQueries), Set(planned))
        XCTAssertEqual(result.flashMetrics?.modelCalls, 3)
        XCTAssertEqual(result.flashMetrics?.inputTokens, 1500)
        XCTAssertEqual(result.flashMetrics?.searchQueries, planned)
        XCTAssertEqual(result.flashMetrics?.subjectCreator, "米津玄师、宇多田光")
        XCTAssertNotNil(result.flashMetrics?.planningSeconds)
        let context = try XCTUnwrap(harness.state.draftContext)
        let identity = try XCTUnwrap(context["subject"] as? [String: Any])
        XCTAssertEqual(identity["creator"] as? String, "米津玄师、宇多田光")
        XCTAssertEqual(result.story?.source, "Real Sound")
    }

    func testLongLatinWorkNamesUseVisualWidthInsteadOfRejectingAnAuditedStory() async throws {
        let current = LeadSubject(id: "test:latin", kind: .song, title: "JANE DOE", creator: "米津玄師, 宇多田ヒカル", album: "")
        let title = "I've Seen It All (Björk & Thom Yorke — Dancer in the Dark, Original Motion Picture Soundtrack)"
        let texts = [
            "米津玄师在写《JANE DOE》前，先以《\(title)》的男女对唱作为创作参考，把这首电影歌曲放在构思的起点。",
            "随着钢琴动机和歌词逐渐成形，他确认要邀请宇多田光参与；交给她的是一个内心复杂的女孩，与不理解她的男孩对唱的设定。",
            "两人分别处理演唱，再往返交流录音数据。《\(title)》在这里提供的是对唱方向，而不是可以直接套用的完整编曲。"
        ]
        let quote = "これは映画の男女デュエットを参考にして制作を始めた、ふたりの歌声を重ねる曲です。"
        let text = texts.joined()
        XCTAssertGreaterThan(text.count, 260)
        XCTAssertLessThan(text.count, 800)
        XCTAssertLessThanOrEqual(StoryValidator.visualWidth(text), 420)
        let value: [String: Any] = ["leads": [], "story": ["subject": "song", "subject_name": "JANE DOE",
            "sentences": texts.map { sentence($0, quote: quote) }]]
        let harness = try FlashHarness(searches: [["url": "https://realsound.jp/jane", "title": "JANE DOE インタビュー", "content": quote + String(repeating: "制作インタビューの本文。", count: 30)]], draft: value,
            audit: ["lead_decisions": [], "story_decisions": (0..<3).map { ["index": $0, "keep": true] as [String: Any] }, "subject_valid": true])
        defer { harness.close() }
        let result = try await harness.client.research(current)
        XCTAssertEqual(result.story?.text, text)
        XCTAssertEqual(result.flashMetrics?.keptSentenceCount, 3)
        XCTAssertEqual(result.flashMetrics?.auditedStoryCharacters, text.count)
        XCTAssertEqual(result.flashMetrics?.auditSubjectValid, true)
        XCTAssertNil(result.flashMetrics?.storyRejectionReason)
    }

    func testMislabeledSongCanBecomeKnownArtistWithoutRewritingAndUsesMostCitedSource() async throws {
        let current = LeadSubject(id: "test:scope", kind: .song, title: "Lilac", creator: "岩崎太整", album: "First Love 初恋")
        let metadata = "Lilacは岩崎太整が手掛けたサウンドトラックに収録された楽曲です。"
        let quotes = [
            "80年代のシンセサイザーを使ったサウンドをやりたいと話していました。",
            "全部捨てて、オーケストラによる音楽へと方向を変えていきました。",
            "楽器や奏者を変えながら、レコーディングを3回に分けて行いました。"
        ]
        let texts = [
            "岩崎太整的《Lilac》收录在《First Love 初恋》的原声带中。",
            "他在另一部作品《ひそねとまそたん》的配乐中，最初与导演商量采用八十年代的合成器音色。",
            "后来，他判断这种音色不适合故事，舍弃原来的方案，转向管弦乐的写法，让声音随剧情推进。",
            "为了处理不同的乐器与演奏者，录音被分成三次进行；这些选择讲的是那部动画的配乐，而不是《Lilac》的单曲录音。"
        ]
        let value: [String: Any] = ["leads": [], "story": ["subject": "song", "subject_name": "Lilac", "sentences": [
            sentence(texts[0], quote: metadata),
            sentence(texts[1], quote: quotes[0], id: "S2"),
            sentence(texts[2], quote: quotes[1], id: "S2"),
            sentence(texts[3], quote: quotes[2], id: "S2")
        ]]]
        let metadataURL = "https://catalog.example/lilac"
        let interviewURL = "https://ure.pia.co.jp/other"
        let pages: [[String: Any]] = [
            ["url": metadataURL, "title": "Lilac 岩崎太整", "content": metadata + String(repeating: "Lilac 目录资料。", count: 30)],
            ["url": interviewURL, "title": "岩崎太整采访", "content": quotes.joined(separator: "\n") + String(repeating: "岩崎太整の制作インタビュー。", count: 30)]
        ]
        for correctedName in ["岩崎太整", "宇多田ヒカル"] {
            let audit: [String: Any] = ["lead_decisions": [], "story_decisions": (0..<4).map { ["index": $0, "keep": true] as [String: Any] },
                "subject_valid": true, "corrected_subject": "artist", "corrected_subject_name": correctedName]
            let harness = try FlashHarness(searches: pages, draft: value, audit: audit)
            defer { harness.close() }
            let result = try await harness.client.research(current)
            XCTAssertEqual(result.flashMetrics?.keptSentenceCount, 4)
            if correctedName == "岩崎太整" {
                XCTAssertEqual(result.story?.subject, "artist")
                XCTAssertEqual(result.story?.text, texts.joined())
                XCTAssertEqual(result.story?.url, interviewURL)
                XCTAssertEqual(result.story?.source, "ぴあ")
                XCTAssertEqual(result.story?.additionalSources?.map(\.url), [metadataURL])
                XCTAssertNil(result.flashMetrics?.storyRejectionReason)
            } else {
                XCTAssertNil(result.story)
                XCTAssertEqual(result.flashMetrics?.storyRejectionReason, "invalidSubjectCorrection")
            }
        }
    }

    private func subject() -> LeadSubject {
        .init(id: "test:pool", kind: .song, title: "in the pool", creator: "牛尾憲輔", album: "CHAINSAW MAN soundtrack")
    }
    private func lead(_ name: String, kind: String = "song", label: String, why: String, quote: String, id: String = "S1") -> [String: Any] {
        ["name": name, "kind": kind, "label": label, "why": why, "creator": "牛尾憲輔", "evidence": [["id": id, "quote": quote]], "url": "https://wrong.example/ignored"]
    }
    private func sentence(_ text: String, quote: String, id: String = "S1") -> [String: Any] {
        ["text": text, "evidence": [["id": id, "quote": quote]]]
    }
}

private final class FlashHarness {
    let state: FlashStubState
    let client: FlashLeadResearchClient
    private let session: URLSession
    private let token = UUID().uuidString
    init(searches: [[String: Any]], fetchedBody: String = "", draft: [String: Any], audit: [String: Any], planner: [String: Any]? = nil) throws {
        state = try FlashStubState(searches: searches, fetchedBody: fetchedBody, draft: draft, audit: audit, planner: planner)
        FlashStubRegistry.shared.put(token, state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlashURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Flash-Offline-Test": token]
        session = URLSession(configuration: configuration)
        client = FlashLeadResearchClient(credential: "offline-only", session: session, queryPlanning: planner != nil)
    }
    func close() { session.invalidateAndCancel(); FlashStubRegistry.shared.remove(token) }
}

private final class FlashStubState: @unchecked Sendable {
    private let lock = NSLock()
    private let searchReplies: [Data]
    private let fetchReply: Data
    private let models: [Data]
    private var observedQueries: [String] = []
    private var observedFetchURLs: [String] = []
    private var observedContexts: [Data] = []
    private var modelIndex = 0
    private let contextOffset: Int
    init(searches: [[String: Any]], fetchedBody: String, draft: [String: Any], audit: [String: Any], planner: [String: Any]?) throws {
        if searches.isEmpty { searchReplies = [try JSONSerialization.data(withJSONObject: ["results": []])] }
        else {
            searchReplies = try stride(from: 0, to: searches.count, by: 4).map { offset in
                try JSONSerialization.data(withJSONObject: ["results": Array(searches[offset..<min(offset + 4, searches.count)])])
            }
        }
        fetchReply = try JSONSerialization.data(withJSONObject: ["content": fetchedBody])
        contextOffset = planner == nil ? 0 : 1
        models = try (planner.map { [$0, draft, audit] } ?? [draft, audit]).map { value in
            let content = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "usage": ["prompt_tokens": 500, "completion_tokens": 100]])
        }
    }
    var modelCalls: Int { lock.lock(); defer { lock.unlock() }; return modelIndex }
    var searchQueries: [String] { lock.lock(); defer { lock.unlock() }; return observedQueries }
    var fetchURLs: [String] { lock.lock(); defer { lock.unlock() }; return observedFetchURLs }
    var draftContext: [String: Any]? { context(at: contextOffset) }
    var auditContext: [String: Any]? { context(at: contextOffset + 1) }
    private func context(at index: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard observedContexts.indices.contains(index) else { return nil }
        return (try? JSONSerialization.jsonObject(with: observedContexts[index])) as? [String: Any]
    }
    func reply(to request: URLRequest) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
            data = body
        } else { data = Data() }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch request.url?.path {
        case "/v1/tools/search":
            let reply = searchReplies[observedQueries.count % searchReplies.count]
            observedQueries.append(body["query"] as? String ?? "")
            return reply
        case "/v1/tools/fetch": observedFetchURLs.append(body["url"] as? String ?? ""); return fetchReply
        case "/chat/completions":
            guard models.indices.contains(modelIndex) else { return nil }
            let messages = body["messages"] as? [[String: Any]] ?? []
            let context = messages.last?["content"] as? String ?? "{}"
            observedContexts.append(Data(context.utf8))
            defer { modelIndex += 1 }
            return models[modelIndex]
        default: return nil
        }
    }
}

private final class FlashStubRegistry: @unchecked Sendable {
    static let shared = FlashStubRegistry()
    private let lock = NSLock()
    private var values: [String: FlashStubState] = [:]
    func put(_ key: String, _ value: FlashStubState) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
    func get(_ key: String?) -> FlashStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
}

private final class FlashURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = FlashStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Flash-Offline-Test")),
              let data = state.reply(to: request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
