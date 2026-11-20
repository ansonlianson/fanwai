import XCTest
import UIKit
@testable import Pianwai

@MainActor final class CrateFeaturedLayoutTests: XCTestCase {
    func testActualSizeLayoutStudies() {
        let cases: [(String, [SeedGraph.Kind])] = [("one-lp", [.album]), ("two-lp", [.album, .album]), ("three-lp", [.album, .album, .album]),
            ("five-lp", [.album, .album, .album, .album, .album]), ("people", [.person, .person, .person]), ("mixed", [.album, .person, .film])]
        for (name, kinds) in cases {
            let items = kinds.enumerated().map { i, kind in
                CrateItem(entity: .init(id: name + String(i), kind: kind, title: ["Distance in Static", "岩崎太整", "First Love 初恋"][i % 3], subtitle: "", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []), relation: "关联作品", path: ["root", name + String(i)])
            }
            let scene = CrateV3Scene(frame: .init(x: 0, y: 0, width: 390, height: 560))
            scene.reservedTop = 225
            let selected = items
            scene.configure(items: selected, entityID: name, reduceMotion: true, loading: false, categories: [])
            scene.layoutIfNeeded()
            for id in scene.interactiveIDs {
                let frame = scene.exposedFrame(id)!
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                let center = CGPoint(x: frame.midX, y: frame.midY)
                XCTAssertTrue(scene.hitObject(center) == id || scene.hitTest(center, with: nil) == scene.nameButtons[id], name + id)
            }
        }
    }
    func testContinuousStackRetainsEveryRealObjectAndPullPosition() throws {
        let kinds: [SeedGraph.Kind] = [.album, .person, .film, .song, .manga]
        let inventory = (0..<24).map { i in
            CrateItem(entity: .init(id: "stack-\(i)", kind: kinds[i % kinds.count], title: "作品 \(i)", subtitle: "", artworkAsset: nil,
                fallbackGlyph: nil, hook: "", actions: []), relation: "关联作品", path: ["root", "stack-\(i)"])
        }
        let scene = CrateV3Scene(frame: .init(x: 0, y: 0, width: 390, height: 560))
        scene.reservedTop = 225
        scene.configure(items: inventory, entityID: "continuous-layout", reduceMotion: true, loading: false, categories: [])
        scene.layoutIfNeeded()
        XCTAssertEqual(scene.objects.count, inventory.count)
        XCTAssertEqual(scene.detailedIDs.count, 3)
        let layers = scene.objects.mapValues { ObjectIdentifier($0.layer) }
        scene.browsing = true
        for i in inventory.indices {
            scene.moveStack(to: CGFloat(i))
            XCTAssertEqual(scene.objects.mapValues { ObjectIdentifier($0.layer) }, layers)
            XCTAssertLessThanOrEqual(scene.detailedIDs.count, 5)
            for object in scene.objects.values {
                XCTAssertLessThanOrEqual(abs(object.home.x) + object.size.width*object.home.scale/2, 158.01,
                    "Planted objects must remain inside the wooden sides")
            }
            let id = inventory[i].id
            let frame = try XCTUnwrap(scene.exposedFrame(id))
            XCTAssertGreaterThanOrEqual(frame.width, 44); XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(scene.interactiveIDs.contains(id))
            let point = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(scene.hitObject(point) == id || scene.hitTest(point, with: nil) == scene.nameButtons[id])
        }
        scene.moveStack(to: 10.25)
        let quarter = scene.objects[inventory[10].id]!.home
        scene.moveStack(to: 10.5)
        XCTAssertNotEqual(scene.objects[inventory[10].id]!.home, quarter, "The stack follows fractional finger travel, not pages")
        scene.moveStack(to: 10)
        let pose = scene.objects[inventory[10].id]!.home
        scene.take(inventory[10].id); scene.returnHeld()
        XCTAssertEqual(scene.windowIndex, 10)
        XCTAssertEqual(scene.objects[inventory[10].id]!.home, pose)
        scene.configure(items: Array(inventory.prefix(4)), entityID: "different-page", reduceMotion: true, loading: false, categories: [])
        XCTAssertNil(scene.heldID); XCTAssertFalse(scene.browsing); XCTAssertEqual(scene.browseCursor, 0)
        XCTAssertEqual(scene.objects.count, 4)
    }

    func testFeaturedSelectionKeepsFullInventoryAndAtMostOneOrdinaryMusicItem() {
        let inventory = (0..<8).map { i in
            CrateItem(entity: .init(id: "album-\(i)", kind: .album, title: "Album \(i)", subtitle: "", artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []), relation: "同一艺人", path: ["root", "person", "album-\(i)"])
        }
        XCTAssertEqual(CrateFeaturedSelection.items(inventory).count, 1)
        XCTAssertEqual(inventory.count, 8)
        let owned = CrateItem(entity: .init(id: "owned", kind: .album, title: "This album", subtitle: "", artworkAsset: nil,
            fallbackGlyph: nil, hook: "", actions: []), relation: "收录于", path: ["root", "owned"])
        XCTAssertEqual(CrateFeaturedSelection.items([owned] + inventory).map(\.id), ["owned"],
            "An album doorway must not be padded with generic records or editions")
    }

    func testFixedPanelCatalogNamesRemainSelectableAcrossContinuousSwitches() throws {
        func data(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json")))
        }
        struct PanelInput: Decodable {
            let title: String
            let country: String
            let selectedID: String?
            let payload: ITunesCatalogPayload?
        }
        let panel = try JSONDecoder().decode([PanelInput].self, from: data("p26-panel"))
        let known = try JSONDecoder().decode(CatalogSnapshot.self, from: data("p26-known-identities"))
        let suite = "P26.panel-layout." + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let scene = CrateV3Scene(frame: .init(x: 0, y: 0, width: 390, height: 560))
        scene.reservedTop = 225
        var checked = 0
        for row in panel {
            guard let payload = row.payload, let id = row.selectedID else { continue }
            let catalog = CatalogStore(cacheURL: nil)
            try catalog.merge(known); try catalog.merge(payload.materialize(country: row.country).snapshot)
            let library = Library(defaults: prefs, arguments: [], catalog: catalog)
            let root = "apple:song:" + id
            let inventory = PublicCrateInventory.browseItems(for: root, library: library).map { item in
                // The recorded catalog verifies real names/kinds/relations;
                // this geometry run deliberately exercises missing artwork.
                CrateItem(entity: .init(id: item.id, kind: item.entity.kind, title: item.entity.title,
                    subtitle: item.entity.subtitle, artworkAsset: nil, fallbackGlyph: nil, hook: "", actions: []),
                    relation: item.relation, path: item.path)
            }
            scene.configure(items: inventory, entityID: root, reduceMotion: true, loading: false, categories: [])
            scene.layoutIfNeeded()
            XCTAssertNil(scene.heldTitle.text, row.title)
            XCTAssertNil(scene.heldID, row.title)
            XCTAssertLessThanOrEqual(scene.interactiveIDs.count, 3)
            for id in scene.interactiveIDs {
                let frame = try XCTUnwrap(scene.exposedFrame(id), row.title)
                XCTAssertGreaterThanOrEqual(frame.width, 44, row.title)
                XCTAssertGreaterThanOrEqual(frame.height, 44, row.title)
                let point = CGPoint(x: frame.midX, y: frame.midY)
                XCTAssertTrue(scene.hitObject(point) == id || scene.hitTest(point, with: nil) == scene.nameButtons[id], row.title)
            }
            if let first = scene.order.first { scene.take(first) }
            checked += 1
        }
        XCTAssertEqual(checked, 29, "The unresolved Two Weeks identity must not be replaced")
    }
}
