import Foundation

/// A series mark changes search/presentation, never the identity of the playing recording.
enum RecordingVersion {
    private static let firstTake = #"(?i)(?:from\s+)?the\s+f(?:i|1)rst\s+take"#
    static func isFirstTake(_ title: String) -> Bool {
        title.range(of: #"(?i)(?:^|[\s\-–—/／(（\[【])(?:from\s+)?the\s+f(?:i|1)rst\s+take(?:$|[\s)）\]】])"#, options: .regularExpression) != nil
    }
    static func split(_ title: String) -> (title: String, version: String)? {
        let mastering = #"(?i)(?:\d{4}\s*)?(?:lacquer\s+master\s+sound|mastering|remaster(?:ed)?|ラッカーマスターサウンド|リマスター)(?:\s+\d{4})?"#
        let patterns = [#"\s*[-–—/／]\s*("# + firstTake + #")\s*$"#,
                        #"\s*[(（\[【]\s*("# + firstTake + #")\s*[)）\]】]\s*$"#,
                        #"\s*[(（\[【]\s*("# + mastering + #")\s*[)）\]】]\s*$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let range = Range(match.range, in: title), let mark = Range(match.range(at: 1), in: title) else { continue }
            let bare = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !bare.isEmpty { return (bare, String(title[mark])) }
        }
        return nil
    }
    static func searchTitle(_ title: String) -> String { split(title)?.title ?? title }
    static func isLive(_ title: String) -> Bool {
        isFirstTake(title) || title.range(of: #"(?i)\blive\b|ライブ|ライヴ|现场版|現場版"#, options: .regularExpression) != nil
    }
    static func isDerivative(_ title: String) -> Bool {
        isLive(title) || title.range(of: #"(?i)\b(?:remix|cover|piano|acoustic|instrumental|demo|karaoke|arrange(?:ment)?|self[ -]?cover)\b|カバー|カヴァー|アコースティック|ピアノ|アレンジ|オルゴール|翻唱|钢琴|鋼琴|伴奏"#, options: .regularExpression) != nil
    }
}
