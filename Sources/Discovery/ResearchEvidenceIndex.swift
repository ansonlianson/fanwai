import Foundation
import CryptoKit

struct ResearchEvidenceSpan: Codable, Sendable {
    let id: String
    let sourceID: String
    let url: String
    let title: String
    let text: String
}

struct ResearchIdentityQuestion: Codable, Sendable {
    let name: String
    let evidenceID: String
    let sourceURL: String
    let question: String
}

/// Preparation for the next controlled contract. This does not assert new
/// relations, select a media type, dispatch searches, or change the app default.
enum ResearchEvidenceIndex {
    static func spans(_ packet: ResearchMaterialPacket) -> [ResearchEvidenceSpan] {
        var output: [ResearchEvidenceSpan] = [], seen: Set<String> = []
        for source in packet.sources {
            let characters = Array(source.text)
            var offset = 0
            while offset < characters.count {
                var end = min(characters.count, offset + 220)
                if end < characters.count,
                   let newline = characters[(offset + min(120, end - offset))..<end].lastIndex(of: "\n") {
                    end = newline + 1
                }
                if characters.count - end < 8 { end = characters.count }
                let text = String(characters[offset..<end]); offset = end
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { continue }
                let key = (ResearchMaterials.safeURL(source.url) ?? source.url) + "\u{1F}" + source.title + "\u{1F}" + text
                let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                let id = "p" + String(digest.prefix(20))
                guard seen.insert(id).inserted else { continue }
                output.append(.init(id: id, sourceID: source.id, url: source.url, title: source.title, text: text))
            }
        }
        return output
    }

    static func bind(_ ids: [String], in spans: [ResearchEvidenceSpan]) -> [ResearchEvidenceSpan]? {
        guard !ids.isEmpty, ids.count <= 3, Set(ids).count == ids.count else { return nil }
        let indexed = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let found = ids.compactMap { indexed[$0] }
        return found.count == ids.count ? found : nil
    }

    static func originalIdentityQuestions(_ packet: ResearchMaterialPacket, known: [ResearchKnownSubject]) -> [ResearchIdentityQuestion] {
        let names = ResearchMaterials.observedNameVariants(packet.topic).filter { $0.count >= 3 }
        let knownNames = Set(known.map { ResearchMaterials.normalized($0.name) })
        let spans = spans(packet)
        let pattern = try! NSRegularExpression(pattern: #"(?m)(?:^|[/／|])\s*原作\s*[:：]\s*([^\r\n■|]{2,140})"#)
        var seen: Set<String> = [], output: [ResearchIdentityQuestion] = []
        for source in packet.sources {
            for match in pattern.matches(in: source.text, range: NSRange(source.text.startIndex..., in: source.text)) {
                guard let range = Range(match.range(at: 1), in: source.text) else { continue }
                let contextStart = source.text.index(range.lowerBound, offsetBy: -min(220, source.text.distance(from: source.text.startIndex, to: range.lowerBound)))
                let context = String(source.text[contextStart..<range.lowerBound])
                guard names.contains(where: { ResearchContradictions.literal($0, in: context) }) else { continue }
                for name in splitNames(String(source.text[range])) {
                    let normalized = ResearchMaterials.normalized(name)
                    let keyed = ResearchContradictions.key(name)
                    let knownPerson = known.contains { person in
                        let key = ResearchContradictions.key(person.name)
                        return person.layer == "person" && !key.isEmpty && keyed.hasPrefix(key + "(") && keyed.hasSuffix(")")
                    }
                    guard (2...80).contains(name.count), !knownNames.contains(normalized), seen.insert(normalized).inserted,
                          !knownPerson,
                          let evidence = spans.first(where: { $0.url == source.url && ResearchContradictions.literal(name, in: $0.text) }) else { continue }
                    output.append(.init(name: name, evidenceID: evidence.id, sourceURL: source.url,
                        question: "确认「\(name)」的作品身份与媒介；核对来源指的是哪一版本。"))
                    if output.count == 2 { return output }
                }
            }
        }
        return output
    }

    private static func splitNames(_ value: String) -> [String] {
        var depth = 0, part = "", output: [String] = []
        for char in value {
            if "「『《（(".contains(char) { depth += 1 }
            if "」』》）)".contains(char) { depth = max(0, depth - 1) }
            if char == "、", depth == 0 { output.append(part); part = "" }
            else { part.append(char) }
        }
        output.append(part)
        return output.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
