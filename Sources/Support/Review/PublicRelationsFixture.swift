#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit

/// Recorded public responses. Unknown requests fail closed; no fixture means
/// no invented success, empty claim set, account call, or live network fallback.
enum PublicRelationsFixture {
    static func artwork(_ url: String) -> UIImage? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-network=real-relations"),
              let file = Bundle.main.url(forResource: "recorded-artwork", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data), let name = mapping[url],
              let image = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return UIImage(contentsOfFile: image.path)
    }
    static func response(_ url: URL, bundle: Bundle = .main) throws -> (Data, Int) {
        guard let file = bundle.url(forResource: "recorded-responses", withExtension: "json", subdirectory: "PublicRelationsUIFixtures")
            ?? bundle.url(forResource: "recorded-responses", withExtension: "json"),
              let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else { throw CatalogError.invalidData }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.host == "www.wikidata.org", let clause=query.first(where: { $0.name == "srsearch" })?.value, clause.contains(" OR ") {
            // Recorded production behavior: this is not a statement union.
            return (Data(#"{"query":{"search":[]}}"#.utf8),200)
        }
        if url.host == "www.wikidata.org", let clause=query.first(where: { $0.name == "srsearch" })?.value,
           clause.hasPrefix("haswbstatement:"), clause.contains("|") {
            var hits:[[String:Any]]=[]
            for statement in clause.dropFirst("haswbstatement:".count).split(separator:"|") {
                let term = "haswbstatement:" + statement
                var part=URLComponents(url:url,resolvingAgainstBaseURL:false)!
                part.queryItems=query.map { $0.name == "srsearch" ? URLQueryItem(name:"srsearch",value:term) : $0 }
                let raw=try JSONSerialization.jsonObject(with:response(part.url!,bundle:bundle).0) as! [String:Any]
                hits += (raw["query"] as? [String:Any])?["search"] as? [[String:Any]] ?? []
            }
            var seen=Set<String>(); hits=hits.filter { seen.insert($0["title"] as? String ?? "").inserted }
            return (try JSONSerialization.data(withJSONObject:["query":["search":hits]]),200)
        }
        if url.host == "www.wikidata.org", let ids=query.first(where: { $0.name == "ids" })?.value, ids.contains("|") {
            var entities:[String:Any]=[:]
            for id in ids.split(separator:"|").map(String.init) {
                var part=URLComponents(url:url,resolvingAgainstBaseURL:false)!
                part.queryItems=query.map { $0.name == "ids" ? URLQueryItem(name:"ids",value:id) : $0 }
                let raw=try JSONSerialization.jsonObject(with:response(part.url!,bundle:bundle).0) as! [String:Any]
                entities.merge(raw["entities"] as? [String:Any] ?? [:]) { _,new in new }
            }
            return (try JSONSerialization.data(withJSONObject:["entities":entities]),200)
        }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        let matches = rows.filter { row in
            guard row["host"] as? String == url.host, row["path"] as? String == path,
                  let parameters = row["match"] as? [String: String] else { return false }
            return parameters.allSatisfy { name, value in query.contains { $0.name == name && $0.value == value } }
        }
        // A dedicated artist+song response is more specific than the already
        // recorded artist-only lookup. Equally specific duplicates still fail.
        let specificity = matches.map { ($0["match"] as? [String: String])?.count ?? 0 }.max()
        let exact = matches.filter { ($0["match"] as? [String: String])?.count == specificity }
        guard exact.count == 1, let row = exact.first, let payload = row["payload"], let status = row["status"] as? Int else {
            throw URLError(.resourceUnavailable)
        }
        return (try JSONSerialization.data(withJSONObject: payload), status)
    }
    static func load(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw CatalogError.invalidLink }
        let (data, status) = try response(url)
        guard status == 200 else { throw status == 404 ? CatalogError.notFound : CatalogError.server }
        return data
    }
}
#endif
