import XCTest
@testable import Pianwai

@MainActor final class DiscoveryResilienceTests: XCTestCase {
    private let page = "https://example.com/original"
    private func id(_ name: String) -> WorkID { WorkID(rawValue: "test:e08:" + name)! }
    private func piece(_ name: String, _ layer: DiscoveryIdentity.Layer, title: String? = nil) -> Work {
        Work(id: id(name), title: title ?? name, creator: "Creator", kind: DiscoveryIdentity(layer: layer, canonicalTitle: name).displayKind,
             art: "", detail: "", url: nil, discovery: .init(layer: layer, canonicalTitle: title ?? name))
    }
    private func edge(_ a: String, _ b: String, _ relation: DiscoveryRelation, quote: String = "Original credits") -> RelationEdge {
        .init(from: id(a), to: id(b), predicate: relation.predicate, label: relation.labels.forward, inverseLabel: relation.labels.inverse,
              source: .init(title: "线索", detail: quote, url: page, evidenceQuote: quote), researchRoot: id("root"))
    }
    private func library(_ catalog: CatalogStore) throws -> (Library, UserDefaults, String) {
        let suite = "E08-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (Library(defaults: defaults, catalog: catalog), defaults, suite)
    }
    private func storyRaw() -> LeadResearchClient.Raw {
        var raw = LeadResearchClient.Raw(leads: [], story: .init(
            text: "录制时，制作团队保留了原始乐器的录音，并在另一间录音室完成了最后的合奏。这里是一份已经保存、可在本地恢复的幕后材料。",
            subject: "recording", url: page, source: "Original interview", subject_ref: "current"))
        raw.relations = []; raw.observedURLs = [page]
        return raw
    }
    func testActualWindAnswerKeepsOSTSeparateFromArrangedRecording() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/E08/wind-flash-evidence.json")
        let entry = try JSONDecoder().decode(DiscoveryEvidenceCache.Entry.self, from: Data(contentsOf: file))
        let plan = DiscoveryCore.prepare(try entry.decode(), subject: entry.subject)
        XCTAssertFalse(plan.rootAliases.contains("wind_scene_original_recording"))
        let original = try XCTUnwrap(plan.nodes.first { $0.ref == "wind_scene_original_recording" })
        XCTAssertEqual(original.identity.releaseTitle, "クロノ・トリガー オリジナル・サウンドトラック")
        XCTAssertTrue(plan.links.contains { $0.from == original.ref && $0.relation == .createdFor })
        XCTAssertFalse(plan.links.contains { $0.from == "current" && $0.relation == .createdFor }, "The arranged recording must not become the original game BGM")
    }
    func testRecordingIdentityRequiresEditionEvidenceAndSeparatesReleases() {
        let subject = LeadSubject(id: "apple:song:101", kind: .song, title: "Song", creator: "Artist", album: "Live A")
        var identity = DiscoveryIdentity(layer: .recording, canonicalTitle: "Song")
        XCTAssertFalse(DiscoveryRecordingIdentity.aliasesCurrent(identity, creator: "Artist", subject: subject))
        identity.releaseTitle = "Live A"
        XCTAssertTrue(DiscoveryRecordingIdentity.aliasesCurrent(identity, creator: "Artist", subject: subject))
        let a = DiscoveryCore.provisionalID(identity, creator: "Artist", subjectID: subject.id)
        identity.releaseTitle = "Live B"
        XCTAssertFalse(DiscoveryRecordingIdentity.aliasesCurrent(identity, creator: "Artist", subject: subject))
        XCTAssertNotEqual(a, DiscoveryCore.provisionalID(identity, creator: "Artist", subjectID: subject.id))
        XCTAssertFalse(DiscoveryRecordingIdentity.sameCredits("Artist", "Artist & Guest"))
        XCTAssertTrue(DiscoveryRecordingIdentity.sameCredits("ベッツイ&クリス", "クリス & ベッツィ"))
    }
    func testStoreMatchDoesNotTurnSoloCreditIntoDuetOrGuessMissingEdition() throws {
        let catalog = CatalogStore(cacheURL: nil)
        let album = Work(id: WorkID(rawValue: "apple:album:900")!, title: "Album", creator: "Artist", kind: "专辑", art: "", detail: "", url: nil)
        let song = Work(id: WorkID(rawValue: "apple:song:901")!, title: "Song", creator: "Artist & Guest", kind: "歌曲", art: "", detail: "", url: nil, linkedAlbumID: album.id)
        try catalog.merge(.init(works: [album, song], relations: []))
        var lead = Lead(id: "test:lead", name: "Song", original: "Song", kind: .song, label: "原曲", why: "", url: page,
            creator: "Artist", art: "", identity: .init(layer: .recording, canonicalTitle: "Song", releaseTitle: "Album"))
        XCTAssertNil(RecordingCatalogMatch.unique([song.id], lead: lead, catalog: catalog))
        lead.creator = "Guest & Artist"
        XCTAssertEqual(RecordingCatalogMatch.unique([song.id], lead: lead, catalog: catalog), song.id)
        lead.identity?.releaseTitle = nil
        XCTAssertNil(RecordingCatalogMatch.unique([song.id], lead: lead, catalog: catalog), "Unknown editions remain user-selectable candidates")
    }
    func testCitationEquivalenceRetainsObservedAddressAndBusinessQueries() {
        let observed = "https://example.com/article?id=7&shem=search_app"
        let index = DiscoverySourceIndex([observed, "http://example.com/legacy"])
        XCTAssertEqual(index.source("https://example.com/article?id=7"), observed)
        XCTAssertNil(index.source("https://example.com/article?id=8"))
        XCTAssertNil(index.source("https://example.com/legacy"), "Scheme equality needs real redirect evidence")
        XCTAssertNil(index.source("http://example.com/legacy"), "Unsupported HTTP stays raw evidence, not a silently rejected catalog edge")
        XCTAssertNotEqual(DiscoveryCore.sourceKey(page + "?fmid=1"), DiscoveryCore.sourceKey(page + "?fmid=2"), "Unknown parameter semantics stay intact")
        let mora = "https://mora.jp/package/43000021/SQEX-10167_L44/"
        XCTAssertEqual(DiscoveryCore.sourceKey(mora + "?fmid=singleRank_cdq&trackMaterialNo=31840314"), DiscoveryCore.sourceKey(mora + "?trackMaterialNo=31840314"))
        XCTAssertNotEqual(DiscoveryCore.sourceKey(mora + "?fmid=business-id"), DiscoveryCore.sourceKey(mora))
        XCTAssertNotEqual(DiscoveryCore.sourceKey(mora + "?trackMaterialNo=1"), DiscoveryCore.sourceKey(mora + "?trackMaterialNo=2"))
        XCTAssertNotEqual(DiscoveryCore.sourceKey("https://music.163.com/#/song?id=1"), DiscoveryCore.sourceKey("https://music.163.com/#/song?id=2"))
        XCTAssertEqual(DiscoveryCore.sourceKey(page + "#credits"), DiscoveryCore.sourceKey(page))
    }
    func testCrateAndInitialMapUseTheSameRealPathsAndRespectFoldedBranches() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("root", .recording, title: "Song"), piece("work", .musicWork, title: "Song"),
            piece("tv", .tv, title: "Same title"), piece("manga", .manga, title: "Same title")], relations: [
                edge("root", "work", .performanceOf), edge("work", "tv", .createdFor, quote: "挿入歌として書き下ろした"), edge("tv", "manga", .adaptationOf)]))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let leads = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil)
        XCTAssertEqual(leads.first { $0.id == id("tv").rawValue }?.label, "插曲出自")
        XCTAssertEqual(leads.first { $0.id == id("manga").rawValue }?.label, "剧集原作")
        let owners = DiscoveryNavigation.initialMapOwners(from: id("root").rawValue, catalog: catalog, provider: nil)
        let graph = PublicCrateInventory.leadGraph(root: id("root").rawValue, expanding: owners, library: library)
        var map = RelationMapModel(root: id("root").rawValue)
        _ = map.seedKnownPaths(DiscoveryNavigation.initialMapPaths(from: id("root").rawValue, catalog: catalog, provider: nil), graph: graph)
        for lead in leads { XCTAssertNotNil(map.nodes[lead.id]) }
        XCTAssertFalse(map.nodes[id("work").rawValue]?.expanded == true, "Revealing paths does not pretend the entire work was expanded")
        XCTAssertFalse(map.edges.contains { $0.connects(id("root").rawValue, id("manga").rawValue) })
        map.collapse(id("tv").rawValue); map.initialDiscoverySeeded = nil
        map.camera = .init(x: 11, y: 22, scale: 0.66)
        _ = map.seedKnownPaths(DiscoveryNavigation.initialMapPaths(from: id("root").rawValue, catalog: catalog, provider: nil), graph: graph)
        XCTAssertNil(map.nodes[id("manga").rawValue], "A deliberately folded older trail stays folded")
        XCTAssertEqual(map.camera.scale, 0.66)
    }
    func testShorterConcretePathWinsOverDirectInspirationAndLongDetours() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("root", .recording), piece("work", .musicWork), piece("tv", .tv), piece("manga", .manga)],
            relations: [edge("root", "work", .performanceOf), edge("work", "tv", .createdFor), edge("tv", "manga", .adaptationOf), edge("root", "manga", .inspiredBy)]))
        let target = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil).first { $0.id == id("manga").rawValue }
        XCTAssertEqual(target?.path, [id("root").rawValue, id("manga").rawValue], "A three-hop detour does not replace a one-hop fact")
        XCTAssertEqual(target?.label, "灵感来自")
        try catalog.merge(.init(works: [], relations: [edge("root", "tv", .createdFor)]))
        let concrete = DiscoveryNavigation.leads(from: id("root").rawValue, catalog: catalog, known: [:], provider: nil).first { $0.id == id("manga").rawValue }
        XCTAssertEqual(concrete?.path, [id("root").rawValue, id("tv").rawValue, id("manga").rawValue])
        XCTAssertEqual(concrete?.label, "剧集原作")
    }
    func testAFormerlyWrongTrailCannotReassertADeletedDirectClaim() throws {
        let catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece("root", .recording), piece("work", .musicWork), piece("game", .game)],
            relations: [edge("root", "work", .performanceOf), edge("work", "game", .createdFor)]))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let owners = DiscoveryNavigation.initialMapOwners(from: id("root").rawValue, catalog: catalog, provider: nil)
        let graph = PublicCrateInventory.leadGraph(root: id("root").rawValue, expanding: owners, library: library)
        let bad = SeedGraph(version: 1, root: graph.root, entities: graph.entities, relations: [.init(from: graph.root, to: id("game").rawValue, label: "原作出自", via: nil)])
        var map = RelationMapModel(root: graph.root); _ = map.expand(graph.root, graph: bad)
        let valid = Set(graph.relations.map { [$0.from, $0.to].sorted().joined(separator: "|") })
        map.pruneInvalidEdges(keeping: valid); _ = map.seedKnownPaths(DiscoveryNavigation.initialMapPaths(from: id("root").rawValue, catalog: catalog, provider: nil), graph: graph)
        XCTAssertNotNil(map.nodes[id("game").rawValue])
        XCTAssertFalse(map.edges.contains { $0.connects(graph.root, id("game").rawValue) })
    }
    func testMalformedNewerEvidenceRecoversLocallyWithoutCallingProvider() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiscoveryEvidenceCache(directory: folder.appendingPathComponent("evidence"))
        let root = "cache-" + UUID().uuidString, subject = LeadSubject(id: id(root).rawValue, kind: .song, title: root, creator: "Artist", album: "Single")
        let raw = storyRaw(), text = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        cache.write(.init(subject: subject, namespace: "gpt-" + InternalStoryModel.model, visibleText: text, observedURLs: [page], usage: nil, researchSeconds: 40, fetchedAt: Date(timeIntervalSinceNow: -1)))
        cache.write(.init(subject: subject, namespace: "gpt-" + InternalStoryModel.model, visibleText: "{ malformed", observedURLs: [], usage: nil, researchSeconds: 50, fetchedAt: Date()))
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter(), catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece(root, .recording)], relations: []))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = folder.appendingPathComponent("diagnostics")
        let research = LeadResearch(researchOperation: { _ in await counter.increment(); throw LeadResearchClient.Failure.noAccess }, evidenceCache: cache, diagnostics: .init(directory: diagnostics))
        await research.load(subject, library: library)
        let calls = await counter.value; XCTAssertEqual(calls, 0)
        XCTAssertEqual(research.reports[subject.id]?.story?.text, raw.story?.text)
        let files = try FileManager.default.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil)
        let receipt = try JSONDecoder().decode(DiscoveryDiagnostics.Entry.self, from: Data(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "json" })))
        XCTAssertEqual(receipt.outcome, "recovered-cache"); XCTAssertTrue(receipt.reusedEvidence)
    }
    func testFailedRefreshKeepsReadableStoryAndStoresOnlySafeFailureCategory() async throws {
        struct PrivateError: Error, CustomStringConvertible { var description: String { "do-not-serialize-provider-payload" } }
        actor Replies { var count = 0; func next(_ raw: LeadResearchClient.Raw) throws -> LeadResearchClient.Raw { count += 1; if count > 1 { throw PrivateError() }; return raw } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = "refresh-" + UUID().uuidString, catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece(root, .recording)], relations: []))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let subject = LeadSubject(id: id(root).rawValue, kind: .song, title: root, creator: "Artist", album: "Single")
        let replies = Replies(), raw = storyRaw()
        let research = LeadResearch(researchOperation: { _ in try await replies.next(raw) }, evidenceCache: .init(directory: nil), diagnostics: .init(directory: folder))
        await research.load(subject, library: library, force: true)
        await research.load(subject, library: library, force: true)
        XCTAssertEqual(research.state(subject.id), .failed)
        XCTAssertEqual(research.reports[subject.id]?.story?.text, raw.story?.text)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "json" }))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("do-not-serialize"))
        XCTAssertEqual(try JSONDecoder().decode(DiscoveryDiagnostics.Entry.self, from: data).outcome, "processing")
    }
    func testProvisionalIdentityMigrationPreservesSavedTargetsAndRefusesConflictingRelease() throws {
        let catalog = CatalogStore(cacheURL: nil)
        let identity = DiscoveryIdentity(layer: .recording, canonicalTitle: "Song", releaseTitle: "Album A")
        let old = WorkID(rawValue: DiscoveryCore.previousRecordingID(identity, creator: "Artist", subjectID: "root")!)!
        let target = WorkID(rawValue: DiscoveryCore.provisionalID(identity, creator: "Artist", subjectID: "root"))!
        try catalog.merge(.init(works: [
            Work(id: old, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil, discovery: identity),
            Work(id: target, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil, discovery: identity)], relations: []))
        var conflicting = identity; conflicting.releaseTitle = "Album B"
        XCTAssertFalse(catalog.migrateProvisionalRecording(old, to: target, expected: conflicting))
        XCTAssertTrue(catalog.migrateProvisionalRecording(old, to: target, expected: identity))
        let (_, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
        try persistence.save(.init(listenLater: [old]))
        XCTAssertEqual(try persistence.load().listenLater, [target])
        let videoID = WorkID(rawValue: "lead:video:legacy-ova")!, seriesID = WorkID(rawValue: "lead:tv:series")!
        var videoIdentity = DiscoveryIdentity(layer: .video, canonicalTitle: "Series", edition: "OVA", identitySource: page)
        var seriesIdentity = videoIdentity; seriesIdentity.layer = .tv
        try catalog.merge(.init(works: [
            Work(id: videoID, title: "Series", creator: "Studio", kind: "演奏视频", art: "", detail: "", url: nil, discovery: videoIdentity),
            Work(id: seriesID, title: "Series", creator: "Studio", kind: "电视剧", art: "", detail: "", url: nil, discovery: seriesIdentity)], relations: []))
        XCTAssertTrue(catalog.migrateLegacyScreenSeries(videoID, to: seriesID))
        XCTAssertEqual(catalog.canonicalID(for: videoID), seriesID)
    }
    func testMigratedSavedIdentitiesSurviveARealCatalogReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cacheURL = folder.appendingPathComponent("catalog-v2.json")
        let catalog = CatalogStore(cacheURL: cacheURL)
        let identity = DiscoveryIdentity(layer: .recording, canonicalTitle: "Song", releaseTitle: "Album A")
        let old = WorkID(rawValue: DiscoveryCore.previousRecordingID(identity, creator: "Artist", subjectID: "root")!)!
        let target = WorkID(rawValue: DiscoveryCore.provisionalID(identity, creator: "Artist", subjectID: "root"))!
        let videoID = WorkID(rawValue: "lead:video:saved-ova")!, seriesID = WorkID(rawValue: "lead:tv:saved-series")!
        let video = DiscoveryIdentity(layer: .video, canonicalTitle: "Series", edition: "OVA", identitySource: page)
        var series = video; series.layer = .tv
        try catalog.merge(.init(works: [
            Work(id: old, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil, discovery: identity),
            Work(id: target, title: "Song", creator: "Artist", kind: "歌曲", art: "", detail: "", url: nil, discovery: identity),
            Work(id: videoID, title: "Series", creator: "Studio", kind: "演奏视频", art: "", detail: "", url: nil, discovery: video),
            Work(id: seriesID, title: "Series", creator: "Studio", kind: "电视剧", art: "", detail: "", url: nil, discovery: series)
        ], relations: []))
        let (_, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        // Preserve an actual pre-migration bookmark, not an already-canonical one.
        try LibraryPersistence(defaults: defaults).save(.init(saved: [videoID], listenLater: [old]))
        XCTAssertTrue(catalog.migrateProvisionalRecording(old, to: target, expected: identity))
        XCTAssertTrue(catalog.migrateLegacyScreenSeries(videoID, to: seriesID))
        await catalog.flushPendingWrites()
        let reloaded = CatalogStore(cacheURL: cacheURL)
        XCTAssertNil(reloaded.storageError)
        XCTAssertEqual(reloaded.canonicalID(for: old), target)
        XCTAssertEqual(reloaded.canonicalID(for: videoID), seriesID)
        let restored = try LibraryPersistence(defaults: defaults, catalog: reloaded).load()
        XCTAssertEqual(restored.listenLater, [target]); XCTAssertEqual(restored.saved, [seriesID])
        var malformed = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: cacheURL))
        malformed.identityAliases = [old.rawValue: target.rawValue, target.rawValue: old.rawValue]
        XCTAssertThrowsError(try reloaded.merge(malformed), "A corrupt cyclic redirect cannot enter the catalog")
    }
    func testAutomaticBackoffStopsRepeatedChargesButExplicitRetryCanRecover() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = "backoff-" + UUID().uuidString, subject = LeadSubject(id: id(root).rawValue, kind: .song, title: root, creator: "Artist", album: "Single")
        let diagnostics = DiscoveryDiagnostics(directory: folder)
        var last = DiscoveryDiagnostics.Entry(date: Date(), processor: DiscoveryCore.processorVersion, phase: "provider", outcome: "http-503", seconds: 20, reusedEvidence: false, facts: 0, hasStory: false)
        last.consecutiveFailures = 1; last.namespace = "gpt-" + InternalStoryModel.model; diagnostics.write(last, subject: subject)
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter(), raw = storyRaw(), catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece(root, .recording)], relations: []))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let research = LeadResearch(researchOperation: { _ in await counter.increment(); return raw }, evidenceCache: .init(directory: nil), diagnostics: diagnostics)
        await research.load(subject, library: library)
        let automatic = await counter.value; XCTAssertEqual(automatic, 0)
        await research.load(subject, library: library, force: true)
        let explicit = await counter.value; XCTAssertEqual(explicit, 1)
        XCTAssertEqual(research.state(subject.id), .ready)
    }
    func testAliasResolutionKeepsMapPositionCameraAndSingleVisibleIdentity() {
        let root = id("root").rawValue, provisional = id("provisional").rawValue, target = id("catalog").rawValue
        var map = RelationMapModel(root: root)
        map.nodes[provisional] = .init(id: provisional, position: CGPoint(x: 100, y: 20), via: root, label: "原曲", expanded: false)
        map.order.append(provisional); map.edges = [.init(from: root, to: provisional, label: "原曲", meet: false)]
        map.camera = .init(x: 10, y: 11, scale: 0.7); map.focus = provisional
        map.canonicalize { $0 == provisional ? target : $0 }
        XCTAssertNil(map.nodes[provisional]); XCTAssertEqual(map.nodes[target]?.position, CGPoint(x: 100, y: 20))
        XCTAssertEqual(map.focus, target); XCTAssertEqual(map.camera.scale, 0.7)
        XCTAssertEqual(map.path(to: target), [root, target]); XCTAssertEqual(map.edges.count, 1)
    }
    func testLegacyReadingFocusCannotTurnAnAlbumOrArtistStoryIntoARecordingStory() throws {
        let catalog = CatalogStore(cacheURL: nil)
        let album = piece("album", .release), artist = piece("artist", .person)
        var recording = piece("root", .recording)
        recording.linkedAlbumID = album.id; recording.linkedCreatorIDs = [artist.id]
        try catalog.merge(.init(works: [recording, album, artist], relations: []))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        for (subject, expected) in [("album", album.id), ("artist", artist.id)] {
            let story = LeadStory(text: "A saved story", subject: subject, url: page, source: "Interview", focusEntityID: recording.id.rawValue)
            XCTAssertEqual(LeadResearch.resolvedStoryFocus(story, rootID: recording.id.rawValue, library: library), expected.rawValue)
        }
    }
    func testAStoryStaysReadableWhileAnEmptyRefreshRefinesMetadata() async throws {
        actor Replies {
            var count = 0
            func next(_ first: LeadResearchClient.Raw) -> LeadResearchClient.Raw {
                count += 1
                if count == 1 { return first }
                var empty = LeadResearchClient.Raw(leads: [], story: nil)
                empty.relations = []; empty.observedURLs = []
                return empty
            }
        }
        @MainActor final class Probe {
            weak var research: LeadResearch?
            var seen: [String?] = []
        }
        let root = "loading-" + UUID().uuidString, catalog = CatalogStore(cacheURL: nil)
        try catalog.merge(.init(works: [piece(root, .recording)], relations: []))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        let subject = LeadSubject(id: id(root).rawValue, kind: .song, title: root, creator: "Artist", album: "Single")
        let replies = Replies(), raw = storyRaw(), probe = Probe()
        let research = LeadResearch(researchOperation: { _ in await replies.next(raw) }, evidenceCache: .init(directory: nil),
            diagnostics: .init(directory: nil), metadataRefinement: { leads, _ in
                probe.seen.append(probe.research?.story(for: subject.id)?.body)
                return leads
            })
        probe.research = research
        await research.load(subject, library: library, force: true)
        await research.load(subject, library: library, force: true)
        XCTAssertEqual(probe.seen, [raw.story?.text, raw.story?.text], "The old story stays visible during the refresh, not only after it finishes")
        XCTAssertEqual(research.state(subject.id), .ready)
    }
    func testAllRetainedPaidAnswersReplayWithoutClearingUnattributedOlderFacts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiscoveryEvidenceCache(directory: folder), root = "history-" + UUID().uuidString
        let subject = LeadSubject(id: id(root).rawValue, kind: .song, title: root, creator: "Artist", album: "Single")
        func answer(_ name: String, date: TimeInterval) throws -> DiscoveryEvidenceCache.Entry {
            let text = "{\"leads\":[{\"ref\":\"game\",\"name\":\"\(name)\",\"target_type\":\"game\"}],\"relations\":[{\"from\":\"current\",\"to\":\"game\",\"relation\":\"created_for\",\"url\":\"\(page)\",\"evidence_quote\":\"Credits for \(name)\"}],\"story\":null}"
            return .init(subject: subject, namespace: "gpt-" + InternalStoryModel.model, visibleText: text,
                observedURLs: [page], usage: nil, researchSeconds: 30, fetchedAt: Date(timeIntervalSince1970: date))
        }
        let a = try answer("Game A", date: 1), b = try answer("Game B", date: 2)
        cache.write(a); cache.write(b)
        XCTAssertEqual(cache.answers(subject, namespace: a.namespace).count, 2)
        let catalog = CatalogStore(cacheURL: nil)
        let kept = RelationEdge(from: id(root), to: id("older"), predicate: .techniqueReference, label: "灵感来自", inverseLabel: "启发",
            source: .init(title: "线索", detail: "Older evidence", url: page, researchEvidenceKey: "rotated-out-answer"), researchRoot: id(root))
        let invalid = RelationEdge(from: id(root), to: id("bad"), predicate: .soundtrackOf, label: "Old processor claim", inverseLabel: "音乐",
            source: .init(title: "线索", url: page, researchEvidenceKey: a.fingerprint), researchRoot: id(root))
        try catalog.merge(.init(works: [piece(root, .recording), piece("older", .book), piece("bad", .game)], relations: [kept, invalid]))
        let (library, defaults, suite) = try library(catalog); defer { defaults.removePersistentDomain(forName: suite) }
        actor Counter { var count = 0; func increment() { count += 1 } }
        let counter = Counter()
        let research = LeadResearch(researchOperation: { _ in await counter.increment(); throw LeadResearchClient.Failure.noAccess },
            evidenceCache: cache, diagnostics: .init(directory: nil), metadataRefinement: { cards, _ in cards })
        await research.load(subject, library: library)
        let calls = await counter.count; XCTAssertEqual(calls, 0)
        let names = Set(research.navigationLeads(subject.id, library: library).map(\.original))
        XCTAssertTrue(names.contains("Game A")); XCTAssertTrue(names.contains("Game B")); XCTAssertTrue(names.contains("older"))
        XCTAssertFalse(catalog.edges.contains { $0.id == invalid.id })
        XCTAssertTrue(catalog.edges.contains { $0.id == kept.id })
    }
    func testAnHTTPOnlyConnectionBecomesAPendingNameBeforeCatalogInstallation() throws {
        let text = #"{"leads":[{"ref":"game","name":"Game","target_type":"game"}],"relations":[{"from":"current","to":"game","relation":"created_for","url":"http://example.com/credits","evidence_quote":"Music credits"}],"story":null}"#
        var raw = try XCTUnwrap(DiscoveryResponseDecoder.decode(text)); raw.observedURLs = ["http://example.com/credits"]
        let plan = DiscoveryCore.prepare(raw, subject: .init(id: "test:current", kind: .song, title: "Song", creator: "Artist", album: "Album"))
        XCTAssertTrue(plan.nodes.isEmpty); XCTAssertTrue(plan.links.isEmpty); XCTAssertEqual(plan.clues.map(\.ref), ["game"])
    }
    func testPrintedCoversKeepWordsAndStoryDisplayKeepsLatinNames() {
        for (title, word) in [("DISSIDIA FINAL FANTASY NT", "DISSIDIA"), ("布里奇顿", "布里奇顿"),
            ("麻烦一族", "麻烦一族"), ("龍の尾 ～神龍討滅戦～", "神龍討滅戦"),
            ("冥き水底 ～テンペスト～", "テンペスト"), ("最终幻想14：暗影之逆焰", "暗影之逆焰"),
            ("Concerto in E major", "Concerto"), ("THE PRIMALS", "PRIMALS"), ("这次没翻到可核对的关联", "关联")] {
            let layout = PrintedCoverTypography.layout(title, width: 70, height: 100)
            XCTAssertLessThanOrEqual(layout.lines.count, 3)
            XCTAssertTrue(layout.lines.contains { $0.contains(word) }, title + " must not split " + word + ": " + layout.lines.joined(separator: " / "))
        }
        XCTAssertEqual(StoryTextPresentation.clean("《红莲之狂潮》 的音乐由 THE PRIMALS 演奏。"), "《红莲之狂潮》的音乐由THE PRIMALS演奏。")
    }
}
