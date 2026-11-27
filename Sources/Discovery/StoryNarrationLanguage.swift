import Foundation
import NaturalLanguage

/// Runs at publication/cache intake, never on each view update. Foreign titles,
/// names and source quotations do not determine the language of the narration.
enum StoryNarrationLanguage {
    static func prose(_ text: String, names: [String] = []) -> String {
        var result = text
        for name in names.sorted(by: { $0.count > $1.count }) where (2...48).contains(name.count)
            && !name.contains(where: { "。\n\r".contains($0) }) {
            result = result.replacingOccurrences(of: name, with: " ")
        }
        // Only short, bounded titles. Quoting a whole foreign paragraph must
        // not turn it into accepted narration.
        result = result.replacingOccurrences(of: #"《[^》。\n]{1,48}》|「[^」。\n]{1,48}」|『[^』。\n]{1,48}』|“[^”。\n]{1,48}”"#,
                                             with: " ", options: .regularExpression)
        return result
    }

    static func isChinese(_ text: String, names: [String] = []) -> Bool {
        let narration = prose(text, names: names)
        func counts(_ line: String) -> (han: Int, kana: Int, hangul: Int, letters: Int) {
            var han = 0, kana = 0, hangul = 0, letters = 0
            for scalar in line.unicodeScalars {
                if CharacterSet.letters.contains(scalar) { letters += 1 }
                switch scalar.value {
                case 0x3400...0x9FFF, 0x20000...0x3134F: han += 1
                case 0x3040...0x30FF, 0xFF66...0xFF9F: kana += 1
                case 0x1100...0x11FF, 0xAC00...0xD7AF: hangul += 1
                default: break
                }
            }
            return (han, kana, hangul, letters)
        }
        let total = counts(narration)
        guard total.han >= 10 else { return false }
        let lines = narration.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n\r"))
        for line in lines + [narration] {
            let value = counts(line)
            // Unlisted proper names (竹内まりや, 来生たかお, etc.) can
            // appear in Chinese prose too. The language recognizer below
            // distinguishes that prose from an actual foreign sentence.
            if value.hangul > max(4, value.letters / 5) || value.kana > max(4, value.letters / 5) { return false }
            // Also reject a foreign sentence surrounded by Chinese paragraphs.
            if value.letters >= 24 {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(line)
                guard let language = recognizer.dominantLanguage,
                      language == .simplifiedChinese || language == .traditionalChinese else { return false }
            }
        }
        return true
    }
}
