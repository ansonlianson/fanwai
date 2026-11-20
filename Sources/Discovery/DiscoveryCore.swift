import CryptoKit
import Foundation

struct DiscoveryUsage: Codable, Sendable {
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let webToolCalls: Int
}

/// Semantic identity is independent of the physical object used to draw it.
/// In particular a work/movement has no implicit playable recording.
struct DiscoveryIdentity: Codable, Hashable, Sendable {
    enum Layer: String, Codable, Sendable, CaseIterable {
        case recording, musicWork = "music_work", movement, release, game, film, tv, video, book, manga, person, group
        var isMusic: Bool { [.recording, .musicWork, .movement].contains(self) }
        var isComposition: Bool { self == .musicWork || self == .movement }
    }
    var layer: Layer
    var canonicalTitle: String
    var composer = ""
    var arranger = ""
    var performers = ""
    var catalogue = ""
    var movement = ""
    var edition = ""
    /// A consulted source anchors a provisional identity, not a verification badge.
    var identitySource: String? = nil
    var aliases: [String]? = nil
    var releaseTitle: String? = nil
    var pages: [Source]? = nil
    var nameKeys: Set<String> { Set(([canonicalTitle] + (aliases ?? [])).map(LeadMatch.norm).filter { !$0.isEmpty }) }

    var displayKind: String {
        switch layer {
        case .musicWork: "音乐作品"
        case .movement: "乐章"
        case .game: "游戏"
        case .recording: "歌曲"
        case .release: "专辑"
        case .film: "电影"
        case .tv: "电视剧"
        case .video: "演奏视频"
        case .book: "书籍"
        case .manga: "漫画"
        case .person, .group: "创作者"
        }
    }
}

enum DiscoveryRelation: String, Codable, Hashable, Sendable, CaseIterable {
    case performanceOf = "performance_of", arrangementOf = "arrangement_of", remixOf = "remix_of"
    case adaptationOf = "adaptation_of", coverOf = "cover_of", originalRecordingOf = "original_recording_of"
    case partOf = "part_of", createdFor = "created_for", usedIn = "used_in"
    case samples, inspiredBy = "inspired_by", musicVideoOf = "music_video_of"
    case composedBy = "composed_by", arrangedBy = "arranged_by", performedBy = "performed_by"
    case featuredBy = "featured_by", directedBy = "directed_by", authoredBy = "authored_by"
    case other

    var labels: (forward: String, inverse: String) {
        switch self {
        case .performanceOf: ("乐曲", "演奏版本")
        case .arrangementOf: ("改编自", "改编版本")
        case .adaptationOf: ("改编自", "改编作品")
        case .coverOf: ("原曲", "翻唱版本")
        case .originalRecordingOf: ("原版录音", "现场版本")
        case .remixOf: ("混音自", "混音版本")
        case .partOf: ("属于", "包含")
        case .createdFor: ("为此而作", "原声作品")
        case .usedIn: ("用于", "采用音乐")
        case .samples: ("采样自", "被采样于")
        case .inspiredBy: ("灵感来自", "启发作品")
        case .musicVideoOf: ("对应歌曲", "音乐影像")
        case .composedBy: ("作曲", "创作作品")
        case .arrangedBy: ("编曲", "编曲作品")
        case .performedBy: ("演奏", "演奏作品")
        case .featuredBy: ("合唱", "合作作品")
        case .directedBy: ("导演", "导演作品")
        case .authoredBy: ("作者", "创作作品")
        case .other: ("关联", "关联")
        }
    }
    var predicate: RelationKind {
        switch self {
        case .performanceOf: .performanceOf
        case .arrangementOf, .adaptationOf: .adaptedFrom
        case .coverOf: .coverOf
        // Keep the on-disk predicate compatible with existing libraries.
        case .originalRecordingOf: .coverOf
        case .remixOf: .remixOf
        case .partOf: .partOf
        case .createdFor: .soundtrackOf
        case .usedIn: .usedIn
        case .samples: .samplesFrom
        case .inspiredBy: .techniqueReference
        case .musicVideoOf: .musicVideoOf
        case .composedBy: .composedBy
        case .arrangedBy: .arrangedBy
        case .performedBy: .performedBy
        case .featuredBy: .performedBy
        case .directedBy: .directedBy
        case .authoredBy: .authoredBy
        case .other: .publicRelation
        }
    }
    static func parse(_ value: String?) -> Self? {
        guard let value else { return nil }
        if let exact = Self(rawValue: value) { return exact }
        switch value {
        case "composition", "original", "rearrangement_of": return .arrangementOf
        case "based_on": return .adaptationOf
        case "source_game": return .createdFor
        case "excerpt_of", "in_album": return .partOf
        case "quotes": return .inspiredBy
        default: return nil
        }
    }
    func accepts(from: DiscoveryIdentity.Layer, to: DiscoveryIdentity.Layer) -> Bool {
        switch self {
        case .performanceOf: [.recording, .video].contains(from) && to.isComposition
        case .coverOf, .originalRecordingOf: from == .recording && to == .recording
        case .arrangementOf, .remixOf, .samples: from.isMusic && to.isMusic
        case .adaptationOf: [.film, .tv, .game, .book, .manga, .video].contains(from) && [.book, .manga, .film, .tv, .game, .video].contains(to)
        case .partOf: (from == .movement && to == .musicWork) || (from == .recording && to == .release)
            || (from == to && [.game, .book, .manga, .tv].contains(from))
        case .createdFor, .usedIn: from.isMusic && [.game, .film, .tv, .video].contains(to)
        case .musicVideoOf: from == .video && to.isMusic
        case .composedBy, .arrangedBy, .performedBy, .featuredBy: from.isMusic && [.person, .group].contains(to)
        case .directedBy: [.film, .tv, .video].contains(from) && [.person, .group].contains(to)
        case .authoredBy: [.book, .manga, .film, .tv, .game].contains(from) && [.person, .group].contains(to)
        case .inspiredBy, .other: true
        }
    }
}

/// One provider-independent contract. No song names, franchises or expected answers.
enum DiscoveryCore {
    static let contractVersion = "discovery-v3.1"
    static let processorVersion = "p5"
    struct Node: Sendable {
        let ref: String
        let raw: LeadResearchClient.RawLead
        let identity: DiscoveryIdentity
        let provisionalID: String
    }
    struct Link: Sendable {
        let from: String
        let to: String
        let relation: DiscoveryRelation
        let label: String
        let inverse: String
        let why: String
        let url: String
        let quote: String
        var evidenceKey: String? = nil
    }
    struct Plan: Sendable {
        let nodes: [Node]
        let links: [Link]
        var clues: [Node] = []
        var rootAliases: Set<String> = []
    }

    static func layer(_ raw: LeadResearchClient.RawLead) -> DiscoveryIdentity.Layer? {
        // An OVA series is a screen work, not a single performance/MV. Some
        // providers use video for both; retain the explicit series context.
        if raw.target_type == "video", ["动画", "电视剧", "剧集"].contains(raw.kind ?? ""),
           (raw.edition ?? "").uppercased().contains("OVA") { return .tv }
        return switch raw.target_type ?? raw.kind ?? "" {
        case "composition", "arrangement", "music_work": .musicWork
        case "movement": .movement
        case "song", "recording": .recording
        case "album", "release": .release
        case "游戏": .game
        case "电影", "动画电影": .film
        case "剧集", "电视剧", "动画": .tv
        case "漫画": .manga
        case "小说", "书籍": .book
        case "MV", "视频": .video
        case "乐曲", "音乐作品": .musicWork
        case "乐章": .movement
        default: DiscoveryIdentity.Layer(rawValue: raw.target_type ?? raw.kind ?? "")
        }
    }
    static func kind(_ layer: DiscoveryIdentity.Layer) -> SeedGraph.Kind {
        switch layer {
        case .recording, .musicWork, .movement: .song
        case .release: .album
        case .game: .game
        case .film: .film
        case .tv: .tv
        case .video: .video
        case .book: .book
        case .manga: .manga
        case .person: .person
        case .group: .group
        }
    }
    static func sourceKey(_ raw: String?) -> String? {
        guard let raw, var u = URLComponents(string: raw), ["https", "http"].contains(u.scheme ?? ""), let host = u.host,
              !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        // A normal page anchor does not change the document. Client-side
        // routes do: stripping #/song?id=... would merge different songs.
        if let fragment = u.fragment, !fragment.hasPrefix("/"), !fragment.hasPrefix("!/") { u.fragment = nil }
        u.host = host.lowercased()
        if u.scheme == "https" && u.port == 443 || u.scheme == "http" && u.port == 80 { u.port = nil }
        // Tool citations and generated references often spell the same page with
        // a trailing slash or escaped parentheses. Preserve path case and query
        // values; never conflate domains, subpages, or encoded path separators.
        let pattern = try! NSRegularExpression(pattern: "%[0-9a-fA-F]{2}")
        var path = u.percentEncodedPath
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~()")
        for match in pattern.matches(in: path, range: NSRange(path.startIndex..., in: path)).reversed() {
            guard let range = Range(match.range, in: path), let byte = UInt8(path[range].dropFirst(), radix: 16) else { continue }
            let scalar = UnicodeScalar(byte)
            path.replaceSubrange(range, with: allowed.contains(scalar) ? String(scalar) : String(format: "%%%02X", byte))
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        u.percentEncodedPath = path
        let tracking: Set<String> = ["uo", "at", "ct", "ref", "feature", "shem"]
        u.queryItems = u.queryItems?.filter { item in
            let name = item.name.lowercased(), host = host.lowercased()
            if tracking.contains(name) || name.hasPrefix("utm_") { return false }
            if name == "bcrefid", ["www.sonymusic.co.jp", "ssl.sme.co.jp"].contains(host) { return false }
            if name == "ref_", ["www.imdb.com", "imdb.com"].contains(host) { return false }
            if name == "fmid", host == "mora.jp", let value = item.value,
               ["albumRank_", "singleRank_", "mora."].contains(where: value.hasPrefix) { return false }
            return true
        }.sorted { $0.name < $1.name }
        if u.queryItems?.isEmpty == true { u.queryItems = nil }
        return u.string
    }
    static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func identity(_ raw: LeadResearchClient.RawLead, layer: DiscoveryIdentity.Layer, sources: DiscoverySourceIndex) -> DiscoveryIdentity {
        var result = DiscoveryIdentity(layer: layer, canonicalTitle: clean(raw.canonical_title).isEmpty ? clean(raw.name) : clean(raw.canonical_title),
                                       composer: clean(raw.composer), arranger: clean(raw.arranger), performers: clean(raw.performers),
                                       catalogue: clean(raw.work_number), movement: clean(raw.movement), edition: clean(raw.edition))
        result.identitySource = sources.source(raw.identity_url)
        result.aliases = Array(Set([raw.name, raw.zh, raw.en, raw.canonical_title].compactMap { $0 }.map(clean).filter { !$0.isEmpty })).sorted()
        if !clean(raw.release_title).isEmpty { result.releaseTitle = clean(raw.release_title) }
        return result
    }
    static func provisionalID(_ identity: DiscoveryIdentity, creator: String, subjectID: String) -> String {
        // A shared title alone never aliases two recordings or two compositions.
        // Compositions can share only a consulted identity source AND a composer.
        let nonRecordingWork = [.game, .film, .tv, .book, .manga, .person, .group].contains(identity.layer)
        let share = identity.identitySource != nil && (nonRecordingWork || (identity.layer.isComposition && !identity.composer.isEmpty))
        let context = share ? sourceKey(identity.identitySource) ?? identity.identitySource! : subjectID
        var parts = [context, identity.layer.rawValue,
            LeadMatch.norm(identity.canonicalTitle), LeadMatch.norm(identity.composer), LeadMatch.norm(identity.arranger), identity.layer.isComposition ? "" : LeadMatch.norm(creator),
            LeadMatch.norm(identity.catalogue), LeadMatch.norm(identity.movement), identity.layer.isComposition ? "" : LeadMatch.norm(identity.edition)]
        if identity.layer == .recording {
            if let release = identity.releaseTitle, !release.isEmpty { parts += ["release", RecordingCatalogMatch.albumKey(release)] }
            if !identity.performers.isEmpty { parts += ["performers", LeadMatch.norm(identity.performers)] }
        }
        return "lead:" + identity.layer.rawValue + ":" + digest(parts)
    }
    static func previousRecordingID(_ identity: DiscoveryIdentity, creator: String, subjectID: String) -> String? {
        guard identity.layer == .recording else { return nil }
        var prior = identity; prior.releaseTitle = nil; prior.performers = ""
        return provisionalID(prior, creator: creator, subjectID: subjectID)
    }
    static func sameSourcedEntity(_ a: DiscoveryIdentity, _ b: DiscoveryIdentity) -> Bool {
        guard a.layer == b.layer, !a.layer.isMusic, a.layer != .release,
              let left = sourceKey(a.identitySource), left == sourceKey(b.identitySource),
              !a.nameKeys.isDisjoint(with: b.nameKeys),
              LeadMatch.norm(a.edition) == LeadMatch.norm(b.edition) else { return false }
        return true
    }
    /// Reuse a previously sourced composition locally. A publisher's tracklist and
    /// an original interview can identify the same work without sharing a URL.
    /// This never aliases recordings or promotes a name to an authoritative ID.
    static func sameSourcedComposition(_ a: DiscoveryIdentity, _ b: DiscoveryIdentity) -> Bool {
        guard a.layer.isComposition, a.layer == b.layer, a.identitySource != nil, b.identitySource != nil,
              !a.composer.isEmpty, !b.composer.isEmpty else { return false }
        return !a.nameKeys.isDisjoint(with: b.nameKeys)
            && [a.composer, a.arranger, a.catalogue, a.movement].map(LeadMatch.norm)
                == [b.composer, b.arranger, b.catalogue, b.movement].map(LeadMatch.norm)
    }
    static func mergeMetadata(_ current: DiscoveryIdentity?, _ incoming: DiscoveryIdentity?) -> DiscoveryIdentity? {
        guard let a = current else { return incoming }
        guard let b = incoming, a.layer == b.layer else { return current }
        // A newly accepted report can refresh its recording roles. Work identities
        // retain their existing primary spelling and add corroborated aliases.
        var result = a.layer == .recording ? b : a
        result.aliases = Array(Set([a.canonicalTitle, b.canonicalTitle] + (a.aliases ?? []) + (b.aliases ?? []))).sorted()
        var pageURLs = Set<String>()
        result.pages = ((a.pages ?? []) + (b.pages ?? [])).filter { pageURLs.insert($0.url).inserted }
        return result
    }

    static func prepare(_ raw: LeadResearchClient.Raw, subject: LeadSubject) -> Plan {
        let sources = DiscoverySourceIndex(raw.observedURLs ?? [])
        var nodes: [Node] = [], refs = Set<String>(), rootAliases = Set<String>()
        for (index, item) in (raw.leads ?? []).prefix(12).enumerated() {
            var candidate = item
            guard let layer = layer(candidate), !clean(candidate.name).isEmpty else { continue }
            let ref = clean(candidate.ref).isEmpty ? "n\(index)" : clean(candidate.ref)
            guard ref != "current", ref.count <= 50, refs.insert(ref).inserted else { continue }
            if !(candidate.composer ?? "").isEmpty,
               (raw.relations ?? []).contains(where: { edge in
                   guard edge.from == ref, edge.relation == "composed_by",
                         ResearchProofRules.contradictsRole("composed_by", quote: clean(edge.evidence_quote)),
                         let target = raw.leads?.first(where: { $0.ref == edge.to }) else { return false }
                   return LeadMatch.same(clean(target.name), clean(candidate.composer), loose: false)
               }) {
                // Quarantine the contradicted role instead of inventing a new
                // composer or relabelling the artist supplied by Apple Music.
                candidate.composer = nil
            }
            let identity = identity(candidate, layer: layer, sources: sources)
            let id = provisionalID(identity, creator: clean(candidate.creator), subjectID: subject.id)
            // Current recordings/releases and unreleased working names are context, not discoveries.
            let subjectLayer = subject.identity?.layer ?? (subject.kind == .song ? .recording : subject.kind == .album ? .release : DiscoveryIdentity.Layer(rawValue: subject.kind.rawValue))
            if layer == subjectLayer,
               LeadMatch.same(clean(candidate.name), subject.title, loose: false),
               !subject.creator.isEmpty,
               layer == .recording
                    ? DiscoveryRecordingIdentity.aliasesCurrent(identity, creator: clean(candidate.creator), subject: subject)
                    : LeadMatch.norm(clean(candidate.creator)) == LeadMatch.norm(subject.creator)
                        && (identity.edition.isEmpty || LeadMatch.same(identity.edition, subject.identity?.edition.isEmpty == false ? subject.identity!.edition : subject.album, loose: false)) {
                // A duplicate current subject must keep its edges, including
                // a game/film opened on the second step of exploration.
                // Exact full credits/title only: a solo or a different live edition
                // never becomes an alias of a duet/current recording.
                rootAliases.insert(ref); continue
            }
            if layer == .release, !subject.album.isEmpty, LeadMatch.same(clean(candidate.name), subject.album, loose: false) { continue }
            if ["unreleased", "demo", "working_title"].contains(candidate.release_status ?? "") { continue }
            nodes.append(Node(ref: ref, raw: candidate, identity: identity, provisionalID: id))
        }
        let byRef = Dictionary(uniqueKeysWithValues: nodes.map { ($0.ref, $0) })
        // Context-only names are not useful lookup actions. This hides an
        // uncertain duplicate; it never aliases it or creates a fact edge.
        var contextClues = Set(nodes.filter { node in
            node.identity.layer == .recording && LeadMatch.same(node.identity.canonicalTitle, subject.title, loose: false)
                && LeadMatch.sameCreator(clean(node.raw.creator), subject.creator)
                && (node.identity.releaseTitle?.isEmpty != false || subject.album.isEmpty
                    || RecordingCatalogMatch.albumKey(node.identity.releaseTitle!) == RecordingCatalogMatch.albumKey(subject.album))
        }.map(\.ref))
        for relation in raw.relations ?? [] {
            guard let a = relation.from, let b = relation.to, contextClues.contains(a),
                  let target = byRef[b], let kind = DiscoveryRelation.parse(relation.relation) else { continue }
            if kind == .performanceOf && target.identity.layer.isComposition || kind == .partOf && target.identity.layer == .release { contextClues.insert(b) }
        }
        let rootLayer = subject.identity?.layer ?? (subject.kind == .song ? .recording : subject.kind == .album ? .release : DiscoveryIdentity.Layer(rawValue: subject.kind.rawValue) ?? .book)
        func nodeLayer(_ ref: String) -> DiscoveryIdentity.Layer? { ref == "current" ? rootLayer : byRef[ref]?.identity.layer }
        var links: [Link] = [], seen = Set<String>()
        if let relations = raw.relations {
            for edge in relations.prefix(24) {
                guard var a = edge.from, var b = edge.to, a != b,
                      !a.isEmpty, !b.isEmpty else { continue }
                if rootAliases.contains(a) { a = "current" }
                if rootAliases.contains(b) { b = "current" }
                guard a != b,
                      let from = nodeLayer(a), let to = nodeLayer(b),
                      var relation = DiscoveryRelation.parse(edge.relation),
                      let url = sources.source(edge.url),
                      !clean(edge.evidence_quote).isEmpty else { continue }
                guard !ResearchProofRules.contradictsRole(relation.rawValue, quote: clean(edge.evidence_quote)) else { continue }
                if a == "current", rootLayer == .recording, relation == .partOf, to == .release, !subject.album.isEmpty {
                    guard let release = byRef[b], LeadMatch.same(release.identity.canonicalTitle, subject.album, loose: false) else { continue }
                }
                if !relation.accepts(from: from, to: to) {
                    // Flip only when the reverse is the unique type-valid direction.
                    guard relation.accepts(from: to, to: from) else { continue }
                    swap(&a, &b)
                }
                if relation == .performedBy, ["合唱", "对唱", "客串", "合作演唱"].contains(clean(edge.label)) { relation = .featuredBy }
                guard seen.insert(a + "|" + relation.rawValue + "|" + b).inserted else { continue }
                // A re-played melody is not an audio sample; say so on the card (STEP1-RESULTS).
                // Borrowing from a composition (a sonata movement, a hymn tune) is always the melody.
                let interpolation = relation == .samples && (ResearchProofRules.isInterpolation(clean(edge.evidence_quote)) || to.isComposition)
                let labels = interpolation ? (forward: "引用旋律自", inverse: "旋律被引用于") : relation.labels
                links.append(.init(from: a, to: b, relation: relation,
                                   label: relation == .createdFor ? DiscoveryPathPresentation.creationLabel(target: nodeLayer(b), quote: clean(edge.evidence_quote))
                                        : relation == .other ? clean(edge.label) : labels.forward,
                                   inverse: labels.inverse, why: clean(edge.why), url: url, quote: clean(edge.evidence_quote)))
            }
        } else {
            // Compatibility with previous providers. Keep legacy facts, never invent a via edge.
            for node in nodes {
                let label = clean(node.raw.label)
                let relation = legacyRelation(label, to: node.identity.layer)
                let url = sourceKey(node.raw.url) ?? ""
                guard !url.isEmpty else { continue }
                links.append(.init(from: "current", to: node.ref, relation: relation, label: label.isEmpty ? relation.labels.forward : label,
                                   inverse: relation.labels.inverse, why: clean(node.raw.why), url: url, quote: ""))
            }
        }
        // Unconnected output cannot be turned into a direct relation just to fill the crate.
        var reached: Set<String> = ["current"]
        for _ in 0..<4 {
            for link in links where reached.contains(link.from) || reached.contains(link.to) { reached.insert(link.from); reached.insert(link.to) }
        }
        return .init(nodes: nodes.filter { reached.contains($0.ref) },
                     links: links.filter { reached.contains($0.from) && reached.contains($0.to) && !$0.label.isEmpty },
                     clues: nodes.filter { !reached.contains($0.ref) && !contextClues.contains($0.ref) }, rootAliases: rootAliases)
    }
    /// Each paid answer is validated on its own sources before it joins the
    /// projection. Prefix refs so two answers cannot borrow each other's refs.
    static func combine(_ answers: [(key: String?, raw: LeadResearchClient.Raw)], subject: LeadSubject) -> Plan {
        guard answers.count > 1 || answers.first?.key != nil else { return answers.first.map { prepare($0.raw, subject: subject) } ?? .init(nodes: [], links: []) }
        var nodes: [Node] = [], links: [Link] = [], clues: [Node] = []
        for (index, answer) in answers.enumerated() {
            let plan = prepare(answer.raw, subject: subject)
            func ref(_ value: String) -> String { value == "current" ? value : "h\(index)_" + value }
            func node(_ value: Node) -> Node { .init(ref: ref(value.ref), raw: value.raw, identity: value.identity, provisionalID: value.provisionalID) }
            nodes += plan.nodes.map(node); clues += plan.clues.map(node)
            links += plan.links.map { .init(from: ref($0.from), to: ref($0.to), relation: $0.relation, label: $0.label,
                inverse: $0.inverse, why: $0.why, url: $0.url, quote: $0.quote, evidenceKey: answer.key) }
        }
        return .init(nodes: nodes, links: links, clues: clues)
    }
    static func clean(_ raw: String?) -> String { (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static func years(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }
    private static func legacyRelation(_ label: String, to: DiscoveryIdentity.Layer) -> DiscoveryRelation {
        if ["原曲", "翻唱自"].contains(label), to == .recording { return .coverOf }
        if ["原曲", "翻唱自", "改编自"].contains(label) { return .arrangementOf }
        if label.contains("出自") || label.contains("出处") { return .createdFor }
        if label == "被采样于" { return .other } // Do not reverse an edge without typed endpoints.
        if label == "采样自" { return .samples }
        if label == "作曲" { return .composedBy }
        if label == "编曲" { return .arrangedBy }
        return .other
    }

    static let promptRules = """
    本次使用 discovery-v3.1 合同。以可继续探索的作品为主，不凑数量；不把自己的专辑、署名人或同曲另一版堆满首页。
    区分当前录音、演奏/改编的音乐作品、乐章、发行、具体游戏和影视；游戏用game，不用film。动画剧集／OVA用tv，只有单个MV／演奏影像用video，不能按DVD载体归类。器乐的作曲者不是原唱。
    当前是演奏/现场/重作曲时，必须保留它直接演奏的音乐作品节点；上游的主题、原曲或具体游戏另建节点，不跳过同名中间作品。一首改编可以有多首原曲。
    古典原作精确到作品号和乐章。普通演奏不是改编，重新作曲不是混音旧录音。作曲、编曲、演奏、指挥分别核实，唱片总署名不得下放到每一首；音乐会品牌不证明录音是live。
    leads是节点，不代表每个节点都直接连当前对象。给每个节点唯一ref，当前对象固定叫current，不要在leads重复返回current节点。
    节点只给ref、原名name、target_type(recording/music_work/movement/release/game/film/tv/video/book/manga/person/group)、creator。以下字段按需要给，空值直接省略：通行中文zh、英文别名en、与name不同的canonical_title、composer、arranger、performers、work_number、movement、release_title、edition、identity_url、wiki。不要重复节点的label/why/url/kind；关系事实写relations。release_title只写实际发行的专辑／单曲名，edition保留具体现场日期／重制等版本，不能是一整句发行说明。identity_url只写实际查到、明确指认该作品的署名页／条目，wiki只填已确认的「语言:条目名」。不同现场的edition必须保留。
    原版录音是recording，原唱现场重演用original_recording_of、翻唱他人用cover_of指向原版；合唱／客串用featured_by，普通演奏者仍用performed_by；导演用directed_by，原作者用authored_by。首页人物最多一位，主艺人不重复。原唱录音保留，不因它也是同曲版本而省略；旋律/作品本身是music_work，不猜一份录音当原曲。creator用于展示，音乐作品同时给原文composer。没有独立发行的工作名/demo不列。
    返回relations数组，每条含from/to（引用节点ref）、relation、why（40字内具体关联理由）、url和evidence_quote（40字内原文证据）；非other关系省略label，由App统一提供。url必须来自这次实际搜索/阅读的结果。各箭头分别给证据，不能只证明其中一端存在。
    relation可选performance_of(录音或演奏视频→乐曲)、arrangement_of(音乐改编→原作)、adaptation_of(影视/游戏/漫画改编→原作)、cover_of(翻唱录音→原唱录音)、original_recording_of(现场重演→原版录音)、featured_by(音乐→合唱/客串者)、directed_by、authored_by、remix_of、part_of(乐章→整部作品/录音→发行/分部→系列)、created_for(音乐→最初原作游戏或影视)、used_in(音乐→后来采用它的作品)、samples(采样者→被采样作品)、inspired_by、music_video_of(视频→音乐)、composed_by、arranged_by、performed_by、other。
    后来的再改编指向前作，不把前作标成改编自后作；电影采用某乐曲不等于使用当前这份录音。原作游戏和后来收录它的音游也分开。未知关系不编。
    最多10个节点、16条有意义的关系；只选能解释且值得继续看的路径。多数歌不需要用满。先保证直接原曲/作品与具体原作，再找明确差异的改编、官方影像、跨媒介新作品。只因为同作者/同唱片不算发现。
    返回前逐项核对下面这些常见的强关联，查到有证据的就保留，查不到不编：歌曲依据的小说、漫画等原作（用inspired_by指向原作）；作为片头、片尾、插曲或主题曲用于的动画、剧集、电影、游戏、演出活动（created_for或used_in）；同一旋律的另一语言或另填词版本（other，label写「同曲异词」）；以这首歌命名或讲述它的电影、纪录片、书（used_in或inspired_by）；它采样、翻唱或改编的原曲，以及采样、翻唱它的知名作品。
    story仍无标题，有完整经过时250–400个汉字、材料少时100–200字（不凑数），具体幕后事件，主体注明recording/music_work/album/artist/work，并用subject_ref明确指向current或某一节点ref；可以讲原作前史但不伪装为本次现场幕后，无材料则null。范围由App标签说明，正文禁止「这是前史并非本次幕后」「尚未核实当前录音」「可以继续探索」这类任务旁白，不介绍检索方法。事实和目标入口分开。
    story非null时，必须包含text、subject、subject_ref、url、source五个非空字段。url是支持这段幕后事实且本次实际查阅的主原文页，source写出处名；不能省略出处，不能以作品存在页替代幕后证据。多个真实出处放additionalSources:[{title,url}]，无可溯源的故事直接null。
    仅输出JSON：{"leads":[...],"relations":[...],"story":{...}或null}。空关系写[]，不要省略relations。不要输出未查证的置信度分数。
    """
}
