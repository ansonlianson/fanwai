import CoreFoundation
import UIKit

/// Presentation only: preserve words on a small printed insert. Catalog names
/// and search identities remain untouched.
@MainActor enum PrintedCoverTypography {
    struct Layout { let lines: [String]; let fontSize: CGFloat }
    private static var cache: [String: Layout] = [:]
    static func layout(_ title: String, width: CGFloat, height: CGFloat) -> Layout {
        let key = title + "|\(Int(width * 10))|\(Int(height * 10))"
        if let saved = cache[key] { return saved }
        let result = makeLayout(title, width: width, height: height)
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result; return result
    }
    private static func makeLayout(_ title: String, width: CGFloat, height: CGFloat) -> Layout {
        // Five full-width characters at the starting size leave room for
        // complete short CJK names before the 0.6 scaling floor is reached.
        let tokens = words(title), base = min(18, max(8, width * 0.20))
        let minimum = base * 0.6
        func measure(_ text: String, _ size: CGFloat) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width
        }
        func join(_ left: String, _ right: String) -> String {
            let latin = left.last?.isASCII == true && right.first?.isASCII == true
            return left + (latin ? " " : "") + right
        }
        func pack(_ size: CGFloat, truncate: Bool) -> [String]? {
            var lines: [String] = [], current = ""
            for token in tokens {
                let next = join(current, token)
                if measure(next, size) <= width { current = next; continue }
                if !current.isEmpty { lines.append(current); current = "" }
                guard lines.count < 3 else {
                    if truncate {
                        while let last = lines.last, measure(last + "…", size) > width {
                            lines[lines.count - 1].removeLast()
                            if lines.last?.isEmpty == true { break }
                        }
                        lines[lines.count - 1] += "…"; return lines
                    }
                    return nil
                }
                guard measure(token, size) <= width else { return truncate ? lines + ["…"] : nil }
                current = token
            }
            if !current.isEmpty { lines.append(current) }
            guard lines.count <= 3, CGFloat(lines.count) * UIFont.systemFont(ofSize: size, weight: .semibold).lineHeight <= height else { return nil }
            if !truncate && lines.count > 1 && lines.contains(where: { $0.count == 1 && $0.first?.isASCII == false }) { return nil }
            return lines
        }
        for size in stride(from: base, through: minimum, by: -0.5) {
            if let lines = pack(size, truncate: false) { return .init(lines: lines, fontSize: size) }
        }
        return .init(lines: pack(minimum, truncate: true) ?? ["…"], fontSize: minimum)
    }
    private static func words(_ title: String) -> [String] {
        var pieces: [String] = [], current = ""
        let closing = Set<Character>("：:·/／—–-）)》〉」』")
        let opening = Set<Character>("（(《〈「『")
        for character in title.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                if !current.isEmpty { pieces.append(current); current = "" }
            } else if opening.contains(character) {
                if !current.isEmpty { pieces.append(current) }; current = String(character)
            } else if character == "～" || character == "〜" || character == "~" {
                if current.first == character { current.append(character); pieces.append(current); current = "" }
                else { if !current.isEmpty { pieces.append(current) }; current = String(character) }
            } else {
                current.append(character)
                if closing.contains(character) { pieces.append(current); current = "" }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.flatMap { piece -> [String] in
            // Short names between preferred punctuation stay whole, including
            // CJK compounds that a dictionary might split (神龍討滅戦).
            guard piece.count > 10, piece.contains(where: { !$0.isASCII }) else { return [piece] }
            let text = piece as NSString
            let japanese = piece.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil
            let locale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: (japanese ? "ja" : "zh") as CFString))
            let tokenizer = CFStringTokenizerCreate(nil, piece as CFString, CFRange(location: 0, length: text.length), kCFStringTokenizerUnitWord, locale)!
            var result: [String] = [], previous = 0
            while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard range.location >= previous, range.length > 0 else { continue }
                result.append(text.substring(with: NSRange(location: previous, length: range.location + range.length - previous)))
                previous = range.location + range.length
            }
            if previous < text.length, !result.isEmpty { result[result.count - 1] += text.substring(from: previous) }
            return result.isEmpty ? [piece] : result
        }
    }
}
