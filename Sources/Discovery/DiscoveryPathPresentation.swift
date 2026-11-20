import Foundation

/// A label describes the real path, not a fabricated direct relationship.
enum DiscoveryPathPresentation {
    static func creationLabel(target: DiscoveryIdentity.Layer?, quote: String) -> String {
        if quote.range(of: #"(?i)オープニング|opening theme|片头曲|片頭曲"#, options: .regularExpression) != nil { return "片头曲出自" }
        if quote.range(of: #"(?i)エンディング|ending theme|片尾曲"#, options: .regularExpression) != nil { return "片尾曲出自" }
        if quote.range(of: #"(?i)挿入歌|插曲|insert(?:ion)? song"#, options: .regularExpression) != nil { return "插曲出自" }
        if quote.range(of: #"(?i)主題歌|主题曲|主題曲|theme song|オープニングテーマ|エンディングテーマ"#, options: .regularExpression) != nil { return "主题曲出自" }
        if target == .game { return "原声出自" }
        if quote.range(of: #"(?i)劇伴|サウンドトラック|soundtrack|配乐|\bBGM\b"#, options: .regularExpression) != nil { return "配乐出自" }
        return "为此而作"
    }
    /// 同作 OP / ED / 插曲: another song made for the same show (AHA-PLAN §3.4).
    static func siblingLabel(quote: String) -> String {
        switch creationLabel(target: nil, quote: quote) {
        case "片头曲出自": "同作 OP"
        case "片尾曲出自": "同作 ED"
        case "插曲出自": "同作插曲"
        case "主题曲出自": "同作主题曲"
        default: "同作歌曲"
        }
    }
    static func quoted(_ title: String) -> String {
        "《" + title.replacingOccurrences(of: "《", with: "〈").replacingOccurrences(of: "》", with: "〉") + "》"
    }
    static func coverTitle(_ work: Work) -> String {
        guard let identity = work.discovery, identity.layer == .movement, !identity.movement.isEmpty else { return work.title }
        var nickname: String?
        for (open, close) in [("\"", "\""), ("《", "》"), ("「", "」"), ("“", "”")] {
            if let a = identity.canonicalTitle.range(of: open), let b = identity.canonicalTitle.range(of: close, range: a.upperBound..<identity.canonicalTitle.endIndex) {
                nickname = String(identity.canonicalTitle[a.upperBound..<b.lowerBound]); break
            }
        }
        let catalogue = RecordingCatalogMatch.catalogueKeys(identity.catalogue).first?.uppercased() ?? identity.catalogue
        let name = nickname ?? (!catalogue.isEmpty ? catalogue : identity.canonicalTitle)
        return name + " · " + identity.movement
    }
    static func typeName(_ work: Work) -> String {
        if let layer = work.discovery?.layer {
            return switch layer {
            case .tv: "剧集"; case .film: "电影"; case .game: "游戏"; case .manga: "漫画"; case .book: "书籍"
            case .video: "影像"; case .musicWork, .movement: "乐曲"; case .recording: "歌曲"; case .release: "专辑"
            case .person, .group: "创作者"
            }
        }
        return work.kind == "电视剧" ? "剧集" : work.kind
    }
    @MainActor static func directLabel(_ edge: RelationEdge, from: WorkID, catalog: CatalogStore) -> String {
        if edge.from == from, edge.predicate == .performanceOf { return "乐曲" }
        if edge.predicate == .musicVideoOf, edge.to == from {
            let quote = edge.source.evidenceQuote ?? ""
            if quote.range(of: #"(?i)\bMV\b|music video|ミュージックビデオ"#, options: .regularExpression) != nil { return "MV" }
            if quote.range(of: #"(?i)players.? video|ライブ|\blive\b|concert|perform|演奏|演出"#, options: .regularExpression) != nil { return "演出影像" }
            return "影像"
        }
        if edge.from == from, edge.predicate == .soundtrackOf {
            let target = catalog.work(edge.to)
            let layer = target.discovery?.layer ?? (target.kind == "游戏" ? .game : target.kind == "电视剧" ? .tv : .film)
            let lines = edge.source.detail.components(separatedBy: "\n")
            let quote = edge.source.evidenceQuote ?? (lines.count > 1 ? lines.last ?? "" : "")
            return creationLabel(target: layer, quote: quote)
        }
        return edge.label(from: from)
    }
    @MainActor static func label(_ edge: RelationEdge, path: [WorkID], facts: [RelationEdge], catalog: CatalogStore) -> String {
        guard path.count >= 2 else { return edge.label }
        let previous = path[path.count - 2], base = directLabel(edge, from: previous, catalog: catalog)
        guard path.count > 2 else { return base }
        let transparent = zip(path, path.dropFirst()).dropLast().allSatisfy { a, b in
            (catalog.relationIndex.adjacent[a] ?? []).map(\.1).contains { $0.from == a && $0.to == b && ($0.predicate == .performanceOf
                || $0.predicate == .partOf && catalog.work(a).isMusicWork && catalog.work(b).isMusicWork) }
        }
        guard !transparent else { return borrowedLabel(edge, path: path, catalog: catalog) ?? base }
        let owner = catalog.work(previous)
        if owner.isSong || owner.isMusicWork {
            if edge.from == previous, edge.predicate == .soundtrackOf { return "原曲出自" }
            if edge.from == previous, edge.predicate == .usedIn { return "原曲用于" }
            if edge.from == previous, edge.predicate == .adaptedFrom { return "原曲取材自" }
            if edge.from == previous, edge.predicate == .samplesFrom { return "原曲采样自" }
            return "原曲 · " + base
        }
        let type = typeName(owner)
        if edge.to == previous, [.soundtrackOf, .usedIn, .themeMusic, .endingOf].contains(edge.predicate) {
            let song = catalog.work(edge.from)
            if song.isSong || song.isMusicWork { return siblingLabel(quote: edge.source.evidenceQuote ?? "") }
        }
        if edge.from == previous, edge.predicate == .adaptedFrom { return type + "原作" }
        if edge.to == previous, edge.predicate == .adaptedFrom { return type + "改编作" }
        return type + " · " + base
    }

    /// 桑原あい's jazz 「ニュー・シネマ・パラダイス」 plays Morricone's piece. The film is where the
    /// piece comes from, not something her recording was made for: 「原曲出自」, not 「为此而作」
    /// (anson 2026-11-18). A recording by the piece's own composer, or one with its own edge to
    /// the work, keeps the direct label (the game's original soundtrack stays 「原声出自」).
    @MainActor static func borrowedLabel(_ edge: RelationEdge, path: [WorkID], catalog: CatalogStore) -> String? {
        guard path.count > 2, let root = path.first else { return nil }
        let previous = path[path.count - 2]
        guard edge.from == previous, catalog.work(previous).isMusicWork, [.soundtrackOf, .usedIn].contains(edge.predicate) else { return nil }
        let creation: Set<RelationKind> = [.soundtrackOf, .usedIn, .themeMusic, .endingOf]
        if (catalog.relationIndex.adjacent[root] ?? []).map(\.1).contains(where: { $0.from == root && $0.to == edge.to && creation.contains($0.predicate) }) { return nil }
        let recording = catalog.work(root)
        var performers = [recording.creator, recording.discovery?.performers ?? ""]
        performers += (recording.linkedCreatorIDs ?? []).map { catalog.work($0).title }
        var composers: [String] = []
        for id in path.dropFirst().dropLast() {
            let piece = catalog.work(id)
            composers += [piece.discovery?.composer ?? "", piece.creator]
            for (_, fact) in catalog.relationIndex.adjacent[id] ?? [] where fact.from == id && fact.predicate == .composedBy {
                let person = catalog.work(fact.to)
                composers += [person.title] + (person.discovery?.aliases ?? [])
            }
        }
        if sameMaker(performers, composers) { return nil }
        return edge.predicate == .usedIn ? "原曲用于" : "原曲出自"
    }
    static func makerKeys(_ names: [String]) -> [String] {
        names.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",，、&＆/／;；")) }
            .map { LeadMatch.norm($0) }.filter { $0.count >= 2 }
    }
    static func sameMaker(_ performers: [String], _ composers: [String]) -> Bool {
        let a = makerKeys(performers), b = makerKeys(composers)
        return a.contains { x in b.contains { y in x.contains(y) || y.contains(x) } }
    }
}
