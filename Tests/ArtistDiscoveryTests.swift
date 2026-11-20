import XCTest
@testable import Pianwai

/// Artist identity crosses catalog boundaries through an exact P2850 claim.
/// These tests exercise both real services, CatalogStore and its disk cache.
@MainActor
final class ArtistDiscoveryTests: XCTestCase {
    func testAppleArtistAutomaticallyDiscoversCreditsAndPersistsIdentityEvidence() async throws {
        let apple: [String: Any] = ["results": [["wrapperType": "artist", "artistId": 881001, "artistName": "New Artist", "artistViewUrl": "https://music.apple.com/us/artist/881001"]]]
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(apple), artistPlan(artistSearch("Q881001")),
            artistPlan(artistEntities([artistNode("Q881001", artistID: "881001", title: "Database name", works: ["Q881010"])])),
            artistPlan(artistEntities([artistFilm("Q881010", composer: "Q881001")]))
        ]); defer { h.close() }
        let store = h.store()
        let results = try await store.search("New Artist", country: "us", kind: .musicArtist)
        let id = try XCTUnwrap(results.first)
        XCTAssertNil(store.work(id).knowledgeID)
        await store.expandKnowledge(id)

        XCTAssertNil(store.knowledgeErrors[id])
        XCTAssertFalse(store.knowledgeLoading.contains(id))
        XCTAssertEqual(store.work(id).knowledgeID, "Q881001")
        XCTAssertEqual(store.work(id).title, "New Artist")
        XCTAssertEqual(store.work(id).catalogID, "881001")
        let source = try XCTUnwrap(store.work(id).knowledgeIdentitySource)
        XCTAssertEqual(URLComponents(string: source.url)?.path, "/wiki/Q881001")
        XCTAssertEqual(URLComponents(string: source.url)?.fragment, "Q881001$44444444-4444-4444-4444-444444444444")
        let identity = try XCTUnwrap(store.edges.first { $0.from == id && $0.predicate == .artistIdentity })
        XCTAssertEqual(identity.to.rawValue, "wikidata:Q881001")
        XCTAssertEqual(identity.label, "创作者")
        XCTAssertEqual(identity.inverseLabel, "音乐目录")
        XCTAssertEqual(identity.source, source)
        XCTAssertEqual(store.work(identity.to).title, "Database name")
        let edge = try XCTUnwrap(store.edges.first { $0.to == identity.to && $0.predicate == .composedBy })
        XCTAssertEqual(store.work(edge.from).knowledgeID, "Q881010")
        XCTAssertEqual(store.work(edge.from).kind, "电影")
        XCTAssertTrue(edge.source.title.hasPrefix("Wikidata · "))
        XCTAssertFalse(store.edges.contains { $0.to == id && $0.predicate == .composedBy }, "A database profile name is not a film credit")
        XCTAssertEqual(h.queries.filter { $0 == "haswbstatement:P2850=881001" }.count, 1)
        XCTAssertNil(store.storageError)

        await store.flushPendingWrites()
        let restored = h.store()
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.work(id).knowledgeID, "Q881001")
        XCTAssertEqual(restored.work(id).knowledgeIdentitySource, source)
        XCTAssertEqual(restored.work(id).catalogID, "881001")
        XCTAssertEqual(restored.edges.first { $0.id == identity.id }?.source, source)
        XCTAssertEqual(restored.work(identity.to).knowledgeID, "Q881001")
        XCTAssertEqual(restored.edges.first { $0.id == edge.id }?.source, edge.source)
        XCTAssertEqual(h.requests.count, 4, "The verified root entity can be reused by expansion and reload is local")
    }

    func testArtistProfileLinksToStablePersonWithoutRelabelingComposerCredits() async throws {
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistSearch("Q11190062")),
            artistPlan(artistEntities([artistNode("Q11190062", artistID: "322356337", title: "牛尾憲輔", works: ["Q881020"])])),
            artistPlan(artistEntities([artistFilm("Q881020", composer: "Q11190062")]))
        ]); defer { h.close() }
        let store = h.store()
        let agraph = appleArtist("322356337", title: "agraph")
        try store.merge(CatalogSnapshot(works: [agraph], relations: []))
        let originalUshio = store.work(.ushio)
        let originalSources = Dictionary(uniqueKeysWithValues: store.edges.map { ($0.id, $0.source) })
        await store.expandKnowledge(agraph.id)

        XCTAssertNil(store.knowledgeErrors[agraph.id])
        XCTAssertEqual(store.work(agraph.id).knowledgeID, "Q11190062")
        XCTAssertEqual(store.work(.ushio).knowledgeID, "Q11190062")
        XCTAssertNotEqual(store.canonicalID(for: agraph.id), store.canonicalID(for: .ushio))
        XCTAssertEqual(store.work(agraph.id).catalogID, "322356337")
        XCTAssertEqual(store.work(.ushio).catalogID, "939561587")
        XCTAssertEqual(store.work(agraph.id).title, "agraph")
        XCTAssertEqual(store.work(.ushio).title, originalUshio.title)
        XCTAssertEqual(store.work(.ushio).knowledgeIdentitySource, originalUshio.knowledgeIdentitySource)
        XCTAssertNotNil(store.work(agraph.id).knowledgeIdentitySource)
        let identity = try XCTUnwrap(store.edges.first { $0.from == agraph.id && $0.predicate == .artistIdentity })
        XCTAssertEqual(identity.to, .ushio)
        XCTAssertEqual(identity.source, store.work(agraph.id).knowledgeIdentitySource)
        let discovered = try XCTUnwrap(store.edges.first { $0.from.rawValue == "wikidata:Q881020" && $0.predicate == .composedBy })
        XCTAssertEqual(discovered.to, .ushio, "A film composer credit points to the stable person, not their Apple profile alias")
        XCTAssertFalse(store.edges.contains { $0.from == discovered.from && $0.to == agraph.id && $0.predicate == .composedBy })
        for edge in store.edges where originalSources[edge.id] != nil { XCTAssertEqual(edge.source, originalSources[edge.id]) }

        await store.flushPendingWrites()
        let restored = h.store()
        XCTAssertNil(restored.storageError)
        XCTAssertNotEqual(restored.canonicalID(for: agraph.id), restored.canonicalID(for: .ushio))
        XCTAssertEqual(restored.work(agraph.id).knowledgeIdentitySource, store.work(agraph.id).knowledgeIdentitySource)
        XCTAssertEqual(restored.edges.first { $0.id == identity.id }?.to, .ushio)
        XCTAssertEqual(restored.edges.first { $0.id == discovered.id }?.to, .ushio)
    }

    func testNoExactArtistIdentityFinishesWithoutErrorOrRepeatedRequests() async throws {
        let h = try ArtistDiscoveryHarness(plans: [artistPlan(["query": ["searchinfo": ["totalhits": 0], "search": []]])]); defer { h.close() }
        let store = h.store()
        let artist = appleArtist("882001", title: "Unlisted Artist")
        try store.merge(CatalogSnapshot(works: [artist], relations: []))
        let originalCount = store.works.count
        await store.expandKnowledge(artist.id)
        await store.expandKnowledge(artist.id)
        XCTAssertNil(store.knowledgeErrors[artist.id])
        XCTAssertFalse(store.knowledgeLoading.contains(artist.id))
        XCTAssertNil(store.work(artist.id).knowledgeID)
        XCTAssertNil(store.work(artist.id).knowledgeIdentitySource)
        XCTAssertEqual(store.works.count, originalCount)
        XCTAssertEqual(h.requests.count, 1)
    }

    func testFailedArtistResolutionCanRetryAndRecoverWithoutChangingIdentity() async throws {
        let h = try ArtistDiscoveryHarness(plans: [
            .failure(.notConnectedToInternet), artistPlan(artistSearch("Q883001")),
            artistPlan(artistEntities([artistNode("Q883001", artistID: "883001", title: "Recovered Artist", works: ["Q883010"])])),
            artistPlan(artistEntities([artistFilm("Q883010", composer: "Q883001")]))
        ]); defer { h.close() }
        let store = h.store()
        let artist = appleArtist("883001", title: "Recovered Artist")
        try store.merge(CatalogSnapshot(works: [artist], relations: []))
        await store.expandKnowledge(artist.id)
        XCTAssertNotNil(store.knowledgeErrors[artist.id])
        XCTAssertNil(store.work(artist.id).knowledgeID)
        XCTAssertNil(store.work(artist.id).knowledgeIdentitySource)
        XCTAssertFalse(store.knowledgeLoading.contains(artist.id))

        await store.expandKnowledge(artist.id, retry: true)
        XCTAssertNil(store.knowledgeErrors[artist.id])
        XCTAssertEqual(store.work(artist.id).knowledgeID, "Q883001")
        XCTAssertNotNil(store.work(artist.id).knowledgeIdentitySource)
        XCTAssertEqual(store.canonicalID(for: artist.id), artist.id)
        let identity = try XCTUnwrap(store.edges.first { $0.from == artist.id && $0.predicate == .artistIdentity })
        XCTAssertEqual(identity.to.rawValue, "wikidata:Q883001")
        XCTAssertTrue(store.edges.contains { $0.to == identity.to && $0.from.rawValue == "wikidata:Q883010" && $0.predicate == .composedBy })
        XCTAssertEqual(h.requests.count, 4, "The failed search must not be cached as a successful negative resolution")
    }

    func testSongsAlbumsAndMoviesDoNotUseArtistIdentifierBridge() async throws {
        let h = try ArtistDiscoveryHarness(plans: []); defer { h.close() }
        let store = h.store()
        let specs = [("song", "歌曲", "884001"), ("album", "专辑", "884002"), ("feature-movie", "电影", "884003")]
        let items = specs.map { route, kind, number in
            Work(id: WorkID(rawValue: "apple:\(route):\(number)")!, title: "Unmapped \(kind)", creator: "", kind: kind, art: "", detail: "", url: nil, linkedCreatorIDs: [], catalogID: number, storeCountry: "us")
        }
        try store.merge(CatalogSnapshot(works: items, relations: []))
        for item in items {
            await store.expandKnowledge(item.id)
            XCTAssertNil(store.work(item.id).knowledgeID)
            XCTAssertNil(store.work(item.id).knowledgeIdentitySource)
            XCTAssertNil(store.knowledgeErrors[item.id])
        }
        XCTAssertTrue(h.requests.isEmpty, "A catalog number without artist type must never be interpreted as P2850")
    }

    func testLegacyCachedArtistTargetCreditsNormalizeWithoutChangingAppleAlbumMembership() async throws {
        let h = try ArtistDiscoveryHarness(plans: []); defer { h.close() }
        var agraph = appleArtist("322356337", title: "agraph")
        agraph.knowledgeID = "Q11190062"
        agraph.knowledgeIdentitySource = Source(title: "Wikidata · 牛尾宪辅", detail: "社区维护的结构化资料", url: "https://www.wikidata.org/wiki/Q11190062#Q11190062$7440196b-4704-e905-eb85-0a14d3230f89")
        let film = Work(id: WorkID(rawValue: "wikidata:Q885010")!, title: "Legacy Film", creator: "", kind: "电影", art: "", detail: "", url: "https://www.wikidata.org/wiki/Q885010", linkedCreatorIDs: [], knowledgeID: "Q885010")
        let album = Work(id: WorkID(rawValue: "apple:album:885020")!, title: "agraph Album", creator: "agraph", kind: "专辑", art: "", detail: "", url: "https://music.apple.com/us/album/885020", linkedCreatorIDs: [agraph.id], catalogID: "885020", storeCountry: "us")
        let creditSource = Source(title: "Wikidata · Legacy Film", detail: "社区维护的结构化资料", url: "https://www.wikidata.org/wiki/Q885010#Q885010$55555555-5555-5555-5555-555555555555")
        let badAliasCredit = RelationEdge(from: film.id, to: agraph.id, predicate: .composedBy, label: "作曲", inverseLabel: "作曲作品", source: creditSource)
        let canonicalCredit = RelationEdge(from: film.id, to: .ushio, predicate: .composedBy, label: "作曲", inverseLabel: "作曲作品", source: creditSource)
        let albumCredit = RelationEdge(from: album.id, to: agraph.id, predicate: .performedBy, label: "发行艺人", inverseLabel: "发行作品", source: Source(title: "agraph Album · Apple Music", detail: "发行与艺人信息", url: "https://music.apple.com/us/album/885020"))
        let legacy = CatalogSnapshot(works: Array(Work.seeds.values) + [agraph, film, album], relations: Relations.seeds + [badAliasCredit, canonicalCredit, albumCredit])
        try JSONEncoder().encode(legacy).write(to: h.cacheURL)

        let restored = h.store()
        XCTAssertNil(restored.storageError)
        let composers = restored.edges.filter { $0.from == film.id && $0.predicate == .composedBy }
        XCTAssertEqual(composers.count, 1, "Two catalog profiles for one person must not appear as co-composers")
        XCTAssertEqual(composers.first?.to, .ushio)
        XCTAssertEqual(composers.first?.source, creditSource)
        XCTAssertEqual(restored.edges.first { $0.id == albumCredit.id }?.to, agraph.id)
        XCTAssertEqual(restored.edges.first { $0.id == albumCredit.id }?.source, albumCredit.source)
        XCTAssertEqual(restored.work(album.id).creatorIDs, [agraph.id])
        XCTAssertEqual(restored.work(agraph.id).catalogID, "322356337")
        XCTAssertNotEqual(restored.canonicalID(for: agraph.id), restored.canonicalID(for: .ushio))
        restored.save()
        await restored.flushPendingWrites()
        XCTAssertNil(restored.storageError)
        let persisted = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: h.cacheURL))
        XCTAssertEqual(persisted.relations.filter { $0.from == film.id && $0.predicate == .composedBy }.map(\.to), [.ushio])
        XCTAssertEqual(persisted.relations.first { $0.id == albumCredit.id }?.to, agraph.id)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testFilmToNewComposerToSeparateDirectoriesReleaseRecordingAndListenLater() async throws {
        let person = directoryPerson("Q886001", profiles: [
            directoryClaim("Q886001", number: "886001", name: "Studio Alias", guid: "11111111-1111-1111-1111-111111111111"),
            directoryClaim("Q886001", number: "886002", name: "Live Alias", guid: "22222222-2222-2222-2222-222222222222")
        ], works: ["Q886010"])
        let artist: [String: Any] = ["wrapperType": "artist", "artistId": 886001, "artistName": "Verified Apple Name"]
        let album: [String: Any] = ["wrapperType": "collection", "collectionId": 886020, "collectionName": "Original Score",
                                  "artistId": 886001, "artistName": "Verified Apple Name", "collectionViewUrl": "https://music.apple.com/jp/album/886020"]
        let song: [String: Any] = ["wrapperType": "track", "kind": "song", "trackId": 886030, "trackName": "Opening",
                                 "artistId": 886001, "artistName": "Verified Apple Name", "collectionId": 886020,
                                 "collectionName": "Original Score", "trackViewUrl": "https://music.apple.com/jp/song/886030"]
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistEntities([artistFilm("Q886010", composer: "Q886001")])),
            artistPlan(artistEntities([person])),
            artistPlan(artistSearch("Q886001")), artistPlan(artistSearch("Q886001")),
            artistPlan(["results": [artist, album]]), artistPlan(["results": [album, song]])
        ]); defer { h.close() }
        let store = h.store()
        let film = try await store.openKnowledgeCandidate("Q886010")
        let composer = try XCTUnwrap(store.edges.first { $0.from == film && $0.predicate == .composedBy }?.to)
        XCTAssertEqual(composer.rawValue, "wikidata:Q886001")
        await store.enrich(composer)
        XCTAssertNil(store.knowledgeErrors[composer])
        let directories = store.edges.filter { $0.to == composer && $0.predicate == .artistIdentity }
        XCTAssertEqual(Set(directories.map { $0.from.rawValue }), ["apple:artist:886001", "apple:artist:886002"])
        XCTAssertEqual(Set(directories.map { store.work($0.from).title }), ["Studio Alias", "Live Alias"])
        for edge in directories {
            XCTAssertEqual(edge.label, "创作者")
            XCTAssertEqual(edge.inverseLabel, "音乐目录")
            XCTAssertEqual(edge.source, store.work(edge.from).knowledgeIdentitySource)
            XCTAssertTrue(URLComponents(string: edge.source.url)?.fragment?.hasPrefix("Q886001$") == true)
            XCTAssertNotEqual(store.canonicalID(for: edge.from), composer)
        }
        let profile = try XCTUnwrap(directories.first { $0.from.rawValue == "apple:artist:886001" }?.from)
        await store.enrich(profile)
        XCTAssertNil(store.lookupErrors[profile])
        XCTAssertEqual(store.work(profile).title, "Verified Apple Name")
        let release = try XCTUnwrap(store.edges.first { $0.to == profile && $0.predicate == .performedBy }?.from)
        XCTAssertEqual(release.rawValue, "apple:album:886020")
        await store.enrich(release)
        let recording = try XCTUnwrap(store.edges.first { $0.to == release && $0.predicate == .inAlbum }?.from)
        XCTAssertEqual(recording.rawValue, "apple:song:886030")
        XCTAssertEqual(store.work(recording).catalogRecordingID, "886030")
        await store.expandKnowledge(composer, retry: true)
        XCTAssertEqual(store.work(profile).title, "Verified Apple Name", "A knowledge refresh cannot replace an already resolved catalog display name")
        XCTAssertEqual(store.edges.first { $0.from == film && $0.predicate == .composedBy }?.to, composer,
                       "Catalog profiles never become person anchors for film credits")
        XCTAssertNotEqual(store.canonicalID(for: profile), store.canonicalID(for: WorkID(rawValue: "apple:artist:886002")!))

        let suite = "Pianwai.ReverseJourney.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        library.explore(film); library.open(composer); library.open(profile); library.open(release); library.open(recording)
        let path = library.path
        library.toggleListenLater(recording)
        XCTAssertEqual(library.listenLater, [recording])
        XCTAssertEqual(library.path, path)
        XCTAssertEqual(library.reading, recording)
        await store.flushPendingWrites()
        let restored = h.store()
        library.flushPendingWritesBeforeTermination()
        let restoredLibrary = Library(defaults: defaults, arguments: [], catalog: restored)
        XCTAssertEqual(restoredLibrary.listenLater, [recording])
        XCTAssertEqual(restored.work(profile).knowledgeIdentitySource, store.work(profile).knowledgeIdentitySource)
        XCTAssertEqual(restored.work(profile).title, "Verified Apple Name")
        XCTAssertEqual(h.requests.count, 6, "No name search or playback request is needed anywhere in the journey")
    }

    func testSecondDirectoryHTTPFailureKeepsPersonAndCreditsAndCanRetry() async throws {
        let qid = "Q888001"
        let person = directoryPerson(qid, profiles: [
            directoryClaim(qid, number: "888101", name: "First Alias", guid: "11111111-1111-1111-1111-111111111111"),
            directoryClaim(qid, number: "888102", name: "Second Alias", guid: "22222222-2222-2222-2222-222222222222"),
            directoryClaim(qid, number: "888103", name: "Third Alias", guid: "33333333-3333-3333-3333-333333333333")
        ], works: ["Q888010"])
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistEntities([person])), artistPlan(artistEntities([artistFilm("Q888010", composer: qid)])),
            artistPlan(artistSearch(qid)), .http(500), artistPlan(artistSearch(qid)),
            .http(500), artistPlan(artistSearch(qid))
        ]); defer { h.close() }
        let store = h.store()
        let selected = try await store.openKnowledgeCandidate(qid)
        let first = WorkID(rawValue: "apple:artist:888101")!
        let second = WorkID(rawValue: "apple:artist:888102")!
        let third = WorkID(rawValue: "apple:artist:888103")!
        XCTAssertEqual(selected.rawValue, "wikidata:\(qid)", "A failed directory must not prevent the verified person from opening")
        XCTAssertEqual(Set(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.map(\.from)), [first, third],
                       "Keep the earlier success and continue checking independent directories after the failure")
        XCTAssertNotNil(store.works[first])
        XCTAssertNil(store.works[second])
        XCTAssertNotNil(store.works[third])
        let credit = try XCTUnwrap(store.edges.first { $0.from.rawValue == "wikidata:Q888010" && $0.to == selected && $0.predicate == .composedBy })
        XCTAssertTrue(store.knowledgePartial.contains(selected))
        XCTAssertNotNil(store.knowledgeErrors[selected])
        XCTAssertFalse(store.knowledgeLoading.contains(selected))
        XCTAssertEqual(h.requests.count, 5)

        await store.expandKnowledge(selected, retry: true)
        XCTAssertNotNil(store.knowledgeErrors[selected], "The store expansion path must retain its retryable partial state too")
        XCTAssertEqual(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.count, 2)
        XCTAssertEqual(store.edges.first { $0.id == credit.id }?.source, credit.source)
        XCTAssertFalse(store.knowledgeLoading.contains(selected))
        XCTAssertEqual(h.requests.count, 6)

        await store.expandKnowledge(selected)
        XCTAssertNil(store.knowledgeErrors[selected], "A partial response must not be marked completely loaded")
        XCTAssertEqual(Set(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.map(\.from)), [first, second, third])
        XCTAssertEqual(store.edges.filter { $0.id == credit.id }.count, 1)
        XCTAssertEqual(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.count, 3)
        XCTAssertEqual(h.requests.count, 7, "Only the failed directory should need another network request")
        await store.expandKnowledge(selected)
        XCTAssertEqual(h.requests.count, 7, "A completed recovery is cached")
    }

    func testCancelledDirectoryExpansionDoesNotPublishPartialCandidate() async throws {
        let secondRequested = XCTestExpectation(description: "Second directory request is in flight")
        let qid = "Q889001"
        let person = directoryPerson(qid, profiles: [
            directoryClaim(qid, number: "889101", name: "Verified Alias", guid: "11111111-1111-1111-1111-111111111111"),
            directoryClaim(qid, number: "889102", name: "Cancelled Alias", guid: "22222222-2222-2222-2222-222222222222")
        ], works: ["Q889010"])
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistEntities([person])), artistPlan(artistEntities([artistFilm("Q889010", composer: qid)])),
            artistPlan(artistSearch(qid)), .waitForCancellation { secondRequested.fulfill() },
            artistPlan(artistSearch(qid))
        ]); defer { h.close() }
        let store = h.store()
        store.save()
        await store.flushPendingWrites()
        let initialDisk = try Data(contentsOf: h.cacheURL)
        let initialWorkCount = store.works.count
        let initialEdgeCount = store.edges.count
        let task = Task { @MainActor in try await store.openKnowledgeCandidate(qid) }
        let started = await XCTWaiter.fulfillment(of: [secondRequested], timeout: 3)
        XCTAssertEqual(started, .completed)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate instead of publishing partial results")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(store.works.count, initialWorkCount)
        XCTAssertEqual(store.edges.count, initialEdgeCount)
        XCTAssertNil(store.works[WorkID(rawValue: "wikidata:\(qid)")!])
        XCTAssertNil(store.works[WorkID(rawValue: "apple:artist:889101")!])
        XCTAssertNil(store.works[WorkID(rawValue: "apple:artist:889102")!])
        XCTAssertEqual(try Data(contentsOf: h.cacheURL), initialDisk, "A cancelled operation must not persist its earlier successful branches")
        XCTAssertEqual(h.requests.count, 4)

        let selected = try await store.openKnowledgeCandidate(qid)
        XCTAssertEqual(selected.rawValue, "wikidata:\(qid)")
        XCTAssertEqual(Set(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.map { $0.from.rawValue }),
                       ["apple:artist:889101", "apple:artist:889102"])
        XCTAssertNil(store.knowledgeErrors[selected])
        XCTAssertEqual(h.requests.count, 5, "A fresh caller can reuse verified responses but must retry the genuinely cancelled directory")
    }

    func testProviderOnlyDirectoryCancellationPersistsVerifiedBranchesAndRetryAddsTheMissingAlias() async throws {
        let qid = "Q889001"
        let person = directoryPerson(qid, profiles: [
            directoryClaim(qid, number: "889101", name: "Verified Alias", guid: "11111111-1111-1111-1111-111111111111"),
            directoryClaim(qid, number: "889102", name: "Interrupted Alias", guid: "22222222-2222-2222-2222-222222222222")
        ], works: ["Q889010"])
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistEntities([person])), artistPlan(artistEntities([artistFilm("Q889010", composer: qid)])),
            artistPlan(artistSearch(qid)), .failure(.cancelled), artistPlan(artistSearch(qid))
        ]); defer { h.close() }
        let store = h.store()
        let selected = try await store.openKnowledgeCandidate(qid)
        let verified = WorkID(rawValue: "apple:artist:889101")!
        let missing = WorkID(rawValue: "apple:artist:889102")!
        let film = WorkID(rawValue: "wikidata:Q889010")!
        XCTAssertFalse(Task.isCancelled, "The provider failure must not be mistaken for cancellation of this caller")
        XCTAssertEqual(selected.rawValue, "wikidata:\(qid)")
        XCTAssertNotNil(store.knowledgeErrors[selected], "Partial publication must retain a visible retryable failure")
        XCTAssertTrue(store.knowledgePartial.contains(selected))
        XCTAssertNotNil(store.works[verified])
        XCTAssertNil(store.works[missing])
        let credit = try XCTUnwrap(store.edges.first { $0.from == film && $0.to == selected && $0.predicate == .composedBy })
        XCTAssertEqual(Set(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.map(\.from)), [verified])
        await store.flushPendingWrites()
        let restored = h.store()
        XCTAssertNotNil(restored.works[verified])
        XCTAssertNil(restored.works[missing])
        XCTAssertEqual(restored.edges.first { $0.id == credit.id }?.source, credit.source)
        XCTAssertEqual(h.requests.count, 4)

        await store.expandKnowledge(selected)
        XCTAssertNil(store.knowledgeErrors[selected], "Provider-only cancellation must not mark the person completely loaded")
        XCTAssertEqual(Set(store.edges.filter { $0.to == selected && $0.predicate == .artistIdentity }.map(\.from)), [verified, missing])
        XCTAssertEqual(store.edges.filter { $0.id == credit.id }.count, 1)
        XCTAssertEqual(store.edges.first { $0.id == credit.id }?.source, credit.source)
        XCTAssertEqual(h.requests.count, 5)
        await store.flushPendingWrites()
        XCTAssertNotNil(h.store().works[missing])
    }

    func testReverseDirectoriesRejectDeprecatedUnknownQualifiedAndAmbiguousClaims() async throws {
        var deprecated = directoryClaim("Q887001", number: "887101", name: nil); deprecated["rank"] = "deprecated"
        var scoped = directoryClaim("Q887001", number: "887102", name: nil)
        scoped["qualifiers"] = ["P580": [["snaktype": "value", "datatype": "time"]]]
        let unknown: [String: Any] = ["id": "Q887001$33333333-3333-3333-3333-333333333333", "rank": "normal",
                                      "mainsnak": ["snaktype": "somevalue", "datatype": "external-id"]]
        let ambiguous = directoryClaim("Q887001", number: "887103", name: "Ambiguous Alias")
        let person = directoryPerson("Q887001", profiles: [deprecated, scoped, unknown, ambiguous], works: ["Q887010"])
        let other = directoryPerson("Q887002", profiles: [directoryClaim("Q887002", number: "887103", name: nil)], works: [])
        let h = try ArtistDiscoveryHarness(plans: [
            artistPlan(artistEntities([person])), artistPlan(artistEntities([artistFilm("Q887010", composer: "Q887001")])),
            artistPlan(["query": ["searchinfo": ["totalhits": 2], "search": [["title": "Q887001"], ["title": "Q887002"]]]]),
            artistPlan(artistEntities([person, other]))
        ]); defer { h.close() }
        let store = h.store()
        let selected = try await store.openKnowledgeCandidate("Q887001")
        XCTAssertFalse(store.edges.contains { $0.to == selected && $0.predicate == .artistIdentity })
        XCTAssertFalse(store.works.keys.contains { $0.rawValue.hasPrefix("apple:artist:887") })
        XCTAssertTrue(store.knowledgePartial.contains(selected))
        XCTAssertEqual(h.queries, ["haswbstatement:P2850=887103"], "Unsupported statements never trigger directory lookup")
    }

    func testLiveFilmComposerDirectoryReleaseRecordingCanBeSavedWithoutNameSearch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 for the reverse artist journey")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.ReverseLive.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CatalogStore(cacheURL: directory.appendingPathComponent("catalog.json"), bundle: Bundle(for: Self.self))
        let film = try await store.openKnowledgeCandidate("Q578595")
        let composer = try XCTUnwrap(store.edges.first { $0.from == film && $0.predicate == .composedBy && store.work($0.to).knowledgeID == "Q930143" }?.to)
        await store.enrich(composer)
        XCTAssertNil(store.knowledgeErrors[composer])
        let profile = try XCTUnwrap(store.edges.first { $0.to == composer && $0.predicate == .artistIdentity && store.work($0.from).catalogID == "76056888" }?.from)
        XCTAssertNotEqual(profile, composer)
        let source = try XCTUnwrap(store.work(profile).knowledgeIdentitySource)
        XCTAssertEqual(URLComponents(string: source.url)?.path, "/wiki/Q930143")
        XCTAssertTrue(URLComponents(string: source.url)?.fragment?.hasPrefix("Q930143$") == true)
        await store.enrich(profile)
        XCTAssertNil(store.lookupErrors[profile])
        let release = try XCTUnwrap(store.edges.first { $0.to == profile && $0.predicate == .performedBy && store.work($0.from).isAlbum }?.from)
        await store.enrich(release)
        XCTAssertNil(store.lookupErrors[release])
        let recording = try XCTUnwrap(store.edges.first { $0.to == release && $0.predicate == .inAlbum && store.work($0.from).isSong }?.from)
        XCTAssertNotNil(store.work(recording).catalogRecordingID)
        let suite = "Pianwai.ReverseLiveLibrary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = Library(defaults: defaults, arguments: [], catalog: store)
        library.explore(film); library.open(composer); library.open(profile); library.open(release); library.open(recording)
        library.toggleListenLater(recording)
        XCTAssertEqual(library.listenLater, [recording])
        XCTAssertEqual(library.reading, recording)
        XCTAssertEqual(store.edges.first { $0.from == film && $0.predicate == .composedBy }?.to, composer)
        XCTAssertNil(library.currentTrack, "This is live discovery, never a MusicKit playback test")
    }

    func testLiveAgraphArtistDiscoversUshioCreditsWithoutMergingAppleProfiles() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PIANWAI_LIVE_KNOWLEDGE"] == "1", "Set PIANWAI_LIVE_KNOWLEDGE=1 for the live artist bridge")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.ArtistLive.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let store = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self), knowledgeService: KnowledgeGraphService())
        let agraph = appleArtist("322356337", title: "agraph")
        try store.merge(CatalogSnapshot(works: [agraph], relations: []))
        await store.expandKnowledge(agraph.id)
        XCTAssertNil(store.knowledgeErrors[agraph.id])
        XCTAssertEqual(store.work(agraph.id).knowledgeID, "Q11190062")
        let identitySource = try XCTUnwrap(store.work(agraph.id).knowledgeIdentitySource)
        XCTAssertEqual(URLComponents(string: identitySource.url)?.host, "www.wikidata.org")
        XCTAssertEqual(URLComponents(string: identitySource.url)?.path, "/wiki/Q11190062")
        XCTAssertTrue(URLComponents(string: identitySource.url)?.fragment?.contains("$") == true)
        XCTAssertEqual(store.work(agraph.id).catalogID, "322356337")
        XCTAssertEqual(store.work(.ushio).catalogID, "939561587")
        XCTAssertNotEqual(store.canonicalID(for: agraph.id), store.canonicalID(for: .ushio))
        let identity = try XCTUnwrap(store.edges.first { $0.from == agraph.id && $0.predicate == .artistIdentity })
        XCTAssertEqual(identity.to, .ushio)
        XCTAssertEqual(identity.source, identitySource)
        let credits = store.edges.filter { $0.to == .ushio && $0.predicate == .composedBy && URLComponents(string: $0.source.url)?.host == "www.wikidata.org" }
        XCTAssertFalse(credits.isEmpty, "The live P800 candidates currently include works carrying a verified composer credit")
        XCTAssertTrue(credits.allSatisfy { URLComponents(string: $0.source.url)?.host == "www.wikidata.org" })
        XCTAssertFalse(store.edges.contains { $0.to == agraph.id && $0.predicate == .composedBy && URLComponents(string: $0.source.url)?.host == "www.wikidata.org" })
        XCTAssertNil(store.storageError)
        await store.flushPendingWrites()
        let restored = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        XCTAssertNil(restored.storageError)
        XCTAssertEqual(restored.work(agraph.id).knowledgeIdentitySource, identitySource)
        XCTAssertNotEqual(restored.canonicalID(for: agraph.id), restored.canonicalID(for: .ushio))
        XCTAssertEqual(restored.edges.first { $0.id == identity.id }?.to, .ushio)
        XCTAssertEqual(Set(restored.edges.filter { $0.to == .ushio && $0.predicate == .composedBy && URLComponents(string: $0.source.url)?.host == "www.wikidata.org" }.map(\.id)), Set(credits.map(\.id)))
    }
}

private func appleArtist(_ number: String, title: String) -> Work {
    Work(id: WorkID(rawValue: "apple:artist:\(number)")!, title: title, creator: "音乐人", kind: "创作者", art: "", detail: "", url: "https://music.apple.com/us/artist/\(number)", linkedCreatorIDs: [], catalogID: number, storeCountry: "us")
}
private func directoryClaim(_ qid: String, number: String, name: String?, guid: String = "33333333-3333-3333-3333-333333333333") -> [String: Any] {
    var result: [String: Any] = ["id": qid + "$" + guid, "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "external-id", "datavalue": ["value": number]]]
    if let name { result["qualifiers"] = ["P1810": [["snaktype": "value", "datatype": "string", "datavalue": ["value": name]]]] }
    return result
}
private func directoryPerson(_ qid: String, profiles: [[String: Any]], works: [String]) -> [String: Any] {
    ["id": qid, "type": "item", "labels": ["zh": ["value": "New Composer"]],
     "claims": ["P31": [artistClaim(qid, "Q5")], "P2850": profiles, "P800": works.map { artistClaim(qid, $0) }]]
}
private func artistSearch(_ qid: String) -> [String: Any] { ["query": ["searchinfo": ["totalhits": 1], "search": [["title": qid]]]] }
private func artistClaim(_ qid: String, _ target: String) -> [String: Any] {
    ["id": qid + "$55555555-5555-5555-5555-555555555555", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": target]]]]
}
private func artistNode(_ qid: String, artistID: String, title: String, works: [String]) -> [String: Any] {
    var external: [String: Any] = ["id": qid + "$44444444-4444-4444-4444-444444444444", "rank": "normal", "mainsnak": ["snaktype": "value", "datatype": "external-id", "datavalue": ["value": artistID]]]
    if artistID == "322356337" { external["qualifiers"] = ["P1810": [["snaktype": "value", "datatype": "string", "datavalue": ["value": "agraph"]]]] }
    return ["id": qid, "type": "item", "labels": ["zh": ["value": title]], "claims": ["P31": [artistClaim(qid, "Q5")], "P2850": [external], "P800": works.map { artistClaim(qid, $0) }]]
}
private func artistFilm(_ qid: String, composer: String) -> [String: Any] {
    ["id": qid, "type": "item", "labels": ["zh": ["value": "Discovered Film"]], "claims": ["P31": [artistClaim(qid, "Q20650540")], "P86": [artistClaim(qid, composer)]]]
}
private func artistEntities(_ values: [[String: Any]]) -> [String: Any] { ["success": 1, "entities": Dictionary(uniqueKeysWithValues: values.map { ($0["id"] as! String, $0) })] }
private func artistPlan(_ object: [String: Any]) throws -> ArtistTransportPlan { .response(try JSONSerialization.data(withJSONObject: object)) }
private enum ArtistTransportPlan: Sendable {
    case response(Data), http(Int), failure(URLError.Code)
    case waitForCancellation(@Sendable () -> Void)
}

@MainActor
private final class ArtistDiscoveryHarness {
    let cacheURL: URL
    private let directory: URL
    private let token = UUID().uuidString
    private let session: URLSession
    private let state: ArtistStubState
    private let knowledge: KnowledgeGraphService
    private let apple: AppleCatalogService
    init(plans: [ArtistTransportPlan]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pianwai.ArtistDiscovery.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("catalog.json")
        state = ArtistStubState(plans: plans)
        ArtistStubRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtistURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Artist-Discovery-Test": token]
        session = URLSession(configuration: config)
        knowledge = KnowledgeGraphService(session: session)
        apple = AppleCatalogService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    var queries: [String] { requests.compactMap { request in request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "srsearch" })?.value } } }
    func store() -> CatalogStore { CatalogStore(cacheURL: cacheURL, service: apple, bundle: Bundle(for: ArtistDiscoveryTests.self), knowledgeService: knowledge) }
    func close() { session.invalidateAndCancel(); ArtistStubRegistry.shared.remove(token); try? FileManager.default.removeItem(at: directory) }
}
private final class ArtistStubRegistry: @unchecked Sendable {
    static let shared = ArtistStubRegistry()
    private let lock = NSLock()
    private var values: [String: ArtistStubState] = [:]
    func put(_ key: String, _ value: ArtistStubState) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String?) -> ArtistStubState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { values[$0] } }
    func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key); lock.unlock() }
}
private final class ArtistStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [ArtistTransportPlan]
    private var observed: [URLRequest] = []
    init(plans: [ArtistTransportPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    func next(_ request: URLRequest) -> ArtistTransportPlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        return plans.isEmpty ? nil : plans.removeFirst()
    }
}
private final class ArtistURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = ArtistStubRegistry.shared.get(request.value(forHTTPHeaderField: "X-Artist-Discovery-Test")), let plan = state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch plan {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let data): respond(data, status: 200)
        case .http(let status): respond(Data("{}".utf8), status: status)
        case .waitForCancellation(let notify): notify()
        }
    }
    private func respond(_ data: Data, status: Int) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MusicKitTestFixture.transcode(data, url: request.url))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
