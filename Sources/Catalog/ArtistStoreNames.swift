import Foundation

/// Apple's Japanese storefront lists many artists under a Japanese name (The Who → ザ・フー,
/// 张国荣 → レスリー・チャン, Neil Sedaka → ニール・セダカ) and keeps Chinese titles in
/// traditional characters (拒絕再玩), so a card that says 「拒绝再玩 · 张国荣」 never matched a
/// playable recording there, although the search itself returned it (anson 2026-11-18).
/// The artist number is the same in every storefront: a store that writes the card's own name
/// (US for Latin names, Hong Kong and Taiwan for Chinese ones) tells which numbers carry it.
@MainActor enum ArtistStoreNames {
    private static var cache: [String: Set<String>] = [:]
    /// For tests and the offline review build.
    static var lookup: (URL) async -> Data? = { url in
        try? await PianwaiRuntime.publicCatalogSession.data(from: url).0
    }

    /// The stores that write this credit the way the card does, unless the user's own store already does.
    static func bridgeStores(creator: String, country: String) -> [String] {
        let country = country.lowercased()
        let kana = creator.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil
        if creator.range(of: "[A-Za-z]", options: .regularExpression) != nil, !kana { return country == "us" ? [] : ["us"] }
        if creator.range(of: "\\p{Han}", options: .regularExpression) != nil, !kana {
            return ["hk", "tw"].filter { $0 != country }
        }
        return []
    }
    static func needsBridge(creator: String, country: String) -> Bool { !bridgeStores(creator: creator, country: country).isEmpty }

    static func artistIDs(named creator: String, title: String, country: String = "jp") async -> Set<String> {
        let stores = bridgeStores(creator: creator, country: country)
        let key = LeadMatch.norm(creator) + "|" + LeadMatch.norm(title) + "|" + stores.joined(separator: ",")
        if let known = cache[key] { return known }
        var ids = Set<String>()
        for store in stores {
            var parts = URLComponents(string: "https://itunes.apple.com/search")!
            parts.queryItems = [.init(name: "term", value: title + " " + creator), .init(name: "country", value: store),
                                .init(name: "media", value: "music"), .init(name: "entity", value: "song"), .init(name: "limit", value: "15")]
            guard let url = parts.url, let data = await lookup(url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = payload["results"] as? [[String: Any]] else { continue }
            for row in results {
                guard let name = row["artistName"] as? String, let number = row["artistId"] as? Int,
                      ScriptFold.sameCredits(name, creator) else { continue }
                ids.insert(String(number))
            }
            if !ids.isEmpty { break }
        }
        cache[key] = ids
        return ids
    }
}

/// Chinese written in traditional and simplified characters is the same name (拒絕再玩 = 拒绝再玩,
/// 張國榮 = 张国荣). Used where a store's listing is compared with a card.
enum ScriptFold {
    static func simplified(_ text: String) -> String {
        guard text.range(of: "\\p{Han}", options: .regularExpression) != nil else { return text }
        return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
    static func sameCredits(_ a: String, _ b: String) -> Bool {
        DiscoveryRecordingIdentity.sameCredits(a, b) || DiscoveryRecordingIdentity.sameCredits(simplified(a), simplified(b))
    }
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        LeadMatch.same(a, b, loose: false) || LeadMatch.same(simplified(a), simplified(b), loose: false)
    }
}
