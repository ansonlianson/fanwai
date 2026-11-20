import Foundation

/// Values are reused until their actual inputs change. Cache storage is not
/// observable; only reading the source revisions subscribes a page to updates.
@MainActor final class ShopPageDerivedCache {
    struct Key: Equatable {
        let entityID: String
        let seed: Bool
        let catalog: Int
        let fetchedAt: Date?
        let leads: [Lead]
        let interests: Int
        let collections: [WorkID]
    }
    private var key: Key?
    private var inventory: [CrateItem] = []
    func items(for next: Key, make: () -> [CrateItem]) -> [CrateItem] {
        if key != next { inventory = make(); key = next }
        return inventory
    }
}

@MainActor final class ShopSelectionCache {
    struct Value { var saved: Set<String> = []; var queued: Set<String> = [] }
    private var revision = -1
    private var saved: [WorkID] = []
    private var next: WorkID?
    private var result = Value()
    func value(in library: Library) -> Value {
        let ids = library.listenLater + library.later
        guard revision != library.catalog.revision || saved != ids || next != library.next else { return result }
        revision = library.catalog.revision; saved = ids; next = library.next
        result.saved = Set(ids.map { SeedLibraryBridge.entity(for: $0, in: library).id })
        result.queued = Set(next.map { [SeedLibraryBridge.entity(for: $0, in: library).id] } ?? [])
        return result
    }
}
