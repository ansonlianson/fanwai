import Foundation

/// An uploaded video, independent of a song or a reading page. Tracking and
/// start-time parameters are not identity; a Bilibili part number is.
struct VideoReference: Codable, Hashable, Sendable, Identifiable {
    enum Provider: String, Codable, Sendable { case bilibili, youtube, web }
    let provider: Provider
    let assetID: String
    let canonicalURL: String
    var id: String { provider.rawValue + ":" + assetID }
    var providerName: String {
        switch provider { case .bilibili: "哔哩哔哩"; case .youtube: "YouTube"; case .web: "网页视频" }
    }

    init?(url raw: String) {
        guard let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        if ["www.bilibili.com", "bilibili.com"].contains(host), path.count == 2, path[0] == "video" {
            let bvid = path[1]
            guard bvid.range(of: #"^BV[0-9A-Za-z]{10}$"#, options: .regularExpression) != nil else { return nil }
            let values = (parts.queryItems ?? []).filter { $0.name == "p" }
            guard values.count <= 1 else { return nil }
            let part: Int
            if let value = values.first {
                guard let rawPart = value.value, let number = Int(rawPart), (1...10000).contains(number) else { return nil }
                part = number
            } else { part = 1 }
            provider = .bilibili; assetID = bvid + ":p" + String(part)
            canonicalURL = "https://www.bilibili.com/video/\(bvid)/" + (part == 1 ? "" : "?p=\(part)")
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host) {
            let video: String?
            if host == "youtu.be", path.count == 1 { video = path.first }
            else if path == ["watch"] {
                let values = (parts.queryItems ?? []).filter { $0.name == "v" }
                guard values.count == 1 else { return nil }
                video = values.first?.value
            } else if path.count == 2, ["shorts", "embed"].contains(path[0]) { video = path[1] }
            else { return nil }
            guard let video, video.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            provider = .youtube; assetID = video; canonicalURL = "https://www.youtube.com/watch?v=" + video
        } else {
            // Unknown providers retain their exact URL, without inventing a
            // platform identifier or a provider-specific timestamp parameter.
            guard let url = parts.url?.absoluteString else { return nil }
            provider = .web; assetID = url; canonicalURL = url
        }
    }

    var isValid: Bool { VideoReference(url: canonicalURL) == self }

    func destination(seconds: Int? = nil) -> URL? {
        guard isValid, var parts = URLComponents(string: canonicalURL) else { return nil }
        if let seconds {
            guard (0...604800).contains(seconds), provider != .web else { return nil }
            var items = parts.queryItems ?? []
            items.append(URLQueryItem(name: "t", value: String(seconds)))
            parts.queryItems = items
        }
        return parts.url
    }
}

struct VideoCue: Codable, Hashable, Sendable, Identifiable {
    let video: VideoReference
    let seconds: Int
    let title: String
    let source: Source
    var duration: Int? = nil
    var id: String { video.id + ":" + String(seconds) }
    var timeLabel: String {
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var isValid: Bool {
        video.isValid && video.provider != .web && (0...604800).contains(seconds)
            && duration.map { $0 > seconds && $0 > 0 } != false
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URLComponents(string: source.url)?.scheme == "https"
    }
}

struct WatchLaterEntry: Codable, Equatable, Identifiable, Sendable {
    var workID: WorkID
    var video: VideoReference?
    var cue: VideoCue?
    var updatedAt: Date
    var id: String { video?.id ?? "work:" + workID.rawValue }
    var subtitle: String? { cue.map { $0.timeLabel + " · " + $0.title } }

    @MainActor static func forWork(_ id: WorkID, catalog: CatalogStore, now: Date = Date()) -> Self {
        let work = catalog.work(id)
        return .init(workID: id, video: work.isVideo ? work.url.flatMap { VideoReference(url: $0) } : nil,
                     cue: nil, updatedAt: now)
    }

    /// Preserve unresolved legacy work IDs. Only exact existing upload identities
    /// are deduplicated; timestamps never follow an alias to another upload.
    @MainActor static func normalized(_ entries: [Self], catalog: CatalogStore) -> [Self] {
        var result: [Self] = []
        for original in entries {
            var entry = original
            entry.workID = catalog.canonicalID(for: entry.workID)
            if entry.video?.isValid == false { entry.video = nil }
            if let cue = entry.cue, !cue.isValid || cue.video != entry.video { entry.cue = nil }
            if let index = result.firstIndex(where: { $0.id == entry.id }) {
                if entry.updatedAt > result[index].updatedAt { result[index] = entry }
            } else { result.append(entry) }
        }
        return result
    }
}

struct VideoCueFocus: Identifiable {
    let id = UUID()
    let entry: WatchLaterEntry
    let ownerTab: AppTab
    /// The final stack after opening the video. Repeated work IDs at different
    /// depths must not consume one another's one-shot focus request.
    let destinationPath: [Route]
}

enum VideoCues {
    // Verified against this exact upload's publisher description. These cues
    // do not apply to another performance, edit or upload with the same title.
    static let animenz: [VideoCue] = {
        guard let video = VideoReference(url: Source.animenz.url) else { return [] }
        return [VideoCue(video: video, seconds: 76, title: "向上流动的琶音", source: .animenz, duration: 324),
                VideoCue(video: video, seconds: 215, title: "高音区的水光", source: .animenz, duration: 324)]
    }()
}
