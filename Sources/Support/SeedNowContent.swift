import Foundation

/// Literal, authored copy from SPEC §5.4 and the approved HTML prototype.
/// Raw authored fixtures. Display only after the P5 validator/provider accepts them.
enum SeedNowContent {
    static func contains(_ id: String) -> Bool { entity(id) != nil }
    // Metadata only: ranking must never instantiate the story payloads.
    static let rankedStoryIDs: Set<String> = ["pool", "jane", "actor", "utada", "olkmv"]

    static func stories(for id: String) -> [Story] {
        switch id {
        case "pool":
            return [
                Story(id: "pool-main", entityID: id, title: "两年前，它是先导片没用上的 B 方案",
                      body: "2023 年做《蕾塞篇》先导 PV 时，牛尾宪辅准备的 B 方案就是这首，私下叫它「我们的歌」。后来它被放进电次和蕾塞在泳池的那场戏。",
                      relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "Real Sound 访谈", url: "https://realsound.jp/2025/10/post-2167153_2.html")),
                Story(id: "pool-suite", entityID: id, title: "说好拆成几段，最后还是一整首",
                      body: "和导演商量时，原计划是把它切成几段短曲分开用。做到最后，它还是作为一整首组曲留在了电影里。",
                      relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "Real Sound 访谈", url: "https://realsound.jp/2025/10/post-2167153_2.html"))
            ]
        case "jane":
            return [Story(id: "jane-main", entityID: id, title: "写到一半，米津玄师觉得只能请宇多田光来唱",
                          body: "开始写时他没想好请谁唱。歌声放进来的那一刻，他说自己倒吸了一口气。",
                          relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "THE FIRST TIMES", url: "https://www.thefirsttimes.jp/news/0000668201/"))]
        case "actor":
            return [Story(id: "actor-main", entityID: id, title: "写《Actor》时，几田莉拉想到的是她妈妈",
                          body: "她说妈妈一直努力演好「母亲」这个角色。她由此觉得，扮演也可以是出于爱。",
                          relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "几田莉拉官方访谈", url: "https://lilasikuta.jp/laugh/"))]
        case "utada":
            return [Story(id: "utada-main", entityID: id, title: "EVA 四部新剧场版的主题曲，都是她唱的",
                          body: "从 2007 年的《Beautiful World》到 2021 年的《One Last Kiss》，十四年里庵野秀明的四部新剧场版一直用她的歌收尾。",
                          relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "福音战士官方网站", url: "https://www.evangelion.jp/news/shin_themesong/"))]
        case "olkmv":
            return [Story(id: "olkmv-main", entityID: id, title: "《终》上映当晚，庵野秀明亲自导演的 MV 首播",
                          body: "20 天播放量破 2000 万，是宇多田光所有 MV 里最快的一支。",
                          relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "音楽ナタリー", url: "https://natalie.mu/music/news/419206"))]
        // Additional literal copy from v4 STORY; absent links stay absent.
        case "film":
            return [Story(id: "film-main", entityID: id, title: "牛尾宪辅、米津玄师和宇多田光，都在这部电影里", body: "配乐是牛尾宪辅，片尾曲《JANE DOE》由米津玄师写、宇多田光唱。", relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "官方网站", url: ""))]
        case "ushio":
            return [Story(id: "ushio-main", entityID: id, title: "TV 版《电锯人》、《声之形》、《恶魔人 Crybaby》都是他配的乐", body: "", relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "", url: ""))]
        case "manga":
            return [Story(id: "manga-main", entityID: id, title: "蕾塞的故事在原作第一部的后半段", body: "电影只讲了这一段。", relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "", url: ""))]
        case "yonezu":
            return [Story(id: "yonezu-main", entityID: id, title: "他给《电锯人》写过三首：KICK BACK、IRIS OUT、JANE DOE", body: "", relatedEntityIDs: connections(id).map { $0.entity.id }, source: Source(title: "", url: ""))]
        default: return []
        }
    }
    static func entity(_ id: String) -> SeedGraph.Entity? { SeedGraph.bundled[id] ?? extras.first { $0.id == id } }
    static let extras: [SeedGraph.Entity] = [
        .init(id: "actor", kind: .song, title: "Actor", subtitle: "几田莉拉", artworkAsset: "review-actor", fallbackGlyph: nil,
              hook: "写《Actor》时，几田莉拉想到的是她妈妈", actions: ["下一首播放", "稍后听"]),
        .init(id: "ikuta", kind: .person, title: "几田莉拉", subtitle: "词曲演唱", artworkAsset: nil, fallbackGlyph: "几", hook: "", actions: []),
        .init(id: "spy", kind: .tv, title: "间谍过家家 第三季", subtitle: "片尾曲", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: ["想看"]),
        .init(id: "yoasobi", kind: .group, title: "YOASOBI", subtitle: "几田莉拉是主唱", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []),
        .init(id: "actormv", kind: .video, title: "Actor MV", subtitle: "官方 MV", artworkAsset: "review-actor", fallbackGlyph: nil, hook: "", actions: ["稍后看"])
    ]
    static var connectionGraph: SeedGraph {
        let graph = SeedGraph.bundled
        let actorEdges = connections("actor").map { SeedGraph.Relation(from: "actor", to: $0.entity.id, label: $0.label) }
        let additions = ReviewedRelations.browsingEdges.filter { edge in
            !graph.relations.contains { $0.from == edge.from && $0.to == edge.to }
        }
        return SeedGraph(version: graph.version, root: graph.root, entities: graph.entities + extras, relations: graph.relations + actorEdges + additions)
    }
    static func metadata(_ id: String) -> String? {
        switch id {
        case "pool": "summer's end，2025"
        case "actor": "Laugh，2025"
        case "utada": "从《JANE DOE》走到这里"
        default: nil
        }
    }
    static func connections(_ id: String) -> [(entity: SeedGraph.Entity, label: String)] {
        if id == "actor" {
            return zip(["ikuta", "spy", "yoasobi", "actormv"], ["词曲演唱", "片尾曲", "所在组合", "官方 MV"])
                .compactMap { key, label in entity(key).map { ($0, label) } }
        }
        if id == "utada" {
            return zip(["olk", "anno", "jane", "distance"], ["词曲演唱", "合作", "演唱", "专辑"])
                .compactMap { key, label in entity(key).map { ($0, label) } }
        }
        return connectionGraph.outgoing(from: id).compactMap { edge in entity(edge.to).map { ($0, edge.label) } }
    }
}

struct NowStation: Identifiable, Sendable {
    let entity: SeedGraph.Entity
    let reason: String
    let path: [String]
    var id: String { entity.id }
}
