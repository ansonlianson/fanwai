import Foundation

/// A release's name is not the prose describing when/how a recording appeared.
/// Catalog format suffixes can be ignored; live/remaster/edition words cannot.
enum RecordingCatalogMatch {
    /// Reuse the work's typed credits and performance links, including older
    /// database cards that stored those facts only as edges. Story prose is
    /// never an identity source, and the cover artist is never the composer.
    @MainActor static func source(_ work: Work, catalog: CatalogStore) -> Work {
        guard work.isMusicWork else { return work }
        let id = catalog.canonicalID(for: work.id)
        var identity = work.discovery ?? .init(layer: work.kind == "乐章" ? .movement : .musicWork, canonicalTitle: work.title)
        var composers: [WorkID: String] = [:], recordings = Set<WorkID>()
        var performedWorks: [WorkID: Set<WorkID>] = [:]
        let workPage = work.id.rawValue.hasPrefix("musicbrainz:work:") ? DiscoveryCore.sourceKey(work.url) : nil
        for edge in catalog.edges {
            let from = catalog.canonicalID(for: edge.from), to = catalog.canonicalID(for: edge.to)
            if edge.predicate == .composedBy,
               from == id || workPage != nil && DiscoveryCore.sourceKey(edge.source.url) == workPage {
                let person = catalog.work(to)
                if person.isPerson, !person.title.isEmpty { composers[to] = person.title }
            }
            if [.performanceOf, .coverOf].contains(edge.predicate), catalog.work(to).isMusicWork {
                performedWorks[from, default: []].insert(to)
                if to == id { recordings.insert(from) }
            }
        }
        if identity.composer.isEmpty {
            identity.composer = composers.isEmpty ? work.creator : composers.values.sorted().joined(separator: "、")
        }
        // A medley performs several works; its whole title cannot name each one.
        let names = recordings.filter { performedWorks[$0]?.count == 1 }.compactMap { id -> String? in
            let recording = catalog.work(id)
            return recording.isSong ? recording.title : nil
        }
        identity.aliases = Array(Set((identity.aliases ?? []) + names + [work.title])).sorted()
        var resolved = work; resolved.discovery = identity
        return resolved
    }

    /// A movement's catalogue number survives translations and the catalog's
    /// long concerto title. These are user-selectable results, never aliases.
    static func query(for source: Work) -> String {
        let name = source.discovery?.canonicalTitle ?? source.title
        let credit = source.discovery?.layer.isComposition == true ? source.discovery?.composer ?? source.creator : source.creator
        let key = source.discovery.flatMap { $0.layer == .movement ? catalogueKeys($0.catalogue).first : nil }
        return (key ?? name) + " " + credit
    }
    static func matchesCandidate(_ candidate: Work, source: Work) -> Bool {
        let names = [source.title, source.discovery?.canonicalTitle ?? ""] + (source.discovery?.aliases ?? [])
        if names.contains(where: { !$0.isEmpty && ScriptFold.sameTitle(SongTitlePresentation(candidate.title).title, SongTitlePresentation($0).title) }) { return true }
        guard let identity = source.discovery, identity.layer == .movement,
              let ordinal = movementNumber(identity.movement),
              movementNumber(candidate.title) == ordinal else { return false }
        let expected = Set(catalogueKeys(identity.catalogue)), actual = Set(catalogueKeys(candidate.title))
        return !expected.isEmpty && !expected.isDisjoint(with: actual)
    }
    static func catalogueKeys(_ text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"(?i)\b(RV|BWV|HWV|KV|K|D|WoO|Sz|BB|Wq)\.?\s*([0-9]+[a-z]?)\b"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let prefix = Range(match.range(at: 1), in: text), let number = Range(match.range(at: 2), in: text) else { return nil }
            return (text[prefix] + text[number]).lowercased()
        }
    }
    private static func movementNumber(_ text: String) -> Int? {
        let expression = try! NSRegularExpression(pattern: #"(?i)(?:^|[\s:.)])([IVX]{1,5}|[1-9][0-9]?)\s*[.、)]"#)
        if let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let range = Range(match.range(at: 1), in: text) {
            let token = String(text[range]).uppercased()
            return Int(token) ?? ["I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10, "XI": 11, "XII": 12][token]
        }
        for (index, number) in ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"].enumerated() {
            if ["第" + number + "乐章", "第" + number + "樂章", "第" + number + "楽章"].contains(where: text.contains) { return index + 1 }
        }
        return nil
    }
    /// The discovery resolver and an opened page share the same exact matcher.
    /// Looking up a recording never starts another model research request.
    @MainActor static func find(_ lead: Lead, library: Library) async -> WorkID? {
        guard lead.kind == .song, lead.identity?.layer.isComposition != true,
              !lead.creator.isEmpty else { return nil }
        let existing = library.catalog.works.keys.filter { library.catalog.work($0).isSong && library.catalog.work($0).catalogRecordingID != nil }
        if let match = unique(existing, lead: lead, catalog: library.catalog) { return match }
        let performer = lead.identity?.performers.isEmpty == false ? lead.identity!.performers : lead.creator
        let names = [lead.original, lead.alias].compactMap { $0 }.filter { !$0.isEmpty }
        for name in names.prefix(2) {
            if Task.isCancelled { return nil }
            let ids = (try? await library.catalog.search(name + " " + performer, country: library.country, kind: .song, persist: false, candidateOnly: true)) ?? []
            if let match = unique(ids, lead: lead, catalog: library.catalog) { return match }
        }
        return nil
    }

    @MainActor @discardableResult static func attach(_ target: WorkID, to provisional: WorkID, identity: DiscoveryIdentity?, catalog: CatalogStore) -> Bool {
        let matched = catalog.work(target)
        guard matched.isSong, matched.catalogRecordingID != nil,
              catalog.work(provisional).isSong else { return false }
        if catalog.canonicalID(for: provisional) == catalog.canonicalID(for: target) { return true }
        let alias = Work(id: provisional, title: matched.title, creator: matched.creator, kind: matched.kind,
            art: matched.art, detail: matched.detail, url: matched.url, linkedAlbumID: matched.albumID,
            linkedCreatorIDs: matched.creatorIDs, catalogID: matched.catalogRecordingID, storeCountry: matched.storeCountry,
            discovery: identity)
        do { try catalog.merge(.init(works: [alias], relations: [])); return true }
        catch { return false }
    }
    static func albumKey(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: #"\s*[-–—]\s*(?:EP|Single)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return LeadMatch.norm(clean)
    }
    static func releaseHint(title: String?, edition: String?) -> String? {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        guard let edition, !edition.isEmpty else { return nil }
        for (a, b) in [("《", "》"), ("『", "』"), ("「", "」")] {
            if let open = edition.range(of: a), let close = edition.range(of: b, range: open.upperBound..<edition.endIndex), open.upperBound < close.lowerBound {
                return String(edition[open.upperBound..<close.lowerBound])
            }
        }
        return nil
    }
    @MainActor static func unique(_ candidates: [WorkID], lead: Lead, catalog: CatalogStore) -> WorkID? {
        let performer = lead.identity?.performers.isEmpty == false ? lead.identity!.performers : lead.creator
        guard !performer.isEmpty else { return nil }
        if lead.identity?.layer == .recording,
           releaseHint(title: lead.identity?.releaseTitle, edition: lead.identity?.edition) == nil,
           lead.identity?.edition.isEmpty != false {
            // A unique search result is not proof of an original recording.
            // The existing version picker can offer it as a selectable candidate.
            return nil
        }
        let names = [lead.original, lead.alias].compactMap { $0 }.filter { !$0.isEmpty }
        var matched = candidates.filter { id in
            let work = catalog.work(id)
            return work.isSong && names.contains { ScriptFold.sameTitle(work.title, $0) }
                && ScriptFold.sameCredits(work.creator, performer)
        }
        if let hint = releaseHint(title: lead.identity?.releaseTitle, edition: lead.identity?.edition) {
            matched = matched.filter { id in
                guard let album = catalog.work(id).albumID else { return false }
                return albumKey(catalog.work(album).title) == albumKey(hint)
            }
        } else if let edition = lead.identity?.edition, !edition.isEmpty {
            let exactRelease = matched.filter { id in
                catalog.work(id).albumID.map { albumKey(catalog.work($0).title) == albumKey(edition) } ?? false
            }
            if !exactRelease.isEmpty { matched = exactRelease }
            // Preserve an explicit live-edition distinction if the source supplied
            // one; never attach a studio version just because it has the same name.
            else if edition.range(of: #"(?i)\blive\b|现场版|現場版|ライブ"#, options: .regularExpression) != nil {
                matched = matched.filter { id in
                    let work = catalog.work(id)
                    let text = work.title + " " + (work.albumID.map { catalog.work($0).title } ?? "")
                    return text.range(of: #"(?i)\blive\b|现场版|現場版|ライブ"#, options: .regularExpression) != nil
                }
            }
        }
        if let edition = lead.identity?.edition,
           edition.range(of: #"(?i)\blive\b|现场|現場|ライブ|remaster|リマスター"#, options: .regularExpression) != nil {
            let years = DiscoveryCore.years(edition)
            if !years.isEmpty {
                matched = matched.filter { id in
                    let work = catalog.work(id)
                    let text = work.title + " " + (work.albumID.map { catalog.work($0).title } ?? "")
                    return years.allSatisfy(text.contains)
                }
            }
        }
        let unique = Set(matched.map { catalog.canonicalID(for: $0) })
        return unique.count == 1 ? unique.first : nil
    }
}
