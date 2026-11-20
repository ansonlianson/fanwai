import Foundation

/// A numeric task ledger. Failed requests consume the same budget as successful ones.
actor ModelRequestLedger {
    static let shared = ModelRequestLedger()
    func reserve(_ configuration: ResearchModelConfiguration, kind: String = "model") throws {
        guard let root = ProcessInfo.processInfo.environment["PIANWAI_ARCH2_OUTPUT"],
              root.hasSuffix("/QA/ARCH2") else { return }
        let file = URL(fileURLWithPath: root).appendingPathComponent("MODEL-BUDGET.json")
        var counts = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        let provider = configuration.providerID == "internal" ? "internal" : configuration.isDeepSeek ? "deepseek" : "other"
        let limit = provider == "internal" ? 60 : provider == "deepseek" ? 60 : 0
        guard counts[provider, default: 0] < limit else { throw ResearchRequestBudget.Failure.exhausted }
        counts[provider, default: 0] += 1; counts[provider + ":" + kind, default: 0] += 1
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(counts).write(to: file, options: .atomic)
    }
}

enum ConfiguredResearchTransport {
    static func send(_ prompt: String, configuration: ResearchModelConfiguration, subject: LeadSubject,
                     knownFacts: [String] = [], skipRelations: Bool = false, skipStory: Bool = false, hints: ResearchHints = .init(),
                     writing: StoryWritingPreferences = StoryWritingStore.runtime.load(),
                     progress: (@Sendable (DiscoveryProgressEvent) async -> Void)? = nil) async throws -> ResearchNativeAnswer {
        // A lookup on a 体验码 pass: everything it sends carries one mark, so the relay charges it once.
        if configuration.isTrial, TrialRelay.lookup == nil {
            return try await TrialRelay.$lookup.withValue(.init(subjectID: subject.id, title: subject.title, creator: subject.creator)) {
                try await send(prompt, configuration: configuration, subject: subject, knownFacts: knownFacts, skipRelations: skipRelations,
                               skipStory: skipStory, hints: hints, writing: writing, progress: progress)
            }
        }
        if configuration.endpoint.api == .responses {
            return try await native(prompt, configuration: configuration, progress: progress)
        }
        // E10 material selection and literal binding are shared with all Chat adapters.
        let effectiveAlbum = subject.album.isEmpty ? (subject.identity?.releaseTitle ?? subject.identity?.edition ?? "") : subject.album
        let topic = ResearchTopic(id: subject.id, title: subject.title, creator: subject.creator,
            album: effectiveAlbum, layer: subject.identity?.layer.rawValue ?? "recording",
            canonicalTitle: subject.identity?.canonicalTitle, catalogue: subject.identity?.catalogue,
            movement: subject.identity?.movement)
        let collection: ResearchMaterialCollection
        var planUsage: StoryModelUsage? = nil
        if configuration.isDeepSeek {
            let budget = ResearchRequestBudget(limits: ["search": skipRelations ? 3 : 6, "fetch": 2, "model": 0])
            let stageStarted = Date()
            // Wikipedia (free) is read while the search words are written; the search follows them.
            let firstWiki = Task { await WikipediaMaterials.pages(topic: topic, hints: hints) }
            let draft = ResearchMaterials.queryPlan(topic, storyOnly: skipRelations)
            let plan = await ResearchQueryPlanner.plan(topic: topic, knownFacts: knownFacts, draft: draft, storyOnly: skipRelations,
                                                       client: configuration.client(), configuration: configuration)
            let plannedAt = Date()
            planUsage = plan.usage
            async let searched = ResearchMaterialCollector(http: .init(budget: budget, reservation: {
                try await ModelRequestLedger.shared.reserve(configuration, kind: "material")
            })).collect(topic, credential: configuration.credential.value, queries: plan.queries, storyOnly: skipRelations)
            // The planner's own names find what the store's spelling did not (a Western singer in
            // katakana, a work the databases did not know); tried while the search runs.
            let allWiki = Task { () -> [ResearchPage] in
                var wiki = await firstWiki.value
                let needSong = !wiki.contains { $0.purposes.contains(.story) }, needWork = !wiki.contains { !$0.purposes.contains(.story) }
                if plan.planned, needSong && (plan.hints.title != nil || plan.hints.artist != nil) || needWork && !plan.hints.works.isEmpty {
                    var named = hints
                    let own = LeadMatch.norm(topic.title + " " + topic.album)
                    named.title = plan.hints.title; named.artist = plan.hints.artist
                    named.works = hints.works + plan.hints.works.map { work in
                        var work = work; let key = LeadMatch.norm(WikipediaMaterials.bracketed(work.name) ?? work.name)
                        work.known = key.count >= 2 && own.contains(key) ? true : nil; return work
                    }
                    wiki += await WikipediaMaterials.pages(topic: topic, hints: named, songs: needSong, works: needWork)
                }
                return wiki
            }
            let found = try await searched
            let searchedAt = Date()
            // Wikipedia never holds the lookup up (unreachable without a VPN in mainland China, or
            // throttled): once the search has answered, it gets one and a half seconds more.
            let wiki = await MetadataDeadline.value(seconds: 1.5) { await allWiki.value } ?? []
            allWiki.cancel(); firstWiki.cancel()
            EvalResearchCapture.value(wiki.map { ["url": $0.url, "characters": String($0.text.count)] }, name: "wikipedia.json")
            EvalResearchCapture.value(["plan": plannedAt.timeIntervalSince(stageStarted), "search": searchedAt.timeIntervalSince(plannedAt),
                                       "wikipediaWait": Date().timeIntervalSince(searchedAt)], name: "timing.json")
            collection = found.adding(wiki)
        } else {
            collection = .init(packet: .init(topic: topic, queries: [], sources: [], fetchedAt: Date(),
                searchSeconds: 0, fetchSeconds: 0, searches: 0, fetches: 0), discoveredPages: [])
        }
        EvalResearchCapture.value(collection, name: "collection.json")
        if RecordingVersion.isFirstTake(subject.title) {
            ResearchMaterialStore(directory: PianwaiRuntime.cacheDirectory("FirstTakeMaterials-v1")).write(.init(packet: collection.packet, discoveredPages: []))
        }
        if collection.packet.sources.isEmpty {
            return .init(answer: .init(text: #"{"leads":[],"relations":[],"story":null}"#, completed: true,
                usage: .init(model: configuration.endpoint.model, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0),
                seconds: 0), observedURLs: [], webToolCalls: collection.packet.searches)
        }
        let started = Date()
        let client = configuration.client()
        if skipRelations {
            // 铁律二 + 铁律三：免费库已给出合格作品卡，跳过找卡调用（Call A = 0 Token），只调用窄合同写独立幕后故事（Call B）。
            try await ModelRequestLedger.shared.reserve(configuration, kind: "story")
            let storyReply = try await client.complete(system: ResearchWriter.storySystemRules,
                user: ResearchWriter.storyPrompt(writing: writing, packet: ResearchWriter.storyMaterials(collection.packet)), maxTokens: 3000)
            EvalResearchCapture.data(Data(storyReply.text.utf8), name: "story-raw.txt", secret: configuration.credential.value)
            let storyObj = ResearchWriter.groundStory(storyReply.text, packet: collection.packet)
            let combined = try ResearchWriter.combineNarrow(leads: [], relations: [], story: storyObj)
            let parts = [planUsage, storyReply.usage].compactMap { $0 }
            return .init(answer: .init(text: combined, completed: !storyReply.text.isEmpty,
                usage: .init(model: storyReply.model, inputTokens: parts.reduce(0) { $0 + $1.inputTokens },
                    cachedInputTokens: parts.reduce(0) { $0 + $1.cachedInputTokens }, outputTokens: parts.reduce(0) { $0 + $1.outputTokens },
                    reasoningTokens: parts.reduce(0) { $0 + $1.reasoningTokens }), seconds: Date().timeIntervalSince(started)),
                observedURLs: collection.packet.sources.map(\.url), webToolCalls: collection.packet.searches)
        } else {
            // 铁律三：搜写拆为两个并行极简窄合同（Call A 仅补缺口卡片，Call B 仅写独立故事）。
            // Each call fails on its own: a transport failure is retried once, and a
            // story is never thrown away because the relation call failed (or back).
            try await ModelRequestLedger.shared.reserve(configuration, kind: "relations+story")
            let relationsUser = ResearchWriter.relationsPrompt(packet: collection.packet, knownFacts: knownFacts)
            let storyUser = ResearchWriter.storyPrompt(writing: writing, packet: ResearchWriter.storyMaterials(collection.packet))
            let packet = collection.packet, secret = configuration.credential.value
            // Call A, then (if it found the show, film or game) the 同门 stage, while Call B runs alongside.
            // Names the free databases already gave (「from | label | to | url」) are trusted spellings.
            let knownNames = knownFacts.flatMap { fact -> [String] in
                let parts = fact.components(separatedBy: " | "); return parts.count >= 3 ? [parts[0], parts[2]] : []
            }
            async let relationPart = Self.relationsAndSiblings(client: client, configuration: configuration, packet: packet, user: relationsUser, knownNames: knownNames)
            // A sleeve followed on the map wants its related works only (anson 2026-11-18): no story
            // call is made or paid for; the page offers 查幕后 when the reader opens it.
            async let storyTask: Result<StoryModelReply, Error>? = skipStory ? nil
                : Self.attempt { try await client.complete(system: ResearchWriter.storySystemRules, user: storyUser, maxTokens: 3000) }
            let (relation, storyResult) = await (relationPart, storyTask)
            let relResult = relation.reply
            let relReply = try? relResult.get(), storyReply = try? storyResult?.get()
            if relReply == nil, storyReply == nil { _ = try relResult.get() }
            if let relReply { EvalResearchCapture.data(Data(relReply.text.utf8), name: "relations-raw.txt", secret: secret) }
            let relGrounded = (leads: relation.leads, relations: relation.relations)
            var storyObj = storyReply.flatMap { reply -> [String: Any]? in
                EvalResearchCapture.data(Data(reply.text.utf8), name: "story-raw.txt", secret: configuration.credential.value)
                return ResearchWriter.groundStory(reply.text, packet: collection.packet)
            }
            // The song has no story of its own: one level out, once (设置 › 放宽故事范围).
            var wider = WiderStory()
            if storyObj == nil, storyReply != nil, !skipStory, Self.widerStoryEnabled {
                wider = await Self.widerStory(client: client, configuration: configuration, packet: packet,
                                              leads: relGrounded.leads, relations: relGrounded.relations, writing: writing)
                storyObj = wider.story
            }
            let combined = try ResearchWriter.combineNarrow(leads: relGrounded.leads, relations: relGrounded.relations, story: storyObj)
            let usages = [planUsage, relReply?.usage, storyReply?.usage, relation.siblingUsage, wider.usage].compactMap { $0 }
            // A half answer is shown but not marked complete.
            return .init(answer: .init(text: combined, completed: relReply != nil && (storyReply != nil || skipStory),
                usage: .init(model: relReply?.model ?? storyReply?.model ?? configuration.endpoint.model,
                    inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
                    cachedInputTokens: usages.reduce(0) { $0 + $1.cachedInputTokens },
                    outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
                    reasoningTokens: usages.reduce(0) { $0 + $1.reasoningTokens }),
                seconds: Date().timeIntervalSince(started)),
                observedURLs: (packet.sources.map(\.url) + relation.siblingURLs + wider.urls), webToolCalls: packet.searches + relation.siblingSearches + wider.searches)
        }
    }

    struct WiderStory: @unchecked Sendable {
        var story: [String: Any]? = nil
        var usage: StoryModelUsage? = nil
        var searches = 0
        var urls: [String] = []
    }
    /// 设置 › 放宽故事范围 (anson 2026-11-18 13:00: on, as a switch the reader can turn off).
    static let widerStoryKey = "research.widerStory"
    static var widerStoryEnabled: Bool { UserDefaults.standard.object(forKey: widerStoryKey) as? Bool ?? true }
    /// What one extra wider-story attempt uses: one search and one writing call over its pages.
    static func widerStoryCost(_ price: ModelPrice?) -> Double? { price?.cost(inputTokens: 9_000, outputTokens: 700, searches: 1) }
    /// Where the song belongs: the show, film or game it was made for; else its album; else its maker.
    static func home(packet: ResearchMaterialPacket, leads: [[String: Any]], relations: [[String: Any]]) -> (name: String, kind: String) {
        var origins: Set<String> = ["current", "_piece"]
        for edge in relations where edge["from"] as? String == "current" && edge["relation"] as? String == "performance_of" {
            if let piece = edge["to"] as? String { origins.insert(piece) }
        }
        for edge in relations where origins.contains(edge["from"] as? String ?? "") && ["created_for", "used_in", "part_of"].contains(edge["relation"] as? String ?? "") {
            if let node = leads.first(where: { $0["ref"] as? String == edge["to"] as? String }),
               let kind = node["target_type"] as? String, ["tv", "film", "game"].contains(kind), let name = node["name"] as? String, !name.isEmpty {
                return (name, kind)
            }
        }
        let album = packet.topic.album.replacingOccurrences(of: #"\s*-\s*(?:EP|Single)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if album.count >= 2 { return (album, "album") }
        return (packet.topic.creator, "artist")
    }
    static func widerStory(client: any StoryModelClient, configuration: ResearchModelConfiguration, packet: ResearchMaterialPacket,
                           leads: [[String: Any]], relations: [[String: Any]], writing: StoryWritingPreferences) async -> WiderStory {
        var result = WiderStory()
        guard configuration.isDeepSeek else { return result }
        let topic = packet.topic, place = Self.home(packet: packet, leads: leads, relations: relations)
        guard place.name.count >= 2 else { return result }
        let credit = DiscoveryNavigation.mainCreatorName(topic.creator)
        let combined = [topic.title, topic.creator, topic.album, place.name].joined()
        let kana = ResearchMaterials.hasKana(combined), han = combined.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let words = place.kind == "album" ? (kana ? " アルバム インタビュー 制作" : han ? " 专辑 采访 创作" : " album interview making of")
            : place.kind == "artist" ? (kana ? " インタビュー" : han ? " 采访" : " interview")
            : (kana ? " 音楽 インタビュー 制作" : han ? " 配乐 音乐 采访 幕后" : " soundtrack music interview composer")
        let query = String((place.name + (place.kind == "artist" ? "" : " " + credit) + words).prefix(128))
        let budget = ResearchRequestBudget(limits: ["search": 1, "fetch": 1, "model": 0])
        guard let materials = try? await ResearchMaterialCollector(http: .init(budget: budget, reservation: {
                  try await ModelRequestLedger.shared.reserve(configuration, kind: "wider-material")
              })).collect(topic, credential: configuration.credential.value, queries: [.init(purpose: .story, text: query)]),
              !materials.packet.sources.isEmpty else { return result }
        result.searches = 1
        EvalResearchCapture.value(materials, name: "wider-collection.json")
        let reply = await attempt { try await client.complete(system: ResearchWriter.storySystemRules,
            user: ResearchWriter.widerStoryPrompt(writing: writing, packet: ResearchWriter.storyMaterials(materials.packet), home: place.name, kind: place.kind), maxTokens: 3000) }
        guard let text = try? reply.get() else { return result }
        EvalResearchCapture.data(Data(text.text.utf8), name: "wider-story-raw.txt", secret: configuration.credential.value)
        result.usage = text.usage
        if let story = ResearchWriter.groundStory(text.text, packet: materials.packet, wider: true) {
            result.story = story
            result.urls = materials.packet.sources.map(\.url)
        }
        return result
    }

    // JSON dictionaries of strings only; never mutated after construction.
    /// 深挖 (see DeepResearch): user-confirmed, up to three planned rounds on the same model.
    static func deep(_ prompt: String, configuration: ResearchModelConfiguration, subject: LeadSubject,
                     knownFacts: [String], knownCards: [String], hasStory: Bool, hints: ResearchHints = .init(),
                     writing: StoryWritingPreferences = StoryWritingStore.runtime.load(),
                     progress: (@Sendable (DiscoveryProgressEvent) async -> Void)? = nil) async throws -> ResearchNativeAnswer {
        if configuration.endpoint.api == .responses {
            let known = knownCards.isEmpty ? "" : "\n已知（不要重复）：\n" + knownCards.prefix(24).joined(separator: "\n")
            return try await native(prompt + "\n\n深挖：这是用户主动要求、愿意多付费用的深入查找。请在已知内容之外多检索几次，重点找旋律或歌词的来源、采样与翻唱的来龙去脉、改编版本对应的原曲与原作、同一部作品的其他主题曲，以及有具体人物和经过的幕后轶事。" + known,
                                    configuration: configuration, progress: progress)
        }
        guard configuration.isDeepSeek else { throw ResearchHTTP.Failure.noEvidence }
        if DeepResearch.strategy == .follow {
            return try await deepFollow(configuration: configuration, subject: subject, knownFacts: knownFacts, knownCards: knownCards,
                                        hasStory: hasStory, hints: hints, writing: writing, progress: progress)
        }
        let effectiveAlbum = subject.album.isEmpty ? (subject.identity?.releaseTitle ?? subject.identity?.edition ?? "") : subject.album
        let topic = ResearchTopic(id: subject.id, title: subject.title, creator: subject.creator,
            album: effectiveAlbum, layer: subject.identity?.layer.rawValue ?? "recording",
            canonicalTitle: subject.identity?.canonicalTitle, catalogue: subject.identity?.catalogue,
            movement: subject.identity?.movement)
        let client = configuration.client(), started = Date()
        var leads: [[String: Any]] = [], relations: [[String: Any]] = [], story: [String: Any]? = nil
        var usages: [StoryModelUsage] = [], searches = 0, urls: [String] = []
        var known = knownCards + knownFacts
        var knownNames = DeepResearch.knownNames(cards: knownCards, facts: knownFacts, topic: topic)
        for round in 1...DeepResearch.maxRounds {
            try Task.checkCancellation()
            await progress?(.requested)
            try await ModelRequestLedger.shared.reserve(configuration, kind: "deep-plan")
            let planUser = DeepResearch.plannerPrompt(topic: topic, known: known, hasStory: hasStory || story != nil, round: round)
            let plan = await attempt { try await client.complete(system: DeepResearch.plannerRules, user: planUser, maxTokens: 600) }
            guard let planReply = try? plan.get() else { if round == 1 { _ = try plan.get() }; break }
            if let usage = planReply.usage { usages.append(usage) }
            let queries = DeepResearch.queries(planReply.text)
            guard !queries.isEmpty else { break }
            let budget = ResearchRequestBudget(limits: ["search": queries.count, "fetch": 2, "model": 0])
            guard let collection = try? await ResearchMaterialCollector(http: .init(budget: budget, reservation: {
                try await ModelRequestLedger.shared.reserve(configuration, kind: "deep-material")
            })).collect(topic, credential: configuration.credential.value, queries: queries) else { continue }
            searches += collection.packet.searches
            guard !collection.packet.sources.isEmpty else { continue }
            urls += collection.packet.sources.map(\.url)
            let wantsStory = !hasStory && story == nil
            let relationsUser = ResearchWriter.relationsPrompt(packet: collection.packet, knownFacts: known)
            async let relationPart = relationsAndSiblings(client: client, configuration: configuration, packet: collection.packet,
                user: relationsUser)
            async let storyPart = optionalStory(wantsStory, client: client, writing: writing, packet: collection.packet)
            let (part, storyReply) = await (relationPart, storyPart)
            if let usage = (try? part.reply.get())?.usage { usages.append(usage) }
            if let usage = part.siblingUsage { usages.append(usage) }
            searches += part.siblingSearches; urls += part.siblingURLs
            let fresh = DeepResearch.prefixed((part.leads, part.relations), round: round)
            leads += fresh.leads; relations += fresh.relations
            var storyAdded = false
            if let storyReply {
                if let usage = storyReply.usage { usages.append(usage) }
                if let grounded = ResearchWriter.groundStory(storyReply.text, packet: collection.packet) { story = grounded; storyAdded = true }
            }
            known += fresh.leads.compactMap { $0["name"] as? String }
            // A round that found nothing new ends the dive early; the user pays only for what ran.
            // Finding again what the page already shows is nothing new.
            let novel = DeepResearch.novelNames(fresh.leads, known: &knownNames)
            if (fresh.relations.isEmpty || novel.isEmpty) && !storyAdded { break }
        }
        let combined = try ResearchWriter.combineNarrow(leads: leads, relations: relations, story: story)
        return .init(answer: .init(text: combined, completed: true,
            usage: .init(model: configuration.endpoint.model,
                inputTokens: usages.reduce(0) { $0 + $1.inputTokens }, cachedInputTokens: usages.reduce(0) { $0 + $1.cachedInputTokens },
                outputTokens: usages.reduce(0) { $0 + $1.outputTokens }, reasoningTokens: usages.reduce(0) { $0 + $1.reasoningTokens }),
            seconds: Date().timeIntervalSince(started)),
            observedURLs: Array(Set(urls)), webToolCalls: searches)
    }
    /// 深挖, second design (anson 2026-11-18 17:00: three rounds of the same searches "就相当于我在百度
    /// 用同一个搜索词重复搜3遍"). Measured before: three songs paid ¥0.15–0.18 each and two gained nothing.
    /// Now each round first names what is still missing, then aims at least half of its searches at the
    /// song's neighbours (the work it belongs to, its album, composer, original, covers) and changes the
    /// kind of source and the language, not just the word order; it reads the song's Wikipedia articles
    /// in up to three languages and gives the model a larger packet (10 pages, 30,000 characters). A second
    /// round follows only the leads the first one found. Pages are not read in full (anson 17:05: 「不做3」).
    /// Measured 11-18 on 8 songs against the first design on copies of the same lookup: about 12 genuinely
    /// new cards against 5, ¥0.17 against ¥0.11 a dive on average, no new story either way.
    static func deepFollow(configuration: ResearchModelConfiguration, subject: LeadSubject, knownFacts: [String], knownCards: [String],
                           hasStory: Bool, hints: ResearchHints, writing: StoryWritingPreferences,
                           progress: (@Sendable (DiscoveryProgressEvent) async -> Void)?) async throws -> ResearchNativeAnswer {
        let effectiveAlbum = subject.album.isEmpty ? (subject.identity?.releaseTitle ?? subject.identity?.edition ?? "") : subject.album
        let topic = ResearchTopic(id: subject.id, title: subject.title, creator: subject.creator,
            album: effectiveAlbum, layer: subject.identity?.layer.rawValue ?? "recording",
            canonicalTitle: subject.identity?.canonicalTitle, catalogue: subject.identity?.catalogue,
            movement: subject.identity?.movement)
        let client = configuration.client(), started = Date()
        var leads: [[String: Any]] = [], relations: [[String: Any]] = [], story: [String: Any]? = nil
        var usages: [StoryModelUsage] = [], toolCalls = 0, urls: [String] = []
        var cards = knownCards, known = knownCards + knownFacts
        var knownNames = DeepResearch.knownNames(cards: knownCards, facts: knownFacts, topic: topic)
        var searched = ResearchMaterials.queryPlan(topic).map(\.text)
        // Free and usually cached from the lookup: the song in up to three languages, the works' music sections.
        let wiki = await MetadataDeadline.value(seconds: 10) { await WikipediaMaterials.pages(topic: topic, hints: hints, songLimit: 3, workLimit: 3) } ?? []
        let lead = wiki.first { $0.purposes.contains(.story) }.map { String($0.text.prefix(1500)) }
        for round in 1...DeepResearch.followRounds {
            try Task.checkCancellation()
            await progress?(.requested)
            try await ModelRequestLedger.shared.reserve(configuration, kind: "deep-plan")
            let planUser = DeepResearch.followPrompt(topic: topic, cards: cards, facts: knownFacts, hasStory: hasStory || story != nil,
                                                     round: round, searched: searched, wikipedia: lead)
            let plan = await attempt { try await client.complete(system: DeepResearch.plannerRules, user: planUser, maxTokens: 1000) }
            guard let planReply = try? plan.get() else { if round == 1 { _ = try plan.get() }; break }
            if let usage = planReply.usage { usages.append(usage) }
            EvalResearchCapture.data(Data(planReply.text.utf8), name: "deep-plan-\(round).txt", secret: configuration.credential.value)
            let queries = DeepResearch.followQueries(planReply.text, searched: searched)
            guard !queries.isEmpty else { break }
            searched += queries.map(\.text)
            let budget = ResearchRequestBudget(limits: ["search": queries.count, "fetch": 4, "model": 0])
            let http = ResearchHTTP(budget: budget, reservation: { try await ModelRequestLedger.shared.reserve(configuration, kind: "deep-material") })
            guard let collected = try? await ResearchMaterialCollector(http: http)
                .collect(topic, credential: configuration.credential.value, queries: queries) else { continue }
            toolCalls += collected.packet.searches + collected.packet.fetches
            let collection = collected.adding(round == 1 ? wiki : [], maxPages: 10, totalCharacters: 30_000, directCharacters: 15_000)
            EvalResearchCapture.value(collection, name: "deep-collection-\(round).json")
            guard !collection.packet.sources.isEmpty else { continue }
            urls += collection.packet.sources.map(\.url)
            let wantsStory = !hasStory && story == nil
            let relationsUser = ResearchWriter.relationsPrompt(packet: collection.packet, knownFacts: known)
            async let relationPart = relationsAndSiblings(client: client, configuration: configuration, packet: collection.packet, user: relationsUser)
            async let storyPart = optionalStory(wantsStory, client: client, writing: writing, packet: collection.packet)
            let (part, storyReply) = await (relationPart, storyPart)
            if let usage = (try? part.reply.get())?.usage { usages.append(usage) }
            if let usage = part.siblingUsage { usages.append(usage) }
            toolCalls += part.siblingSearches; urls += part.siblingURLs
            let fresh = DeepResearch.prefixed((part.leads, part.relations), round: round)
            leads += fresh.leads; relations += fresh.relations
            if let storyReply {
                if let usage = storyReply.usage { usages.append(usage) }
                if let grounded = ResearchWriter.groundStory(storyReply.text, packet: collection.packet) { story = grounded }
            }
            known += fresh.leads.compactMap { $0["name"] as? String }
            let novel = DeepResearch.novelNames(fresh.leads, known: &knownNames)
            cards += novel.map { "本轮新找到：" + $0 }
            // The next round follows the new leads; with none, it would only search the same ground again.
            if novel.isEmpty { break }
        }
        let combined = try ResearchWriter.combineNarrow(leads: leads, relations: relations, story: story)
        return .init(answer: .init(text: combined, completed: true,
            usage: .init(model: configuration.endpoint.model,
                inputTokens: usages.reduce(0) { $0 + $1.inputTokens }, cachedInputTokens: usages.reduce(0) { $0 + $1.cachedInputTokens },
                outputTokens: usages.reduce(0) { $0 + $1.outputTokens }, reasoningTokens: usages.reduce(0) { $0 + $1.reasoningTokens }),
            seconds: Date().timeIntervalSince(started)),
            observedURLs: Array(Set(urls)), webToolCalls: toolCalls)
    }
    private static func optionalStory(_ wanted: Bool, client: any StoryModelClient, writing: StoryWritingPreferences,
                                      packet: ResearchMaterialPacket) async -> StoryModelReply? {
        guard wanted else { return nil }
        return try? await attempt { try await client.complete(system: ResearchWriter.storySystemRules,
            user: ResearchWriter.storyPrompt(writing: writing, packet: packet), maxTokens: 3000) }.get()
    }

    struct RelationPart: @unchecked Sendable {
        let reply: Result<StoryModelReply, Error>
        let leads: [[String: Any]]
        let relations: [[String: Any]]
        var siblingUsage: StoryModelUsage? = nil
        var siblingSearches = 0
        var siblingURLs: [String] = []
    }

    /// Call A, grounded; then, if it reached a show, film or game the song was made
    /// for, one search and one small call for that work's other theme songs (≤ 2).
    static func relationsAndSiblings(client: any StoryModelClient, configuration: ResearchModelConfiguration,
                                     packet: ResearchMaterialPacket, user: String, knownNames: [String] = []) async -> RelationPart {
        let reply = await attempt { try await client.complete(system: ResearchWriter.relationsSystemRules, user: user, maxTokens: 2500) }
        guard let text = try? reply.get().text,
              let grounded = try? ResearchWriter.groundRelations(text, packet: packet, knownNames: knownNames) else { return .init(reply: reply, leads: [], relations: []) }
        var part = RelationPart(reply: reply, leads: grounded.leads, relations: grounded.relations)
        let shows: Set<String> = ["tv", "film", "game"]
        // The song itself, or the piece this recording performs (current → piece → show).
        var origins: Set<String> = ["current", "_piece"]
        for edge in grounded.relations where edge["from"] as? String == "current" && edge["relation"] as? String == "performance_of" {
            if let piece = edge["to"] as? String { origins.insert(piece) }
        }
        guard configuration.isDeepSeek,
              let edge = grounded.relations.first(where: { edge in
                  origins.contains(edge["from"] as? String ?? "") && ["created_for", "used_in"].contains(edge["relation"] as? String ?? "")
                      && grounded.leads.contains { $0["ref"] as? String == edge["to"] as? String && shows.contains($0["target_type"] as? String ?? "") }
              }),
              let workRef = edge["to"] as? String,
              let workNode = grounded.leads.first(where: { $0["ref"] as? String == workRef }),
              let work = workNode["name"] as? String, !work.isEmpty else { return part }
        let workAliases = (["zh", "en", "canonical_title"].compactMap { workNode[$0] as? String } + (workNode["aliases"] as? [String] ?? []).prefix(4))
            .filter { !$0.isEmpty }
        let topic = packet.topic, combined = [topic.title, topic.creator, topic.album, work].joined()
        let kana = ResearchMaterials.hasKana(combined)
        let han = combined.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let query = String((work + (kana ? " 主題歌 オープニング エンディング" : han ? " 主题曲 片头曲 片尾曲 主題歌" : " opening ending theme songs")).prefix(128))
        let budget = ResearchRequestBudget(limits: ["search": 1, "fetch": 1, "model": 0])
        guard let materials = try? await ResearchMaterialCollector(http: .init(budget: budget, reservation: {
                  try await ModelRequestLedger.shared.reserve(configuration, kind: "sibling-material")
              })).collect(topic, credential: configuration.credential.value, queries: [.init(purpose: .context, text: query)]),
              !materials.packet.sources.isEmpty else { return part }
        part.siblingSearches = 1
        let sibling = await attempt { try await client.complete(system: ResearchWriter.siblingSystemRules,
            user: ResearchWriter.siblingPrompt(work: work, packet: materials.packet), maxTokens: 800) }
        guard let siblingReply = try? sibling.get() else { return part }
        EvalResearchCapture.data(Data(siblingReply.text.utf8), name: "siblings-raw.txt", secret: configuration.credential.value)
        part.siblingUsage = siblingReply.usage
        let found = ResearchWriter.groundSiblings(siblingReply.text, packet: materials.packet, work: work, workRef: workRef, workAliases: workAliases)
        part = RelationPart(reply: reply, leads: part.leads + found.leads, relations: part.relations + found.relations,
                            siblingUsage: part.siblingUsage, siblingSearches: 1,
                            siblingURLs: found.relations.compactMap { $0["url"] as? String })
        return part
    }

    /// One retry for a transport failure (timeout, connection, 429/5xx). A bad key
    /// or a refused model is not retried. Cancellation always propagates.
    static func attempt<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        for round in 0..<2 {
            do { return .success(try await operation()) }
            catch {
                if error is CancellationError || Task.isCancelled { return .failure(error) }
                let retryable: Bool
                switch error {
                case ResearchHTTP.Failure.http(let code): retryable = code == 429 || code >= 500
                case ResearchHTTP.Failure.deadline, ResearchHTTP.Failure.badReply, StoryModelError.connection: retryable = true
                case let urlError as URLError: retryable = urlError.code != .cancelled
                default: retryable = false
                }
                if round == 1 || !retryable { return .failure(error) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return .failure(ResearchHTTP.Failure.badReply)
    }

    static func native(_ prompt: String, configuration: ResearchModelConfiguration,
                       capabilityProbe: Bool = false,
                       progress: (@Sendable (DiscoveryProgressEvent) async -> Void)? = nil) async throws -> ResearchNativeAnswer {
        try await ModelRequestLedger.shared.reserve(configuration, kind: capabilityProbe ? "probe" : "model")
        var request = URLRequest(url: try configuration.endpoint.url("responses"), timeoutInterval: 150)
        request.httpMethod = "POST"
        request.setValue("Bearer " + configuration.credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ResearchNativeResponse.body(prompt: prompt, model: configuration.endpoint.model, deepSeek: configuration.isDeepSeek)
        if capabilityProbe { body["max_output_tokens"] = 512; body["tool_choice"] = "required" }
        let started = Date()
        let bytes: Data
        if let progress, !capabilityProbe, !configuration.isDeepSeek {
            // A research answer takes tens of seconds. Streaming keeps the connection
            // alive past idle timeouts and reports the real search/read steps to the
            // page and the Dynamic Island, as before BYOK (0.5.13).
            body["stream"] = true
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let secret = configuration.credential.value
            let (data, response) = try await DiscoveryResponseStream.receive(request, session: LeadResearchClient.session) { event in
                switch event {
                case .search(let query) where query.contains(secret): return
                case .read(let url) where url.absoluteString.contains(secret): return
                default: await progress(event)
                }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw LeadResearchClient.Failure.http(status) }
            bytes = data
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard let data = try await configuration.http.send(request) else { throw StoryModelError.connection }
            bytes = data
        }
        EvalResearchCapture.data(bytes, name: "native-response.json", secret: configuration.credential.value)
        return try ResearchNativeResponse.decode(bytes, fallbackModel: configuration.endpoint.model, seconds: Date().timeIntervalSince(started))
    }
}

enum ResearchCapabilityProbe {
    enum Result: Equatable {
        case available, unverified, unsupported
        var message: String {
            switch self {
            case .available: "连接正常，可以联网查找"
            case .unverified: "连上了，但联网查找没有成功，这样查不到故事。稍后再试，或换一个模型。"
            case .unsupported: "连上了，但这个模型不能联网查找，查不到故事。换一个模型试试。"
            }
        }
    }
    static func check(_ configuration: ResearchModelConfiguration) async throws -> Result {
        if configuration.endpoint.api == .responses {
            do {
                let reply = try await ConfiguredResearchTransport.native("请使用联网工具查找 example.com，只回复网站名称和网址。", configuration: configuration, capabilityProbe: true)
                return reply.webToolCalls > 0 && !reply.observedURLs.isEmpty ? .available : .unverified
            } catch let error as StoryModelError where error == .unavailableModel {
                // Tool support is independent of basic text connectivity.
                try await ModelRequestLedger.shared.reserve(configuration, kind: "probe-fallback")
                let plain = try await configuration.client().complete(system: "请只回复 OK。", user: "测试连接。", maxTokens: 128)
                guard !plain.text.isEmpty else { throw StoryModelError.unavailableModel }
                return .unsupported
            }
        }
        try await ModelRequestLedger.shared.reserve(configuration, kind: "probe")
        let reply = try await configuration.client().complete(system: "请只回复 OK。", user: "测试连接。", maxTokens: 128)
        guard !reply.text.isEmpty else { throw StoryModelError.unavailableModel }
        guard configuration.isDeepSeek else { return .unsupported }
        try await ModelRequestLedger.shared.reserve(configuration, kind: "search-probe")
        // Search is a separate App tool, independent of the Chat base path.
        var request = URLRequest(url: TrialRelay.toolURL("search", credential: configuration.credential.value), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer " + configuration.credential.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": "MusicBrainz music database", "count": 1, "need_content": true])
        guard let data = try? await configuration.http.send(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return .unverified }
        // A source URL proves search ran. Empty page text does not disprove
        // search support; production can fetch that page separately.
        return results.contains { ($0["url"] as? String).flatMap(ResearchMaterials.safeURL) != nil } ? .available : .unverified
    }
}
