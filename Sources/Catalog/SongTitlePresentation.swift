import Foundation

/// Presentation only. Never rewrite the catalog title used to match a recording.
struct SongTitlePresentation: Equatable {
    let title: String
    let version: String?

    init(_ original: String, isSong: Bool = true) {
        let raw = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSong else { title = raw; version = nil; return }
        if let split = RecordingVersion.split(raw) { title = split.title; version = split.version; return }
        var split: (String, String)?
        if let last = raw.last, [")", "）"].contains(last) {
            let opening: Character = last == ")" ? "(" : "（"
            var depth = 0
            for index in raw.indices.reversed() {
                if raw[index] == last { depth += 1 }
                if raw[index] == opening {
                    depth -= 1
                    if depth == 0 {
                        split = (String(raw[..<index]), String(raw[raw.index(after: index)..<raw.index(before: raw.endIndex)]))
                        break
                    }
                }
            }
        } else if let range = raw.range(of: " - ", options: .backwards) {
            split = (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        if let split {
            let main = split.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = split.1.trimmingCharacters(in: .whitespacesAndNewlines)
            // Named works, featured artists, and generic parenthetical text are
            // deliberately not inferred to be a recording version.
            let marker = #"(?i)\b(live|remix|remaster(?:ed)?|instrumental|acoustic|demo|mono|stereo|edit|tv\s*size|radio\s*version|extended\s*(mix|version)|[a-z]+\s+ver\.?|version)\b|ライブ|ライヴ|リミックス|リマスター|现场版|現場版|混音版|伴奏版"#
            if !main.isEmpty, suffix.range(of: marker, options: .regularExpression) != nil {
                title = main; version = suffix; return
            }
        }
        title = raw; version = nil
    }

    func identity(creator: String, album: String? = nil) -> String {
        var result = [version, creator].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty,
           !result.contains(where: { $0.compare(album, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
            result.append(album)
        }
        return result.joined(separator: " · ")
    }
}
