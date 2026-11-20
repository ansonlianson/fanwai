import XCTest
@testable import Pianwai

@MainActor final class PublicSelectionTests: XCTestCase {
    private func prepared(_ number: String) async throws -> (CatalogStore, Library, PublicRelationService) {
        let service = ITunesCatalogService(transport: .init(loader: PublicRelationsFixture.load, limiter: .init()))
        let store = CatalogStore(cacheURL: nil, service: service)
        let response = try await service.lookup(number, country: "jp", entity: nil, kind: .songs)
        try store.merge(response.snapshot)
        let collector = PublicRelationService(loader: PublicRelationsFixture.load, directory: nil, paced: false)
        let artwork = WorkArtworkStore(service: NoSelectionArtwork(), directory: nil, officialService: .init(loader: { _ in throw URLError(.notConnectedToInternet) }))
        await store.preparePublicSelection(WorkID(rawValue: "apple:song:" + number)!, collector: collector, artwork: artwork)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PublicSelection-" + UUID().uuidString))
        return (store, Library(defaults: defaults, arguments: [], catalog: store), collector)
    }
    func testPoolFiveAndCreatorSixPreserveViaAndSeries() async throws {
        let (store, library, collector) = try await prepared("1840141274")
        let root = "apple:song:1840141274"
        let items = PublicCrateInventory.items(for: root, library: library)
        XCTAssertEqual(items.map(\.id), ["ushio", "apple:album:1840140991", "film", "bangumi:subject:551455", "bangumi:subject:529431"], store.lookupErrors.description)
        XCTAssertEqual(items[2].path, [root, "ushio", "film"])
        XCTAssertEqual(items[2].relation, "配乐")
        XCTAssertEqual(store.canonicalID(for: WorkID(rawValue: "bangumi:subject:470660")!), .film)
        await store.preparePublicSelection(.ushio, expanding: true,
            onMap: Set(items.map { SeedLibraryBridge.workID($0.id) }), excluding: [WorkID(rawValue: root)!, WorkID(rawValue: "apple:album:1840140991")!], collector: collector,
            artwork: WorkArtworkStore(service: NoSelectionArtwork(), directory: nil, officialService: .init(loader: { _ in throw URLError(.notConnectedToInternet) })))
        let picks = PublicCrateInventory.creatorWorks(.ushio, catalog: store, limit: 6, musicLimit: 2)
        XCTAssertEqual(picks.map { store.work($0.other(than: .ushio)).bangumiID }, ["470660","551455","529431","515869","493016","443168"])
        XCTAssertFalse(picks.contains { ["616930", "580872", "321885", "467461", "441795"].contains(store.work($0.other(than: .ushio)).bangumiID ?? "") })
        let graph = PublicCrateInventory.graph(root: root, expanding: [root,"ushio"], library: library)
        var map = RelationMapModel(root: root); _ = map.expand(root, graph: graph)
        let before = map.nodes.mapValues(\.position)
        _ = map.expand("ushio", graph: graph)
        for (id, point) in before { XCTAssertEqual(map.nodes[id]?.position, point) }
        XCTAssertTrue(map.edges.contains { $0.from == "ushio" && $0.to == "film" && $0.label == "配乐" })
        XCTAssertFalse(map.edges.contains { $0.from == root && $0.to == "film" })
        XCTAssertEqual(items[3].entity.title, "春夏秋冬代行者 春の舞")
    }
    func testDiverSingleStaysInListButNotCrateOrMap() async throws {
        let (store, library, _) = try await prepared("6803304739")
        let root = WorkID(rawValue: "apple:song:6803304739")!
        let items = PublicCrateInventory.items(for: root.rawValue, library: library)
        XCTAssertEqual(items.first?.id, "apple:artist:1779486576")
        XCTAssertEqual(items.map(\.id), ["apple:artist:1779486576", "apple:song:6778229289", "apple:song:1824577027", "apple:song:1791458949"], store.lookupErrors.description)
        for number in ["6803304740", "6803304741", "1824577032", "1824577033", "1808349571", "1791458954", "1791458955", "1779738295"] {
            let id = WorkID(rawValue: "apple:song:" + number)!
            XCTAssertFalse(items.contains { $0.id == id.rawValue })
            XCTAssertNotNil(store.works[id], "Selection must preserve every catalog identity")
            XCTAssertEqual(store.canonicalID(for: id), id)
        }
        XCTAssertFalse(items.contains { $0.id == "apple:album:6803304738" })
        XCTAssertEqual(items.last?.path.count, 3)
        XCTAssertTrue(PublicCrateInventory.directEdges(root, catalog: store).contains { $0.other(than: root).rawValue == "apple:album:6803304738" })
        let graph = PublicCrateInventory.graph(root: root.rawValue, expanding: [root.rawValue], library: library)
        XCTAssertEqual(graph.outgoing(from: root.rawValue).map(\.to), items.map(\.id))
        XCTAssertFalse(graph.outgoing(from: root.rawValue).contains { $0.to == "apple:album:6803304738" })
    }
    func testObjectInkIsStableAndAdjacentLayersDiffer() {
        let ids = (0..<60).map { "bangumi:subject:\($0)" }
        let first = ObjectInk.indices(ids)
        XCTAssertEqual(first, ObjectInk.indices(ids))
        for (a,b) in zip(ids,ids.dropFirst()) { XCTAssertNotEqual(first[a],first[b]) }
        for id in ids { XCTAssertTrue((0..<5).contains(ObjectInk.index(id))) }
        let collision = ids.first { ObjectInk.index($0) == ObjectInk.index(ids[0]) && $0 != ids[0] }!
        XCTAssertEqual(ObjectInk.indices([ids[0],collision])[collision], (ObjectInk.index(collision)+1)%5)
    }
    func testAlbumOrderTracksAndLayerLimit() async throws {
        let (store, library, collector) = try await prepared("1840141274")
        let id = WorkID(rawValue: "apple:album:1840140991")!
        await store.preparePublicSelection(id, collector: collector, artwork: WorkArtworkStore(service: NoSelectionArtwork(), directory: nil, officialService: .init(loader: { _ in throw URLError(.notConnectedToInternet) })))
        let items = PublicCrateInventory.items(for: id.rawValue, library: library)
        XCTAssertEqual(items.first?.id, "ushio")
        XCTAssertLessThanOrEqual(items.count, 5)
        // An album page shows one of its own tracks at most, and never offers
        // another track of the same album as "another work" by the artist.
        let tracks = items.filter { store.work(SeedLibraryBridge.workID($0.id)).albumID == id }
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.relation, "收录歌曲")
        XCTAssertTrue(items.contains { $0.id == "film" })
    }
    func testMappingOriginalNamesAndSingleCriteria() throws {
        XCTAssertEqual(PublicRelationService.bangumiLabel("艺术家", type: 3), "发行作品")
        XCTAssertNil(PublicRelationService.bangumiLabel("艺术家", type: 2))
        XCTAssertEqual(PublicRelationService.bangumiLabel("主题歌演出", type: 2), "演唱")
        XCTAssertEqual(PublicRelationService.bangumiLabel("书籍", type: 1), "相关书籍")
        let row = try JSONDecoder().decode(PublicBangumiRelation.self, from: Data(#"{"id":123,"name":"Original","name_cn":"中文","type":2}"#.utf8))
        XCTAssertEqual(row.title, "Original")
        var album = Work(id: .poolAlbum, title: "Work - Single", creator: "", kind: "专辑", art: "", detail: "", url: nil)
        XCTAssertTrue(PublicCrateInventory.isSingle(album))
        album = Work(id: .poolAlbum, title: "Work", creator: "", kind: "专辑", art: "", detail: "", url: nil, catalogTrackCount: 1)
        XCTAssertTrue(PublicCrateInventory.isSingle(album))
        album.catalogTrackCount = 2; XCTAssertFalse(PublicCrateInventory.isSingle(album))
    }
    func testStrongestCreditAndConflictingIdentityDoNotDuplicateOrMerge() throws {
        let store = CatalogStore(cacheURL: nil)
        let id = WorkID(rawValue: "bangumi:subject:470660")!
        let film = Work(id: id, title: "Raw name", creator: "", kind: "动画", art: "", detail: "", url: nil, linkedCreatorIDs: [], bangumiID: "470660")
        let source = Source(title: "Bangumi", url: "https://api.bgm.tv/v0/persons/14186/subjects")
        try store.merge(.init(works: [film], relations: ["演唱", "作曲"].map {
            RelationEdge(from: .ushio, to: id, predicate: .publicRelation, label: $0, inverseLabel: $0, source: source)
        }))
        let targets = PublicCrateInventory.directEdges(.ushio, catalog: store).filter { $0.other(than: .ushio) == .film }
        XCTAssertEqual(targets.count, 1); XCTAssertEqual(targets.first?.label(from: .ushio), "作曲")
        var conflicting = film; conflicting.knowledgeID = "Q1"
        XCTAssertThrowsError(try store.merge(.init(works: [conflicting], relations: [])))
        XCTAssertEqual(store.work(.film).knowledgeID, "Q123906765")
    }
    func testFitUsesMeasuredAvailableSpaceAndKeepsWorldPositions() {
        var map = RelationMapModel(root: "pool")
        _ = map.expand("pool", graph: SeedNowContent.connectionGraph)
        let original = map.nodes
        let area = CGRect(x: 12, y: 166, width: 305, height: 310)
        let camera = map.fittedCamera(ids: map.order, viewport: .init(width: 393, height: 852), available: area)
        for node in map.nodes.values {
            let center = camera.project(node.position)
            XCTAssertGreaterThanOrEqual(center.x - 54*camera.scale, area.minX)
            XCTAssertLessThanOrEqual(center.x + 54*camera.scale, area.maxX)
            XCTAssertGreaterThanOrEqual(center.y - 52*camera.scale, area.minY)
            XCTAssertLessThanOrEqual(center.y + 100*camera.scale, area.maxY)
        }
        XCTAssertEqual(original, map.nodes)
    }
}
private struct NoSelectionArtwork: WorkArtworkFetching {
    func fetch(qid: String) async throws -> WorkArtworkResponse { .init(qid: qid, artwork: nil) }
}
