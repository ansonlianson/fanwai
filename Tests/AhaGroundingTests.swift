import XCTest
@testable import Pianwai

/// AHA-PLAN §3.3: the code, not the model, decides what reaches the crate and the story.
final class AhaGroundingTests: XCTestCase {
    private func packet(title: String, creator: String, album: String = "", sources: [(String, String)]) -> ResearchMaterialPacket {
        ResearchMaterialPacket(topic: .init(id: "apple:song:1", title: title, creator: creator, album: album, layer: "recording"),
            queries: [], sources: sources.enumerated().map { index, item in
                ResearchSource(id: "S\(index + 1)", url: "https://example.org/\(index + 1)", title: item.0, publisher: "Example", text: item.1, purposes: [.lineage])
            }, fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 1, fetches: 0)
    }

    func testACoverCalledTheOriginalIsTurnedRoundNotShownAsOriginal() throws {
        let p = packet(title: "My Heart Will Go On", creator: "Céline Dion", sources: [("Song history",
            "My Heart Will Go On was recorded by Céline Dion in 1997. The song was covered by Kenny G on his album Greatest Hits.")])
        let reply = #"{"leads":[{"ref":"n1","name":"My Heart Will Go On","target_type":"recording","creator":"Kenny G"}],"relations":[{"from":"current","to":"n1","relation":"cover_of","why":"x","source_id":"S1","quote":"The song was covered by Kenny G on his album Greatest Hits."}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        // Kenny G's version covers the playing song; it is never the playing song's 原曲.
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["from"] as? String, "n1")
        XCTAssertEqual(kept.first?["to"] as? String, "current")
    }

    func testSameTitleByAnotherArtistWithoutAnyCueIsNotAnOriginal() throws {
        let p = packet(title: "Suzume", creator: "RADWIMPS", sources: [("list", "Suzume – RADWIMPS. Suzume – Shania Yan. Both appear in this playlist of songs.")])
        let reply = #"{"leads":[{"ref":"n1","name":"Suzume","target_type":"recording","creator":"Shania Yan"}],"relations":[{"from":"current","to":"n1","relation":"cover_of","why":"x","source_id":"S1","quote":"Suzume – RADWIMPS. Suzume – Shania Yan."}]}"#
        XCTAssertTrue(try ResearchWriter.groundRelations(reply, packet: p).relations.isEmpty)
    }

    func testCrossLanguageCoverWithAnOriginalCueIsKept() throws {
        let p = packet(title: "千千阙歌", creator: "陈慧娴", sources: [("千千阙歌",
            "《千千阙歌》是陈慧娴演唱的歌曲，原曲为近藤真彦的《夕焼けの歌》，由马浚伟作粤语词。")])
        let reply = #"{"leads":[{"ref":"n1","name":"夕焼けの歌","target_type":"recording","creator":"近藤真彦"}],"relations":[{"from":"current","to":"n1","relation":"cover_of","why":"粤语翻唱","source_id":"S1","quote":"原曲为近藤真彦的《夕焼けの歌》"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["relation"] as? String, "cover_of")
    }

    func testChineseActiveOrderTurnsTheEdgeRound() throws {
        let p = packet(title: "Suzume", creator: "RADWIMPS", sources: [("翻唱", "歌手Shania Yan翻唱了RADWIMPS的Suzume，这个版本在网上流传。")])
        let reply = #"{"leads":[{"ref":"n1","name":"Suzume","target_type":"recording","creator":"Shania Yan"}],"relations":[{"from":"current","to":"n1","relation":"cover_of","why":"x","source_id":"S1","quote":"歌手Shania Yan翻唱了RADWIMPS的Suzume"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.first?["from"] as? String, "n1")
        XCTAssertEqual(kept.first?["to"] as? String, "current")
    }

    func testIncomingCoversAndSamplesNeedNoOriginalCue() throws {
        let p = packet(title: "Plastic Love", creator: "竹内まりや", sources: [("covers", "Plastic Love by Mariya Takeuchi was covered by Friday Night Plans in 2018 and sampled by 9m88.")])
        let reply = #"{"leads":[{"ref":"n1","name":"Plastic Love","target_type":"recording","creator":"Friday Night Plans"}],"relations":[{"from":"n1","to":"current","relation":"cover_of","why":"翻唱","source_id":"S1","quote":"Plastic Love by Mariya Takeuchi was covered by Friday Night Plans in 2018"}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(reply, packet: p).relations.count, 1)
    }

    func testNamesMatchAsPagesPrintThem() throws {
        // Bracketed subtitle, 第2期/第二期, and a bilingual catalogue title.
        let heart = packet(title: "My Heart Will Go On (Love Theme from \"Titanic\")", creator: "Céline Dion", sources: [("Titanic", "My Heart Will Go On is the main theme song to James Cameron's film Titanic.")])
        let a = #"{"leads":[{"ref":"n1","name":"Titanic","target_type":"film","creator":"James Cameron"}],"relations":[{"from":"current","to":"n1","relation":"created_for","why":"主题曲","source_id":"S1","quote":"My Heart Will Go On is the main theme song to James Cameron's film Titanic."}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(a, packet: heart).relations.count, 1)
        let ao = packet(title: "青のすみか", creator: "キタニタツヤ", sources: [("青のすみか", "テレビアニメ『呪術廻戦』第二期「懐玉・玉折」編のオープニングテーマとしてリリースされた「青のすみか」。")])
        let b = #"{"leads":[{"ref":"t1","name":"呪術廻戦 第2期","target_type":"tv","creator":"MAPPA"}],"relations":[{"from":"current","to":"t1","relation":"created_for","why":"OP","source_id":"S1","quote":"テレビアニメ『呪術廻戦』第二期「懐玉・玉折」編のオープニングテーマとしてリリースされ"}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(b, packet: ao).relations.count, 1)
        let oto = packet(title: "オトノケ - Otonoke", creator: "Creepy Nuts", sources: [("ダンダダン", "Creepy Nutsの「オトノケ」はTVアニメ『ダンダダン』オープニングテーマ。")])
        let c = #"{"leads":[{"ref":"n1","name":"ダンダダン","target_type":"tv","creator":"サイエンスSARU"}],"relations":[{"from":"current","to":"n1","relation":"created_for","why":"OP","source_id":"S1","quote":"「オトノケ」はTVアニメ『ダンダダン』オープニングテーマ"}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(c, packet: oto).relations.count, 1)
    }

    func testMisencodedEndpointsAreDropped() throws {
        let p = packet(title: "ロキ", creator: "みきとP", sources: [("Roki", "《ロキ》由神田沙也加与绪方惠美翻唱的版本收录在神田的专辑中。“ロキ” was written by みきとP and Will Jennings.")])
        // A "cover" node that is the playing song itself (same title, same artist), and a credit pointing at a work.
        let reply = #"{"leads":[{"ref":"n2","name":"ロキ","target_type":"music_work","creator":"みきとP"},{"ref":"n3","name":"ロキ 原曲","target_type":"music_work","creator":"みきとP"}],"relations":[{"from":"n2","to":"current","relation":"cover_of","why":"x","source_id":"S1","quote":"由神田沙也加与绪方惠美翻唱的版本收录在神田的专辑中"},{"from":"current","to":"n3","relation":"composed_by","why":"x","source_id":"S1","quote":"“ロキ” was written by みきとP and Will Jennings."}]}"#
        XCTAssertTrue(try ResearchWriter.groundRelations(reply, packet: p).relations.isEmpty)
    }

    func testAWorkBasedOnTheSongIsNotTheSongsInspiration() throws {
        let p = packet(title: "ロキ", creator: "みきとP", sources: [("Roki", "小说《Roki 1：The Cursed Song》根据みきとP的歌曲《ロキ》改编，2019年出版。")])
        let reply = #"{"leads":[{"ref":"n1","name":"Roki 1：The Cursed Song","target_type":"book","creator":"みきとP"}],"relations":[{"from":"current","to":"n1","relation":"inspired_by","why":"x","source_id":"S1","quote":"小说《Roki 1：The Cursed Song》根据みきとP的歌曲《ロキ》改编"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.first?["from"] as? String, "n1")
        XCTAssertEqual(kept.first?["to"] as? String, "current")
    }

    func testALaterRemixIsNotWhatTheOriginalRemixes() throws {
        let p = packet(title: "稻香", creator: "周杰伦", sources: [("稻香", "《稻香》是周杰伦2008年的歌曲。2024年推出《稻香 (Remix)》版本。")])
        let reply = #"{"leads":[{"ref":"n1","name":"稻香 (Remix)","target_type":"recording","creator":"周杰伦"}],"relations":[{"from":"current","to":"n1","relation":"remix_of","why":"x","source_id":"S1","quote":"2024年推出《稻香 (Remix)》版本"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.first?["from"] as? String, "n1")
        XCTAssertEqual(kept.first?["to"] as? String, "current")
    }

    func testAQuoteFoundOnNoPageIsNoEvidenceEvenIfANameAppears() throws {
        let p = packet(title: "KICK BACK", creator: "米津玄師", sources: [("KICK BACK", "米津玄師の「KICK BACK」はTVアニメ『チェンソーマン』のオープニング・テーマ。")])
        let reply = #"{"leads":[{"ref":"n1","name":"チェンソーマン","target_type":"tv","creator":"MAPPA"}],"relations":[{"from":"current","to":"n1","relation":"created_for","why":"x","source_id":"S9","quote":"this sentence is not on any page at all"}]}"#
        XCTAssertTrue(try ResearchWriter.groundRelations(reply, packet: p).relations.isEmpty)
    }

    func testAVerbatimQuoteOnAnotherPageIsAcceptedAndTypesAreNotRewritten() throws {
        let p = packet(title: "KICK BACK", creator: "米津玄師", sources: [("other", "unrelated text about something else entirely"),
            ("KICK BACK", "米津玄師の「KICK BACK」はTVアニメ『チェンソーマン』のオープニング・テーマ。モーニング娘。の楽曲にインスパイアされた。")])
        let reply = #"{"leads":[{"ref":"n1","name":"チェンソーマン","target_type":"tv","creator":"MAPPA"},{"ref":"n2","name":"そうだ! We're ALIVE","target_type":"recording","creator":"モーニング娘。"}],"relations":[{"from":"current","to":"n1","relation":"created_for","why":"OP","source_id":"S1","quote":"TVアニメ『チェンソーマン』のオープニング・テーマ"},{"from":"current","to":"n1","relation":"inspired_by","why":"x","source_id":"S2","quote":"モーニング娘。の楽曲にインスパイアされた"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.first?["url"] as? String, "https://example.org/2")
        XCTAssertTrue(kept.contains { $0["relation"] as? String == "created_for" })
        // inspired_by is no longer turned into created_for.
        XCTAssertFalse(kept.contains { $0["relation"] as? String == "created_for" && $0["evidence_quote"] as? String == "モーニング娘。の楽曲にインスパイアされた" })
    }

    func testStoryNeedsEverySentenceSupported() {
        let p = packet(title: "Weight of the World", creator: "岡部啓一", sources: [("interview",
            "岡部啓一は、コンサートで未発表曲をいきなり演奏しても観客が戸惑うので、事前にネットで公開しようと横尾太郎さんに言われたと振り返った。急いで音源を仕上げたという。")])
        let supported = #"{"story":{"subject":"recording","sentences":[{"text":"冈部启一回忆，横尾太郎提出在音乐会上突然演奏没听过的新曲会让观众困惑，最好提前在网上公开。","evidence":[{"source_id":"S1","quote":"事前にネットで公開しようと横尾太郎さんに言われた"}]},{"text":"既然要发表，他只好赶着把音源做到能拿出手的程度，这首歌就是这样匆忙完成的，也定下了之后创作的方向和基调。","evidence":[{"source_id":"S1","quote":"急いで音源を仕上げたという"}]}]}}"#
        XCTAssertNotNil(ResearchWriter.groundStory(supported, packet: p))
        let oneUnsupported = supported.replacingOccurrences(of: "急いで音源を仕上げたという", with: "この一文は原文にない引用です")
        XCTAssertNil(ResearchWriter.groundStory(oneUnsupported, packet: p))
        let newNumber = supported.replacingOccurrences(of: "这首歌就是这样匆忙完成的", with: "这首歌在2017年匆忙完成")
        XCTAssertNil(ResearchWriter.groundStory(newNumber, packet: p))
        XCTAssertNil(ResearchWriter.groundStory(#"{"story":{"text":"没有逐句引文的旧格式故事一律不收。"}}"#, packet: p))
    }

    func testStoryToleratesQuoteSlipsAndNumbersPrintedOnTheCitedPage() {
        let p = packet(title: "杀死那个石家庄人", creator: "万能青年旅店", sources: [("报道",
            "乐队在2006年07月开始排练这首歌，董亚千说歌词写的是下岗工人的生活。录音[12]在石家庄的排练室完成，后来收进2010年的首张专辑。")])
        let reply = #"{"story":{"subject":"recording","sentences":[{"text":"乐队从2006年7月开始排练这首歌，董亚千说歌词写的是下岗工人的生活。","evidence":[{"source_id":"S1","quote":"董亚千说歌词写的是下岗工人的生活"}]},{"text":"录音在石家庄的排练室完成，后来收进了2010年发行的首张专辑里，成为乐队最广为人知的一首歌曲作品。","evidence":[{"source_id":"S1","quote":"录音在石家庄的排练室完成，后来收进2010年的首张专辑"}]}]}}"#
        // 07 → 7, the year sits elsewhere on the cited page, and the quote skips a footnote mark.
        XCTAssertNotNil(ResearchWriter.groundStory(reply, packet: p))
        // A year printed nowhere on the cited page still withholds the story.
        XCTAssertNil(ResearchWriter.groundStory(reply.replacingOccurrences(of: "2006年7月", with: "1999年7月"), packet: p))
    }

    func testStoryAboutAnotherVersionMovesToTheSong() {
        let p = packet(title: "青のすみか", creator: "キタニタツヤ", album: "青のすみか - EP", sources: [("interview",
            "劇場版総集編ではアコースティックバージョンに編曲を変えた。観客は結末を知っているので、切なく悲しい方向に寄せたと語った。")])
        let reply = #"{"story":{"subject":"recording","sentences":[{"text":"到了剧场版总集篇，这首歌改成了Acoustic版本，因为观众已经知道结局，他把编曲往更切实的悲伤一侧推。","evidence":[{"source_id":"S1","quote":"劇場版総集編ではアコースティックバージョンに編曲を変えた"}]},{"text":"他说观众看完正片已经知道结局，所以新版本要更加悲伤，连唱法也跟着一起改掉了，避免和作品产生违和。","evidence":[{"source_id":"S1","quote":"切なく悲しい方向に寄せたと語った"}]}]}}"#
        XCTAssertEqual(ResearchWriter.groundStory(reply, packet: p)?["subject"] as? String, "music_work")
    }

    func testDatabaseCoversAloneNeverSkipTheModel() {
        let root = WorkID(rawValue: "local:aha")!, piece = WorkID(rawValue: "local:piece")!
        let game = WorkID(rawValue: "local:game")!, novel = WorkID(rawValue: "local:novel")!
        let works: [Work] = [.init(id: root, title: "录音", creator: "", kind: "歌曲", art: "", detail: "", url: nil),
                             .init(id: piece, title: "原曲", creator: "", kind: "音乐作品", art: "", detail: "", url: nil),
                             .init(id: game, title: "游戏", creator: "", kind: "游戏", art: "", detail: "", url: nil),
                             .init(id: novel, title: "小说", creator: "", kind: "小说", art: "", detail: "", url: nil)]
        var result = DatabaseDiscoveryResult(snapshot: .init(works: works, relations: [
            .init(from: root, to: piece, predicate: .adaptedFrom, label: "改编自", inverseLabel: "改编版本", source: .init(title: "MusicBrainz", url: "https://musicbrainz.org"))]))
        // Slot 原作 still open.
        XCTAssertTrue(result.needsRelationships(root: root, title: "Song"))
        // A novel the song is based on fills 原作; nothing else is open.
        result.snapshot.relations.append(.init(from: root, to: novel, predicate: .adaptedFrom, label: "取材自", inverseLabel: "歌曲", source: .init(title: "Wikidata", url: "https://www.wikidata.org")))
        XCTAssertFalse(result.needsRelationships(root: root, title: "Song"))
        // A version must also reach the piece it performs; here it does (adaptedFrom → piece).
        XCTAssertFalse(result.needsRelationships(root: root, title: "Orchestra: Song"))
        result.snapshot.relations.removeAll { $0.to == piece }
        XCTAssertTrue(result.needsRelationships(root: root, title: "Orchestra: Song"))
        // A game soundtrack opens the 同门 slot, which only research fills.
        result.snapshot.relations.append(.init(from: root, to: game, predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐", source: .init(title: "VocaDB", url: "https://vocadb.net")))
        XCTAssertTrue(result.needsRelationships(root: root, title: "Song"))
    }

    func testStoryMentionsMustBePrintedAndNeverTheSongItself() {
        let p = packet(title: "Weight of the World", creator: "岡部啓一", sources: [("interview",
            "岡部啓一は、コンサートで未発表曲をいきなり演奏しても観客が戸惑うので、事前にネットで公開しようと横尾太郎さんに言われたと振り返った。急いで音源を仕上げたという。")])
        let reply = #"{"story":{"subject":"recording","sentences":[{"text":"冈部启一回忆，横尾太郎提出在音乐会上突然演奏没听过的新曲会让观众困惑，最好提前在网上公开。","evidence":[{"source_id":"S1","quote":"事前にネットで公開しようと横尾太郎さんに言われた"}]},{"text":"既然要发表，他只好赶着把音源做到能拿出手的程度，这首歌就是这样匆忙完成的，也定下了之后创作的方向和基调。","evidence":[{"source_id":"S1","quote":"急いで音源を仕上げたという"}]}],"mentions":["横尾太郎","冈部启一","尼尔：自动人形","Weight of the World"]}}"#
        let story = ResearchWriter.groundStory(reply, packet: p)
        XCTAssertEqual(story?["mentions"] as? [String], ["横尾太郎", "冈部启一"])
    }

    func testVersionsAreSearchedByTheSongTheyPerform() {
        let z = ResearchMaterials.versionParts("Zanarkand (FINAL FANTASY X Piano Collections Version)")
        XCTAssertEqual(z.bare, "Zanarkand"); XCTAssertEqual(z.origin, "FINAL FANTASY X"); XCTAssertTrue(z.isVersion)
        let w = ResearchMaterials.versionParts("Orchestra: Weight of the World (Emi Evans & J'Nique Nicole Vocals)")
        XCTAssertEqual(w.bare, "Weight of the World (Emi Evans & J'Nique Nicole Vocals)"); XCTAssertTrue(w.isVersion)
        XCTAssertFalse(ResearchMaterials.versionParts("My Heart Will Go On (Love Theme from \"Titanic\")").isVersion)
        let topic = ResearchTopic(id: "x", title: "Zanarkand (FINAL FANTASY X Piano Collections Version)", creator: "Hikaru Shirosu", album: "Piano Covers", layer: "recording")
        let plan = ResearchMaterials.queryPlan(topic)
        XCTAssertTrue(plan.first?.text.hasPrefix("Zanarkand FINAL FANTASY X") == true)
        XCTAssertFalse(plan[1].text.contains("Hikaru Shirosu"))
        XCTAssertTrue(ResearchMaterials.observedNameVariants(topic).contains("Zanarkand"))
    }

    func testYearsOnTheCitedPageTurnABackwardsInspirationRound() throws {
        let p = packet(title: "ロキ", creator: "みきとP", sources: [("Roki", "みきとPが2018年に発表した楽曲「ロキ」。2021年にはこの曲をモチーフにした小説『ロキ』が刊行された。")])
        func reply(_ from: Int, _ to: Int) -> String {
            #"{"leads":[{"ref":"n1","name":"ロキ","target_type":"book","creator":"みきとP"}],"relations":[{"from":"current","to":"n1","relation":"inspired_by","from_year":\#(from),"to_year":\#(to),"why":"x","source_id":"S1","quote":"2021年にはこの曲をモチーフにした小説『ロキ』が刊行された"}]}"#
        }
        // The song (2018) came first: the 2021 novel is inspired by the song, never the other way.
        let turned = try ResearchWriter.groundRelations(reply(2018, 2021), packet: p).relations
        XCTAssertEqual(turned.first?["from"] as? String, "n1")
        XCTAssertEqual(turned.first?["to"] as? String, "current")
        // Years the page does not print change nothing.
        let unprinted = try ResearchWriter.groundRelations(reply(1990, 2021), packet: p).relations
        XCTAssertEqual(unprinted.first?["from"] as? String, "current")
    }

    func testYearsNeverTurnACoverRound() throws {
        let p = packet(title: "千千阙歌", creator: "陈慧娴", sources: [("千千阙歌",
            "《千千阙歌》是陈慧娴1989年演唱的歌曲，原曲为近藤真彦的《夕焼けの歌》，2014年推出纪念版。")])
        let reply = #"{"leads":[{"ref":"n1","name":"夕焼けの歌","target_type":"recording","creator":"近藤真彦"}],"relations":[{"from":"current","to":"n1","relation":"cover_of","from_year":1989,"to_year":2014,"why":"粤语翻唱","source_id":"S1","quote":"原曲为近藤真彦的《夕焼けの歌》"}]}"#
        let kept = try ResearchWriter.groundRelations(reply, packet: p).relations
        XCTAssertEqual(kept.first?["from"] as? String, "current")
        XCTAssertEqual(kept.first?["to"] as? String, "n1")
    }

    func testARomanisedTitleFindsItsPageAndItsOtherSpelling() throws {
        // Long vowels: the catalogue says SAISHU … IMOTO, the page says Saishuu … Imouto.
        let p = packet(title: "SAISHU-KICHIKU IMOTO Flandre-S", creator: "COOL&CREATE", album: "TOHO STRIKE", sources: [
            ("Saishuu Kichiku Imouto Flandre-S", "Saishuu Kichiku Imouto Flandre-S by COOL&CREATE is an arrangement of U.N.オーエンは彼女なのか？ from 東方紅魔郷."),
            ("最終鬼畜妹フランドール・S", "最終鬼畜妹フランドール・S（COOL&CREATE）。原曲：U.N.オーエンは彼女なのか？"),
            ("楽譜", "最終鬼畜妹フランドール・Sの原曲はU.N.オーエンは彼女なのか？で、東方紅魔郷のEXボス曲。")])
        let folded = #"{"leads":[{"ref":"n1","name":"U.N.オーエンは彼女なのか？","target_type":"music_work","creator":"ZUN"}],"relations":[{"from":"current","to":"n1","relation":"arrangement_of","why":"原曲","source_id":"S1","quote":"is an arrangement of U.N.オーエンは彼女なのか？ from 東方紅魔郷"}]}"#
        XCTAssertFalse(try ResearchWriter.groundRelations(folded, packet: p).relations.isEmpty)
        // S3 never prints the catalogue title; the Japanese title counts because S2 prints it with the artist.
        let alias = #"{"current_names":["最終鬼畜妹フランドール・S"],"leads":[{"ref":"n1","name":"U.N.オーエンは彼女なのか？","target_type":"music_work","creator":"ZUN"}],"relations":[{"from":"current","to":"n1","relation":"arrangement_of","why":"原曲","source_id":"S3","quote":"最終鬼畜妹フランドール・Sの原曲はU.N.オーエンは彼女なのか？"}]}"#
        XCTAssertFalse(try ResearchWriter.groundRelations(alias, packet: p).relations.isEmpty)
        // A spelling no page ties to this artist or album is not this song.
        let loose = alias.replacingOccurrences(of: #""current_names":["最終鬼畜妹フランドール・S"]"#, with: #""current_names":["東方紅魔郷のEXボス曲"]"#)
            .replacingOccurrences(of: "最終鬼畜妹フランドール・Sの原曲はU.N.オーエンは彼女なのか？", with: "東方紅魔郷のEXボス曲")
        XCTAssertTrue(try ResearchWriter.groundRelations(loose, packet: p).relations.isEmpty)
    }

    func testAWorksOtherSpellingFindsItOnAnEnglishPage() throws {
        let p = packet(title: "Suzume (feat. Toaka)", creator: "RADWIMPS", sources: [
            ("Billboard", "RADWIMPS wrote the theme song Suzume, sung by Toaka, for Makoto Shinkai's film Suzume."),
            ("ビルボード", "新海誠監督の映画『すずめの戸締まり』の主題歌。")])
        let reply = #"{"leads":[{"ref":"n1","name":"すずめの戸締まり","aliases":["Suzume"],"target_type":"film","creator":"新海誠"}],"relations":[{"from":"current","to":"n1","relation":"created_for","why":"主题歌","source_id":"S1","quote":"RADWIMPS wrote the theme song Suzume, sung by Toaka, for Makoto Shinkai's film Suzume."}]}"#
        XCTAssertEqual(try ResearchWriter.groundRelations(reply, packet: p).relations.count, 1)
        // A spelling a database already gave becomes the name, so the reply's node and the database's are one card.
        let english = reply.replacingOccurrences(of: #""name":"すずめの戸締まり","aliases":["Suzume"]"#, with: #""name":"Suzume","aliases":["すずめの戸締まり"]"#)
        let known = try ResearchWriter.groundRelations(english, packet: p, knownNames: ["すずめの戸締まり"])
        XCTAssertEqual(known.leads.first?["name"] as? String, "すずめの戸締まり")
        XCTAssertEqual(known.relations.count, 1)
    }

    func testAMarkerMustBeTheQuotesOwnWordAndAWorkMadeFromTheSongIsTurnedRound() throws {
        // "sample di Gimme" is Italian for "sample of", not the English "sampled".
        let hung = packet(title: "Hung Up", creator: "Madonna", sources: [("Hung Up", "Hung Up di Madonna. Benny Andersson e Bjorn Ulvaeus degli Abba approvano il sample di Gimme! Gimme! Gimme! (A Man After Midnight) in cambio del 50% dei crediti.")])
        let a = #"{"leads":[{"ref":"n1","name":"Gimme! Gimme! Gimme! (A Man After Midnight)","target_type":"music_work","creator":"ABBA"}],"relations":[{"from":"current","to":"n1","relation":"samples","why":"采样","source_id":"S1","quote":"Benny Andersson e Bjorn Ulvaeus degli Abba approvano il sample di Gimme! Gimme! Gimme! (A Man After Midnight)"}]}"#
        let kept = try ResearchWriter.groundRelations(a, packet: hung).relations
        XCTAssertEqual(kept.first?["from"] as? String, "current")
        XCTAssertEqual(kept.first?["to"] as? String, "n1")
        // 「根據此曲改編的小說《X》」: the novel is made from the song.
        let roki = packet(title: "Roki", creator: "mikitoP", sources: [("Roki", "Roki是mikitoP的歌曲。根據此曲改編的小說《Roki 1：The Cursed Song》在2022年9月22日由Kadokawa出版。")])
        let b = #"{"leads":[{"ref":"n1","name":"Roki 1：The Cursed Song","target_type":"book","creator":"総夜ムカイ"}],"relations":[{"from":"current","to":"n1","relation":"inspired_by","why":"x","source_id":"S1","quote":"根據此曲改編的小說《Roki 1：The Cursed Song》在2022年9月22日由Kadokawa出版"}]}"#
        let turned = try ResearchWriter.groundRelations(b, packet: roki).relations
        XCTAssertEqual(turned.first?["from"] as? String, "n1")
        XCTAssertEqual(turned.first?["to"] as? String, "current")
    }

    func testClassicalMovementsAreSearchedByThePieceNotThePerformer() {
        let topic = ResearchTopic(id: "x", title: "Suite bergamasque: III. Clair de lune", creator: "让-伊夫・蒂博戴", album: "Debussy: Complete Works for Solo Piano Vol. 2", layer: "recording")
        let plan = ResearchMaterials.queryPlan(topic)
        XCTAssertTrue(plan.first?.text.hasPrefix("Clair de lune Suite bergamasque") == true)
        XCTAssertFalse(plan.prefix(4).contains { $0.text.contains("蒂博戴") })
        XCTAssertTrue(plan.contains { $0.purpose == .downstream && $0.text.contains("film") })
        XCTAssertTrue(ResearchMaterials.observedNameVariants(topic).contains("Clair de lune"))
        // An ordinary song with a number in its title keeps the ordinary plan.
        let pop = ResearchTopic(id: "y", title: "Mambo No. 5 (A Little Bit of...)", creator: "Lou Bega", album: "A Little Bit of Mambo", layer: "recording")
        XCTAssertTrue(ResearchMaterials.queryPlan(pop).first?.text.contains("Lou Bega") == true)
        // The work is found whichever catalogue numbers the page prints.
        let p = packet(title: "Suite bergamasque: III. Clair de lune", creator: "Jean-Yves Thibaudet", sources: [("Clair de lune",
            "Clair de lune is the third movement of Suite bergamasque by Claude Debussy, published in 1905.")])
        let reply = #"{"leads":[{"ref":"w1","name":"Suite bergamasque, L. 75, CD 82","movement":"III. Clair de lune","target_type":"music_work","creator":"Claude Debussy"}],"relations":[{"from":"current","to":"w1","relation":"performance_of","why":"演奏","source_id":"S1","quote":"Clair de lune is the third movement of Suite bergamasque by Claude Debussy"}]}"#
        XCTAssertEqual(try? ResearchWriter.groundRelations(reply, packet: p).relations.count, 1)
    }

    func testAHeavyStoryPacketIsTrimmedButKeepsEveryPage() {
        func source(_ i: Int, _ count: Int) -> ResearchSource {
            ResearchSource(id: "S\(i)", url: "https://example.org/\(i)", title: "t", publisher: "p", text: String(repeating: "字", count: count), purposes: [.identity])
        }
        func packet(_ counts: [Int]) -> ResearchMaterialPacket {
            ResearchMaterialPacket(topic: .init(id: "a", title: "T", creator: "C", album: "", layer: "recording"), queries: [],
                sources: counts.enumerated().map { source($0.offset + 1, $0.element) }, fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 5, fetches: 0)
        }
        // Within the limit nothing changes.
        XCTAssertEqual(ResearchWriter.storyMaterials(packet([3000, 3000, 3000])).sources.map(\.text.count), [3000, 3000, 3000])
        // Over it, short pages stay whole and the long ones share the rest; no page is dropped.
        let cut = ResearchWriter.storyMaterials(packet([3400, 3400, 3400, 3400, 3400, 1000, 600, 400]))
        XCTAssertEqual(cut.sources.map(\.id), ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"])
        XCTAssertEqual(cut.sources.map(\.text.count), [2000, 2000, 2000, 2000, 2000, 1000, 600, 400])
        // The model reads titles and text; addresses are not sent.
        XCTAssertFalse(ResearchWriter.storyPrompt(packet: cut).contains("example.org"))
        // The sibling call reads the passage that lists the theme songs, not the head of the page.
        let page = String(repeating: "前言。", count: 1000) + "エンディングテーマはずっと真夜中でいいのに。の「TAIDADA」。" + String(repeating: "后记。", count: 1000)
        let excerpt = ResearchWriter.siblingExcerpt(page)
        XCTAssertTrue(excerpt.contains("TAIDADA")); XCTAssertLessThanOrEqual(excerpt.count, 1600)
    }

    func testAWorkTheReplyForgotToListIsReadFromTheQuote() throws {
        let p = packet(title: "Piano: Weight of the World", creator: "冈部启一 & 榊原大", sources: [("Weight Of The World",
            "Weight of the World是冈部启一作曲的歌曲，作为动作角色扮演游戏《尼尔：机械纪元》主题曲于2017年3月29日全球发行。Piano: Weight of the World为钢琴版。")])
        let reply = #"{"leads":[{"ref":"m1","name":"Weight of the World","target_type":"music_work","creator":"MONACA"}],"relations":[{"from":"current","to":"m1","relation":"performance_of","why":"钢琴版","source_id":"S1","quote":"Piano: Weight of the World为钢琴版"},{"from":"m1","to":"g1","relation":"created_for","why":"游戏主题曲","source_id":"S1","quote":"作为动作角色扮演游戏《尼尔：机械纪元》主题曲于2017年3月29日全球发行"}]}"#
        let grounded = try ResearchWriter.groundRelations(reply, packet: p)
        XCTAssertTrue(grounded.leads.contains { $0["ref"] as? String == "g1" && $0["name"] as? String == "尼尔：机械纪元" && $0["target_type"] as? String == "game" })
        XCTAssertTrue(grounded.relations.contains { $0["to"] as? String == "g1" && $0["relation"] as? String == "created_for" })
        // No bracketed title, or no word for what kind of work it is: nothing is invented.
        let vague = reply.replacingOccurrences(of: "作为动作角色扮演游戏《尼尔：机械纪元》主题曲于2017年3月29日全球发行", with: "作曲的歌曲")
        XCTAssertFalse(try ResearchWriter.groundRelations(vague, packet: p).relations.contains { $0["to"] as? String == "g1" })
    }

    func testACoverNamedAfterItsSingerCarriesTheSongsTitleAndAClipIsNoInspiration() throws {
        let p = packet(title: "Hallelujah", creator: "Leonard Cohen", sources: [("Hallelujah", "Hallelujah by Leonard Cohen was covered by John Cale in 1991. 网友制作了手语版Hallelujah视频。")])
        let reply = #"{"leads":[{"ref":"n1","name":"John Cale","target_type":"recording","creator":"John Cale"},{"ref":"v1","name":"手语版Hallelujah","target_type":"video","creator":""}],"relations":[{"from":"n1","to":"current","relation":"cover_of","why":"翻唱","source_id":"S1","quote":"Hallelujah by Leonard Cohen was covered by John Cale in 1991"},{"from":"current","to":"v1","relation":"inspired_by","why":"衍生视频","source_id":"S1","quote":"网友制作了手语版Hallelujah视频"}]}"#
        let grounded = try ResearchWriter.groundRelations(reply, packet: p)
        XCTAssertEqual(grounded.leads.first { $0["ref"] as? String == "n1" }?["name"] as? String, "Hallelujah")
        XCTAssertEqual(grounded.relations.map { $0["relation"] as? String }, ["cover_of"])
    }

    func testAnArrangedVersionShowsTheSongItArrangesAsItsOwnWork() throws {
        XCTAssertTrue(ResearchMaterials.isArrangedVersion("Piano: Weight of the World"))
        XCTAssertTrue(ResearchMaterials.isArrangedVersion("Zanarkand (FINAL FANTASY X Piano Collections Version)"))
        XCTAssertFalse(ResearchMaterials.isArrangedVersion("Piano Sonata No. 8 in C minor, Op. 13"))
        XCTAssertFalse(ResearchMaterials.isArrangedVersion("千本桜 (Live)"))
        let p = packet(title: "Piano: Weight of the World", creator: "冈部启一 & 榊原大", sources: [("Piano Collections",
            "01.Piano: Weight of the World／Weight of the World 作曲者：岡部啓一 編曲者：榊原大。Weight of the Worldはゲーム『NieR:Automata』のエンディングテーマ。")])
        let reply = #"{"leads":[{"ref":"m1","name":"Weight of the World","target_type":"music_work","creator":"岡部啓一"},{"ref":"g1","name":"NieR:Automata","target_type":"game","creator":"スクウェア・エニックス"}],"relations":[{"from":"current","to":"m1","relation":"performance_of","why":"钢琴版","source_id":"S1","quote":"01.Piano: Weight of the World／Weight of the World"},{"from":"current","to":"m1","relation":"arrangement_of","why":"编曲","source_id":"S1","quote":"作曲者：岡部啓一 編曲者：榊原大"},{"from":"m1","to":"g1","relation":"created_for","why":"片尾曲","source_id":"S1","quote":"Weight of the Worldはゲーム『NieR:Automata』のエンディングテーマ"}]}"#
        let grounded = try ResearchWriter.groundRelations(reply, packet: p)
        func has(_ from: String, _ relation: String, _ to: String) -> Bool {
            grounded.relations.contains { $0["from"] as? String == from && $0["relation"] as? String == relation && $0["to"] as? String == to }
        }
        // The recording plays its own piano piece; that piece arranges the original, which leads to the game.
        XCTAssertEqual(grounded.leads.first { $0["ref"] as? String == "_piece" }?["name"] as? String, "Piano: Weight of the World")
        XCTAssertTrue(has("current", "performance_of", "_piece"))
        XCTAssertTrue(has("_piece", "arrangement_of", "m1"))
        XCTAssertTrue(has("m1", "created_for", "g1"))
        XCTAssertFalse(has("current", "performance_of", "m1"))
    }

    func testTheSongUnderItsOtherSpellingIsThePieceItPlays() throws {
        let p = packet(title: "SAISHU-KICHIKU IMOTO Flandre-S", creator: "COOL&CREATE", album: "TOHO STRIKE", sources: [
            ("最終鬼畜妹フランドール・S", "最終鬼畜妹フランドール・S（COOL&CREATE）はU.N.オーエンは彼女なのか？のアレンジ。")])
        let reply = #"{"current_names":["最終鬼畜妹フランドール・S"],"leads":[{"ref":"n0","name":"最終鬼畜妹フランドール・S","target_type":"music_work","creator":""},{"ref":"n1","name":"U.N.オーエンは彼女なのか？","target_type":"music_work","creator":"ZUN"}],"relations":[{"from":"current","to":"n0","relation":"arrangement_of","why":"同曲","source_id":"S1","quote":"最終鬼畜妹フランドール・S（COOL&CREATE）"},{"from":"n0","to":"n1","relation":"arrangement_of","why":"改编","source_id":"S1","quote":"最終鬼畜妹フランドール・S（COOL&CREATE）はU.N.オーエンは彼女なのか？のアレンジ"}]}"#
        let grounded = try ResearchWriter.groundRelations(reply, packet: p)
        XCTAssertTrue(grounded.relations.contains { $0["from"] as? String == "current" && $0["relation"] as? String == "performance_of" && $0["to"] as? String == "n0" })
        XCTAssertFalse(grounded.leads.contains { $0["ref"] as? String == "_piece" })
        XCTAssertTrue(grounded.relations.contains { $0["from"] as? String == "n0" && $0["to"] as? String == "n1" })
    }

    func testATransliteratedWesternCreditIsSearchedInEnglishByTheNamePagesPrint() {
        let topic = ResearchTopic(id: "x", title: "Defying Gravity", creator: "克莉丝汀‧肯诺维斯、Idina Menzel", album: "Wicked (Original 2003 Broadway Cast Recording)", layer: "recording")
        let plan = ResearchMaterials.queryPlan(topic)
        XCTAssertEqual(plan.first?.text, "Defying Gravity Idina Menzel")
        XCTAssertFalse(plan.contains { $0.text.contains("インタビュー") || $0.text.contains("肯诺维斯") })
        XCTAssertTrue(plan.contains { $0.text.contains("interview") })
        // A Japanese or Chinese artist keeps the searches in that language.
        let jp = ResearchTopic(id: "y", title: "KICK BACK", creator: "米津玄師", album: "KICK BACK - Single", layer: "recording")
        XCTAssertTrue(ResearchMaterials.queryPlan(jp).contains { $0.text.contains("原曲") })
        let kana = ResearchTopic(id: "z", title: "unravel", creator: "TK from 凛として時雨", album: "unravel", layer: "recording")
        XCTAssertTrue(ResearchMaterials.queryPlan(kana).contains { $0.text.contains("インタビュー") })
        XCTAssertFalse(ResearchMaterials.hasKana("让-伊夫・蒂博戴"))
    }
}
