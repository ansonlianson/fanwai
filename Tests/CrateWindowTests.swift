import XCTest
@testable import Pianwai

final class CrateWindowTests: XCTestCase {
    func testAllFourteenItemsHaveAccessibleSlotsAndPersistedPosition() throws {
        let items = Array(SeedGraph.bundled.entities.prefix(14)).map { CrateItem(entity: $0, relation: "关联作品", path: [$0.id]) }
        let pages = CrateWindow.pages(items)
        XCTAssertEqual(pages.map { $0.items.count }, [5, 5, 4])
        XCTAssertEqual(pages.flatMap { $0.items.map(\.id) }, items.map(\.id))
        XCTAssertEqual(CrateWindow.slot(of: items[10].id, items: items), 0)
        let name = "Pianwai.CrateWindowTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        CrateWindowPosition.save(pages[2].id, entityID: "pool", defaults: defaults)
        XCTAssertEqual(CrateWindowPosition.read(entityID: "pool", items: items, defaults: defaults), pages[2].id)
        XCTAssertEqual(RecordCrateLayout(count: 14, availableHeight: 260).height, RecordCrateLayout(count: 5, availableHeight: 260).height)
    }
}
