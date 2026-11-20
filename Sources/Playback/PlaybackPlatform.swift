import Foundation

enum PlaybackPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple, qq, netease
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: "Apple Music"; case .qq: "QQ 音乐"; case .netease: "网易云音乐" }
    }
    var listenTitle: String {
        switch self { case .apple: "播放"; case .qq: "去 QQ 音乐听"; case .netease: "去网易云听" }
    }
    var searchTitle: String { self == .qq ? "在 QQ 音乐搜索" : "在网易云搜索" }
    func searchURL(_ query: String) -> URL {
        var c = URLComponents(string: self == .qq ? "https://y.qq.com/n/ryqq/search" : "https://music.163.com/#/search")!
        if self == .qq { c.queryItems = [.init(name: "w", value: query), .init(name: "t", value: "song")] }
        else { c.fragment = "/search/m/?s=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&#?="))) ?? "") + "&type=1" }
        return c.url!
    }
}

struct PlatformSongLink: Equatable, Sendable {
    let platform: PlaybackPlatform
    let identifier: String
    static func urls(in text: String) -> [URL] {
        let pattern = #"https?://[^\s<>\"'（）()]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).flatMap { URL(string: String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;"))) }
        }
    }
    static func parse(_ url: URL) -> Self? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil else { return nil }
        var path = c.path, items = c.queryItems ?? []
        // The share short link 163cn.tv lands on y.music.163.com/m/song?id=… (anson 11-18 14:22:
        // pasting a 网易云 share found nothing), the desktop site on music.163.com/#/song?id=….
        if ["music.163.com", "y.music.163.com", "m.music.163.com"].contains(c.host ?? "") {
            if let fragment = c.fragment, let f = URLComponents(string: "https://music.163.com" + fragment) {
                path = f.path; items = f.queryItems ?? []
            }
            guard ["/song", "/m/song"].contains(path), let id = items.first(where: { $0.name == "id" })?.value,
                  UInt64(id).map({ $0 > 0 }) == true else { return nil }
            return .init(platform: .netease, identifier: id)
        }
        if c.host == "y.qq.com" {
            let parts = path.split(separator: "/")
            if parts.count == 4, parts[0] == "n", ["ryqq", "ryqq_v2"].contains(parts[1]), parts[2] == "songDetail" {
                let id = String(parts[3])
                if !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    return .init(platform: .qq, identifier: id)
                }
            }
        }
        // QQ 音乐 shares open i.y.qq.com (or i2.…) /v8/playsong.html?songmid=… after the short link.
        let host = c.host ?? ""
        if host == "y.qq.com" || host.hasSuffix(".y.qq.com"), ["/n/yqq/song", "/v8/playsong.html"].contains(path),
           let id = items.first(where: { ["songmid", "songid", "mid"].contains($0.name) && !($0.value ?? "").isEmpty })?.value,
           !id.isEmpty, id.count <= 40, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return .init(platform: .qq, identifier: id)
        }
        return nil
    }
    static func first(in text: String) -> Self? { urls(in: text).compactMap(parse).first }
    static func isShort(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && ["c6.y.qq.com", "c.y.qq.com", "u.y.qq.com", "163cn.tv"].contains(url.host ?? "")
    }
    static func importURL(in text: String) -> URL? {
        urls(in: text).first { parse($0) != nil || isShort($0) || $0.host == "music.apple.com" }
    }
}

/// The source platform's exact item. It never occupies Apple's catalogID.
struct PlatformRecording: Codable, Equatable, Identifiable, Sendable {
    let platform: PlaybackPlatform
    let identifier: String
    let numericID: String?
    let title: String
    let artists: [String]
    let album: String
    let seconds: Double
    let artwork: String
    var id: String { platform.rawValue + ":song:" + (numericID ?? identifier) }
    var url: URL {
        if platform == .qq { return URL(string: "https://y.qq.com/n/ryqq_v2/songDetail/" + (numericID ?? identifier))! }
        return PublicDatabaseHTTP.endpoint("music.163.com", "/song", ["id": identifier])
    }
    func matches(_ link: PlatformSongLink) -> Bool {
        platform == link.platform && (identifier == link.identifier || numericID == link.identifier)
    }
    var work: Work {
        .init(id: WorkID(rawValue: id)!, title: title, creator: artists.joined(separator: "、"), kind: "歌曲", art: artwork,
            detail: album, url: url.absoluteString, linkedCreatorIDs: [], platformRecording: self)
    }
    static func ranking(_ source: Work, candidate: Self) -> Int {
        func key(_ value: String) -> String { LeadMatch.norm(value) }
        guard key(source.title) == key(candidate.title) else { return 0 }
        let artists = source.platformRecording?.artists ?? source.creator.components(separatedBy: CharacterSet(charactersIn: "、,/&，"))
        guard Set(artists.map(key).filter { !$0.isEmpty }) == Set(candidate.artists.map(key)) else { return 0 }
        var score = 2
        let album = source.platformRecording?.album ?? source.discovery?.releaseTitle ?? ""
        if !album.isEmpty, !candidate.album.isEmpty { guard key(album) == key(candidate.album) else { return 0 }; score += 1 }
        let seconds = source.platformRecording?.seconds ?? source.catalogTrack.map { Double($0.milliseconds) / 1000 } ?? 0
        if seconds > 0, candidate.seconds > 0 { guard abs(seconds - candidate.seconds) <= 3 else { return 0 }; score += 1 }
        return score
    }
}

struct ListeningDestination: Codable, Equatable, Sendable {
    enum Evidence: String, Codable { case sourceID, userConfirmed }
    let platform: PlaybackPlatform
    let identifier: String
    let url: URL
    let evidence: Evidence
    var valid: Bool { PlatformSongLink.parse(url) == .init(platform: platform, identifier: identifier) }
}

@MainActor final class ListeningDestinationStore {
    private let defaults: UserDefaults
    private var values: [String: [String: ListeningDestination]]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        values = defaults.data(forKey: "playback.destinations.v1").flatMap { try? JSONDecoder().decode([String: [String: ListeningDestination]].self, from: $0) } ?? [:]
    }
    func destination(_ id: WorkID, platform: PlaybackPlatform) -> ListeningDestination? {
        let d = values[id.rawValue]?[platform.rawValue]
        return d?.valid == true ? d : nil
    }
    func confirm(_ recording: PlatformRecording, for id: WorkID) {
        let d = ListeningDestination(platform: recording.platform, identifier: recording.numericID ?? recording.identifier,
            url: recording.url, evidence: .userConfirmed)
        guard d.valid else { return }
        values[id.rawValue, default: [:]][recording.platform.rawValue] = d
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "playback.destinations.v1") }
    }
}
