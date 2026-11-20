import Foundation

struct ResearchHTTPEvent: Codable, Sendable {
    let kind: String
    let status: Int
    let seconds: Double
}

actor ResearchRequestBudget {
    enum Failure: Error { case exhausted }
    private var counts: [String: Int] = [:]
    private var events: [ResearchHTTPEvent] = []
    let limits: [String: Int]
    init(limits: [String: Int] = ["search": 7, "fetch": 2, "model": 3]) { self.limits = limits }
    func reserve(_ kind: String) throws {
        guard counts[kind, default: 0] < limits[kind, default: 0] else { throw Failure.exhausted }
        counts[kind, default: 0] += 1
    }
    func record(_ event: ResearchHTTPEvent) { events.append(event) }
    func receipt() -> [ResearchHTTPEvent] { events }
}

struct ResearchHTTP: Sendable {
    enum Failure: Error { case noAccess, http(Int), replyTooLarge, deadline, badReply, noEvidence }
    let session: URLSession
    let budget: ResearchRequestBudget
    let reservation: (@Sendable () async throws -> Void)?
    init(session: URLSession = .shared, budget: ResearchRequestBudget = .init(), reservation: (@Sendable () async throws -> Void)? = nil) {
        self.session = session; self.budget = budget; self.reservation = reservation
    }
    func post(_ url: URL, body: Data, credential: String, kind: String, timeout: Double) async throws -> Data {
        guard !credential.isEmpty else { throw Failure.noAccess }
        try await budget.reserve(kind)
        try await reservation?()
        let started = Date()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        TrialRelay.mark(&request)
        var recorded = false
        do {
            let prepared = request
            let (data, status): (Data, Int) = try await withThrowingTaskGroup(of: (Data, Int).self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: prepared)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                group.addTask { try await Task.sleep(for: .seconds(timeout)); throw Failure.deadline }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw Failure.badReply }; return value
            }
            await budget.record(.init(kind: kind, status: status, seconds: Date().timeIntervalSince(started)))
            recorded = true
            // The relay said no (the pass ran out, the day's free lookups are gone): ask it what is left.
            if status != 200, url.host == TrialAccess.relayHost { await TrialAccess.shared.refresh() }
            guard status == 200 else { throw Failure.http(status) }
            guard data.count <= 4_000_000 else { throw Failure.replyTooLarge }
            return data
        } catch {
            // Provider messages and request headers never enter diagnostics.
            if !recorded { await budget.record(.init(kind: kind, status: 0, seconds: Date().timeIntervalSince(started))) }
            throw error
        }
    }
}

struct ResearchMaterialCollection: Codable, Sendable {
    let packet: ResearchMaterialPacket
    let discoveredPages: [ResearchPage]
    var events: [ResearchHTTPEvent]? = nil
}

struct ResearchMaterialCollector: Sendable {
    let http: ResearchHTTP
    private struct SearchReply: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let url: String?; let title: String?; let content: String?; let site_name: String?
            let authority: Int?; let rerank_score: Double?; let date: String?
        }
        let results: [Item]
    }
    private struct FetchReply: Decodable, Sendable { let title: String?; let content: String? }

    func collect(_ topic: ResearchTopic, credential: String, queries override: [ResearchQuery]? = nil,
                 storyOnly: Bool = false,
                 previousPages: [ResearchPage] = []) async throws -> ResearchMaterialCollection {
        let queries = override ?? ResearchMaterials.queryPlan(topic, storyOnly: storyOnly), started = Date()
        // Each query reports whether the search itself answered. If none did, the
        // search service is down or the key is refused: that is a failure to show
        // and retry, never a cached "nothing found" (EVAL-0.5.15 review #4).
        let outcomes = await withTaskGroup(of: (Int, [ResearchPage], Error?).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    guard let body = try? JSONSerialization.data(withJSONObject: ["query": query.text, "count": 8, "need_content": true,
                        "ori_question": String((topic.title + " " + topic.creator + " 作品关联与创作经过").prefix(128))]) else { return (index, [], nil) }
                    let data: Data
                    do {
                        data = try await http.post(TrialRelay.toolURL("search", credential: credential),
                            body: body, credential: credential, kind: "search", timeout: 9)
                    } catch ResearchRequestBudget.Failure.exhausted { return (index, [], nil) }
                    catch { return (index, [], error) }
                    guard let reply = try? JSONDecoder().decode(SearchReply.self, from: data) else { return (index, [], ResearchHTTP.Failure.badReply) }
                    let pages: [ResearchPage] = reply.results.compactMap { item in
                        guard let raw = item.url, let url = ResearchMaterials.safeURL(raw) else { return nil }
                        return ResearchPage(url: url, title: item.title ?? "", text: String((item.content ?? "").prefix(80_000)),
                            purposes: [query.purpose], publisher: item.site_name, authority: item.authority,
                            searchRank: item.rerank_score, publishedAt: item.date)
                    }
                    return (index, pages, nil)
                }
            }
            var values: [(Int, [ResearchPage], Error?)] = []
            for await outcome in group { values.append(outcome) }
            return values.sorted { $0.0 < $1.0 }
        }
        let failures = outcomes.compactMap(\.2)
        if !queries.isEmpty, failures.count == outcomes.count, let first = failures.first { throw first }
        let batches = outcomes.flatMap(\.1)
        try Task.checkCancellation()
        let searchSeconds = Date().timeIntervalSince(started), fetchStart = Date()
        var pages = previousPages + batches, missing: [ResearchPage] = [], seen: Set<String> = []
        if Set(pages.filter { $0.text.count >= 160 }.map(\.url)).count < 4 {
            for page in pages where page.text.count < 160 && seen.insert(page.url).inserted {
                missing.append(page); if missing.count == 2 { break }
            }
        }
        let targets = missing
        let fetched = await withTaskGroup(of: ResearchPage?.self) { group in
            for page in targets {
                group.addTask {
                    guard let body = try? JSONEncoder().encode(["url": page.url]),
                          let data = try? await http.post(TrialRelay.toolURL("fetch", credential: credential), body: body,
                            credential: credential, kind: "fetch", timeout: 6),
                          let reply = try? JSONDecoder().decode(FetchReply.self, from: data),
                          let text = reply.content, text.count >= 160 else { return nil }
                    return ResearchPage(url: page.url, title: reply.title ?? page.title, text: String(text.prefix(80_000)),
                        purposes: page.purposes, publisher: page.publisher, authority: page.authority,
                        searchRank: page.searchRank, publishedAt: page.publishedAt)
                }
            }
            var values: [ResearchPage] = []
            for await page in group { if let page { values.append(page) } }
            return values
        }
        pages += fetched
        let fetchSeconds = Date().timeIntervalSince(fetchStart), selectionStart = Date()
        let sources = ResearchMaterials.select(pages, topic: topic)
        return ResearchMaterialCollection(packet: .init(topic: topic, queries: queries, sources: sources, fetchedAt: Date(),
            searchSeconds: searchSeconds, fetchSeconds: fetchSeconds, searches: queries.count, fetches: targets.count,
            selectionSeconds: Date().timeIntervalSince(selectionStart)),
            discoveredPages: pages, events: await http.budget.receipt())
    }

    /// One bounded structural follow-up, based on observed metadata, never a
    /// per-song expected answer. These query suffixes apply to every provider.
    func enrich(_ previous: ResearchMaterialCollection, credential: String) async throws -> ResearchMaterialCollection {
        let topic = previous.packet.topic
        let original = ResearchMaterials.queryPlan(topic).first?.text ?? topic.title
        let asian = [topic.title, topic.creator, topic.album].joined().range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil
        let queries: [ResearchQuery] = [
            .init(purpose: .lineage, text: String((original + (asian ? " 原曲 作曲 原作ゲーム" : " original composer game concerto movement")).prefix(128))),
            .init(purpose: .context, text: String((original + (asian ? " 原曲 出典 公式" : " original work catalogue movement source")).prefix(128)))
        ]
        let result = try await collect(topic, credential: credential, queries: queries, previousPages: previous.discoveredPages)
        let old = previous.packet, new = result.packet
        let packet = ResearchMaterialPacket(topic: topic, queries: old.queries + new.queries, sources: new.sources, fetchedAt: new.fetchedAt,
            searchSeconds: old.searchSeconds + new.searchSeconds, fetchSeconds: old.fetchSeconds + new.fetchSeconds,
            searches: old.searches + new.searches, fetches: old.fetches + new.fetches,
            selectionSeconds: (old.selectionSeconds ?? 0) + (new.selectionSeconds ?? 0))
        return .init(packet: packet, discoveredPages: result.discoveredPages, events: result.events)
    }
}

extension ResearchMaterialCollection {
    /// The same collection with pages read outside the web search (Wikipedia) added and the
    /// packet chosen again. Search counts are unchanged: these reads cost nothing.
    func adding(_ pages: [ResearchPage], maxPages: Int = 8, totalCharacters: Int = 20_000, directCharacters: Int = 9_000) -> ResearchMaterialCollection {
        guard !pages.isEmpty || maxPages != 8 || totalCharacters != 20_000 else { return self }
        // The search's own copy of an article read directly would only take its room twice.
        let direct = Set(pages.compactMap { Self.wikipediaKey($0.url) })
        let searched = discoveredPages.filter { page in Self.wikipediaKey(page.url).map { !direct.contains($0) } ?? true }
        let all = pages + searched, p = packet
        let sources = ResearchMaterials.select(all, topic: p.topic, maxPages: maxPages, totalCharacters: totalCharacters, directCharacters: directCharacters)
        return .init(packet: .init(topic: p.topic, queries: p.queries, sources: sources, fetchedAt: p.fetchedAt,
            searchSeconds: p.searchSeconds, fetchSeconds: p.fetchSeconds, searches: p.searches, fetches: p.fetches,
            selectionSeconds: p.selectionSeconds), discoveredPages: all, events: events)
    }
    /// 「ja.wikipedia.org/wiki/Lemon_(米津玄師の曲)」, 「ja.m.wikipedia.org/wiki/Lemon%20(…)」 and
    /// 「zh.wikipedia.org/zh-cn/…」 are one article.
    static func wikipediaKey(_ url: String) -> String? {
        guard let address = URL(string: url), let host = address.host?.lowercased(), host.hasSuffix("wikipedia.org"),
              let language = host.components(separatedBy: ".").first else { return nil }
        let title = (address.lastPathComponent.removingPercentEncoding ?? address.lastPathComponent).replacingOccurrences(of: " ", with: "_")
        return language + ":" + title.lowercased()
    }
}
