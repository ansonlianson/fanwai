import Foundation

/// The introduction is literal text from the full story. No second generated
/// summary, missing names, or invitation to reread an identical paragraph.
struct StoryExcerpt {
    let text: String
    let hasMore: Bool

    init(_ body: String) {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefix = "", current = ""
        for character in body {
            current.append(character)
            if "。！？".contains(character) {
                if !prefix.isEmpty && StoryValidator.visualWidth(prefix + current) > 68 { break }
                prefix += current; current = ""
                if StoryValidator.visualWidth(prefix) >= 42 { break }
            }
        }
        let extra = StoryValidator.visualWidth(body) - StoryValidator.visualWidth(prefix)
        hasMore = !prefix.isEmpty && StoryValidator.visualWidth(body) >= 120 && extra >= 60
        text = hasMore ? prefix : body
    }
}
