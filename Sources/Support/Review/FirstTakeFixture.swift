#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit offline replay. Public catalogue metadata and article text are
/// captured files; no model answer or preselected original is injected.
enum FirstTakeFixture {
    static var directory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains("--ui-u20-first-take"),
              let path = ProcessInfo.processInfo.environment["PIANWAI_U20_PUBLIC"],
              path.hasSuffix("/Design/review/U20-first-take/public") else { return nil }
        return URL(fileURLWithPath: path)
    }
    static func report(_ subject: LeadSubject) -> LeadReport? {
        guard directory != nil, subject.id == "apple:song:1809720573" else { return nil }
        let root = SeedLibraryBridge.workID(subject.id), target = WorkID(rawValue: "local:u20-ainori")!
        let source = Source(title: "Wikipedia", detail: "フジテレビ系「あいのり」2002年10月 - 2003年9月度主題歌。", url: articleURL)
        let lead = Lead(id: target.rawValue, name: "あいのり", original: "あいのり", kind: .tv,
            label: "出自", why: source.detail, url: source.url, creator: "", art: "")
        return .init(leads: [lead], story: .init(text: "川嶋あい再次唱起「明日への扉」。这首歌在 2003 年以 I WiSH 的名义发行，也曾作为「あいのり」的主题曲。这次 THE FIRST TAKE 的现场演唱，与当年的录音是两个不同版本。",
            subject: "song", url: articleURL, source: "Wikipedia"), fetchedAt: Date(), seconds: 0,
            relations: [.init(from: root, to: target, predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐", source: source, researchRoot: root)])
    }
    static let articleURL = "https://ja.wikipedia.org/wiki/明日への扉_(I_WiSHの曲)"

    static func response(_ request: URLRequest) throws -> (Data, String)? {
        guard let folder = directory, let url = request.url else { return nil }
        if url.host == "itunes.apple.com", ["/search", "/lookup"].contains(url.path) {
            return (try Data(contentsOf: folder.appendingPathComponent("ashita-itunes.json")), "application/json")
        }
        if url.host == "ja.wikipedia.org" {
            if url.path == "/robots.txt" { return (Data("User-agent: *\nAllow: /\n".utf8), "text/plain") }
            let bytes = try Data(contentsOf: folder.appendingPathComponent("ashita-original-wikipedia.json"))
            let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let pages = (json?["query"] as? [String: Any])?["pages"] as? [String: [String: Any]]
            let text = pages?.values.first?["extract"] as? String ?? ""
            func escape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
            let body = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { "<p>" + escape($0) + "</p>" }.joined()
            return (Data(("<html><head><title>明日への扉 (I WiSHの曲)</title></head><body><article>" + body + "</article></body></html>").utf8), "text/html; charset=utf-8")
        }
        if let bytes = try? Data(contentsOf: folder.appendingPathComponent("IMAGE-MANIFEST.json")),
           let images = try? JSONDecoder().decode([String: String].self, from: bytes), let name = images[url.absoluteString] {
            return (try Data(contentsOf: folder.appendingPathComponent(name)), "image/jpeg")
        }
        return nil
    }
}
#endif
