import Foundation

/// Reviewed article entry points bound to an exact catalog entity. The article
/// still passes robots, current-song identity, paragraph and fact verification.
/// No generated prose or inferred catalog relationships live here.
enum ReviewedStorySources {
    static func sources(for id: WorkID) -> [Source] {
        guard id == .jane else { return [] }
        return [.init(title: "Billboard JAPAN · 米津玄师访谈",
                      url: "https://www.billboard-japan.com/special/detail/4982")]
    }
}
