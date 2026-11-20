import XCTest
@testable import Pianwai

/// Seed-content contracts. These tests check identity, navigation and provenance
/// structure; they do not establish whether an external source proves a claim.
@MainActor
final class CatalogContractTests: XCTestCase {
    func testEverySeedIdentityHasExactlyOneMatchingRecord() {
        XCTAssertEqual(Set(WorkID.allCases), Set(Work.seeds.keys))
        for (key, work) in Work.seeds {
            XCTAssertEqual(key, work.id, "Catalog key differs from its entity identity")
            for field in [work.title, work.creator, work.kind] {
                XCTAssertFalse(field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "Missing seed identity metadata for \(key.rawValue)")
                XCTAssertFalse(["TODO", "TBD", "待补充", "作品暂不可用"].contains(field),
                               "A placeholder must not ship as seed identity metadata")
            }
        }
    }

    func testExternalIDsSurviveCodableWithoutBecomingSeedCases() throws {
        let external = try XCTUnwrap(WorkID(rawValue: "apple:song:1234567890"))
        XCTAssertFalse(WorkID.allCases.contains(external))
        XCTAssertEqual(try JSONDecoder().decode(WorkID.self, from: JSONEncoder().encode(external)), external)
        XCTAssertNil(WorkID(rawValue: ""))
    }

    func testEverySeedRelationHasKnownDistinctEndpointsAndUniqueIdentity() {
        var identities = Set<String>()
        for edge in Relations.seeds {
            XCTAssertNotNil(Work.seeds[edge.from], "Missing source entity: \(edge.id)")
            XCTAssertNotNil(Work.seeds[edge.to], "Missing target entity: \(edge.id)")
            XCTAssertNotEqual(edge.from, edge.to, "Self relation: \(edge.id)")
            XCTAssertTrue(identities.insert(edge.id).inserted, "Duplicate relation: \(edge.id)")
            XCTAssertFalse(edge.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(edge.inverseLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testEverySeedRelationHasUsableSourceMetadata() throws {
        for edge in Relations.seeds {
            let source = edge.source
            let url = try XCTUnwrap(URLComponents(string: source.url), "Malformed source: \(edge.id)")
            XCTAssertEqual(url.scheme, "https", edge.id)
            XCTAssertFalse(try XCTUnwrap(url.host, edge.id).isEmpty)
            XCTAssertNil(url.user, "Credentials must not be embedded in a source URL")
            XCTAssertNil(url.password, "Credentials must not be embedded in a source URL")
            XCTAssertFalse(source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(source.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testSeedCreatorAndAlbumLinksPointToTheRightEntityKinds() throws {
        for work in Work.seeds.values {
            for creatorID in work.creatorIDs {
                let creator = try XCTUnwrap(Work.seeds[creatorID], work.title)
                XCTAssertTrue(creator.isPerson, "A creator link must open a person: \(work.title)")
            }
            if let albumID = work.albumID {
                XCTAssertTrue(work.isSong, "Album membership belongs to a recording")
                XCTAssertTrue(try XCTUnwrap(Work.seeds[albumID]).isAlbum)
                XCTAssertTrue(Relations.seeds.contains {
                    $0.from == work.id && $0.to == albumID && $0.predicate == .inAlbum
                }, "The album link must also exist as a typed relation")
            }
        }
        for edge in Relations.seeds where edge.predicate == .inAlbum {
            XCTAssertTrue(try XCTUnwrap(Work.seeds[edge.from]).isSong)
            XCTAssertTrue(try XCTUnwrap(Work.seeds[edge.to]).isAlbum)
        }
    }

    func testOriginalArrangementReleaseAndAdaptationRetainSeparateIdentities() throws {
        let original = try XCTUnwrap(Work.seeds[.pool])
        let arrangement = try XCTUnwrap(Work.seeds[.animenz])
        // Equal titles are intentional. Deduplicating on title destroys this distinction.
        XCTAssertEqual(original.title, arrangement.title)
        XCTAssertNotEqual(original.id, arrangement.id)
        XCTAssertNotEqual(original.kind, arrangement.kind)
        XCTAssertNotEqual(original.url, arrangement.url)
        XCTAssertNotEqual(original.id, original.albumID)
        XCTAssertNotEqual(WorkID.film, WorkID.manga)
        XCTAssertEqual(Work.seeds[.film]?.kind, "电影")
        XCTAssertEqual(Work.seeds[.manga]?.kind, "漫画")
    }

    func testIncomingRelationsStayDiscoverableAndUseTheirInverseRole() throws {
        let arrangement = try XCTUnwrap(Relations.seeds.first {
            $0.from == .animenz && $0.to == .pool && $0.predicate == .adaptedFrom
        })
        XCTAssertTrue(Relations.forEntity(.pool).contains { $0.id == arrangement.id },
                      "Opening the original must reveal an incoming arrangement relation")
        XCTAssertEqual(arrangement.other(than: .pool), .animenz)
        XCTAssertEqual(arrangement.label(from: .pool), arrangement.inverseLabel)
        XCTAssertEqual(arrangement.other(than: .animenz), .pool)
        XCTAssertEqual(arrangement.label(from: .animenz), arrangement.label)
        for edge in Relations.seeds where [.inAlbum, .adaptedFrom, .soundtrackOf].contains(edge.predicate) {
            XCTAssertNotEqual(edge.label, edge.inverseLabel, "Directional role lost: \(edge.id)")
        }
    }

    func testInterviewMentionAndPreferenceAreNotPresentedAsCreativeInfluence() {
        let conversation = Relations.seeds.filter { $0.from == .jane && $0.to == .distance }
        XCTAssertTrue(conversation.contains { $0.predicate == .interviewMention })
        XCTAssertFalse(conversation.contains { [.adaptedFrom, .techniqueReference].contains($0.predicate) })
        let preference = Relations.seeds.filter { $0.from == .yonezu && $0.to == .distance }
        XCTAssertTrue(preference.contains { $0.predicate == .liked })
        XCTAssertFalse(preference.contains { [.composedBy, .adaptedFrom].contains($0.predicate) })
    }

    func testOrdinarySongHasAnAlbumAndArtistWithoutAnInventedFilmRelation() throws {
        let ordinary = try XCTUnwrap(Work.seeds[.distance])
        XCTAssertTrue(ordinary.isSong)
        XCTAssertNotNil(ordinary.albumID)
        XCTAssertFalse(ordinary.creatorIDs.isEmpty)
        XCTAssertFalse(Relations.seeds.contains {
            $0.from == ordinary.id && [.soundtrackOf, .endingOf].contains($0.predicate)
        })
    }

    func testCollectionsAndReadingCheckpointSurviveIndependentReload() throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let external = try XCTUnwrap(WorkID(rawValue: "apple:song:987654321"))
        let checkpoint = ReadingCheckpoint(workID: .jane, offset: 417.5, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var expected = LibrarySnapshot(saved: [.film, external], listenLater: [external], watchLater: [.animenz], recent: [.jane, .film], checkpoints: [WorkID.jane.rawValue: checkpoint], lastWork: .jane, startedBrowsing: true, country: "jp")
        try LibraryPersistence(defaults: defaults).save(expected)
        XCTAssertEqual(try LibraryPersistence(defaults: defaults).load(), expected)

        // Marking a song as heard must not remove the saved work or a video to watch.
        expected.listenLater = []
        try LibraryPersistence(defaults: defaults).save(expected)
        let reloaded = try LibraryPersistence(defaults: defaults).load()
        XCTAssertEqual(reloaded.saved, [.film, external])
        XCTAssertEqual(reloaded.watchLater, [.animenz])
        XCTAssertEqual(reloaded.checkpoints[WorkID.jane.rawValue], checkpoint)
        XCTAssertTrue(reloaded.listenLater.isEmpty)
    }

    func testLegacyCollectionsMigrateWithoutDroppingExternalIdentity() throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["pool", "apple:song:123456789"], forKey: "savedWorks")
        defaults.set(["distance"], forKey: "listenLaterWorks")
        defaults.set(["animenz"], forKey: "laterWorks")
        let state = try LibraryPersistence(defaults: defaults).load()
        XCTAssertEqual(state.saved.map(\.rawValue), ["pool", "apple:song:123456789"])
        XCTAssertEqual(state.listenLater, [.distance])
        XCTAssertEqual(state.watchLater, [.animenz])
    }

    func testMissingCatalogEntryCanBeRemovedFromListenLaterWithoutAffectingOtherCollections() throws {
        try withIsolatedLibrary { _, defaults, catalog in
            let missing = try XCTUnwrap(WorkID(rawValue: "apple:song:987654321"))
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            try persistence.save(LibrarySnapshot(saved: [missing], listenLater: [missing], watchLater: [.animenz]))
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertNil(catalog.works[missing], "The library survives a missing catalog cache")
            XCTAssertEqual(restored.listenLater, [missing])

            restored.toggleListenLater(missing)
            XCTAssertTrue(restored.listenLater.isEmpty)
            restored.flushPendingWritesBeforeTermination()
            let saved = try persistence.load()
            XCTAssertTrue(saved.listenLater.isEmpty, "The removal must persist across relaunch")
            XCTAssertEqual(saved.saved, [missing])
            XCTAssertEqual(saved.watchLater, [.animenz])

            restored.toggleListenLater(missing)
            restored.toggleListenLater(.film)
            XCTAssertTrue(restored.listenLater.isEmpty, "Removal remains possible without permitting unknown or non-song additions")
        }
    }

    func testUnreadablePersistenceIsReportedWithoutOverwritingStoredBytes() throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LibraryPersistence(defaults: defaults)
        let corrupted = Data("{unfinished".utf8)
        defaults.set(corrupted, forKey: persistence.key)
        XCTAssertThrowsError(try persistence.load())
        XCTAssertEqual(defaults.data(forKey: persistence.key), corrupted)

        var unsupported = LibrarySnapshot()
        unsupported.version = 99
        let future = try JSONEncoder().encode(unsupported)
        defaults.set(future, forKey: persistence.key)
        XCTAssertThrowsError(try persistence.load())
        XCTAssertEqual(defaults.data(forKey: persistence.key), future)
    }

    func testInvalidRelationImportDoesNotPartiallyPublishNewWorks() throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let importedID = try XCTUnwrap(WorkID(rawValue: "test:new-song"))
        let missingID = try XCTUnwrap(WorkID(rawValue: "test:missing-artist"))
        let work = Work(id: importedID, title: "New recording", creator: "Test artist", kind: "歌曲", art: "", detail: "", url: nil)
        let invalidEdge = RelationEdge(from: importedID, to: missingID, predicate: .performedBy, label: "演唱", inverseLabel: "作品", source: .movie)
        let previousIDs = Set(store.works.keys)
        XCTAssertThrowsError(try store.merge(CatalogSnapshot(works: [work], relations: [invalidEdge])))
        XCTAssertEqual(Set(store.works.keys), previousIDs)
        XCTAssertNil(store.works[importedID])
    }

    func testAppleMusicLinksResolveSelectedSongBeforeAlbumAndPreserveRegion() throws {
        let songInAlbum = try CatalogLink.parse("  https://music.apple.com/jp/album/one-last-kiss/1542953969?i=1542953977&uo=4\n")
        XCTAssertEqual(songInAlbum.id, "1542953977")
        XCTAssertEqual(songInAlbum.country, "jp")
        XCTAssertEqual(try CatalogLink.parse("https://music.apple.com/us/song/1837522108").id, "1837522108")
        XCTAssertEqual(try CatalogLink.parse("https://music.apple.com/jp/album/summers-end/1837521647").id, "1837521647")
        XCTAssertEqual(try CatalogLink.parse("https://itunes.apple.com/US/album/id1837521647").id, "1837521647")
        XCTAssertEqual(try CatalogLink.parse("https://itunes.apple.com/US/album/id1837521647").country, "us")
    }

    func testImportRejectsNonMusicWorkLinksAndUnusableIdentifiers() {
        let invalid = [
            "http://music.apple.com/us/song/1837522108",
            "https://music.apple.com.example.org/us/song/1837522108",
            "https://music.apple.com/us/song/not-a-number",
            "https://music.apple.com/us/artist/someone/1234",
            "https://music.apple.com/us/playlist/something/1234",
            "https://music.apple.com/us/song/00000",
            "https://music.apple.com/us/song/１２３４",
            "https://user:password@music.apple.com/us/song/1837522108",
            "https://music.apple.com/us/song/id12id34",
            "https://music.apple.com/us/album/name/1234?i=not-a-song"
        ]
        for link in invalid {
            XCTAssertThrowsError(try CatalogLink.parse(link), "Accepted unsupported import input: \(link)")
        }
    }

    func testAppleCatalogKeepsSameNamedReleaseVersionsDistinct() throws {
        let response = try materialize("""
        {"results":[
          {"wrapperType":"track","kind":"song","trackId":101,"trackName":"One Last Kiss","trackViewUrl":"https://music.apple.com/jp/song/101","trackTimeMillis":252027,"artistId":201,"artistName":"宇多田ヒカル","collectionId":301,"collectionName":"One Last Kiss","releaseDate":"2021-03-09T08:00:00Z"},
          {"wrapperType":"track","kind":"song","trackId":102,"trackName":"One Last Kiss","trackViewUrl":"https://music.apple.com/jp/song/102","artistId":201,"artistName":"宇多田ヒカル","collectionId":302,"collectionName":"SCIENCE FICTION","releaseDate":"2024-04-10T08:00:00Z"}
        ]}
        """)
        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(Set(response.results).count, 2)
        let tracks = response.snapshot.works.filter { response.results.contains($0.id) }
        XCTAssertEqual(Set(tracks.map(\.title)), ["One Last Kiss"])
        XCTAssertEqual(Set(tracks.compactMap(\.albumID)).count, 2)
        XCTAssertEqual(Set(tracks.flatMap(\.creatorIDs)).count, 1)
        XCTAssertEqual(tracks.first { $0.catalogID == "101" }?.detail, "4:12 · 2021")
        try assertImportable(response)
    }

    func testCompilationAlbumKeepsCollectionArtistRegardlessOfTrackOrder() throws {
        let rows = compilationRows
        for ordering in [[rows[0], rows[1], rows[2]], [rows[1], rows[2], rows[0]]] {
            let response = try materialize("{\"results\":[" + ordering.joined(separator: ",") + "]}")
            let albumID = try XCTUnwrap(WorkID(rawValue: "apple:album:660001"))
            let artistID = try XCTUnwrap(WorkID(rawValue: "apple:artist:660010"))
            let album = try XCTUnwrap(response.snapshot.works.first { $0.id == albumID })
            XCTAssertEqual(album.creator, "Various Artists")
            XCTAssertEqual(album.creatorIDs, [artistID])
            XCTAssertEqual(response.snapshot.relations.first { $0.from == albumID && $0.predicate == .performedBy }?.to, artistID)
            let song = try XCTUnwrap(response.snapshot.works.first { $0.id.rawValue == "apple:song:660102" })
            XCTAssertEqual(song.creator, "Singer B")
            XCTAssertEqual(song.creatorIDs.map(\.rawValue), ["apple:artist:660012"], "Track credits remain the track's own")
            try assertImportable(response)
        }
    }

    func testCollectionLookupRepairsCachedAlbumArtistAndLaterTrackSearchPreservesIt() throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let trackResponse = try materialize("{\"results\":[" + compilationRows[2] + "]}")
        try store.merge(trackResponse.snapshot, persist: false)
        let albumID = try XCTUnwrap(WorkID(rawValue: "apple:album:660001"))
        XCTAssertTrue(store.work(albumID).creator.isEmpty, "A song-only response cannot establish the album artist")
        XCTAssertTrue(store.work(albumID).creatorIDs.isEmpty)

        // Recreate metadata persisted by the earlier last-track-wins behavior.
        let wrong = Work(id: albumID, title: "Compilation", creator: "Singer B", kind: "专辑", art: "", detail: "",
                         url: "https://music.apple.com/jp/album/660001",
                         linkedCreatorIDs: [WorkID(rawValue: "apple:artist:660012")!], catalogID: "660001", storeCountry: "jp")
        try store.merge(CatalogSnapshot(works: [wrong], relations: []), persist: false)
        XCTAssertEqual(store.work(albumID).creator, "Singer B")

        let lookup = try materialize("{\"results\":[" + compilationRows.joined(separator: ",") + "]}")
        try store.merge(lookup.snapshot, persist: false)
        XCTAssertEqual(store.work(albumID).creator, "Various Artists", "Authoritative collection metadata replaces the old incorrect credit")
        XCTAssertEqual(store.work(albumID).creatorIDs.map(\.rawValue), ["apple:artist:660010"])

        try store.merge(trackResponse.snapshot, persist: false)
        XCTAssertEqual(store.work(albumID).creator, "Various Artists", "An inferred album placeholder must not erase verified collection metadata")
        XCTAssertEqual(store.work(albumID).creatorIDs.map(\.rawValue), ["apple:artist:660010"])
        XCTAssertEqual(store.edges.first { $0.from == albumID && $0.predicate == .performedBy }?.to.rawValue, "apple:artist:660010")
    }

    func testPartialCatalogMetadataNeverBuildsDanglingNavigationOrRelations() throws {
        let response = try materialize("""
        {"results":[
          {"wrapperType":"track","kind":"song","trackId":401,"trackName":"Sparse recording","trackViewUrl":"https://music.apple.com/jp/song/401","artistId":501,"collectionId":601},
          {"wrapperType":"artist","artistId":502},
          {"wrapperType":"collection","collectionId":602}
        ]}
        """)
        let works = Dictionary(uniqueKeysWithValues: response.snapshot.works.map { ($0.id, $0) })
        for id in response.results { XCTAssertNotNil(works[id], "A search result must open an actual entity") }
        for work in works.values {
            for id in work.creatorIDs { XCTAssertNotNil(works[id], "A creator ID without a named entity must not be linked") }
            if let id = work.albumID { XCTAssertNotNil(works[id], "An album ID without an identified release must not be linked") }
        }
        try assertImportable(response)
    }

    func testNonMusicCatalogResultsDoNotInventMusicCredits() throws {
        let response = try materialize("""
        {"results":[
          {"wrapperType":"track","kind":"feature-movie","trackId":701,"trackName":"Film","trackViewUrl":"https://itunes.apple.com/jp/movie/id701","artistId":801,"artistName":"A director","collectionId":901,"collectionName":"Movie bundle"},
          {"wrapperType":"track","kind":"ebook","trackId":702,"trackName":"Book","trackViewUrl":"https://books.apple.com/jp/book/id702","artistId":802,"artistName":"An author"}
        ]}
        """)
        let results = response.snapshot.works.filter { response.results.contains($0.id) }
        XCTAssertEqual(Set(results.map(\.kind)), ["电影", "书籍"])
        XCTAssertFalse(response.snapshot.works.contains { $0.isAlbum }, "A movie bundle is not a music album")
        XCTAssertFalse(response.snapshot.works.contains { $0.creator == "音乐人" }, "An API artist field does not prove a music credit")
        XCTAssertFalse(response.snapshot.relations.contains { $0.predicate == .performedBy || $0.predicate == .inAlbum })
        try assertImportable(response)
    }

    func testCatalogCanonicalizationRemapsResultsRelationsAndStoryLinks() throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let songID = try XCTUnwrap(WorkID(rawValue: "apple:song:1837522108"))
        let albumID = try XCTUnwrap(WorkID(rawValue: "apple:album:1837521647"))
        let song = Work(id: songID, title: "API song title", creator: "API artist", kind: "歌曲", art: "https://example.com/art.jpg", detail: "API detail", url: "https://music.apple.com/us/song/1837522108", linkedAlbumID: albumID, linkedCreatorIDs: [.ushio], catalogID: "1837522108", storeCountry: "us")
        let album = Work(id: albumID, title: "API release title", creator: "API artist", kind: "专辑", art: "", detail: "", url: "https://music.apple.com/us/album/1837521647", catalogID: "1837521647", storeCountry: "us")
        let edge = RelationEdge(from: songID, to: albumID, predicate: .inAlbum, label: "收录于", inverseLabel: "收录歌曲", source: .movie)
        let story = EditorialStory(id: "test:canonical-story", workID: songID, title: "A sourced observation", body: "The release", entityLinks: ["The release": albumID], source: .movie)
        try store.merge(CatalogSnapshot(works: [song, album], relations: [edge], stories: [story]), persist: false)
        XCTAssertEqual(store.canonicalID(for: songID), .pool)
        XCTAssertEqual(store.canonicalID(for: albumID), .poolAlbum)
        XCTAssertEqual(store.canonicalIDs([songID, .pool, albumID, .poolAlbum]), [.pool, .poolAlbum])
        XCTAssertEqual(store.works[.pool]?.title, Work.seeds[.pool]?.title)
        XCTAssertEqual(store.works[.pool]?.creator, Work.seeds[.pool]?.creator)
        XCTAssertEqual(store.works[.pool]?.detail, Work.seeds[.pool]?.detail)
        XCTAssertEqual(store.works[.pool]?.albumID, .poolAlbum)
        XCTAssertFalse(store.edges.contains { $0.from == songID || $0.to == albumID })
        XCTAssertEqual(store.stories.first { $0.id == story.id }?.workID, .pool)
        XCTAssertEqual(store.stories.first { $0.id == story.id }?.entityLinks["The release"], .poolAlbum)
    }

    func testCanonicalizationNeverUsesTitleOrCrossesEntityKind() throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        let otherID = try XCTUnwrap(WorkID(rawValue: "apple:song:9990001"))
        let albumID = try XCTUnwrap(WorkID(rawValue: "apple:album:1837522108"))
        let other = Work(id: otherID, title: "in the pool", creator: "牛尾宪辅", kind: "歌曲", art: "", detail: "Another recording", url: "https://music.apple.com/jp/song/9990001", catalogID: "9990001")
        let album = Work(id: albumID, title: "in the pool", creator: "牛尾宪辅", kind: "专辑", art: "", detail: "", url: "https://music.apple.com/jp/album/1837522108", catalogID: "1837522108")
        try store.merge(CatalogSnapshot(works: [other, album], relations: []), persist: false)
        XCTAssertEqual(store.canonicalID(for: otherID), otherID)
        XCTAssertEqual(store.canonicalID(for: albumID), albumID)
        XCTAssertNotNil(store.works[otherID])
        XCTAssertNotNil(store.works[albumID])
    }

    func testDamagedLibraryIsBackedUpBeforeAReplacementSnapshotIsWritten() throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LibraryPersistence(defaults: defaults)
        let broken = Data("{unfinished-library".utf8)
        defaults.set(broken, forKey: persistence.key)
        XCTAssertThrowsError(try persistence.load())
        let replacement = LibrarySnapshot(saved: [.film])
        try persistence.save(replacement)
        XCTAssertEqual(defaults.data(forKey: persistence.backupKey), broken)
        XCTAssertEqual(try persistence.load(), replacement)
    }

    func testLibraryBackupConflictPreservesBothOriginalRecords() throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = LibraryPersistence(defaults: defaults)
        let broken = Data("{current-broken-library".utf8)
        let previous = Data("{previous-broken-library".utf8)
        defaults.set(broken, forKey: persistence.key)
        defaults.set(previous, forKey: persistence.backupKey)
        XCTAssertThrowsError(try persistence.load())
        XCTAssertThrowsError(try persistence.save(LibrarySnapshot(saved: [.film])))
        XCTAssertEqual(defaults.data(forKey: persistence.key), broken)
        XCTAssertEqual(defaults.data(forKey: persistence.backupKey), previous)
    }

    func testDamagedCatalogIsBackedUpBeforeSuccessfulReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let broken = Data("{unfinished-catalog".utf8)
        try broken.write(to: cache)
        let store = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        store.save()
        await store.flushPendingWrites()
        let backup = try XCTUnwrap(store.cacheBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), broken)
        XCTAssertNoThrow(try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: cache)))
        XCTAssertNil(store.storageError)
    }

    func testCatalogBackupConflictKeepsUnreadableCacheAndReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PianwaiTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let broken = Data("{current-broken-catalog".utf8)
        let previous = Data("{previous-broken-catalog".utf8)
        try broken.write(to: cache)
        let existingBackup = cache.appendingPathExtension("unreadable-backup")
        try previous.write(to: existingBackup)
        let store = CatalogStore(cacheURL: cache, bundle: Bundle(for: Self.self))
        let backup = try XCTUnwrap(store.cacheBackupURL)
        // A conflicting backup must never be silently replaced by the next save.
        XCTAssertEqual(backup, existingBackup)
        store.save()
        await store.flushPendingWrites()
        XCTAssertEqual(try Data(contentsOf: cache), broken)
        XCTAssertEqual(try Data(contentsOf: backup), previous)
        XCTAssertNotNil(store.storageError)
    }

    func testRealLaunchAndAuthorizedIdleNeverInventACurrentTrack() throws {
        try withIsolatedLibrary { library, _, _ in
            XCTAssertFalse(library.demoMode)
            XCTAssertNil(library.currentTrack)
            XCTAssertFalse(library.isPlaying)
            XCTAssertFalse(library.canControlPlayback)
            XCTAssertFalse(library.canQueueNext)
            library.receivePlayback(playbackSnapshot(track: nil, status: .stopped))
            XCTAssertNil(library.currentTrack)
            XCTAssertTrue(library.canPlayCatalog, "An authorized subscriber may choose play now while idle")
            XCTAssertFalse(library.canControlPlayback)
            XCTAssertFalse(library.canQueueNext, "Next requires a confirmed current track")
        }
    }

    func testInjectedReviewArgumentsDoNotReadOrModifyRealLibrary() throws {
        try withIsolatedLibrary { _, defaults, catalog in
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            try persistence.save(LibrarySnapshot(saved: [.distance], listenLater: [.jane]))
            defaults.set(1, forKey: "appearance")
            let original = defaults.data(forKey: persistence.key)
            let review = Library(defaults: defaults, arguments: ["--scene=film", "--experience=idle", "--visual=atlas"], catalog: catalog)
            XCTAssertTrue(review.demoMode)
            XCTAssertEqual(review.initialExperience, .idle)
            XCTAssertEqual(review.path, [.work(.film)])
            XCTAssertEqual(review.reading, .film)
            XCTAssertEqual(review.visualDirection, .atlas)
            XCTAssertTrue(review.saved.isEmpty, "Review fixtures must not load real saves")
            XCTAssertNil(review.currentTrack)
            review.appearance = 2
            review.toggleSaved(.pool)
            XCTAssertEqual(defaults.integer(forKey: "appearance"), 1)
            review.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
        }
    }

    func testAppearancePreferenceUsesOnlyInjectedDefaults() throws {
        let standardBefore = UserDefaults.standard.object(forKey: "appearance") as? Int
        try withIsolatedLibrary { library, defaults, _ in
            library.appearance = 2
            XCTAssertEqual(defaults.integer(forKey: "appearance"), 2)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "appearance") as? Int, standardBefore)
        }
    }

    func testDeepReadingAndBothNavigationStacksSurviveRelaunch() throws {
        try withIsolatedLibrary { library, defaults, catalog in
            library.explore(.pool)
            library.open(.film)
            library.path.append(.connections(.film))
            library.open(.manga)
            library.saveReading(.manga, offset: 329.25)
            library.tab = .collection
            library.open(.distance)
            library.saveReading(.distance, offset: 114)
            library.tab = .now
            library.persist()
            library.flushPendingWritesBeforeTermination()
            let reloaded = Library(defaults: defaults, arguments: [], catalog: catalog)
            XCTAssertEqual(reloaded.focus, .pool)
            XCTAssertEqual(reloaded.reading, .manga, "Restore the deep reading target, not only the entry point")
            XCTAssertEqual(reloaded.path, [.work(.film), .connections(.film), .work(.manga)])
            XCTAssertEqual(reloaded.collectionPath, [.work(.distance)])
            XCTAssertEqual(reloaded.tab, .now)
            XCTAssertEqual(reloaded.checkpoints[WorkID.manga.rawValue]?.offset, 329.25)
            XCTAssertEqual(reloaded.checkpoints[WorkID.distance.rawValue]?.offset, 114)
            XCTAssertNil(reloaded.currentTrack, "A persisted reading session is not persisted playback truth")
        }
    }

    func testPlaybackUpdatePreservesReadingAndNavigationUntilUserFollows() throws {
        try withIsolatedLibrary { library, _, _ in
            library.explore(.film)
            library.open(.manga)
            library.saveReading(.manga, offset: 200)
            let beforePath = library.path
            let track = MusicNowPlayingMetadata(id: "local:second-track", catalogID: nil, title: "Another song", artist: "Another artist", albumTitle: nil, artworkURL: nil, duration: 100, source: .mediaPlayer)
            library.receivePlayback(playbackSnapshot(track: track))
            XCTAssertEqual(library.reading, .manga)
            XCTAssertEqual(library.path, beforePath)
            XCTAssertEqual(library.checkpoints[WorkID.manga.rawValue]?.offset, 200)
            XCTAssertTrue(library.showNewTrack)
            let current = try XCTUnwrap(library.currentTrack)
            library.followPlayback()
            XCTAssertEqual(library.focus, current)
            XCTAssertTrue(library.path.isEmpty)
            XCTAssertFalse(library.showNewTrack)
        }
    }

    func testLongLocalMetadataIdentityIsStableWithoutCrashingOrGuessingCatalog() throws {
        try withIsolatedLibrary { library, _, catalog in
            let raw = String(repeating: "長いローカル識別子/", count: 100)
            let track = MusicNowPlayingMetadata(id: raw, catalogID: nil, title: "A local file", artist: "Unknown artist", albumTitle: nil, artworkURL: nil, duration: nil, source: .mediaPlayer)
            library.receivePlayback(playbackSnapshot(track: track))
            let first = try XCTUnwrap(library.currentTrack)
            XCTAssertLessThanOrEqual(first.rawValue.count, 240)
            XCTAssertFalse(first.rawValue.hasPrefix("apple:"))
            XCTAssertEqual(catalog.works[first]?.title, "A local file")
            library.receivePlayback(playbackSnapshot(track: track))
            XCTAssertEqual(library.currentTrack, first)
            XCTAssertNotEqual(WorkID.localPlaybackID(raw + "different"), first)
        }
    }

    func testPlaybackCatalogIdentityNeverResolvesToAnAlbumWithTheSameNumber() throws {
        try withIsolatedLibrary { library, _, _ in
            let original = MusicNowPlayingMetadata(id: "system-song", catalogID: "1837522108", title: "in the pool", artist: "牛尾宪辅", albumTitle: nil, artworkURL: nil, duration: nil, source: .musicKit)
            library.receivePlayback(playbackSnapshot(track: original))
            XCTAssertEqual(library.currentTrack, .pool)
            let sameNumberAsAlbum = MusicNowPlayingMetadata(id: "different-system-song", catalogID: "1837521647", title: "Separate recording", artist: "Artist", albumTitle: nil, artworkURL: nil, duration: nil, source: .musicKit)
            library.receivePlayback(playbackSnapshot(track: sameNumberAsAlbum))
            XCTAssertEqual(library.currentTrack?.rawValue, "apple:song:1837521647")
            XCTAssertNotEqual(library.currentTrack, .poolAlbum)
        }
    }

    private func withIsolatedLibrary(_ body: (Library, UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineCatalogURLProtocol.self]
        let catalog = CatalogStore(cacheURL: nil, service: AppleCatalogService(session: URLSession(configuration: configuration)), bundle: Bundle(for: Self.self))
        try body(Library(defaults: defaults, arguments: [], catalog: catalog), defaults, catalog)
    }

    private func playbackSnapshot(track: MusicNowPlayingMetadata?, status: MusicPlaybackStatus = .playing) -> MusicPlaybackSnapshot {
        MusicPlaybackSnapshot(availability: .ready, authorization: .authorized,
                              subscription: .available(.init(canPlayCatalogContent: true, canBecomeSubscriber: false, hasCloudLibraryEnabled: true)),
                              nowPlaying: track, status: status, elapsedTime: 10, capturedAt: Date())
    }

    private func materialize(_ json: String) throws -> CatalogResponse {
        try JSONDecoder().decode(AppleCatalogPayload.self, from: Data(json.utf8)).materialize(country: "jp")
    }

    private var compilationRows: [String] {
        [
            """
            {"wrapperType":"collection","collectionId":660001,"collectionName":"Compilation","collectionViewUrl":"https://music.apple.com/jp/album/660001","artistId":660010,"artistName":"Various Artists"}
            """,
            """
            {"wrapperType":"track","kind":"song","trackId":660101,"trackName":"First song","trackViewUrl":"https://music.apple.com/jp/song/660101","collectionId":660001,"collectionName":"Compilation","artistId":660011,"artistName":"Singer A"}
            """,
            """
            {"wrapperType":"track","kind":"song","trackId":660102,"trackName":"Last song","trackViewUrl":"https://music.apple.com/jp/song/660102","collectionId":660001,"collectionName":"Compilation","artistId":660012,"artistName":"Singer B"}
            """
        ]
    }

    private func assertImportable(_ response: CatalogResponse, file: StaticString = #filePath, line: UInt = #line) throws {
        let store = CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self))
        XCTAssertNoThrow(try store.merge(response.snapshot, persist: false), "Materialized API data must pass catalog validation", file: file, line: line)
    }
}

/// Reducer tests must not send enrichment requests to a real service.
private final class OfflineCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
