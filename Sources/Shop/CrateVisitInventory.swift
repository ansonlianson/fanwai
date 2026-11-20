import Foundation

/// A visit keeps the order of the cards already on the shelf. Cards found later join at the end
/// of the bin by themselves (anson 2026-11-18: hiding them behind 「还有 N 件」 only cost a tap;
/// the hidden ones were often the good ones). Nothing already shown moves.
struct CrateVisitInventory {
    private(set) var root = ""
    private(set) var revealed: [String] = []

    mutating func observe(root: String, available: [String]) {
        if self.root != root { self.root = root; revealed = [] }
        let known = Set(revealed)
        revealed += Self.unique(available).filter { !known.contains($0) }
    }
    func visible(root: String, available: [String]) -> [String] {
        guard self.root == root, !revealed.isEmpty else { return Self.unique(available) }
        let current = Set(available), known = Set(revealed)
        return revealed.filter { current.contains($0) } + Self.unique(available).filter { !known.contains($0) }
    }
    /// Nothing is held back any more; kept for the bin's last tile, which now only offers 再翻一箱.
    func pending(root: String, available: [String]) -> Int { 0 }
    mutating func reveal(root: String, available: [String]) { observe(root: root, available: available) }
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
