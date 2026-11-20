import Foundation

/// Manually verified identities. Public knowledge search never contributes an
/// automatic title match; a selected search entry opens as a separate work.
/// Person evidence: Research/identity-anchor-evidence.json. These mappings apply
/// only to the listed local IDs, never to an arbitrary work with the same title.
enum KnowledgeAnchors {
    static let verified: [WorkID: String] = [
        .film: "Q123906765",
        .manga: "Q65240543",
        .ushio: "Q11190062",
        .yonezu: "Q11604296",
        .utada: "Q234598",
        .yoshihara: "Q125871279",
        .fujimoto: "Q24864023",
        .ravel: "Q1178",
        .debussy: "Q4700",
        .animenzPerson: "Q61102629",
        WorkID(rawValue: "editorial:ryuichi-sakamoto")!: "Q345494",
        WorkID(rawValue: "editorial:hideaki-anno")!: "Q23261",
        WorkID(rawValue: "editorial:david-sylvian")!: "Q519273",
        WorkID(rawValue: "editorial:paprika-film")!: "Q578595",
        WorkID(rawValue: "editorial:paprika-novel")!: "Q7133130",
        WorkID(rawValue: "editorial:yasutaka-tsutsui")!: "Q719250",
        WorkID(rawValue: "editorial:satoshi-kon")!: "Q333643",
        WorkID(rawValue: "editorial:susumu-hirasawa")!: "Q930143",
        WorkID(rawValue: "editorial:millennium-actress")!: "Q939736",
        WorkID(rawValue: "editorial:nagisa-oshima")!: "Q55403"
    ]
}
