import Foundation

/// The work-context reader and story collector use the same claim eligibility
/// rules. A qualifier is not silently flattened into an unconditional fact.
struct WikidataSourceResponse: Decodable, Sendable {
    let success: Int?
    let entities: [String: WikidataSourceEntity]?
}
struct WikidataSourceEntity: Decodable, Sendable {
    let id: String
    let type: String
    let missing: String?
    let labels: [String: Localized]?
    let aliases: [String: [Localized]]?
    let claims: [String: [Claim]]?
    let sitelinks: [String: SiteLink]?
    struct Localized: Decodable, Sendable { let value: String }
    struct SiteLink: Decodable, Sendable { let site: String; let title: String }
    struct Claim: Decodable, Sendable {
        let id: String?
        let rank: String
        let mainsnak: Snak
        let qualifiers: [String: [Snak]]?
    }
    struct Snak: Decodable, Sendable { let snaktype: String; let datatype: String?; let datavalue: Value? }
    struct Value: Decodable, Sendable {
        let entityID: String?
        let stringValue: String?
        let quantity: Quantity?
        let time: WikiTime?
        private enum CodingKeys: String, CodingKey { case value }
        private struct EntityValue: Decodable { let id: String? }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entityID = (try? c.decode(EntityValue.self, forKey: .value))?.id
            stringValue = try? c.decode(String.self, forKey: .value)
            quantity = try? c.decode(Quantity.self, forKey: .value)
            time = try? c.decode(WikiTime.self, forKey: .value)
        }
    }
    struct Quantity: Decodable, Sendable { let amount: String; let unit: String }
    struct WikiTime: Decodable, Sendable {
        let time: String; let precision: Int; let calendar: String
        enum CodingKeys: String, CodingKey { case time, precision; case calendar = "calendarmodel" }
    }
    var names: [String] {
        ["ja", "zh-hans", "zh", "en"].flatMap { language in
            (labels?[language].map { [$0.value] } ?? []) + (aliases?[language]?.map(\.value) ?? [])
        }
    }
    var title: String { names.first ?? id }
    func eligibleClaims(_ property: String, allowName: Bool = false, allowLanguage: Bool = false) -> [Claim] {
        (claims?[property] ?? []).filter { claim in
            guard ["normal", "preferred"].contains(claim.rank), claim.mainsnak.snaktype == "value",
                  let statement = claim.id, let split = statement.firstIndex(of: "$"),
                  statement[..<split].uppercased() == id,
                  UUID(uuidString: String(statement[statement.index(after: split)...])) != nil else { return false }
            return (claim.qualifiers ?? [:]).allSatisfy { property, values in
                if allowLanguage && property == "P407" {
                    return !values.isEmpty && values.allSatisfy { $0.snaktype == "value" && $0.datavalue?.entityID.map(WikiSourceIdentity.validQID) == true }
                }
                return allowName && property == "P1810" && !values.isEmpty && values.allSatisfy {
                    $0.snaktype == "value" && $0.datatype == "string" && !($0.datavalue?.stringValue?.isEmpty ?? true)
                }
            }
        }
    }
    func strings(_ property: String) -> [String] {
        eligibleClaims(property, allowName: true, allowLanguage: property == "P856").compactMap { $0.mainsnak.datavalue?.stringValue }
    }
}
