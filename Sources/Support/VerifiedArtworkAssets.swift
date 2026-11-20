import Foundation

/// Exact local IDs only; no title, artist-name, or fuzzy image matching.
/// Source/license records: Research/artwork-seed-v3-assets.json.
enum VerifiedArtworkAssets {
    static func asset(for id: WorkID) -> String? { names[id.rawValue] }
    static func designAsset(for id: String) -> String? {
        switch id {
        case "devil": "verified-q47087518-poster"
        case "koe": "verified-q23925035-poster"
        case "csmtv": "verified-q104211858-poster"
        case "yoasobi": "verified-yoasobi-official"
        case "ikuta": "verified-ikuta-official"
        case "spy": "verified-spy-official"
        default: nil
        }
    }

    private static let names: [String: String] = [
        "manga": "verified-q65240543",
        "ushio": "verified-q11190062",
        "yonezu": "verified-q11604296",
        "utada": "verified-q234598",
        "ravel": "verified-q1178",
        "debussy": "verified-q4700",
        "editorial:ryuichi-sakamoto": "verified-q345494",
        "editorial:hideaki-anno": "verified-q23261",
        "editorial:david-sylvian": "verified-q519273",
        "editorial:paprika-film": "verified-q578595",
        "editorial:paprika-novel": "verified-q7133130",
        "editorial:yasutaka-tsutsui": "verified-q719250",
        "editorial:satoshi-kon": "verified-q333643",
        "editorial:millennium-actress": "verified-q939736",
        "editorial:nagisa-oshima": "verified-q55403",
        "animenzPerson": "verified-animenz-uploader",
    ]
}
