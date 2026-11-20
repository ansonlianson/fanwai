import Foundation
import CryptoKit

enum StoryGenerationFingerprint {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct StoryNameNode: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case song, person, work }
    let id: String
    let name: String
    let kind: Kind
    var externalIDs: [String] = []
    var aliases: [String] = []
    var priority: Int { kind == .song ? 0 : kind == .person ? 1 : 2 }
}

/// Only identified graph nodes may translate a name. A source can mention other
/// people, but that does not create a node or authorize a guessed translation.
struct StoryNameTable: Sendable {
    let nodes: [StoryNameNode]
    init(nodes: [StoryNameNode] = [], verifiedNames: [String: [String]] = [:]) {
        self.nodes = nodes.map { node in
            var node = node
            let verified = node.aliases + node.externalIDs.flatMap { verifiedNames[$0] ?? [] }
            // A verified film label can wrap its own title in Japanese quotes.
            // Unwrap that literal substring without inventing a new node/name.
            let titles = verified.compactMap { name -> String? in
                guard let range = name.range(of: "(?<=[「『])[^」』]+(?=[」』])", options: .regularExpression) else { return nil }
                return String(name[range])
            }
            node.aliases = Array(Set(verified + titles))
                .filter { !$0.isEmpty }.sorted()
            return node
        }
    }
    var names: [String] { Array(Set(nodes.flatMap { [$0.name] + $0.aliases })).sorted() }
    var payload: [[String: String]] {
        let mappings = nodes.flatMap { node in (node.aliases + [node.name]).map { ($0, node) } }
        let grouped = Dictionary(grouping: mappings, by: { $0.0 })
        return grouped.keys.sorted().compactMap { name in
            guard let matches = grouped[name], Set(matches.map { $0.1.id }).count == 1, let node = matches.first?.1 else { return nil }
            return ["original": name, "app": node.name, "entity_id": node.id]
        }
    }
    static func bundledAliases(bundle: Bundle = .main) -> [String: [String]] {
        struct Record: Decodable { let externalID: String; let names: [String] }
        guard let url = bundle.url(forResource: "story-name-aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.externalID, $0.names) })
    }
    func preferredOwner(of material: StoryMaterial, fallback: String) -> String {
        let mentioned = nodes.compactMap { node -> (StoryNameNode, Int)? in
            let positions = ([node.name] + node.aliases).compactMap { name -> Int? in
                guard !name.isEmpty, let range = material.text.range(of: name, options: [.caseInsensitive]) else { return nil }
                // Avoid matching a Latin song title inside another word.
                if name.allSatisfy({ $0.isASCII }),
                   (range.lowerBound > material.text.startIndex && material.text[material.text.index(before: range.lowerBound)].isLetter ||
                    range.upperBound < material.text.endIndex && material.text[range.upperBound].isLetter) { return nil }
                return material.text.distance(from: material.text.startIndex, to: range.lowerBound)
            }
            return positions.min().map { (node, $0) }
        }
        return mentioned.sorted {
            if $0.0.priority != $1.0.priority { return $0.0.priority < $1.0.priority }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id < $1.0.id
        }.first?.0.id ?? fallback
    }
}

