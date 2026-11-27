import Foundation

/// Explicit simulator-only data. Production coordination consumes an override,
/// just as unit tests inject researchOperation and metadataRefinement.
@MainActor enum LeadResearchFixtures {
    static func stagedDatabase(_ subject: LeadSubject) -> [DatabaseDiscoveryResult]? {
        #if DEBUG && targetEnvironment(simulator)
        if let original = OriginalRecordingFixture.database(subject) { return original }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-isolate-data"), arguments.contains("--ui-u18-direct-play"), subject.id == "apple:song:900000001" {
            let root = SeedLibraryBridge.workID(subject.id)
            let song = Work(id: root, title: subject.title, creator: subject.creator, kind: "歌曲", art: "pool", detail: "", url: nil)
            let composition = Work(id: WorkID(rawValue: "local:u18-composition")!, title: "さよならの向う側", creator: "宇崎竜童",
                kind: "音乐作品", art: "", detail: "", url: nil,
                discovery: .init(layer: .musicWork, canonicalTitle: "さよならの向う側", composer: "宇崎竜童"))
            let recordings: [Work] = arguments.contains("--ui-u18-no-recording") ? [] : [
                Work(id: WorkID(rawValue: "apple:song:900000011")!, title: composition.title, creator: "山口百恵", kind: "歌曲",
                    art: "", detail: "", url: "https://music.apple.com/jp/song/900000011", catalogID: "900000011", storeCountry: "jp", releaseDate: "1980-01-01"),
                Work(id: WorkID(rawValue: "apple:song:900000012")!, title: composition.title, creator: composition.creator, kind: "歌曲",
                    art: "pool", detail: "", url: "https://music.apple.com/jp/song/900000012", catalogID: "900000012", storeCountry: "jp", releaseDate: "1981-01-01")
            ]
            let source = Source(title: "离线播放样本", url: "https://example.org/u18")
            var relations = [RelationEdge(from: root, to: composition.id, predicate: .adaptedFrom, label: "改编自", inverseLabel: "改编版本", source: source, researchRoot: root)]
            relations += recordings.map { RelationEdge(from: $0.id, to: composition.id, predicate: .performanceOf, label: "乐曲", inverseLabel: "能听的版本", source: source, researchRoot: root) }
            return [.init(snapshot: .init(works: [song, composition] + recordings, relations: relations))]
        }
        guard ProcessInfo.processInfo.arguments.contains("--ui-u17-staged-database") else { return nil }
        let root = SeedLibraryBridge.workID(subject.id)
        let song = Work(id: root, title: subject.title, creator: subject.creator, kind: "歌曲", art: "", detail: "", url: nil)
        let works = [("first", "游戏甲", "游戏"), ("later-film", "电影乙", "电影"), ("later-tv", "动画丙", "剧集")].map { key, title, kind in
            Work(id: WorkID(rawValue: "local:u17-" + key)!, title: title, creator: "", kind: kind, art: "", detail: "", url: nil)
        }
        func batch(_ targets: [Work]) -> DatabaseDiscoveryResult {
            .init(snapshot: .init(works: [song] + targets, relations: targets.map {
                .init(from: root, to: $0.id, predicate: .soundtrackOf, label: "出自", inverseLabel: "音乐",
                    source: .init(title: "离线界面样本", url: "https://example.org/" + $0.id.rawValue), researchRoot: root)
            }))
        }
        return [batch(Array(works.prefix(1))), batch(works)]
        #else
        return nil
        #endif
    }

    static func override(_ subject: LeadSubject) -> (report: LeadReport, state: LeadState)? {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"), ProcessInfo.processInfo.arguments.contains("--ui-u25-loading") { return nil }
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data"), ProcessInfo.processInfo.arguments.contains("--ui-u21-story"),
           subject.id == "apple:song:903280858", let path = ProcessInfo.processInfo.environment["PIANWAI_U21_REPORT"],
           path.hasSuffix("/Tests/Fixtures/U21/chinese-album-report.json"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let report = try? JSONDecoder().decode(LeadReport.self, from: data) { return (report, .ready) }
        if let report = FirstTakeFixture.report(subject) { return (report, .ready) }
        if RecordShopArtReview.current != nil {
            let film = SeedNowContent.entity("film")!
            let jane = SeedNowContent.entity("jane")!
            let director = SeedNowContent.entity("yoshihara")!
            let report = LeadReport(leads: [
                Lead(id: film.id, name: film.title, original: film.title, kind: film.kind, label: "配乐出自",
                    why: "这首歌用在电影的泳池场景。", url: Source.movie.url, creator: film.subtitle, art: film.artworkAsset ?? ""),
                Lead(id: jane.id, name: jane.title, original: jane.title, kind: jane.kind, label: "同片片尾曲",
                    why: "米津玄师与宇多田光为同一部电影合唱。", url: Source.jane.url, creator: jane.subtitle, art: jane.artworkAsset ?? ""),
                Lead(id: director.id, name: director.title, original: director.title, kind: director.kind, label: "电影导演",
                    why: "和牛尾宪辅一起讨论先导影像的选曲。", url: Source.interview.url, creator: director.subtitle, art: director.artworkAsset ?? "")
            ], story: .init(text: "为《电锯人 蕾塞篇》先导影像选曲时，牛尾宪辅和吉原达矢支持用泳池场景的《in the pool》。讨论后，团队觉得短暂使用这首曲子有些可惜，最终选用了《Reze》的雏形。",
                subject: "song", url: Source.interview.url, source: "Real Sound 访谈"), fetchedAt: Date(), seconds: 0)
            return (report, .ready)
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-isolate-data"), !arguments.contains("--ui-leads-live"), !arguments.contains("--ui-discovery-replay") {
            return (.init(leads: [], story: nil, fetchedAt: Date(), seconds: 0), .empty)
        }
        if let title = ProcessInfo.processInfo.environment["PIANWAI_FLASH_QA_SUBJECT_TITLE"],
           !LeadMatch.same(title, subject.title, loose: false) {
            return (.init(leads: [], story: nil, fetchedAt: Date(), seconds: 0), .empty)
        }
        #endif
        return nil
    }
    static func database(_ subject: LeadSubject) -> DatabaseDiscoveryResult? {
        #if DEBUG && targetEnvironment(simulator)
        struct Case: Decodable { let database: DatabaseDiscoveryResult }
        guard ProcessInfo.processInfo.arguments.contains("--ui-arch2-database"),
              let path = ProcessInfo.processInfo.environment["PIANWAI_ARCH2_DATABASE_REPLAY"],
              path.hasSuffix("/Design/review/ARCH2-night-plan/DB-COVERAGE-CHECKED.json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else { return nil }
        return cases.first { $0.database.snapshot.works.contains { $0.id.rawValue == subject.id } }?.database
        #else
        return nil
        #endif
    }

    static func replay(_ subject: LeadSubject) async throws -> LeadResearchClient.Raw? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--ui-discovery-replay") else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--ui-e11-delayed-replay") { try await Task.sleep(for: .seconds(8)) }
        return DiscoveryReviewReplay.raw(for: subject)
        #else
        return nil
        #endif
    }
    /// Review only: a replayed answer keeps no pages, so the screenshot states how many were read.
    static func pagesRead() -> Int? {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-isolate-data"), let raw = arguments.first(where: { $0.hasPrefix("--ui-pages-read=") }) else { return nil }
        return Int(raw.dropFirst("--ui-pages-read=".count))
        #else
        return nil
        #endif
    }
}
