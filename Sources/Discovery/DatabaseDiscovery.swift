import Foundation

struct PublicRecordingIdentifiers: Codable, Hashable, Sendable {
    var isrc: String? = nil
    var musicBrainz: String? = nil
    var vocaDB: Int? = nil
    var touhouDB: Int? = nil
}

struct DatabaseDiscoveryResult: Codable, Sendable {
    var snapshot = CatalogSnapshot(works: [], relations: [])
    var failures: [String] = []
    var multipleOriginals = false
    var pages: [String] = []
    var firstCardSeconds: Double? = nil
    var seconds: Double = 0
    static func combine(_ values: [Self]) -> Self {
        var works: [WorkID: Work] = [:], edges: [String: RelationEdge] = [:]
        for value in values {
            for work in value.snapshot.works { works[work.id] = work }
            for edge in value.snapshot.relations { edges[edge.id] = edge }
        }
        return .init(snapshot: .init(works: works.values.sorted { $0.id.rawValue < $1.id.rawValue },
            relations: edges.values.sorted { $0.id < $1.id }), failures: values.flatMap(\.failures),
            multipleOriginals: values.contains { $0.multipleOriginals }, pages: Array(Set(values.flatMap(\.pages))).sorted())
    }
    /// The model relation call (Call A) may be skipped only when the free
    /// databases already filled the aha slots this song opens (AHA-PLAN §3.2).
    /// Covers, arrangements and medleys alone never count as "enough": the most
    /// valuable card is usually the work the song was made for, which they lack.
    /// `title` is the playing recording's title, used to see whether it is a version.
    func needsRelationships(root: WorkID, title: String = "") -> Bool {
        if multipleOriginals { return true }
        let works = Dictionary(snapshot.works.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let structural = Set(snapshot.relations.filter { $0.from == root && $0.predicate == .performanceOf }.map(\.to))
        let origins = Set([root]).union(structural)
        func crossMedia(_ id: WorkID) -> Bool {
            guard let w = works[id] else { return false }
            return !w.isSong && !w.isMusicWork && !w.isPerson && !w.isAlbum && !w.isVideo
        }
        // Slot 原作: the song connects to a game, film, show or book it was made for or adapted from.
        let madeFor: Set<RelationKind> = [.soundtrackOf, .usedIn, .themeMusic, .endingOf, .adaptedFrom]
        let hasWork = snapshot.relations.contains { edge in
            madeFor.contains(edge.predicate) && (origins.contains(edge.from) && crossMedia(edge.to) || origins.contains(edge.to) && crossMedia(edge.from))
        }
        guard hasWork else { return true }
        // Slot 同门: a song made for a show, film or game opens its siblings (the same
        // work's OP, ED or insert songs), which only the research call finds.
        let shows: Set<String> = ["游戏", "电影", "动画", "电视剧"]
        if snapshot.relations.contains(where: { edge in
            madeFor.contains(edge.predicate) && origins.contains(edge.from) && works[edge.to].map { shows.contains($0.kind) } == true
        }) { return true }
        // Slot 归位: a version (live, orchestral, piano, acoustic, remix, TV size) must reach the piece it performs.
        // TFT repair uses the free optional path, never a new automatic model call.
        if !RecordingVersion.isFirstTake(title), DatabaseDiscoveryResult.isVersion(title) && structural.isEmpty
            && !snapshot.relations.contains(where: { edge in
                edge.from == root && [.coverOf, .remixOf, .adaptedFrom].contains(edge.predicate)
                    && works[edge.to].map { $0.isSong || $0.isMusicWork } == true
            }) {
            return true
        }
        return false
    }

    static func isVersion(_ title: String) -> Bool {
        RecordingVersion.isFirstTake(title) || title.range(of: #"(?i)(orchestra|orchestral|piano|acoustic|live|ライブ|アコースティック|ピアノ|オーケストラ|remix|tv\s*size|tv\s*ver|arrange|ver\.|version|現場|现场|钢琴|管弦)"#,
                    options: .regularExpression) != nil
    }
}

/// Structured sources establish their own identities. Search candidates are never
/// asserted facts without an identifier or a title/credit/duration/release join.
actor DatabaseDiscovery {
    static let shared = DatabaseDiscovery()
    let http: PublicDatabaseHTTP
    let exact: PublicRelationService?
    init(http: PublicDatabaseHTTP = .shared, exact: PublicRelationService? = .shared) {
        self.http = http
        if exact === PublicRelationService.shared && http !== PublicDatabaseHTTP.shared {
            self.exact = PublicRelationService(loader: { req in
                guard let url = req.url else { throw CatalogError.invalidLink }
                return try await http.get(url)
            }, paced: false)
        } else {
            self.exact = exact
        }
    }
    func resolve(_ work: Work, known: [Work], onPartial: (@Sendable (DatabaseDiscoveryResult) async -> Void)? = nil) async -> DatabaseDiscoveryResult {
        let started = Date()
        return await withTaskGroup(of: DatabaseDiscoveryResult.self) { group in
            group.addTask { await self.isolated("MusicBrainz") { try await self.musicBrainz(work) } }
            for host in ["vocadb.net", "touhoudb.com"] {
                group.addTask { await self.isolated(host) { try await self.vocal(work, host: host) } }
            }
            group.addTask { await self.isolated("Wikidata") { try await self.wikidata(work) } }
            group.addTask { await self.isolated("Bangumi") { try await self.bangumi(work) } }
            if let exact, work.catalogTrack != nil || work.knowledgeID != nil || work.bangumiID != nil {
                group.addTask {
                    do {
                        let result = try await exact.resolve(work, known: known) { value in
                            await onPartial?(Self.withoutVocals(.init(snapshot: value.snapshot, failures: value.failures)))
                        }
                        return .init(snapshot: result.snapshot, failures: result.failures, pages: result.snapshot.relations.map(\.source.url))
                    } catch { return .init(failures: ["Wikidata/Bangumi: " + CatalogError.message(error)]) }
                }
            }
            var values: [DatabaseDiscoveryResult] = [], first: Double?
            for await raw in group {
                let value = Self.withoutVocals(raw)
                values.append(value)
                let destinations = Dictionary(value.snapshot.works.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if first == nil, value.snapshot.relations.contains(where: { edge in
                    edge.predicate != .performanceOf && destinations[edge.to]?.isPerson == false && destinations[edge.to]?.isAlbum == false
                }) { first = Date().timeIntervalSince(started) }
                await onPartial?(value)
            }
            var result = DatabaseDiscoveryResult.combine(values)
            result.firstCardSeconds = first; result.seconds = Date().timeIntervalSince(started)
            return result
        }
    }
    /// Vocal credits repeat the main artist or name a chorus singer; neither is a
    /// place to go next. Writers, arrangers and works are.
    static func withoutVocals(_ value: DatabaseDiscoveryResult) -> DatabaseDiscoveryResult {
        var value = value
        let people = Set(value.snapshot.works.filter(\.isPerson).map(\.id))
        value.snapshot.relations.removeAll { $0.predicate == .performedBy && people.contains($0.to) }
        let linked = Set(value.snapshot.relations.flatMap { [$0.from, $0.to] })
        value.snapshot.works.removeAll { $0.isPerson && !linked.contains($0.id) }
        return value
    }
    private func isolated(_ name: String, operation: () async throws -> DatabaseDiscoveryResult) async -> DatabaseDiscoveryResult {
        do { return try await operation() }
        catch { return .init(failures: [name + ": " + CatalogError.message(error)]) }
    }
    private func object(_ url: URL, body: Data? = nil) async throws -> [String: Any] {
        let bytes = try await http.get(url, body: body)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CatalogError.invalidData }
        return object
    }
    private func mbURL(_ type: String, _ id: String, _ inc: String) -> URL {
        PublicDatabaseHTTP.endpoint("musicbrainz.org", "/ws/2/" + type + "/" + id, ["fmt": "json", "inc": inc])
    }
    private func musicBrainz(_ work: Work) async throws -> DatabaseDiscoveryResult {
        guard work.isSong || work.isMusicWork else { return .init() }
        var result = DatabaseDiscoveryResult(), recordingID = work.publicIdentifiers?.musicBrainz
        if recordingID == nil, let isrc = work.publicIdentifiers?.isrc.flatMap(CatalogIdentityService.validISRC) {
            let data = try await object(PublicDatabaseHTTP.endpoint("musicbrainz.org", "/ws/2/isrc/" + isrc, ["fmt": "json"]))
            let rows = data["recordings"] as? [[String: Any]] ?? []
            let matches = rows.filter { row in
                LeadMatch.same(row["title"] as? String ?? "", work.title, loose: false)
                    && (work.catalogTrack == nil || abs((row["length"] as? Int ?? -100000) - work.catalogTrack!.milliseconds) <= 2000)
            }
            if matches.count == 1 { recordingID = matches[0]["id"] as? String }
        }
        if recordingID == nil, let ms = work.catalogTrack?.milliseconds, ms > 0 {
            let title = work.title.replacingOccurrences(of: "\"", with: "")
            let artist = work.creator.components(separatedBy: CharacterSet(charactersIn: ",、&＆")).first!.replacingOccurrences(of: "\"", with: "")
            let url = PublicDatabaseHTTP.endpoint("musicbrainz.org", "/ws/2/recording/", ["query": "recording:\"\(title)\" AND artist:\"\(artist)\"", "fmt": "json", "limit": "25"])
            let rows = try await object(url)["recordings"] as? [[String: Any]] ?? []
            let matches = rows.filter { row in
                let artists = (row["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                return LeadMatch.same(row["title"] as? String ?? "", work.title, loose: false)
                    && abs((row["length"] as? Int ?? -100000) - ms) <= 2000
                    && artists.contains { LeadMatch.sameCreator($0, work.creator) }
                    && (row["video"] as? Bool != true)
            }
            if matches.count == 1 { recordingID = matches[0]["id"] as? String }
        }
        guard let recordingID, UUID(uuidString: recordingID) != nil else { return result }
        let url = mbURL("recording", recordingID, "isrcs+artist-credits+artist-rels+recording-rels+work-rels+work-level-rels+url-rels")
        let data = try await http.get(url)
        let recording = try JSONDecoder().decode(PublicMBRecording.self, from: data)
        guard recording.id == recordingID else { throw CatalogError.invalidData }
        var root = work; root.publicIdentifiers = root.publicIdentifiers ?? .init(); root.publicIdentifiers?.musicBrainz = recordingID
        if root.publicIdentifiers?.isrc == nil { root.publicIdentifiers?.isrc = recording.isrcs?.first }
        var works: [WorkID: Work] = [root.id: root], edges: [RelationEdge] = []
        func append(_ origin: WorkID, target: Work, relation: DiscoveryRelation, source: String) {
            works[target.id] = target
            edges.append(.init(from: origin, to: target.id, predicate: relation.predicate, label: relation.labels.forward,
                inverseLabel: relation.labels.inverse, source: .init(title: "MusicBrainz", url: source), researchRoot: work.id))
        }
        func credits(_ relations: [PublicMBRelation], origin: WorkID, source: String) {
            for r in relations {
                // Vocal credits name the main artist again or an uncredited chorus singer;
                // neither is a place to go next. Writers and arrangers are.
                guard r.type != "vocal", let artist = r.artist, UUID(uuidString: artist.id) != nil,
                      let mapping = PublicRelationService.creditLabels[r.type] else { continue }
                let id = WorkID(rawValue: "musicbrainz:artist:" + artist.id)!
                works[id] = .init(id: id, title: artist.name, creator: "", kind: "创作者", art: "", detail: "", url: "https://musicbrainz.org/artist/" + artist.id)
                edges.append(.init(from: origin, to: id, predicate: mapping.0, label: mapping.1, inverseLabel: "作品",
                    source: .init(title: "MusicBrainz", url: source), researchRoot: work.id))
            }
        }
        let recordingPage = "https://musicbrainz.org/recording/" + recordingID
        credits(recording.relations ?? [], origin: work.id, source: recordingPage)
        let performances = (recording.relations ?? []).filter { $0.type == "performance" && $0.work != nil }
        let namedPerformance = performances.contains { $0.attributes?.contains("cover") != true && LeadMatch.same($0.work?.title ?? "", work.title, loose: false) }
        for relation in recording.relations ?? [] {
            if let target = relation.recording, UUID(uuidString: target.id) != nil {
                let mapping: DiscoveryRelation?
                switch relation.type {
                case "samples material": mapping = .samples
                case "remix": mapping = .remixOf
                case "music video": mapping = .musicVideoOf
                default: mapping = nil
                }
                if let mapping {
                    let id = WorkID(rawValue: "musicbrainz:recording:" + target.id)!
                    let item = Work(id: id, title: target.title, creator: "", kind: relation.type == "music video" ? "音乐视频" : "歌曲", art: "", detail: "", url: "https://musicbrainz.org/recording/" + target.id)
                    if relation.type == "music video" || relation.direction == "backward" {
                        append(id, target: root, relation: mapping, source: recordingPage); works[id] = item
                    } else { append(work.id, target: item, relation: mapping, source: recordingPage) }
                }
            }
            guard relation.type == "performance", let composition = relation.work, UUID(uuidString: composition.id) != nil else { continue }
            // Conflicting covered work alongside the recording's exact-title original
            // needs independent proof. Do not import an editor's contradictory assertion.
            if namedPerformance, relation.attributes?.contains("cover") == true, !LeadMatch.same(composition.title, work.title, loose: false) { continue }
            let id = WorkID(rawValue: "musicbrainz:work:" + composition.id)!
            let page = "https://musicbrainz.org/work/" + composition.id
            let detailed = try? await object(mbURL("work", composition.id, "work-rels+artist-rels+url-rels"))
            let relations = (detailed.flatMap { try? JSONSerialization.data(withJSONObject: $0) }).flatMap { try? JSONDecoder().decode(MBComposition.self, from: $0) }?.relations ?? composition.relations ?? []
            let composers = Array(Set(relations.filter { $0.type == "composer" }.compactMap { $0.artist }
                .filter { UUID(uuidString: $0.id) != nil }.map(\.name))).sorted().joined(separator: "、")
            var identity = DiscoveryIdentity(layer: .musicWork, canonicalTitle: composition.title, composer: composers)
            identity.identitySource = page
            identity.aliases = performances.count == 1 ? Array(Set([composition.title, recording.title])).sorted() : [composition.title]
            append(work.id, target: .init(id: id, title: composition.title, creator: composers, kind: "音乐作品", art: "", detail: "", url: page, discovery: identity),
                relation: relation.attributes?.contains("cover") == true ? .coverOf : .performanceOf, source: recordingPage)
            credits(relations, origin: id, source: page)
            for r in relations where ["arrangement", "based on", "medley"].contains(r.type) {
                guard let target = r.work, UUID(uuidString: target.id) != nil else { continue }
                let targetID = WorkID(rawValue: "musicbrainz:work:" + target.id)!
                let targetWork = Work(id: targetID, title: target.title, creator: "", kind: "音乐作品", art: "", detail: "", url: "https://musicbrainz.org/work/" + target.id)
                if r.direction != "backward" {
                    works[targetID] = targetWork
                    edges.append(.init(from: targetID, to: id, predicate: r.type == "medley" ? .partOf : .adaptedFrom,
                        label: r.type == "medley" ? "属于" : "改编自", inverseLabel: "改编版本", source: .init(title: "MusicBrainz", url: page), researchRoot: work.id))
                } else { append(id, target: targetWork, relation: r.type == "medley" ? .partOf : .arrangementOf, source: page) }
            }
        }
        result.snapshot = .init(works: Array(works.values), relations: edges)
        result.pages = Array(Set(edges.map(\.source.url)))
        return result
    }
    private struct MBComposition: Decodable { let relations: [PublicMBRelation]? }

    private func vocal(_ work: Work, host: String) async throws -> DatabaseDiscoveryResult {
        guard work.isSong || work.isMusicWork else { return .init() }
        let db = host == "vocadb.net" ? "VocaDB" : "TouhouDB"
        let keys = DatabaseTitleKeys.keys(work.title)
        let title = keys.first ?? work.title
        func search(_ query: String) async throws -> [VocalSong] {
            let url = PublicDatabaseHTTP.endpoint(host, "/api/songs", ["query": query, "maxResults": "50", "nameMatchMode": "Exact", "sort": "RatingScore", "fields": "Names,Artists,Albums,Tags"])
            return try JSONDecoder().decode(VocalSearch.self, from: await http.get(url)).items
        }
        let rows = try await search(title)
        let strictMatches = rows.filter { row in
            let sameTitle = row.allNames.contains { LeadMatch.same($0, title, loose: false) }
            let credits = [row.artistString] + row.artists.map(\.name) + row.albums.map(\.artistString)
            let artist = credits.contains { LeadMatch.sameCreator($0, work.creator) }
            let duration = work.catalogTrack.map { abs($0.milliseconds / 1000 - row.lengthSeconds) <= 2 } ?? false
            let album = !work.detail.isEmpty && row.albums.contains { LeadMatch.same($0.name, work.detail, loose: false) }
            return sameTitle && artist && (duration || album)
        }
        let titleArtistMatches = rows.filter { row in
            let sameTitle = row.allNames.contains { LeadMatch.same($0, title, loose: false) }
            let credits = [row.artistString] + row.artists.map(\.name) + row.albums.map(\.artistString)
            let artist = !work.creator.isEmpty && credits.contains { LeadMatch.sameCreator($0, work.creator) }
            return sameTitle && artist
        }
        let matches: [VocalSong]
        if !strictMatches.isEmpty {
            matches = strictMatches
        } else if titleArtistMatches.count == 1 || (!titleArtistMatches.isEmpty && Set(titleArtistMatches.map { $0.originalVersionId ?? $0.id }).count == 1) {
            matches = [titleArtistMatches.first { $0.songType == "Original" } ?? titleArtistMatches[0]]
        } else {
            matches = []
        }
        guard matches.count == 1, let row = matches.first else {
            // A live, orchestral, piano or medley recording is rarely the database's own
            // entry. Its plain song title can still name the composition it performs.
            let fallbackKeys = Array(keys.dropFirst()).isEmpty ? [title] : Array(keys.dropFirst())
            return try await performedSongs(work, host: host, db: db, keys: fallbackKeys, search: search)
        }
        var result = DatabaseDiscoveryResult(), root = work
        root.publicIdentifiers = root.publicIdentifiers ?? .init()
        if host == "vocadb.net" { root.publicIdentifiers?.vocaDB = row.id } else { root.publicIdentifiers?.touhouDB = row.id }
        var works = [root], edges: [RelationEdge] = []
        let source = Source(title: db, url: "https://" + host + "/S/\(row.id)")
        result.multipleOriginals = row.tags.contains { LeadMatch.norm($0.tag.name) == "multipleoriginals" || $0.tag.additionalNames?.lowercased().contains("multiple originals") == true }
        if let originalID = row.originalVersionId, originalID > 0 {
            let original = try JSONDecoder().decode(VocalSong.self, from: await http.get(PublicDatabaseHTTP.endpoint(host, "/api/songs/\(originalID)", ["fields": "Names,Artists,Albums,Tags"])))
            let id = WorkID(rawValue: db.lowercased() + ":song:\(original.id)")!
            works.append(.init(id: id, title: original.name, creator: original.artistString, kind: "音乐作品", art: "", detail: "", url: "https://" + host + "/S/\(original.id)"))
            let relation: DiscoveryRelation = row.songType == "Remix" ? .remixOf : row.songType == "Cover" ? .coverOf : .arrangementOf
            edges.append(.init(from: work.id, to: id, predicate: relation.predicate, label: relation.labels.forward, inverseLabel: relation.labels.inverse, source: source, researchRoot: work.id))
            for album in original.albums where album.discType == "Game" {
                let gameID = WorkID(rawValue: db.lowercased() + ":album:\(album.id)")!
                works.append(.init(id: gameID, title: album.name, creator: album.artistString, kind: "游戏", art: "", detail: "", url: "https://" + host + "/Al/\(album.id)"))
                edges.append(.init(from: id, to: gameID, predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐", source: .init(title: db, url: "https://" + host + "/S/\(original.id)"), researchRoot: work.id))
            }
        }
        for album in row.albums {
            let id = WorkID(rawValue: db.lowercased() + ":album:\(album.id)")!
            works.append(.init(id: id, title: album.name, creator: album.artistString, kind: album.discType == "Game" ? "游戏" : "专辑", art: "", detail: "", url: "https://" + host + "/Al/\(album.id)"))
            edges.append(.init(from: work.id, to: id, predicate: album.discType == "Game" ? .soundtrackOf : .inAlbum, label: album.discType == "Game" ? "出自" : "收录于", inverseLabel: "音乐", source: source, researchRoot: work.id))
        }
        result.snapshot = .init(works: works, relations: edges); result.pages = [source.url]
        return result
    }

    /// A performance of an existing song: matched by its plain title and either the same
    /// credited artist or an unmistakable domain (Miku/Touhou) in title, album or credit.
    private func performedSongs(_ work: Work, host: String, db: String, keys: [String],
                                search: (String) async throws -> [VocalSong]) async throws -> DatabaseDiscoveryResult {
        guard !keys.isEmpty else { return .init() }
        let context = [work.title, work.detail, work.creator].joined(separator: " ")
        let hint = host == "vocadb.net" ? #"(?i)ミク|miku|初音|vocaloid|ボカロ|ボーカロイド|鏡音|巡音|gumi|重音テト"# : #"(?i)東方|touhou|幻想郷"#
        let domain = context.range(of: hint, options: .regularExpression) != nil
        var root = work; root.publicIdentifiers = root.publicIdentifiers ?? .init()
        var works: [WorkID: Work] = [root.id: root], edges: [RelationEdge] = [], pages: [String] = []
        var multiple = false
        for key in keys.prefix(5) {
            let named = try await search(key).filter { $0.allNames.contains { LeadMatch.same($0, key, loose: false) } }
            let credited = named.filter { row in ([row.artistString] + row.artists.map(\.name)).contains { LeadMatch.sameCreator($0, work.creator) } }
            let pool = credited.isEmpty ? (domain ? named : []) : credited
            let originals = pool.filter { $0.songType == "Original" }
            let candidates = originals.isEmpty ? pool : originals
            guard let song = candidates.first,
                  candidates.count == 1 || Set(candidates.map { $0.originalVersionId ?? $0.id }).count == 1 else { continue }
            let songID = WorkID(rawValue: db.lowercased() + ":song:\(song.id)")!, page = "https://" + host + "/S/\(song.id)"
            works[songID] = .init(id: songID, title: song.name, creator: song.artistString, kind: "音乐作品", art: "", detail: "", url: page)
            let performance = DiscoveryRelation.performanceOf
            edges.append(.init(from: work.id, to: songID, predicate: performance.predicate, label: performance.labels.forward,
                inverseLabel: performance.labels.inverse, source: .init(title: db, url: page), researchRoot: work.id))
            pages.append(page)
            multiple = multiple || song.tags.contains { LeadMatch.norm($0.tag.name) == "multipleoriginals" }
            var lineage = song
            if let originalID = song.originalVersionId, originalID > 0 {
                let original = try JSONDecoder().decode(VocalSong.self, from: await http.get(PublicDatabaseHTTP.endpoint(host, "/api/songs/\(originalID)", ["fields": "Names,Artists,Albums,Tags"])))
                let id = WorkID(rawValue: db.lowercased() + ":song:\(original.id)")!
                works[id] = .init(id: id, title: original.name, creator: original.artistString, kind: "音乐作品", art: "", detail: "", url: "https://" + host + "/S/\(original.id)")
                let relation: DiscoveryRelation = song.songType == "Remix" ? .remixOf : song.songType == "Cover" ? .coverOf : .arrangementOf
                edges.append(.init(from: songID, to: id, predicate: relation.predicate, label: relation.labels.forward, inverseLabel: relation.labels.inverse,
                    source: .init(title: db, url: page), researchRoot: work.id))
                lineage = original
            }
            for album in lineage.albums where album.discType == "Game" {
                let gameID = WorkID(rawValue: db.lowercased() + ":album:\(album.id)")!
                works[gameID] = .init(id: gameID, title: album.name, creator: album.artistString, kind: "游戏", art: "", detail: "", url: "https://" + host + "/Al/\(album.id)")
                edges.append(.init(from: WorkID(rawValue: db.lowercased() + ":song:\(lineage.id)")!, to: gameID, predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐",
                    source: .init(title: db, url: "https://" + host + "/S/\(lineage.id)"), researchRoot: work.id))
            }
        }
        guard !edges.isEmpty else { return .init() }
        return .init(snapshot: .init(works: Array(works.values), relations: edges), multipleOriginals: multiple, pages: pages)
    }

    private func wikidata(_ work: Work) async throws -> DatabaseDiscoveryResult {
        var qid = work.knowledgeID
        let property: String?, value: String?
        if let isrc = work.publicIdentifiers?.isrc { property = "P1243"; value = isrc }
        else if let number = work.catalogID, work.isSong { property = "P10110"; value = number }
        else { property = nil; value = nil }
        if qid == nil, let property, let value {
            let url = PublicDatabaseHTTP.endpoint("www.wikidata.org", "/w/api.php", ["action": "query", "list": "search", "srsearch": "haswbstatement:\(property)=\(value)", "srnamespace": "0", "srlimit": "5", "format": "json"])
            let rows = (try await object(url)["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
            let ids = rows.compactMap { $0["title"] as? String }.filter(WikiSourceIdentity.validQID)
            if ids.count == 1 { qid = ids.first }
        }
        var matchedByTitle = false
        if qid == nil, work.isSong || work.isMusicWork, let found = try? await wikidataByTitle(work) {
            qid = found; matchedByTitle = true
        }
        guard let qid, WikiSourceIdentity.validQID(qid) else { return .init() }
        func endpoint(_ ids: [String]) -> URL {
            PublicDatabaseHTTP.endpoint("www.wikidata.org", "/w/api.php", ["action":"wbgetentities", "ids":ids.joined(separator:"|"), "props":"claims|labels", "languages":"ja|zh-hans|zh|en", "format":"json"])
        }
        guard let entity = try JSONDecoder().decode(WikidataSourceResponse.self, from: await http.get(endpoint([qid]))).entities?[qid], entity.missing == nil else { return .init() }
        if work.knowledgeID == nil, !matchedByTitle, let property, let value, !entity.strings(property).contains(value) { return .init() }
        let mapping: [(String, DiscoveryRelation)] = [("P1441", .usedIn), ("P2550", .performanceOf), ("P144", .adaptationOf), ("P941", .inspiredBy)]
        let proposed = mapping.flatMap { field, relation in entity.eligibleClaims(field).compactMap { claim -> (String, DiscoveryRelation)? in
            guard let target = claim.mainsnak.datavalue?.entityID, WikiSourceIdentity.validQID(target) else { return nil }
            return (target, relation)
        } }
        guard !proposed.isEmpty else { return .init() }
        let targets = try JSONDecoder().decode(WikidataSourceResponse.self, from: await http.get(endpoint(Array(Set(proposed.map(\.0))).sorted()))).entities ?? [:]
        var result = DatabaseDiscoveryResult(snapshot: .init(works: [work], relations: []))
        for (target, relation) in proposed {
            guard let item = targets[target], item.missing == nil else { continue }
            let types = Set(item.eligibleClaims("P31").compactMap { $0.mainsnak.datavalue?.entityID })
            let layer: DiscoveryIdentity.Layer?
            if !types.isDisjoint(with: ["Q11424", "Q202866", "Q20650540"]) { layer = .film }
            else if !types.isDisjoint(with: ["Q5398426", "Q581714", "Q63952888", "Q1107", "Q21191270"]) { layer = .tv }
            else if !types.isDisjoint(with: ["Q7889", "Q7058673"]) { layer = .game }
            else if !types.isDisjoint(with: ["Q571", "Q7725634", "Q747381", "Q8261"]) { layer = .book }
            else if !types.isDisjoint(with: ["Q21198342", "Q8274"]) { layer = .manga }
            else if !types.isDisjoint(with: ["Q2188189", "Q7366", "Q105543609", "Q134556"]) { layer = .musicWork }
            else { layer = nil }
            guard let layer, relation.accepts(from: work.discovery?.layer ?? (work.isSong ? .recording : .film), to: layer) else { continue }
            let id = WorkID(rawValue: "wikidata:" + target)!, page = "https://www.wikidata.org/wiki/" + target
            result.snapshot.works.append(.init(id: id, title: item.title, creator: "", kind: DiscoveryIdentity(layer: layer, canonicalTitle: item.title).displayKind,
                art: "", detail: "", url: page, knowledgeID: target, knowledgeIdentitySource: .init(title: "Wikidata", url: page)))
            result.snapshot.relations.append(.init(from: work.id, to: id, predicate: relation.predicate, label: relation.labels.forward, inverseLabel: relation.labels.inverse,
                source: .init(title: "Wikidata", url: "https://www.wikidata.org/wiki/" + qid), researchRoot: work.id))
        }
        result.pages = result.snapshot.relations.map(\.source.url)
        return result
    }

    private func wikidataByTitle(_ work: Work) async throws -> String? {
        let keys = DatabaseTitleKeys.keys(work.title)
        guard let title = keys.last, !title.isEmpty, !work.creator.isEmpty else { return nil }
        let artist = work.creator.components(separatedBy: CharacterSet(charactersIn: ",，、/&")).first?.trimmingCharacters(in: .whitespaces) ?? work.creator
        let srsearch = "\(title) \(artist)"
        let url = PublicDatabaseHTTP.endpoint("www.wikidata.org", "/w/api.php", ["action": "query", "list": "search", "srsearch": srsearch, "srnamespace": "0", "srlimit": "5", "format": "json"])
        let rows = (try await object(url)["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        let ids = rows.compactMap { $0["title"] as? String }.filter(WikiSourceIdentity.validQID)
        guard !ids.isEmpty else { return nil }
        let entityURL = PublicDatabaseHTTP.endpoint("www.wikidata.org", "/w/api.php", ["action": "wbgetentities", "ids": ids.joined(separator: "|"), "props": "claims|labels", "languages": "ja|zh-hans|zh|en", "format": "json"])
        let entities = try JSONDecoder().decode(WikidataSourceResponse.self, from: await http.get(entityURL)).entities ?? [:]
        let musicTypes: Set<String> = ["Q7366", "Q134556", "Q2188189", "Q105543609", "Q55850593"]
        for id in ids {
            guard let entity = entities[id], entity.missing == nil else { continue }
            let labels = Array((entity.labels ?? [:]).values.map(\.value))
            let sameTitle = labels.contains { label in keys.contains { LeadMatch.same(label, $0, loose: false) } }
            guard sameTitle else { continue }
            let p31 = Set(entity.eligibleClaims("P31").compactMap { $0.mainsnak.datavalue?.entityID })
            let hasRel = !entity.eligibleClaims("P1441").isEmpty || !entity.eligibleClaims("P144").isEmpty || !entity.eligibleClaims("P2550").isEmpty || !entity.eligibleClaims("P941").isEmpty
            if hasRel && (!p31.isDisjoint(with: musicTypes) || !entity.eligibleClaims("P175").isEmpty || !entity.eligibleClaims("P86").isEmpty) {
                return id
            }
        }
        return nil
    }

    private func bangumi(_ work: Work) async throws -> DatabaseDiscoveryResult {
        guard work.isSong else { return .init() }
        let album = (work.discovery?.releaseTitle?.isEmpty == false ? work.discovery!.releaseTitle! : work.detail)
            .replacingOccurrences(of: #"\s*[-–—]\s*Single$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let query = album.isEmpty ? work.title : album
        let body = try JSONSerialization.data(withJSONObject: ["keyword": query, "filter": ["type": [3]]], options: [.sortedKeys])
        let data = try await object(PublicDatabaseHTTP.endpoint("api.bgm.tv", "/v0/search/subjects", ["limit": "5"]), body: body)
        let rows = data["data"] as? [[String: Any]] ?? []
        let matches = rows.filter { row in
            guard LeadMatch.same(row["name"] as? String ?? "", query, loose: false) else { return false }
            let fields = row["infobox"] as? [[String: Any]] ?? []
            return fields.contains { field in
                ["艺术家", "アーティスト", "录音", "厂牌"].contains(field["key"] as? String ?? "")
                    && LeadMatch.sameCreator(field["value"] as? String ?? "", work.creator)
            }
        }
        guard matches.count == 1, let row = matches.first, let number = row["id"] as? Int else { return .init() }
        // Establish song membership from the album track list, not its prose summary.
        let episodes = try await object(PublicDatabaseHTTP.endpoint("api.bgm.tv", "/v0/episodes", ["subject_id": "\(number)", "limit": "100"]))["data"] as? [[String: Any]] ?? []
        guard episodes.contains(where: { LeadMatch.same($0["name"] as? String ?? "", work.title, loose: false) }) else { return .init() }
        let albumID = WorkID(rawValue: "bangumi:subject:\(number)")!
        var albumWork = Work(id: albumID, title: row["name"] as? String ?? query, creator: work.creator, kind: "专辑", art: (row["images"] as? [String: String])?["large"] ?? "", detail: "", url: "https://bgm.tv/subject/\(number)")
        albumWork.bangumiID = "\(number)"
        var result = DatabaseDiscoveryResult(snapshot: .init(works: [work, albumWork], relations: [.init(from: work.id, to: albumID, predicate: .inAlbum,
            label: "收录于", inverseLabel: "收录歌曲", source: .init(title: "Bangumi", url: "https://bgm.tv/subject/\(number)"), researchRoot: work.id)]))
        let related = try JSONDecoder().decode([PublicBangumiRelation].self, from: await http.get(PublicDatabaseHTTP.endpoint("api.bgm.tv", "/v0/subjects/\(number)/subjects")))
        for target in related where [2, 4].contains(target.type) && ["片头曲", "片尾曲", "主题歌", "原声集", "原声带"].contains(target.relation ?? "") {
            let id = WorkID(rawValue: "bangumi:subject:\(target.id)")!
            result.snapshot.works.append(.init(id: id, title: target.name, creator: "", kind: target.type == 4 ? "游戏" : "动画", art: "", detail: "", url: "https://bgm.tv/subject/\(target.id)", bangumiID: "\(target.id)"))
            result.snapshot.relations.append(.init(from: albumID, to: id, predicate: .soundtrackOf, label: target.relation ?? "出自", inverseLabel: "音乐", source: .init(title: "Bangumi", url: "https://bgm.tv/subject/\(number)"), researchRoot: work.id))
        }
        result.pages = ["https://bgm.tv/subject/\(number)"]
        return result
    }
}

private struct VocalSearch: Decodable { let items: [VocalSong] }

/// Search titles for one recording. The first key is the title without a featuring
/// credit; later keys drop performance/edition marks and split medleys, so a live,
/// orchestral or piano recording can still find the song it performs.
enum DatabaseTitleKeys {
    static func keys(_ title: String) -> [String] {
        func strip(_ value: String, _ pattern: String) -> String {
            value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let featured = strip(strip(title, #"\s*[(（\[]\s*(feat|ft)\.?[^)）\]]*[)）\]]"#), #"\s+(feat|ft)\.\s*.*$"#)
        var keys = [featured]
        let seriesTitle = RecordingVersion.searchTitle(featured)
        if seriesTitle != featured { keys.append(seriesTitle) }
        func plain(_ value: String) -> String {
            var current = strip(value, #"^(piano|guitar|orchestra|ピアノ|ギター|オーケストラ)\s*[:：]\s*"#)
            let marks = #"\s*[(（\[【][^)）\]】]*(live|ライブ|現場|现场|remaster|ver\.?|version|バージョン|inst|tv\s*size|edit|再|orchestra|symphon|acoustic|piano|from\s+)[^)）\]】]*[)）\]】]\s*$"#
            while true {
                let next = strip(strip(strip(current, marks), #"\s+-\s+(from|live|remaster|single|.*version).*$"#),
                                 #"\s*[-‐–—~〜～][^-‐–—~〜～]+[-‐–—~〜～]\s*$"#)
                if next == current || next.isEmpty { break }
                current = next
            }
            return current
        }
        let parts = featured.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
        for part in (parts.count >= 2 ? parts : [featured]) {
            let value = plain(part)
            if !value.isEmpty, !keys.contains(where: { LeadMatch.norm($0) == LeadMatch.norm(value) }) { keys.append(value) }
        }
        return Array(keys.prefix(6))
    }
}
private struct VocalSong: Decodable {
    struct Name: Decodable { let value: String }
    struct Artist: Decodable { let name: String }
    struct Album: Decodable { let id: Int; let name: String; let artistString: String; let discType: String }
    struct TagEntry: Decodable { struct Tag: Decodable { let name: String; let additionalNames: String? }; let tag: Tag }
    let id: Int; let name: String; let artistString: String; let songType: String; let lengthSeconds: Int
    let originalVersionId: Int?
    let names: [Name]; let artists: [Artist]; let albums: [Album]; let tags: [TagEntry]
    var allNames: [String] { [name] + names.map(\.value) }
}
