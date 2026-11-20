import Foundation

struct Source: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let detail: String
    let url: String
    let publishedAt: Date?
    /// Internal provenance for review research; nil is the established GPT data.
    let researchProvider: String?
    let evidenceQuote: String?
    let researchEvidenceKey: String?
    var id: String { url }

    init(title: String, detail: String = "", url: String, publishedAt: Date? = nil, researchProvider: String? = nil, evidenceQuote: String? = nil, researchEvidenceKey: String? = nil) {
        self.title = title; self.detail = detail; self.url = url; self.publishedAt = publishedAt
        self.researchProvider = researchProvider
        self.evidenceQuote = evidenceQuote
        self.researchEvidenceKey = researchEvidenceKey
    }
    private enum CodingKeys: String, CodingKey { case title, detail, url, publishedAt, researchProvider, evidenceQuote, researchEvidenceKey }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        researchProvider = try c.decodeIfPresent(String.self, forKey: .researchProvider)
        evidenceQuote = try c.decodeIfPresent(String.self, forKey: .evidenceQuote)
        researchEvidenceKey = try c.decodeIfPresent(String.self, forKey: .researchEvidenceKey)
    }
    static let interview = Source(title: "牛尾宪辅访谈", detail: "Real Sound · 2025.10.22 · PR", url: "https://realsound.jp/2025/10/post-2167153.html/amp")
    static let gq = Source(title: "米津玄师访谈", detail: "GQ JAPAN · 2025.09.26", url: "https://www.gqjapan.jp/article/20250926-kenshi-yonezu-hype")
    static let animenz = Source(title: "Animenz 改编说明", detail: "演奏者发布的视频与简介", url: "https://www.bilibili.com/video/BV1QHyZBbEnT/")
    static let movie = Source(title: "《蕾塞篇》官网", detail: "作品、音乐与制作信息", url: "https://chainsawman.dog/movie_reze/")
    static let jane = Source(title: "JANE DOE", detail: "米津玄师官方网站", url: "https://reissuerecords.net/2025/09/22/janedoe_chainsawman/")
}
