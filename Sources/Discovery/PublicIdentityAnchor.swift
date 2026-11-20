import Foundation

/// Identifier claims already read and verified during the public-source review.
/// This table supplies identity only; it never supplies a relationship edge.
struct PublicIdentityAnchor: Decodable {
    let qid: String
    let bangumiID: String
    let property: String
    let source: String
    static let bundled: [Self] = {
        guard let url = Bundle.main.url(forResource: "public-identity-anchors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }()
}
