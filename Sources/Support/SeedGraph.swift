import Foundation

/// Immutable design fixtures. Relation order is authored and must be preserved.
struct SeedGraph: Decodable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case song, album, film, tv, book, manga, person, group, video, game
        var isMusic: Bool { self == .song || self == .album }
        var objectKind: Kind {
            switch self {
            case .album, .group: .song
            case .tv, .game: .film
                        default: self
            }
        }
    }

    struct Entity: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let artworkAsset: String?
        let fallbackGlyph: String?
        let hook: String
        let actions: [String]
    }

    struct Relation: Codable, Hashable, Sendable {
        let from: String
        let to: String
        let label: String
        var via: String? = nil
    }

    let version: Int
    let root: String
    let entities: [Entity]
    let relations: [Relation]

    subscript(_ id: String) -> Entity? { entities.first { $0.id == id } }
    func outgoing(from id: String) -> [Relation] { relations.filter { $0.from == id } }

    enum LoadError: Error { case missingResource, duplicateIdentity, invalidReference }
    static func load(bundle: Bundle = .main) throws -> SeedGraph {
        guard let url = bundle.url(forResource: "seed-graph", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> SeedGraph {
        let graph = try JSONDecoder().decode(Self.self, from: data)
        let ids = Set(graph.entities.map(\.id))
        guard ids.count == graph.entities.count else { throw LoadError.duplicateIdentity }
        guard ids.contains(graph.root), graph.relations.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) }) else {
            throw LoadError.invalidReference
        }
        return graph
    }
    static let bundled: SeedGraph = {
        do { return try load() }
        catch { preconditionFailure("Invalid bundled design fixture: \(error)") }
    }()
}
