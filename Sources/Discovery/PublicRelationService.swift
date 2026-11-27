import Foundation
import CryptoKit

/// Exact public identifiers only. This collector has no MusicKit dependency and
/// cannot use the name-search/story/seed discovery routes.
actor PublicRelationService {
    static let shared = PublicRelationService()
    typealias Loader = @Sendable (URLRequest) async throws -> Data
    private let load: Loader
    private let directory: URL?
    private let paced: Bool
    private struct Cached: Codable { let data: Data; let fetchedAt: Date }
    private var responses: [URL: Cached] = [:]
    private static let pacer = PublicRelationPacer()
    init(loader: @escaping Loader = PublicRelationService.loadPublic, directory: URL? = PianwaiRuntime.applicationDirectory("PianwaiPublicRelations-v1"), paced: Bool = true) {
        load = loader; self.directory = directory; self.paced = paced
    }
    static func loadPublic(_ request: URLRequest) async throws -> Data {
        guard let url = request.url else { throw CatalogError.invalidLink }
        return try await PublicDatabaseHTTP.shared.get(url)
    }

    nonisolated static func retryDelay(_ value:String?) -> Double {
        if let value, let seconds=Double(value) { return min(30,max(0,seconds)) }
        if let value {
            let format=DateFormatter(); format.locale=Locale(identifier:"en_US_POSIX"); format.timeZone=TimeZone(secondsFromGMT:0)
            format.dateFormat="EEE, dd MMM yyyy HH:mm:ss z"
            if let date=format.date(from:value) { return min(30,max(0,date.timeIntervalSinceNow)) }
        }
        return 5
    }
    private func file(_ key: String) -> URL? {
        directory?.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
    }
    private func fetch(_ url: URL, budget: CatalogRequestBudget) async throws -> Data {
        try Task.checkCancellation()
        guard ["musicbrainz.org", "www.wikidata.org", "api.bgm.tv"].contains(url.host ?? "") else { throw CatalogError.invalidLink }
        if let cached = responses[url] { return cached.data }
        if let path = file(url.absoluteString), let data = try? Data(contentsOf: path), let cached = try? JSONDecoder().decode(Cached.self, from: data), cached.data.count <= 5_000_000 {
            responses[url] = cached; return cached.data
        }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var data=Data()
        for attempt in 0...1 {
            try await budget.charge()
            let queued=Date()
            if paced {
                if WikidataRequestPacer.isWikimedia(url) { try await SourceHTTP.wikidataPacer.wait(for:url) }
                else { try await Self.pacer.wait(url.host!) }
            }
            let started=Date()
            do {
                data=try await load(request)
                await P17Metrics.shared.request(host:url.host!,queued:queued,started:started,status:"ok")
                break
            } catch let retry as PublicRelationRetry {
                await P17Metrics.shared.request(host:url.host!,queued:queued,started:started,status:"throttled")
                guard attempt == 0 else { throw CatalogError.throttled }
                try await Task.sleep(for:.seconds(retry.delay))
            } catch {
                await P17Metrics.shared.request(host:url.host!,queued:queued,started:started,status:"failed")
                throw error
            }
        }
        guard data.count <= 5_000_000 else { throw CatalogError.invalidData }
        let json = try JSONSerialization.jsonObject(with: data)
        guard (json as? [String: Any])?["error"] == nil else { throw CatalogError.invalidData }
        if url.host == "api.bgm.tv", let rows = json as? [[String: Any]] {
            let fields: Set<String> = ["id", "name", "name_cn", "type", "staff", "relation"]
            data = try JSONSerialization.data(withJSONObject: rows.map { $0.filter { fields.contains($0.key) } })
        }
        try Task.checkCancellation()
        responses[url] = Cached(data: data, fetchedAt: Date())
        if let directory, let path = file(url.absoluteString) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(responses[url]) { try? encoded.write(to: path, options: .atomic) }
        }
        return data
    }
    private func endpoint(_ host: String, _ path: String, _ params: [String: String] = [:]) -> URL {
        var c = URLComponents(); c.scheme = "https"; c.host = host; c.path = path
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
    private func wikidata(_ property: String, _ value: String, budget: CatalogRequestBudget) async throws -> ([String], WikidataSourceEntity?, Date) {
        let url = endpoint("www.wikidata.org", "/w/api.php", ["action":"query", "list":"search", "srsearch":"haswbstatement:\(property)=\(value)", "srnamespace":"0", "srlimit":"10", "format":"json"])
        struct Search: Decodable { struct Query: Decodable { struct Hit: Decodable { let title: String }; let search: [Hit] }; let query: Query }
        let rows = try JSONDecoder().decode(Search.self, from: await fetch(url, budget: budget))
        let ids = Array(Set(rows.query.search.map(\.title).filter(WikiSourceIdentity.validQID))).sorted()
        guard ids.count == 1, let id = ids.first else { return (ids, nil, responses[url]?.fetchedAt ?? Date()) }
        let entityURL = endpoint("www.wikidata.org", "/w/api.php", ["action":"wbgetentities", "ids":id, "props":"claims|labels", "languages":"ja|zh-hans|zh|en", "format":"json"])
        let entity = try JSONDecoder().decode(WikidataSourceResponse.self, from: await fetch(entityURL, budget: budget)).entities?[id]
        guard let entity, entity.id == id, entity.missing == nil, entity.strings(property).contains(value) else { return (ids, nil, responses[url]?.fetchedAt ?? Date()) }
        return (ids, entity, responses[entityURL]?.fetchedAt ?? Date())
    }
    private func wikidataBatch(_ targets:[(Work,String,String)], budget:CatalogRequestBudget) async throws -> [String:([String],WikidataSourceEntity?,Date)] {
        let pairs=targets.filter { !$0.2.isEmpty }
        guard !pairs.isEmpty else { return [:] }
        if pairs.count == 1 { let t=pairs[0]; return [t.1+"="+t.2:try await wikidata(t.1,t.2,budget:budget)] }
        // CirrusSearch unions statements inside one filter with `|`. Repeating
        // haswbstatement filters with textual OR silently returns no matches.
        let query="haswbstatement:" + pairs.map { "\($0.1)=\($0.2)" }.joined(separator:"|")
        let url=endpoint("www.wikidata.org","/w/api.php",["action":"query","list":"search","srsearch":query,"srnamespace":"0","srlimit":"50","format":"json"])
        struct Search:Decodable { struct Query:Decodable { struct Hit:Decodable { let title:String }; let search:[Hit] }; let query:Query }
        let data=try await fetch(url,budget:budget)
        let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        guard json?["continue"] == nil else { throw CatalogError.invalidData }
        let ids=Array(Set(try JSONDecoder().decode(Search.self,from:data).query.search.map(\.title).filter(WikiSourceIdentity.validQID))).sorted()
        guard !ids.isEmpty else { return [:] }
        let entityURL=endpoint("www.wikidata.org","/w/api.php",["action":"wbgetentities","ids":ids.joined(separator:"|"),"props":"claims|labels","languages":"ja|zh-hans|zh|en","format":"json"])
        let all=try JSONDecoder().decode(WikidataSourceResponse.self,from:await fetch(entityURL,budget:budget)).entities ?? [:]
        var result:[String:([String],WikidataSourceEntity?,Date)]=[:]
        for (_,property,value) in pairs {
            let matches=all.values.filter { ids.contains($0.id) && $0.missing == nil && $0.strings(property).contains(value) }.sorted { $0.id < $1.id }
            result[property+"="+value]=(matches.map(\.id),matches.count == 1 ? matches.first : nil,responses[entityURL]?.fetchedAt ?? Date())
        }
        return result
    }
    /// The numeric Apple Music / iTunes artist ID in an artist link, if any.
    nonisolated static func appleArtistID(_ link: String) -> String? {
        guard let parts = URLComponents(string: link), let host = parts.host,
              ["music.apple.com", "itunes.apple.com", "geo.music.apple.com"].contains(host) else { return nil }
        let segments = parts.path.split(separator: "/").map(String.init)
        guard let index = segments.firstIndex(of: "artist"), let last = segments.last, index < segments.count-1 else { return nil }
        let digits = last.hasPrefix("id") ? String(last.dropFirst(2)) : last
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? digits : nil
    }
    func resolve(_ work: Work, known: [Work], onPartial: (@Sendable (PublicRelationReport) async -> Void)? = nil) async throws -> PublicRelationReport {
        let cacheKey = "report:" + work.id.rawValue + ":" + (work.storeCountry ?? "unknown")
        if let path = file(cacheKey), let data = try? Data(contentsOf: path),
           let cached = try? JSONDecoder().decode(PublicRelationReport.self, from: data), cached.version == 5 { return cached }
        let budget = CatalogRequestBudget(limit: 20)
        var report = PublicRelationReport()
        var works: [WorkID: Work] = [work.id: work]
        var edges: [RelationEdge] = []
        var evidenceTime = work.catalogFetchedAt ?? Date()
        func hop(_ subject: String, _ field: String, _ level: String, _ candidates: [String], _ verified: Bool, _ source: Source) {
            report.hops.append(.init(subject: subject, field: field, level: level, region: work.storeCountry,
                                     candidates: candidates, verified: verified, source: source, fetchedAt: URL(string: source.url).flatMap { responses[$0]?.fetchedAt } ?? evidenceTime))
        }
        if let track = work.catalogTrack, let source = work.catalogSource {
            hop(work.catalogID ?? work.id.rawValue, "collectionId", "release", [track.albumID], true, source)
            hop(work.catalogID ?? work.id.rawValue, "artistId", "artist", [track.artistID], true, source)
        }
        async let music = musicBrainz(work, budget: budget, onPartial: onPartial)
        var mbArtistAliases: [WorkID: WorkID] = [:]
        var targets: [(Work, String, String)] = []
        if work.isPerson, let id = work.catalogID { targets.append((work, "P2850", id)) }
        if work.isSong, let track = work.catalogTrack {
            if let artist = known.first(where: { $0.isPerson && $0.catalogID == track.artistID }) { targets.append((artist, "P2850", track.artistID)) }
            targets.append((work, "P10110", work.catalogID ?? ""))
            if let album = known.first(where: { $0.isAlbum && $0.catalogID == track.albumID }) { targets.append((album, "P2281", track.albumID)) }
        }
        if work.isAlbum, let id = work.catalogID { targets.append((work, "P2281", id)) }
        var visited = Set<String>()
        let collected=try await collectTargets(targets,work:work,budget:budget,
            state:Resolution(report:report,works:works,edges:edges,visited:visited,aliases:mbArtistAliases,evidenceTime:evidenceTime),onPartial:onPartial)
        report=collected.report; works=collected.works; edges=collected.edges; visited=collected.visited; mbArtistAliases=collected.aliases
        // Known QIDs came from explicit links or verified claims. Their
        // structured relations stay on that entity, never on its songs.
        if let qid = work.knowledgeID, !visited.contains(qid), WikiSourceIdentity.validQID(qid) {
            do {
                let url = endpoint("www.wikidata.org", "/w/api.php", ["action":"wbgetentities", "ids":qid, "props":"claims|labels", "languages":"ja|zh-hans|zh|en", "format":"json"])
                if let entity = try JSONDecoder().decode(WikidataSourceResponse.self, from: await fetch(url, budget: budget)).entities?[qid], entity.id == qid, entity.missing == nil {
                    let source = Source(title: "Wikidata", detail: "subject · " + qid, url: url.absoluteString)
                    for (property, label, kind) in [("P144", "原作", "书籍"), ("P86", "作曲", "创作者"), ("P57", "导演", "创作者")] {
                        for claim in entity.eligibleClaims(property) {
                            guard let targetQID = claim.mainsnak.datavalue?.entityID, WikiSourceIdentity.validQID(targetQID) else { continue }
                            let target = known.first { $0.knowledgeID == targetQID }
                            // Use an already verified ID's name; missing titles
                            // are fetched on expansion instead of rendering a QID.
                            guard let target, target.kind == kind || kind == "书籍" && ["漫画", "书籍"].contains(target.kind) else { continue }
                            works[target.id] = target
                            edges.append(.init(from: work.id, to: target.id, predicate: .publicRelation, label: label, inverseLabel: "作品", source: source))
                            hop(qid, property, "subject", [targetQID], true, source)
                        }
                    }
                    for (field, kind) in [("P6298", "persons"), ("P5732", "subjects")] {
                        let ids = entity.strings(field).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                        hop(qid, field, kind == "persons" ? "person" : "subject", ids, ids.count == 1, source)
                        if ids.count == 1, let id = ids.first {
                            works[work.id]?.bangumiID = id
                            try await appendBangumi(id, kind: kind, origin: work, budget: budget, works: &works, edges: &edges, report: &report)
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.failures.append("Wikidata: " + CatalogError.message(error)) }
        }
        if work.id.rawValue.hasPrefix("bangumi:subject:"), let id = work.id.rawValue.split(separator: ":").last {
            do { try await appendBangumi(String(id), kind: "subjects", origin: work, budget: budget, works: &works, edges: &edges, report: &report) }
            catch is CancellationError { throw CancellationError() }
            catch { report.failures.append("Bangumi: " + CatalogError.message(error)) }
        }
        let (musicReport,isrcs) = try await music
        for item in musicReport.snapshot.works where item.id != work.id { works[item.id] = item }
        edges += musicReport.snapshot.relations; report.hops += musicReport.hops; report.failures += musicReport.failures
        // A MusicBrainz credit is the same person as the iTunes artist only when
        // that MusicBrainz artist itself links to the same Apple Music artist
        // ID. Never by name. Optional: a failed lookup leaves both as they were.
        if let artistID = work.catalogTrack?.artistID,
           let main = known.first(where: { $0.isPerson && $0.catalogID == artistID }) {
            let credited = works.keys.filter { $0.rawValue.hasPrefix("musicbrainz:artist:") && mbArtistAliases[$0] == nil }
                .sorted { $0.rawValue < $1.rawValue }.prefix(4)
            for mb in credited {
                let mbid = String(mb.rawValue.dropFirst("musicbrainz:artist:".count))
                guard UUID(uuidString: mbid) != nil else { continue }
                struct Links: Decodable {
                    struct Relation: Decodable { struct Link: Decodable { let resource: String }; let url: Link? }
                    let relations: [Relation]?
                }
                let url = endpoint("musicbrainz.org", "/ws/2/artist/" + mbid, ["inc": "url-rels", "fmt": "json"])
                do {
                    let links = try JSONDecoder().decode(Links.self, from: await fetch(url, budget: budget))
                    let apple = (links.relations ?? []).compactMap { $0.url?.resource }.compactMap(Self.appleArtistID)
                    if apple.contains(artistID) {
                        works[main.id] = main; mbArtistAliases[mb] = main.id
                        hop(mbid, "url-rels", "artist", [artistID], true, Source(title: "MusicBrainz", detail: "artist url-rels → Apple Music artist", url: url.absoluteString))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
        }
        report.recordingID=musicReport.recordingID; report.storyCredits=musicReport.storyCredits
        if !isrcs.isEmpty {
            let extra=try await collectTargets(isrcs.prefix(1).map { (work,"P1243",$0) },work:work,budget:budget,
                state:Resolution(report:report,works:works,edges:edges,visited:visited,aliases:mbArtistAliases,evidenceTime:evidenceTime),onPartial:onPartial)
            report=extra.report; works=extra.works; edges=extra.edges; mbArtistAliases=extra.aliases
        }
        report.storyCredits = report.storyCredits?.map { credit in
            var credit = credit
            if let raw = WorkID(rawValue: "musicbrainz:artist:" + credit.targetID) {
                credit.targetEntityID = (mbArtistAliases[raw] ?? raw).rawValue
            }
            return credit
        }
        for (alias,target) in mbArtistAliases {
            if let qid=works[target]?.knowledgeID {
                let source=works[target]?.knowledgeIdentitySource
                works[alias]?.knowledgeID=qid
                works[alias]?.knowledgeIdentitySource=source
            } else { works[alias]=nil }
        }
        edges = edges.map { edge in
            .init(from: mbArtistAliases[edge.from] ?? edge.from, to: mbArtistAliases[edge.to] ?? edge.to,
                  predicate: edge.predicate, label: edge.label, inverseLabel: edge.inverseLabel, source: edge.source)
        }
        report.verifiedArtistAliases = mbArtistAliases.filter { works[$0.key] != nil && works[$0.value] != nil }
        report.snapshot = CatalogSnapshot(works: Array(works.values).sorted { $0.id.rawValue < $1.id.rawValue }, relations: edges)
        if report.failures.isEmpty, let directory, let path = file(cacheKey) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: path, options: .atomic)
        }
        return report
    }
    private struct Resolution {
        var report:PublicRelationReport
        var works:[WorkID:Work]
        var edges:[RelationEdge]
        var visited:Set<String>
        var aliases:[WorkID:WorkID]
        var evidenceTime:Date
        var partial:PublicRelationReport { var copy=report; copy.snapshot = CatalogSnapshot(works:Array(works.values),relations:edges); return copy }
    }
    private func collectTargets(_ targets:[(Work,String,String)],work:Work,budget:CatalogRequestBudget,state input:Resolution,
                                onPartial:(@Sendable (PublicRelationReport) async -> Void)?) async throws -> Resolution {
        var state=input
        func hop(_ subject:String,_ field:String,_ level:String,_ candidates:[String],_ verified:Bool,_ source:Source) {
            state.report.hops.append(.init(subject:subject,field:field,level:level,region:work.storeCountry,candidates:candidates,verified:verified,source:source,fetchedAt:state.evidenceTime))
        }
        let identities = try? await wikidataBatch(targets, budget:budget)
        for (target, property, value) in targets where !value.isEmpty {
            do {
                let result: ([String], WikidataSourceEntity?, Date)
                if let identities { result = identities[property+"="+value] ?? ([],nil,Date()) }
                else { result = try await wikidata(property,value,budget:budget) }
                let (candidates, entity, fetchedAt) = result
                state.evidenceTime = fetchedAt
                let source = Source(title: "Wikidata", detail: property + "=" + value, url: entity.map { "https://www.wikidata.org/wiki/" + $0.id } ?? endpoint("www.wikidata.org", "/w/api.php", ["action":"query", "list":"search", "srsearch":"haswbstatement:\(property)=\(value)", "srnamespace":"0", "srlimit":"10", "format":"json"]).absoluteString)
                hop(value, property, target.isPerson ? "artist" : target.isAlbum ? "release" : "recording", candidates, entity != nil, source)
                guard let entity, state.visited.insert(entity.id).inserted else { continue }
                // The fetched P434 statements can name several aliases of one
                // verified artist. Match each MBID exactly; never compare names.
                if target.isPerson {
                    for mbid in entity.strings("P434") {
                        if let id = WorkID(rawValue: "musicbrainz:artist:" + mbid) { state.aliases[id] = target.id }
                    }
                }
                var updated = target; updated.knowledgeID = entity.id; updated.knowledgeIdentitySource = source;
                let bgmField = target.isPerson ? "P6298" : "P5732"
                if entity.strings(bgmField).count == 1 { updated.bangumiID = entity.strings(bgmField).first }
                state.works[target.id] = updated
                if let onPartial { await onPartial(state.partial) }
                for (field, kind) in [("P6298", "persons"), ("P5732", "subjects")] {
                    let ids = entity.strings(field).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                    hop(entity.id, field, kind == "persons" ? "person" : "subject", ids, ids.count == 1, source)
                    guard ids.count == 1, let id = ids.first else { continue }
                    var batchWorks=state.works, batchEdges=state.edges, batchReport=state.report
                    try await appendBangumi(id, kind: kind, origin: target, budget: budget, works: &batchWorks, edges: &batchEdges, report: &batchReport)
                    state.works=batchWorks; state.edges=batchEdges; state.report=batchReport
                    if let onPartial { await onPartial(state.partial) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { state.report.failures.append("Wikidata/Bangumi: " + CatalogError.message(error)) }
        }
        return state
    }
    private func musicBrainz(_ work: Work, budget: CatalogRequestBudget,
                             onPartial: (@Sendable (PublicRelationReport) async -> Void)?) async throws -> (PublicRelationReport, [String]) {
        var report = PublicRelationReport()
        var works: [WorkID: Work] = [work.id: work]
        var edges: [RelationEdge] = []
        var evidenceTime = work.catalogFetchedAt ?? Date()
        func hop(_ subject: String, _ field: String, _ level: String, _ candidates: [String], _ verified: Bool, _ source: Source) {
            report.hops.append(.init(subject: subject, field: field, level: level, region: work.storeCountry,
                                     candidates: candidates, verified: verified, source: source, fetchedAt: URL(string: source.url).flatMap { responses[$0]?.fetchedAt } ?? evidenceTime))
        }
        func credit(_ relation: PublicMBRelation, from origin: WorkID, level: String, external: String) {
            guard let artist = relation.artist, UUID(uuidString: artist.id) != nil,
                  let mapping = Self.creditLabels[relation.type] else { return }
            let id = WorkID(rawValue: "musicbrainz:artist:" + artist.id)!
            works[id] = Work(id: id, title: artist.name, creator: "音乐人", kind: "创作者", art: "", detail: "", url: "https://musicbrainz.org/artist/" + artist.id, linkedCreatorIDs: [])
            let source = Source(title: "MusicBrainz", detail: "\(level) · \(relation.type) · \(work.storeCountry ?? "")", url: "https://musicbrainz.org/\(level)/\(external)")
            edges.append(.init(from: origin, to: id, predicate: mapping.0, label: mapping.1, inverseLabel: "作品", source: source))
            hop(external, relation.type, level, [artist.id], true, source)
        }
        var isrcs: [String] = []
        if work.isSong, let track = work.catalogTrack, let region = work.storeCountry {
            do {
                let albumURL = "https://music.apple.com/\(region)/album/\(track.albumID)"
                let url = endpoint("musicbrainz.org", "/ws/2/url/", ["resource":albumURL, "inc":"release-rels", "fmt":"json"])
                struct Lookup: Decodable { let relations: [PublicMBRelation] }
                let lookup = try JSONDecoder().decode(Lookup.self, from: await fetch(url, budget: budget))
                evidenceTime = responses[url]?.fetchedAt ?? Date()
                let ids = Array(Set(lookup.relations.compactMap { $0.release?.id }.filter { UUID(uuidString: $0) != nil })).sorted()
                let source = Source(title: "MusicBrainz", detail: "Apple collectionId → release", url: url.absoluteString)
                hop(track.albumID, "collectionId", "release", ids, ids.count == 1, source)
                if ids.count == 1, let releaseID = ids.first {
                    let url = endpoint("musicbrainz.org", "/ws/2/release/" + releaseID, ["fmt":"json", "inc":"recordings+isrcs+artist-credits+recording-level-rels+work-rels+work-level-rels+artist-rels+url-rels"])
                    let releaseData = try await fetch(url, budget: budget)
                    let release = try JSONDecoder().decode(PublicMBRelease.self, from: releaseData)
                    evidenceTime = responses[url]?.fetchedAt ?? Date()
                    let recording = release.id == releaseID ? release.matchingRecording(work) : nil
                    hop(releaseID, "url+discNumber+trackNumber+trackCount+duration+title", "recording", recording.map { [$0.id] } ?? [], recording != nil,
                        Source(title: "MusicBrainz", detail: "反向链接与盘轨核对", url: url.absoluteString))
                    if let recording {
                        report.recordingID = recording.id; isrcs = recording.isrcs ?? []
                        report.storyCredits = StoryMusicBrainzCredits.fromRelease(releaseData, verifiedRecordingID: recording.id)
                        for relation in recording.relations ?? [] {
                            credit(relation, from: work.id, level: "recording", external: recording.id)
                            if relation.type == "performance", let composition = relation.work, UUID(uuidString: composition.id) != nil {
                                hop(recording.id, "performance", "work", [composition.id], true, Source(title: "MusicBrainz", url: "https://musicbrainz.org/recording/" + recording.id))
                                for c in composition.relations ?? [] { credit(c, from: work.id, level: "work", external: composition.id) }
                            }
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch CatalogError.notFound {
                let url = endpoint("musicbrainz.org", "/ws/2/url/", ["resource":"https://music.apple.com/\(region)/album/\(track.albumID)", "inc":"release-rels", "fmt":"json"])
                hop(track.albumID, "collectionId", "release", [], false, Source(title: "MusicBrainz", detail: "exact URL: no release", url: url.absoluteString))
            }
            catch { report.failures.append("MusicBrainz: " + CatalogError.message(error)) }
        }
        report.snapshot = CatalogSnapshot(works: Array(works.values), relations: edges)
        if let onPartial { await onPartial(report) }
        return (report, isrcs)
    }
    private func appendBangumi(_ id: String, kind: String, origin: Work, budget: CatalogRequestBudget,
                               works: inout [WorkID: Work], edges: inout [RelationEdge], report: inout PublicRelationReport) async throws {
        let url = endpoint("api.bgm.tv", "/v0/\(kind)/\(id)/subjects")
        let rows = try JSONDecoder().decode([PublicBangumiRelation].self, from: await fetch(url, budget: budget))
        guard rows.count <= 2000 else { throw CatalogError.invalidData }
        for row in rows {
            guard row.id > 0, [1, 2, 3].contains(row.type), let raw = kind == "persons" ? row.staff : row.relation,
                  let label = Self.bangumiLabel(raw, type: row.type) else { continue }
            let target = WorkID(rawValue: "bangumi:subject:\(row.id)")!
            works[target] = Work(id: target, title: row.title, creator: "", kind: row.kind, art: "", detail: "", url: "https://bgm.tv/subject/\(row.id)", linkedCreatorIDs: [], bangumiID: String(row.id))
            let source = Source(title: "Bangumi", detail: "\(kind) · \(id) · \(raw)", url: url.absoluteString)
            edges.append(.init(from: origin.id, to: target, predicate: .publicRelation, label: label, inverseLabel: label, source: source))
            report.hops.append(.init(subject: id, field: raw, level: kind == "persons" ? "person" : "subject", region: origin.storeCountry,
                                     candidates: [String(row.id)], verified: true, source: source, fetchedAt: responses[url]?.fetchedAt ?? Date()))
        }
    }
    static func bangumiLabel(_ raw: String, type: Int) -> String? {
        if raw == "艺术家" { return type == 3 ? "发行作品" : nil }
        return bangumiLabels[raw]
    }
    func series(for id: String) async throws -> [String] {
        let rows = try JSONDecoder().decode([PublicBangumiRelation].self,
            from: await fetch(endpoint("api.bgm.tv", "/v0/subjects/" + id + "/subjects"), budget: CatalogRequestBudget(limit: 1)))
        return rows.filter { ["前传", "续集", "总集篇", "番外篇"].contains($0.relation ?? "") }.map { String($0.id) }
    }
    func artworkIdentity(_ work: Work) async throws -> Work {
        if work.isPerson, work.id.rawValue.hasPrefix("musicbrainz:artist:"),
           let mbid = work.id.rawValue.split(separator: ":").last, UUID(uuidString: String(mbid)) != nil {
            var updated = work
            let budget = CatalogRequestBudget(limit: 3), id = String(mbid)
            if updated.knowledgeID == nil, let result = try? await wikidata("P434", id, budget: budget), let entity = result.1 {
                updated.knowledgeID = entity.id
                updated.knowledgeIdentitySource = Source(title: "Wikidata", detail: "P434=" + id, url: "https://www.wikidata.org/wiki/" + entity.id)
            }
            // The credited artist may publish an Apple link in MusicBrainz
            // even when Wikidata has no image or Apple identifier.
            if updated.catalogID == nil {
                struct Artist: Decodable {
                    let id: String
                    let relations: [Relation]?
                    struct Relation: Decodable { struct Link: Decodable { let resource: String }; let url: Link? }
                }
                let url = endpoint("musicbrainz.org", "/ws/2/artist/" + id, ["inc": "url-rels", "fmt": "json"])
                if let data = try? await fetch(url, budget: budget), let artist = try? JSONDecoder().decode(Artist.self, from: data), artist.id == id {
                    let ids = Set((artist.relations ?? []).compactMap { $0.url?.resource }.compactMap(Self.appleArtistID))
                    if ids.count == 1 {
                        updated.catalogID = ids.first
                        updated.catalogSource = Source(title: "MusicBrainz", detail: "artist url-rels → Apple Music artist", url: url.absoluteString)
                    }
                }
            }
            return updated
        }
        guard !work.isPerson, work.knowledgeID == nil, let id = work.bangumiID else { return work }
        let (_, entity, _) = try await wikidata("P5732", id, budget: CatalogRequestBudget(limit: 2))
        guard let entity else { return work }
        var updated = work; updated.knowledgeID = entity.id
        updated.knowledgeIdentitySource = Source(title: "Wikidata", detail: "P5732=" + id, url: "https://www.wikidata.org/wiki/" + entity.id)
        return updated
    }
    static let creditLabels: [String: (RelationKind, String)] = ["composer":(.composedBy,"作曲"), "lyricist":(.publicRelation,"作词"), "arranger":(.arrangedBy,"编曲"), "vocal":(.performedBy,"演唱")]
    static let bangumiLabels = ["音乐":"配乐", "音楽":"配乐", "作曲":"作曲", "作词":"作词", "编曲":"编曲", "主题歌演出":"演唱", "艺术家":"发行作品", "原作":"原作", "改编":"改编", "原声集":"原声集", "原声带":"原声集", "片头曲":"片头曲", "片尾曲":"片尾曲", "主题歌":"主题歌", "书籍":"相关书籍", "前传":"前传", "续集":"续集"]
}
private actor PublicRelationPacer {
    private var last: [String: ContinuousClock.Instant] = [:]
    func wait(_ host: String) async throws {
        while let last = last[host], ContinuousClock.now < last.advanced(by: .seconds(1)) {
            try await ContinuousClock().sleep(until: last.advanced(by: .seconds(1)), tolerance: .zero)
        }
        try Task.checkCancellation(); last[host] = .now
    }
}

struct PublicRelationRetry: Error, Sendable { let delay: Double }
