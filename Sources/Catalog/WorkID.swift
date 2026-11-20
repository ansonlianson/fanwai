import Foundation
import CryptoKit

struct WorkID: RawRepresentable, Hashable, Identifiable, Codable, Sendable, CaseIterable {
    let rawValue: String
    var id: String { rawValue }
    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= 240 else { return nil }
        self.rawValue = rawValue
    }
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid work ID")) }
        self = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    /// Playback entry IDs are unbounded external strings. A deterministic digest
    /// keeps local identity stable without truncation collisions or force unwraps.
    static func localPlaybackID(_ externalID: String) -> WorkID {
        let digest = SHA256.hash(data: Data(externalID.utf8)).map { String(format: "%02x", $0) }.joined()
        return WorkID(validated: "local:" + digest)
    }
    private init(validated rawValue: String) { self.rawValue = rawValue }
    static let pool = Self(rawValue: "pool")!
    static let film = Self(rawValue: "film")!
    static let animenz = Self(rawValue: "animenz")!
    static let jane = Self(rawValue: "jane")!
    static let janeMV = Self(rawValue: "editorial:jane-doe-mv")!
    static let distance = Self(rawValue: "distance")!
    static let ourFilm = Self(rawValue: "ourFilm")!
    static let slow = Self(rawValue: "slow")!
    static let manga = Self(rawValue: "manga")!
    static let ushio = Self(rawValue: "ushio")!
    static let yonezu = Self(rawValue: "yonezu")!
    static let utada = Self(rawValue: "utada")!
    static let yoshihara = Self(rawValue: "yoshihara")!
    static let fujimoto = Self(rawValue: "fujimoto")!
    static let ravel = Self(rawValue: "ravel")!
    static let debussy = Self(rawValue: "debussy")!
    static let animenzPerson = Self(rawValue: "animenzPerson")!
    static let poolAlbum = Self(rawValue: "poolAlbum")!
    static let janeAlbum = Self(rawValue: "janeAlbum")!
    static let distanceAlbum = Self(rawValue: "distanceAlbum")!
    static let allCases: [WorkID] = [.pool, .film, .animenz, .jane, .distance, .ourFilm, .slow, .manga, .ushio, .yonezu, .utada, .yoshihara, .fujimoto, .ravel, .debussy, .animenzPerson, .poolAlbum, .janeAlbum, .distanceAlbum]
}
