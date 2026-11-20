import Foundation

/// A confirmed neighbor identity does not prove that every occurrence of its
/// name refers to that neighbor. Keep same-name works out of prose-wide links.
enum ContextEntityLinks {
    static func make(current: Work, neighbors: [Work]) -> [String: WorkID] {
        let currentName = normalized(current.title)
        let candidates = neighbors.filter { $0.id != current.id && normalized($0.title).count > 1 }
        let groups = Dictionary(grouping: candidates, by: { normalized($0.title) })
        var links: [String: WorkID] = [:]
        for (name, works) in groups {
            guard name != currentName, Set(works.map(\.id)).count == 1 else { continue }
            // Preserve the source spelling and the existing entity ID. Multiple
            // edges to the same entity do not make its name ambiguous.
            for work in works { links[work.title] = work.id }
        }
        return links
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
