import XCTest
@testable import Pianwai

/// 同门 (AHA-PLAN §3.2–3.4): another song made for the same show, at most two.
@MainActor final class AhaSiblingTests: XCTestCase {
    private func packet(_ text: String) -> ResearchMaterialPacket {
        ResearchMaterialPacket(topic: .init(id: "apple:song:1", title: "紅蓮華", creator: "LiSA", album: "紅蓮華 - Single", layer: "recording"),
            queries: [], sources: [ResearchSource(id: "S1", url: "https://example.org/kimetsu", title: "鬼滅の刃 (アニメ)", publisher: "Example",
                text: text, purposes: [.context])], fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 1, fetches: 0)
    }
    private let page = "テレビアニメ『鬼滅の刃』竈門炭治郎 立志編のオープニングテーマはLiSAの「紅蓮華」、エンディングテーマはFictionJunction feat. LiSAの「from the edge」。挿入歌は椎名豪の「竈門炭治郎のうた」。"

    func testSiblingsNeedAQuoteThatNamesThemAndNeverIncludeTheCurrentSong() {
        let reply = #"{"siblings":[{"name":"紅蓮華","creator":"LiSA","role":"op","source_id":"S1","quote":"オープニングテーマはLiSAの「紅蓮華」"},{"name":"from the edge","creator":"FictionJunction feat. LiSA","role":"ed","source_id":"S1","quote":"エンディングテーマはFictionJunction feat. LiSAの「from the edge」"},{"name":"竈門炭治郎のうた","creator":"椎名豪","role":"insert","source_id":"S1","quote":"挿入歌は椎名豪の「竈門炭治郎のうた」"},{"name":"残響散歌","creator":"Aimer","role":"op","source_id":"S1","quote":"この引用はページにありません残響散歌"}]}"#
        let found = ResearchWriter.groundSiblings(reply, packet: packet(page), work: "鬼滅の刃", workRef: "n1")
        XCTAssertEqual(found.leads.map { $0["name"] as? String }, ["from the edge", "竈門炭治郎のうた"])
        XCTAssertEqual(found.relations.first?["to"] as? String, "n1")
        XCTAssertEqual(found.relations.first?["why"] as? String, "同一部作品的片尾曲")
    }

    func testOneCharacterTitlesAndWorkAliases() {
        let jp = "『呪術廻戦』第2期「懐玉・玉折」オープニング・テーマ：キタニタツヤ “青のすみか”、エンディング・テーマ：崎山蒼志 “燈”"
        let reply = #"{"siblings":[{"name":"燈","creator":"崎山蒼志","role":"ed","source_id":"S1","quote":"エンディング・テーマ：崎山蒼志 “燈”"}]}"#
        let ao = ResearchMaterialPacket(topic: .init(id: "apple:song:2", title: "青のすみか", creator: "キタニタツヤ", album: "", layer: "recording"),
            queries: [], sources: [ResearchSource(id: "S1", url: "https://example.org/jjk", title: "呪術廻戦", publisher: "Example", text: jp, purposes: [.context])],
            fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 1, fetches: 0)
        XCTAssertEqual(ResearchWriter.groundSiblings(reply, packet: ao, work: "Jujutsu Kaisen", workRef: "n1", workAliases: ["呪術廻戦"]).leads.count, 1)
        XCTAssertTrue(ResearchWriter.groundSiblings(reply, packet: ao, work: "Jujutsu Kaisen", workRef: "n1").leads.isEmpty)
    }

    func testSiblingLabels() {
        XCTAssertEqual(DiscoveryPathPresentation.siblingLabel(quote: "エンディングテーマはFictionJunction feat. LiSAの「from the edge」"), "同作 ED")
        XCTAssertEqual(DiscoveryPathPresentation.siblingLabel(quote: "オープニングテーマは「残響散歌」"), "同作 OP")
        XCTAssertEqual(DiscoveryPathPresentation.siblingLabel(quote: "挿入歌は「竈門炭治郎のうた」"), "同作插曲")
    }

    func testCrateShowsAtMostTwoSiblingsOfTheShowTheSongWasMadeFor() throws {
        func id(_ name: String) -> WorkID { WorkID(rawValue: "test:aha:" + name)! }
        func work(_ name: String, _ layer: DiscoveryIdentity.Layer) -> Work {
            Work(id: id(name), title: name, creator: "Creator", kind: DiscoveryIdentity(layer: layer, canonicalTitle: name).displayKind,
                 art: "", detail: "", url: nil, discovery: .init(layer: layer, canonicalTitle: name))
        }
        func edge(_ a: String, _ b: String, quote: String) -> RelationEdge {
            .init(from: id(a), to: id(b), predicate: .soundtrackOf, label: "为此而作", inverseLabel: "原声作品",
                  source: .init(title: "线索", detail: quote, url: "https://example.org/kimetsu", evidenceQuote: quote), researchRoot: id("root"))
        }
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [work("root", .recording), work("show", .tv), work("ed", .recording), work("insert", .recording), work("op2", .recording)],
            relations: [edge("root", "show", quote: "オープニングテーマはLiSAの「紅蓮華」"),
                        edge("ed", "show", quote: "エンディングテーマは「from the edge」"),
                        edge("insert", "show", quote: "挿入歌は「竈門炭治郎のうた」"),
                        edge("op2", "show", quote: "第2期オープニングテーマは「残響散歌」")]))
        let leads = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(leads.first?.id, id("show").rawValue)
        let siblings = leads.filter { $0.label.hasPrefix("同作") }
        XCTAssertEqual(siblings.count, 2)
        XCTAssertTrue(Set(siblings.map(\.label)).isSubset(of: ["同作 ED", "同作插曲", "同作 OP"]))
        XCTAssertEqual(leads.first { $0.id == id("ed").rawValue }.map(\.label) ?? "同作 ED", "同作 ED")
    }
}
