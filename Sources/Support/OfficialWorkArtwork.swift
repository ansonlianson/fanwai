import Foundation
import SwiftSoup

/// Follow the exact subject's registered official link. The subject API's
/// image and prose fields are intentionally not decoded or used.
struct OfficialWorkArtwork: Sendable {
    let loader: StoryMaterialTransport.Loader
    private let sharedMetadata: Bool
    init(loader: StoryMaterialTransport.Loader? = nil) {
        sharedMetadata = loader == nil
        self.loader = loader ?? { request in
            let (data, response) = try await SourceHTTP.noRedirectSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }
    static func publisherPage(_ work: Work) -> URL? {
        guard let layer = work.discovery?.layer, [.film, .tv].contains(layer) else { return nil }
        let candidates = [work.discovery?.identitySource].compactMap { $0 } + (work.discovery?.pages ?? []).map(\.url)
        return candidates.compactMap(URL.init(string:)).first {
            ["www.vap.co.jp", "vap.co.jp"].contains($0.host?.lowercased() ?? "") && allowed($0)
        }
    }
    func fetch(_ work: Work) async throws -> WorkArtwork? {
        if let publisher = Self.publisherPage(work) {
            // The publisher commonly redirects a directory URL to its slash
            // form. Budget robots + landing + redirect + two registered editions.
            let transport = StoryMaterialTransport(limit: 5, loader: loader)
            guard let (body, url) = await transport.page(publisher, purpose: "已核对作品的发行商页面", allowedHosts: ["www.vap.co.jp", "vap.co.jp"]),
                  let html = StorySourceDocument.decode(body) else { return nil }
            let name = work.discovery?.canonicalTitle ?? work.title
            if let art = try Self.parse(html, url: url, name: name, identityURL: publisher.absoluteString) { return art }
            for product in try Self.publisherProducts(html, url: url).prefix(2) {
                guard let (data, finalURL) = await transport.page(product, purpose: "发行商登记的同作品封面", allowedHosts: ["www.vap.co.jp", "vap.co.jp"]),
                      let page = StorySourceDocument.decode(data),
                      let art = try Self.publisherProduct(page, url: finalURL, name: name, parent: publisher) else { continue }
                return art
            }
            return nil
        }
        // The exact Wikidata item can register its own official website even
        // when none of its Wikipedia articles carries a usable poster. Do not
        // treat an arbitrary research citation as an official artwork source.
        if !work.isPerson, let qid = work.knowledgeID, WorkContextService.validQID(qid) {
            let transport = StoryMaterialTransport(limit: 7, loader: loader)
            var parts = URLComponents(string: "https://www.wikidata.org/w/api.php")!
            parts.queryItems = [URLQueryItem(name: "action", value: "wbgetentities"),
                .init(name: "ids", value: qid), .init(name: "props", value: "claims|sitelinks"),
                .init(name: "format", value: "json")]
            let registrationData: Data?
            if sharedMetadata { registrationData = await MetadataTransport.shared.response(parts.url!, timeout: 4)?.data }
            else { registrationData = await transport.api(parts.url!, purpose: "精确作品登记的官方网站") }
            if let data = registrationData,
               let registration = try? JSONDecoder().decode(OfficialRegistration.self, from: data),
               let item = registration.entities[qid], item.id == qid, item.type == "item" {
                let names = [work.discovery?.canonicalTitle ?? "", work.title]
                    + (work.discovery?.aliases ?? []) + (item.sitelinks ?? [:]).values.map(\.title)
                for site in item.websites.prefix(2) {
                    guard let (body, finalURL) = await transport.page(site, purpose: "已登记作品的官网主视觉",
                        allowedHosts: Self.hosts(site)), let html = StorySourceDocument.decode(body) else { continue }
                    for name in names where Self.normalized(name).count >= 3 {
                        if let art = try Self.parse(html, url: finalURL, name: name,
                            identityURL: "https://www.wikidata.org/wiki/" + qid) { return art }
                    }
                }
            }
        }
        guard !work.isPerson, let id = work.bangumiID, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let transport = StoryMaterialTransport(limit: 7, loader: loader)
        guard let data = await transport.api(URL(string: "https://api.bgm.tv/v0/subjects/" + id)!, purpose: "精确条目的官网链接"),
              let subject = try? JSONDecoder().decode(Subject.self, from: data), String(subject.id) == id,
              Self.normalized(subject.name) == Self.normalized(work.title) else { throw WorkArtworkError.identityMismatch }
        for entry in subject.infobox ?? [] where ["官方网站", "官网", "公式サイト", "official website"].contains(entry.key.lowercased()) {
            guard let raw = entry.value, let url = URL(string: raw), Self.allowed(url),
                  let (body, finalURL) = await transport.page(url, purpose: "作品官网宣传图", allowedHosts: [url.host!, "www." + url.host!.replacingOccurrences(of: "www.", with: "")]),
                  let html = StorySourceDocument.decode(body) else { continue }
            if let art = try Self.parse(html, url: finalURL, name: subject.name, identityURL: "https://bgm.tv/subject/" + id) { return art }
        }
        return nil
    }
    private static func hosts(_ url: URL) -> Set<String> {
        guard let host = url.host?.lowercased() else { return [] }
        return [host, "www." + host.replacingOccurrences(of: "www.", with: "")]
    }

    private struct OfficialRegistration: Decodable {
        let entities: [String: Item]
        struct Item: Decodable {
            let id: String?; let type: String?; let claims: Claims?; let sitelinks: [String: Link]?
            var websites: [URL] {
                let statements = (claims?.websites ?? []).filter {
                    ["normal", "preferred"].contains($0.rank ?? "") && ($0.qualifiers ?? [:]).allSatisfy { key, values in
                        key == "P407" && !values.isEmpty && values.allSatisfy {
                            $0.property == "P407" && $0.snaktype == "value" && $0.datatype == "wikibase-item"
                                && $0.id.map(WorkContextService.validQID) == true
                        }
                    }
                        && $0.mainsnak.property == "P856" && $0.mainsnak.snaktype == "value"
                        && $0.mainsnak.datatype == "url"
                }
                let preferred = statements.filter { $0.rank == "preferred" }
                var seen = Set<URL>()
                // Wikidata still registers many official sites as http:// (FINAL FANTASY XIV:
                // Shadowbringers is "http://na.finalfantasyxiv.com/shadowbringers"). Only public
                // HTTPS is fetched, so ask for the same address over HTTPS instead of dropping it.
                return (preferred.isEmpty ? statements : preferred).compactMap { $0.mainsnak.datavalue?.value }
                    .compactMap { OfficialWorkArtwork.secure($0) }.filter { allowed($0) && seen.insert($0).inserted }
            }
        }
        struct Claims: Decodable {
            let websites: [Claim]?
            enum CodingKeys: String, CodingKey { case websites = "P856" }
        }
        struct Link: Decodable { let title: String }
        struct Claim: Decodable {
            let rank: String?; let qualifiers: [String: [Qualifier]]?; let mainsnak: Snak
        }
        struct Qualifier: Decodable {
            let property: String?; let snaktype: String?; let datatype: String?; let id: String?
            enum CodingKeys: CodingKey { case property, snaktype, datatype, datavalue }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                property = try? c.decode(String.self, forKey: .property)
                snaktype = try? c.decode(String.self, forKey: .snaktype)
                datatype = try? c.decode(String.self, forKey: .datatype)
                id = (try? c.decode(EntityValue.self, forKey: .datavalue))?.value.id
            }
            struct EntityValue: Decodable { let value: Entity }
            struct Entity: Decodable { let id: String? }
        }
        struct Snak: Decodable {
            let property: String?; let snaktype: String?; let datatype: String?; let datavalue: Value?
        }
        struct Value: Decodable { let value: String? }
    }
    static func parse(_ html: String, url: URL, name: String, identityURL: String) throws -> WorkArtwork? {
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        let metadata = try doc.select("meta[property='og:title'], meta[property='og:description'], meta[name=description]").array().map { try $0.attr("content") }
        let headings = try doc.select("h1, h2").text()
        let imageTitles = try doc.select("h1 img[alt], h2 img[alt]").array().map { try $0.attr("alt") }
        let identity = normalized(([try doc.title(), headings] + metadata + imageTitles).joined(separator: "\n"))
        guard identity.contains(normalized(name)), normalized(name).count >= 3,
              let raw = try doc.select("meta[property='og:image'], meta[name='twitter:image']").first()?.attr("content"),
              let image = URL(string: raw, relativeTo: url)?.absoluteURL, allowed(image), usefulImage(image) else { return nil }
        return .init(id: "official:" + identityURL, fileTitle: name, thumbnailURL: image.absoluteString,
                     sourcePageURL: url.absoluteString, articleURL: url.absoluteString,
                     artist: nil, credit: "作品官网宣传图", licenseName: nil, licenseURL: nil, isNonFree: nil,
                     width: 0, height: 0, rawMetadata: ["identitySource": identityURL, "officialPage": url.absoluteString])
    }
    /// VAP's public product blocks explicitly register each edition. Follow
    /// that registration, not guessed image names or a title search.
    static func publisherProducts(_ html: String, url: URL) throws -> [URL] {
        guard ["www.vap.co.jp", "vap.co.jp"].contains(url.host ?? "") else { return [] }
        let doc = try SwiftSoup.parse(html)
        return try doc.select("pr-product01").array().compactMap { element in
            guard let data = try element.attr(":data").data(using: .utf8),
                  let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = item["product_item_id"] as? String, !id.isEmpty, id.count <= 64,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return URL(string: "/data/html/product/" + id + ".html", relativeTo: url)?.absoluteURL
        }
    }
    static func publisherProduct(_ html: String, url: URL, name: String, parent: URL) throws -> WorkArtwork? {
        let doc = try SwiftSoup.parse(html)
        guard let json = try doc.select("script#json-data[type=application/json]").first()?.html().data(using: .utf8),
              let item = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              item["modal_type"] as? String == "product", let id = item["item_id"] as? String,
              url.lastPathComponent == id + ".html", let rawParent = item["pr_site_url"] as? String,
              let registered = URL(string: rawParent, relativeTo: url)?.absoluteURL,
              DiscoveryCore.sourceKey(registered.absoluteString) == DiscoveryCore.sourceKey(parent.absoluteString),
              let title = item["title"] as? String, normalized(title).contains(normalized(name)),
              (item["product_divisions"] as? [String])?.contains("bluray") == true,
              let raw = item["image"] as? String, let image = URL(string: raw, relativeTo: url)?.absoluteURL,
              image.host == url.host, usefulImage(image) else { return nil }
        return .init(id: "publisher-product:" + id, fileTitle: title, thumbnailURL: image.absoluteString,
            sourcePageURL: url.absoluteString, articleURL: parent.absoluteString, artist: nil,
            credit: "发行商商品封面", licenseName: nil, licenseURL: nil, isNonFree: nil, width: 0, height: 0,
            rawMetadata: ["identitySource": parent.absoluteString, "edition": title])
    }
    private static func usefulImage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return !["logo", "ogp_blu-ray", "/meta/", "noimage", "no_image", "placeholder"].contains(where: path.contains)
    }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func allowed(_ url: URL) -> Bool {
        guard StoryMaterialTransport.publicURL(url), let host = url.host?.lowercased() else { return false }
        return !["bgm.tv", "bangumi.tv", "chii.in"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// A registered http:// address, asked for over HTTPS (same host and path); anything else as is.
    static func secure(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        if parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }
    private struct Subject: Decodable {
        let id: Int; let name: String; let infobox: [Entry]?
        struct Entry: Decodable {
            let key: String; let value: String?
            enum CodingKeys: CodingKey { case key, value }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                key = try c.decode(String.self, forKey: .key)
                value = try? c.decode(String.self, forKey: .value)
            }
        }
    }
}
