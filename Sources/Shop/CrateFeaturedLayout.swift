import UIKit

/// Selection does not discard the inventory. It only chooses a small entry
/// display; browsing keeps every exact work ID.
enum CrateFeaturedSelection {
    static func items(_ inventory: [CrateItem], limit: Int = 3) -> [CrateItem] {
        func rank(_ item: CrateItem) -> Int {
            if [.film, .tv, .book, .manga, .video].contains(item.entity.kind) { return 0 }
            if item.hasStory || SeedNowContent.rankedStoryIDs.contains(item.id) { return 1 }
            if [.person, .group].contains(item.entity.kind) { return 2 }
            if item.path.count <= 2 && item.relation != "同一艺人" { return 3 }
            return 4
        }
        var ordinary = false, selected: [CrateItem] = []
        let ordered = inventory.enumerated().sorted {
            let a = rank($0.element), b = rank($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }
        for (_, item) in ordered {
            let music = [.song, .album].contains(item.entity.kind)
            let ordinaryMusic = music && !item.hasStory && (rank(item) == 4 || ["作品", "发行作品", "演唱"].contains(item.relation))
            if ordinaryMusic {
                // An owned album already gives this page a music doorway.
                // Do not fill the remaining place with another edition or a
                // generic same-artist record; it remains in the full inventory.
                if ordinary || selected.contains(where: { $0.entity.kind == .album }) { continue }
                ordinary = true
            }
            selected.append(item)
            if selected.count == max(1, min(3, limit)) { break }
        }
        return selected

    }
}

/// The first selection is in front, companions in two distinct side lanes.
/// Pose scales belong to the scene; pull/open interpolation starts from these.
enum CrateFeaturedLayout {
    static func pose(index: Int, count: Int) -> CrateV3Pose {
        if count == 1 { return .init(x: 0, z: -18, rx: 5, scale: 0.94) }
        if count == 2 { return .init(x: index == 0 ? -84 : 84, z: -30, rx: 5, rz: index == 0 ? -2 : 2, scale: 0.72) }
        if index == 0 { return .init(x: 0, z: 0, rx: 4, scale: 0.76) }
        return .init(x: index == 1 ? -116 : 116, z: -88, rx: 8, rz: index == 1 ? -4 : 4, scale: 0.62)
    }
}
