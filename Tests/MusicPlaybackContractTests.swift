import XCTest
@testable import Pianwai

/// These contracts never connect an account or mutate a device's Music queue.
/// Reducer inputs are explicit observations; simulator-only adapter checks must
/// remain skipped on device test destinations.
@MainActor
final class MusicPlaybackContractTests: XCTestCase {
    func testAnonymousMediaBridgeTracksCannotCollapseIntoOneLocalRecording() async throws {
        try await withLibrary { library, _ in
            let a = MusicNowPlayingMetadata(id: "media:0:local", catalogID: nil, title: "First local recording", artist: "Orchestra",
                albumTitle: "Concert A", artworkURL: nil, duration: 180, source: .mediaPlayer)
            let b = MusicNowPlayingMetadata(id: "media:0:local", catalogID: nil, title: "Second local recording", artist: "Orchestra",
                albumTitle: "Concert B", artworkURL: nil, duration: 220, source: .mediaPlayer)
            library.receivePlayback(snapshot(track: a)); let first = try XCTUnwrap(library.currentTrack)
            library.receivePlayback(snapshot(track: b)); let second = try XCTUnwrap(library.currentTrack)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(library.catalog.work(first).title, a.title)
            XCTAssertEqual(library.catalog.work(second).title, b.title)
        }
    }
    func testObservedCoverWorksWithoutAnyCatalogIDAndKeepsItsAlbumContext() async throws {
        try await withLibrary { library, _ in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            }
            let key = try XCTUnwrap(ObservedArtwork.remember(identity: "test-observed-" + UUID().uuidString) { image })
            let metadata = MusicNowPlayingMetadata(id: "system-library-occurrence", catalogID: nil,
                title: "Observed orchestral recording", artist: "Actual orchestra", albumTitle: "Specific concert release",
                artworkURL: nil, duration: 293, source: .mediaPlayer, artworkAsset: key)
            library.receivePlayback(snapshot(track: metadata))
            let id = try XCTUnwrap(library.currentTrack)
            XCTAssertNil(library.catalog.work(id).catalogRecordingID, "An image is not evidence for a guessed recording ID")
            XCTAssertEqual(library.catalog.work(id).art, key)
            XCTAssertEqual(SeedLibraryBridge.playbackEntity(in: library)?.artworkAsset, key)
            XCTAssertNotNil(ObservedArtwork.image(key))
            XCTAssertEqual(LeadResearch().subject(id.rawValue, library: library)?.album, metadata.albumTitle)
        }
    }
    func testCurrentHeaderAndPlayerKeepObservedAppleMusicNamesAfterRegionalMetadataArrives() async throws {
        try await withLibrary { library, _ in
            let metadata = MusicNowPlayingMetadata(id: "observed-anata", catalogID: "1987654321", title: "あなた", artist: "宇多田光",
                albumTitle: nil, artworkURL: URL(string: "https://example.com/observed-cover.jpg"), duration: 180, source: .mediaPlayer)
            library.receivePlayback(snapshot(track: metadata))
            let id = try XCTUnwrap(library.currentTrack)
            let regional = Work(id: id, title: "Anata", creator: "Hikaru Utada", kind: "歌曲", art: "https://example.com/regional.jpg",
                detail: "", url: "https://music.apple.com/jp/song/1987654321", catalogID: "1987654321")
            try library.catalog.merge(.init(works: [regional], relations: []))
            let shown = try XCTUnwrap(SeedLibraryBridge.playbackEntity(in: library))
            XCTAssertEqual(shown.title, metadata.title); XCTAssertEqual(shown.subtitle, metadata.artist)
            XCTAssertEqual(shown.artworkAsset, metadata.artworkURL?.absoluteString)
        }
    }
    func testMusicLinkPlayUsesExactRecordingAndPreservesReading() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "before")))
        try await withLibrary(client: client) { library, _ in
            let before = library.reading
            let played = await library.playLinkedMusic(.jane)
            XCTAssertTrue(played)
            XCTAssertEqual(client.calls.count, 1)
            XCTAssertEqual(client.calls.first?.command, .playNow)
            XCTAssertEqual(client.calls.first?.catalogID, library.catalog.work(.jane).catalogRecordingID)
            XCTAssertEqual(library.reading, before)
        }
    }

    func testMusicLinkPlayFailureAllowsExactURLFallbackWithoutRetry() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "before")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            let pending = Task { await library.playLinkedMusic(.jane) }
            await waitUntil { !client.calls.isEmpty }
            client.complete(.failure(.init(.notPlayable, "Unavailable")))
            let played = await pending.value
            XCTAssertFalse(played)
            XCTAssertEqual(client.calls.count, 1)
            XCTAssertNotNil(library.catalog.work(.jane).appleMusicURL)
            XCTAssertEqual(library.playbackOperations.first?.outcome, .failed)
        }
    }
    func testAvailableEditorialMetadataIsKeptWithoutStartingUnverifiedLegacyCollection() async throws {
        try await withLibrary { library, _ in
            let notes = StoryMaterial.appleEditorial(text: "<p>DIVER was released by sis.</p>",
                url: URL(string: "https://music.apple.com/jp/song/6803304739"), title: "DIVER", location: "song.editorialNotes")
            let metadata = MusicNowPlayingMetadata(id: "source-metadata", catalogID: "6803304739", title: "DIVER", artist: "sis",
                albumTitle: nil, artworkURL: nil, duration: 180, source: .musicKit, releaseDate: "2026-09-09", editorialNotes: notes)
            library.receivePlayback(snapshot(track: metadata))
            let id = try XCTUnwrap(library.currentTrack)
            let stored = library.catalog.work(id)
            XCTAssertEqual(stored.releaseDate, "2026-09-09"); XCTAssertEqual(stored.editorialNotes, notes)
            XCTAssertEqual(library.currentPlaybackMetadata?.editorialNotes, notes)
            // E06 intentionally keeps a playback-only ID out of the retired
            // collector until an exact catalog identity has been resolved.
            XCTAssertNil(stored.catalogTrack)
        }
    }
    /// A single stateless offline transport lives for the test process. Playback
    /// observations schedule enrichment tasks that may start after a test body
    /// returns, so a per-test invalidation would race those producers. Each test
    /// still owns fresh service actors, catalog state and UserDefaults; this
    /// shared transport has no responses, cookies, credentials or cache to leak.
    private static let offlineSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetworkMusicContractURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    func testOpaqueMusicKitArtworkCannotOverwriteAResolvedCatalogCover() async throws {
        try await withLibrary { library, _ in
            let id = WorkID(rawValue: "apple:song:1857886409")!
            let cover = "https://is1-ssl.mzstatic.com/image/thumb/Music211/cover.jpg/800x800bb.jpg"
            let work = Work(id: id, title: "Actor", creator: "幾田りら", kind: "歌曲", art: cover,
                            detail: "Laugh", url: "https://music.apple.com/jp/song/1857886409", catalogID: "1857886409")
            try library.catalog.merge(CatalogSnapshot(works: [work], relations: []))
            let metadata = MusicNowPlayingMetadata(id: "actor-occurrence", catalogID: "1857886409",
                title: "Actor", artist: "幾田りら", albumTitle: "Laugh",
                artworkURL: URL(string: "musicKit://artwork/library/TEST-FIXTURE/800x800?aat=Music211%2Fcover.jpg"),
                duration: 229, source: .musicKit)
            library.receivePlayback(snapshot(track: metadata))
            library.receivePlayback(snapshot(track: metadata, elapsed: 12))
            XCTAssertEqual(library.catalog.work(id).art, cover)
            XCTAssertEqual(library.currentTrack, id)
        }
    }

    func testQueueReceiptIsConsumedWhenSameSongStartsAnotherOccurrence() async throws {
        try await withLibrary { library, _ in
            library.receivePlayback(snapshot(track: song(entry: "first-occurrence")))
            library.next = .pool // Receipt for queuing this same song again.
            library.receivePlayback(snapshot(track: song(entry: "first-occurrence"), elapsed: 25))
            XCTAssertEqual(library.next, .pool, "The already-playing occurrence has not consumed the insertion")

            library.receivePlayback(snapshot(track: song(entry: "second-occurrence"), elapsed: 0))
            XCTAssertEqual(library.currentTrack, .pool)
            XCTAssertNil(library.next, "The queued occurrence is now playing even though its WorkID did not change")
        }
    }

    func testQueueReceiptSurvivesMetadataMaterializationAndWaitsForANewOccurrence() async throws {
        try await withLibrary { library, _ in
            library.receivePlayback(snapshot(track: unresolvedSong(entry: "original-occurrence")))
            let originalReading = try XCTUnwrap(library.currentTrack)
            library.explore(originalReading)
            library.next = .pool

            library.receivePlayback(snapshot(track: song(entry: "original-occurrence")))
            XCTAssertEqual(library.currentTrack, .pool)
            XCTAssertEqual(library.next, .pool, "Resolving the current song is not consumption of its queued repeat")
            XCTAssertEqual(library.reading, originalReading)
            XCTAssertFalse(library.showNewTrack, "The same queue occurrence did not start a new song")

            // The next occurrence may appear before its catalog metadata does.
            library.receivePlayback(snapshot(track: unresolvedSong(entry: "queued-occurrence")))
            XCTAssertEqual(library.next, .pool, "An unidentified new entry does not prove which song started")
            library.receivePlayback(snapshot(track: song(entry: "queued-occurrence")))
            XCTAssertNil(library.next, "The receipt retains its original occurrence across intermediate metadata")
        }
    }

    func testQueueReceiptIsNotConsumedByCatalogIdentityWithoutAnObservedOccurrence() async throws {
        try await withLibrary { library, _ in
            library.receivePlayback(snapshot(track: song(entry: "current-occurrence")))
            library.next = .jane
            let target = MusicNowPlayingMetadata(id: "bridge-jane", catalogID: "1840081736", title: "JANE DOE",
                                                  artist: "米津玄师", albumTitle: nil, artworkURL: nil,
                                                  duration: nil, source: .mediaPlayer)
            var observation = snapshot(track: target)
            observation.currentEntryID = nil
            library.receivePlayback(observation)
            XCTAssertEqual(library.next, .jane, "Metadata alone cannot prove that the queued occurrence began")
            observation.currentEntryID = "queued-occurrence"
            library.receivePlayback(observation)
            XCTAssertNil(library.next, "A later exact occurrence confirms the retained receipt")
        }
    }

    func testAuthorizationRevocationRemovesTransportWithoutChangingReadingOrSaves() async throws {
        try await withLibrary { library, _ in
            library.explore(.film)
            library.open(.manga)
            library.toggleSaved(.jane)
            library.toggleListenLater(.distance)
            library.receivePlayback(snapshot(track: song(entry: "active")))
            library.playerPresented = true
            library.next = .jane
            let path = library.path

            library.receivePlayback(.init(availability: .authorizationDenied, authorization: .denied,
                                          subscription: .unknown, nowPlaying: nil, status: .stopped,
                                          elapsedTime: 0, capturedAt: Date()))

            XCTAssertNil(library.currentTrack)
            XCTAssertFalse(library.canControlPlayback)
            XCTAssertFalse(library.canPlayCatalog)
            XCTAssertFalse(library.canQueueNext)
            XCTAssertFalse(library.isPlaying)
            XCTAssertFalse(library.playerPresented)
            XCTAssertFalse(library.showNewTrack)
            XCTAssertNil(library.next)
            XCTAssertEqual(library.path, path)
            XCTAssertEqual(library.reading, .manga)
            XCTAssertEqual(library.saved, [.jane])
            XCTAssertEqual(library.listenLater, [.distance])
        }
    }

    func testAnExistingLocalTrackRemainsControllableWithoutCatalogSubscription() async throws {
        try await withLibrary { library, _ in
            let local = MusicNowPlayingMetadata(id: "local-recording", catalogID: nil,
                                               title: "A local recording", artist: "Local artist",
                                               albumTitle: nil, artworkURL: nil, duration: 90, source: .mediaPlayer)
            library.receivePlayback(snapshot(track: local, subscribed: false, status: .paused))
            XCTAssertNotNil(library.currentTrack)
            XCTAssertTrue(library.canControlPlayback, "An existing local recording can still be resumed")
            XCTAssertFalse(library.isPlaying)
            XCTAssertFalse(library.canPlayCatalog)
            XCTAssertFalse(library.canQueueNext, "Existing playback alone does not grant catalog insertion")
        }
    }

    func testMissingMetadataWhilePlayingKeepsReadingAndReceiptWithoutInventingAStopOrQueueMutation() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "same-occurrence")))
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.explore(.film)
            library.open(.manga)
            library.next = .jane
            let path = library.path
            client.emit(snapshot(track: nil, status: .playing))

            XCTAssertTrue(library.isPlaying)
            XCTAssertTrue(library.isPlaybackUnidentified)
            XCTAssertNil(library.currentTrack)
            XCTAssertNil(library.currentEntryID)
            XCTAssertFalse(library.canControlPlayback)
            XCTAssertFalse(library.canQueueNext)
            XCTAssertEqual(library.next, .jane)
            XCTAssertEqual(library.reading, .manga)
            XCTAssertEqual(library.path, path)
            library.togglePlayback()
            library.skip()
            XCTAssertTrue(client.calls.isEmpty)

            client.emit(snapshot(track: song(entry: "same-occurrence")))
            XCTAssertFalse(library.isPlaybackUnidentified)
            XCTAssertFalse(library.showNewTrack, "Restored metadata for the old occurrence is not a new song")
            XCTAssertTrue(library.canControlPlayback)
            XCTAssertEqual(library.next, .jane)
            XCTAssertEqual(library.path, path)
            XCTAssertEqual(library.reading, .manga)
        }
    }

    func testUnidentifiedPausedAndInterruptedStatesDoNotBecomeStoppedAndSearchingDoesNotIdentifyTheAudio() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: nil, status: .paused))
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            for status in [MusicPlaybackStatus.paused, .interrupted, .seekingForward, .seekingBackward] {
                client.emit(snapshot(track: nil, status: status))
                XCTAssertTrue(library.isPlaybackUnidentified)
                XCTAssertFalse(library.isPlaying)
                XCTAssertFalse(library.canControlPlayback)
            }
            library.openSearchResult(.film)
            XCTAssertEqual(library.reading, .film)
            XCTAssertNil(library.currentTrack, "Selecting a work is not a playback identification")
            XCTAssertTrue(library.isPlaybackUnidentified)
            XCTAssertTrue(client.calls.isEmpty)
        }
    }

    func testConfirmedStopAndRevokedAuthorizationClearUnidentifiedStatusButKeepReading() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: nil))
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.explore(.film)
            library.next = .jane
            client.emit(snapshot(track: nil, status: .stopped))
            XCTAssertFalse(library.isPlaybackUnidentified)
            XCTAssertFalse(library.isPlaying)
            XCTAssertNil(library.next)
            XCTAssertEqual(library.reading, .film)

            client.emit(snapshot(track: nil))
            XCTAssertTrue(library.isPlaybackUnidentified)
            client.emit(.init(availability: .authorizationDenied, authorization: .denied,
                              subscription: .unknown, nowPlaying: nil, status: .playing,
                              elapsedTime: 0, capturedAt: Date()))
            XCTAssertFalse(library.isPlaybackUnidentified, "Revoked access cannot claim a current playback observation")
            XCTAssertFalse(library.isPlaying)
            XCTAssertEqual(library.reading, .film)
            XCTAssertTrue(client.calls.isEmpty)
        }
    }

    func testAllSimulatorCommandsRejectWithoutOptimisticPlaybackOrPendingState() async throws {
        #if targetEnvironment(simulator)
        let service = MusicPlaybackService()
        let original = service.snapshot
        let results = [
            await service.requestAuthorization(),
            await service.pause(),
            await service.resume(),
            await service.skipToNext(),
            await service.insertNext(catalogID: "1837522108"),
            await service.playNow(catalogID: "1837522108")
        ]
        for result in results {
            guard case let .failure(error) = result else {
                XCTFail("A simulator must never report an accepted real Music command")
                continue
            }
            XCTAssertEqual(error.code, .simulatorUnsupported)
        }
        XCTAssertEqual(service.snapshot.availability, .simulatorUnsupported)
        XCTAssertEqual(service.snapshot.nowPlaying, original.nowPlaying)
        XCTAssertEqual(service.snapshot.status, original.status)
        XCTAssertNil(service.commandInFlight)
        #else
        throw XCTSkip("Never run playback commands against a physical device or account in this suite")
        #endif
    }

    func testMetadataWithoutAQueueAnchorDoesNotOfferPlayNext() async throws {
        try await withLibrary { library, _ in
            var state = snapshot(track: song(entry: "bridge-metadata"))
            state.currentEntryID = nil
            library.receivePlayback(state)
            XCTAssertTrue(library.canControlPlayback)
            XCTAssertTrue(library.canPlayCatalog, "An authorized subscriber may explicitly start a song")
            XCTAssertFalse(state.canQueueNext)
            XCTAssertFalse(library.canQueueNext, "Play Next requires the actual MusicKit queue anchor")
        }
    }

    func testPlayNowRequiresTheNewOccurrenceEvenWhenCatalogSongAlreadyMatches() {
        let unchanged = snapshot(track: song(entry: "old-occurrence"))
        XCTAssertFalse(MusicPlaybackConfirmation.isPlaying(entryID: "inserted-occurrence", in: unchanged))
        let started = snapshot(track: song(entry: "inserted-occurrence"))
        XCTAssertTrue(MusicPlaybackConfirmation.isPlaying(entryID: "inserted-occurrence", in: started))
        let paused = snapshot(track: song(entry: "inserted-occurrence"), status: .paused)
        XCTAssertFalse(MusicPlaybackConfirmation.isPlaying(entryID: "inserted-occurrence", in: paused))
    }

    func testMetadataMaterializationDoesNotCountAsSkippingToAnotherOccurrence() {
        var bridge = snapshot(track: .init(id: "media:123:1837522108", catalogID: "1837522108",
                                          title: "in the pool", artist: "牛尾宪辅", albumTitle: nil,
                                          artworkURL: nil, duration: nil, source: .mediaPlayer))
        bridge.currentEntryID = "same-queue-entry"
        var materialized = snapshot(track: song(entry: "same-queue-entry"))
        XCTAssertFalse(MusicPlaybackConfirmation.didAdvance(from: bridge, to: materialized))
        bridge.currentEntryID = nil
        materialized.currentEntryID = nil
        XCTAssertFalse(MusicPlaybackConfirmation.didAdvance(from: bridge, to: materialized),
                       "Switching metadata sources is not evidence of a skip")
    }

    func testMusicVideoRetainsItsCatalogTypeInsteadOfAcquiringSongStories() async throws {
        try await withLibrary { library, catalog in
            var video = song(entry: "video-occurrence")
            video.kind = .musicVideo
            library.receivePlayback(snapshot(track: video))
            let id = try XCTUnwrap(library.currentTrack)
            XCTAssertEqual(id.rawValue, "apple:music-video:1837522108")
            XCTAssertNotEqual(id, .pool)
            XCTAssertEqual(catalog.work(id).kind, "演奏视频")
            XCTAssertFalse(catalog.work(id).isSong)
        }
    }

    func testPendingInsertionPreservesPausedPlaybackAndReadingAndRejectsDoubleTap() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current"), status: .paused))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.explore(.film)
            library.open(.manga)
            let path = library.path
            library.queueNext(.jane)
            library.queueNext(.distance)
            await waitUntil { client.calls.count == 1 }
            XCTAssertEqual(client.calls.map(\.command), [.insertNext])
            XCTAssertEqual(client.calls.first?.catalogID, "1840081736")
            XCTAssertEqual(library.pendingSong, .jane)
            XCTAssertTrue(library.playbackBusy)
            XCTAssertEqual(library.currentTrack, .pool)
            XCTAssertFalse(library.isPlaying)
            XCTAssertNil(library.next, "Pending is not accepted")
            library.toggleListenLater(.distance)
            library.toggleSaved(.manga)

            client.complete(.success(.init(command: .insertNext, catalogID: "1840081736", verification: .acceptedBySystem)))
            await waitUntil { !library.playbackBusy }
            XCTAssertEqual(library.next, .jane)
            XCTAssertFalse(library.isPlaying, "Queue insertion must not resume a paused song")
            XCTAssertEqual(library.currentTrack, .pool)
            XCTAssertEqual(library.reading, .manga)
            XCTAssertEqual(library.path, path)
            XCTAssertEqual(library.listenLater, [.distance])
            XCTAssertEqual(library.saved, [.manga])
            XCTAssertEqual(client.calls.count, 1, "No playNow/resume or automatic retry may follow insertion")
        }
    }

    func testUncertainInsertionSurvivesMetadataSourceChangesAndBlocksOnlyItsExactRetry() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.songSheet = .pool
            library.queueNext(.pool)
            await waitUntil { client.calls.count == 1 }
            client.complete(uncertain(.insertNext, catalogID: "1837522108"))
            await waitUntil { !library.playbackBusy }
            XCTAssertTrue(library.isPlaybackUncertain(for: .pool, command: .insertNext))
            XCTAssertNil(library.next)

            var changedSource = snapshot(track: .init(id: "media:123:1837522108", catalogID: "1837522108",
                                                     title: "in the pool", artist: "牛尾宪辅", albumTitle: nil,
                                                     artworkURL: nil, duration: nil, source: .mediaPlayer))
            changedSource.currentEntryID = "current"
            client.emit(changedSource)
            XCTAssertTrue(library.isPlaybackUncertain(for: .pool, command: .insertNext),
                          "A new metadata ID must not unlock an ambiguous duplicate insertion")
            library.clearPlaybackFeedback()
            library.queueNext(.pool)
            XCTAssertEqual(client.calls.count, 1)
            library.songSheet = .jane
            XCTAssertNil(library.playbackError)
            XCTAssertFalse(library.isPlaybackUncertain(for: .jane, command: .insertNext))
            library.queueNext(.jane)
            await waitUntil { client.calls.count == 2 }
            client.complete(.failure(.init(.catalogUnavailable, "Unavailable in this storefront")))
            await waitUntil { !library.playbackBusy }
            XCTAssertTrue(library.isPlaybackUncertain(for: .pool, command: .insertNext))

            client.emit(snapshot(track: song(entry: "next-occurrence")))
            XCTAssertFalse(library.isPlaybackUncertain(for: .pool, command: .insertNext),
                           "A verified new queue occurrence of that song can resolve the ambiguity")
        }
    }

    func testUnavailableFeedbackDistinguishesAlreadySavedSongs() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.queueNext(.pool)
            await waitUntil { client.calls.count == 1 }
            client.complete(.failure(.init(.catalogUnavailable, "fixture failure")))
            await waitUntil { !library.playbackBusy }
            XCTAssertEqual(library.playbackError, "这首歌暂时无法播放。可以先收藏。")
            library.toggleSaved(.pool)
            library.queueNext(.pool)
            await waitUntil { client.calls.count == 2 }
            client.complete(.failure(.init(.catalogUnavailable, "fixture failure")))
            await waitUntil { !library.playbackBusy }
            XCTAssertEqual(library.playbackError, "这首歌暂时无法播放。")
        }
    }

    func testLateFailureIsNotShownOnAnotherSongsOpenSheet() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.songSheet = .jane
            library.queueNext(.jane)
            await waitUntil { client.calls.count == 1 }
            library.songSheet = .distance
            client.complete(.failure(.init(.catalogUnavailable, "JANE DOE unavailable")))
            await waitUntil { !library.playbackBusy }
            XCTAssertEqual(library.songSheet, .distance)
            XCTAssertNil(library.playbackError, "A completed request belongs to its original song")
            XCTAssertNil(library.pendingSong)
            XCTAssertNil(library.next)
        }
    }

    func testTransportUncertaintyAcknowledgementDoesNotAutomaticallySkipAgain() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            library.skip()
            await waitUntil { client.calls.count == 1 }
            client.complete(uncertain(.skipToNext))
            await waitUntil { !library.playbackBusy }
            XCTAssertTrue(library.isPlaybackUncertain(for: nil, command: .skipToNext))
            library.clearPlaybackFeedback()
            library.skip()
            XCTAssertEqual(client.calls.count, 1)
            library.acknowledgePlaybackCheck(for: nil, command: .skipToNext)
            XCTAssertFalse(library.isPlaybackUncertain(for: nil, command: .skipToNext))
            XCTAssertEqual(client.calls.count, 1, "Acknowledgement only clears the guard; it never retries")
        }
    }

    func testGlobalAcknowledgementUsesTheDisplayedOperationAfterPlaybackChanges() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "current")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, _ in
            library.startServices()
            // Hero actions have no song sheet. Keep two different unresolved operations.
            library.queueNext(.jane)
            await waitUntil { client.calls.count == 1 }
            client.complete(uncertain(.insertNext, catalogID: "1840081736"))
            await waitUntil { !library.playbackBusy }
            library.clearPlaybackFeedback()
            library.queueNext(.pool)
            await waitUntil { client.calls.count == 2 }
            client.complete(uncertain(.insertNext, catalogID: "1837522108"))
            await waitUntil { !library.playbackBusy }
            let other = MusicNowPlayingMetadata(id: "external-change", catalogID: "1444855975", title: "FINAL DISTANCE",
                                               artist: "宇多田光", albumTitle: nil, artworkURL: nil, duration: nil, source: .musicKit)
            client.emit(snapshot(track: other))
            XCTAssertEqual(library.currentTrack, .distance)
            XCTAssertTrue(library.playbackUncertain)
            // SwiftUI may clear the alert binding before executing its button action.
            library.playbackError = nil
            library.acknowledgeDisplayedPlaybackCheck()
            XCTAssertFalse(library.isPlaybackUncertain(for: .pool, command: .insertNext))
            XCTAssertTrue(library.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertEqual(client.calls.count, 2, "Reviewing a result must not perform a new queue mutation")
        }
    }

    func testCompletedOperationsPersistExactTimesAndTargetsWithoutRestoringPlayback() async throws {
        for verification: MusicPlaybackReceipt.Verification in [.acceptedBySystem, .observed] {
            let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "history-origin")))
            client.holdCommands = true
            try await withLibrary(client: client) { library, catalog, defaults in
                library.startServices()
                library.explore(.film)
                let command: MusicPlaybackCommand = verification == .acceptedBySystem ? .insertNext : .playNow
                let beforeIssue = Date()
                if command == .insertNext { library.queueNext(.jane) }
                else { library.startNow(.jane) }
                let afterIssue = Date()
                await waitUntil { client.calls.count == 1 }
                XCTAssertTrue(library.playbackOperations.isEmpty, "Pending is not a completed historical operation")
                var observedAt: Date?
                if verification == .observed {
                    let track = MusicNowPlayingMetadata(id: "history-new-entry", catalogID: "1840081736", title: "JANE DOE",
                        artist: "米津玄师", albumTitle: nil, artworkURL: nil, duration: nil, source: .musicKit)
                    let observation = snapshot(track: track)
                    observedAt = observation.capturedAt
                    client.emit(observation)
                }
                let completedAt = Date()
                client.complete(.success(.init(command: command, catalogID: "1840081736", verification: verification,
                                               completedAt: completedAt, observedAt: observedAt)))
                await waitUntil { !library.playbackBusy }
                let record = try XCTUnwrap(library.playbackOperations.first)
                XCTAssertEqual(library.playbackOperations.count, 1)
                XCTAssertEqual(record.command, command)
                XCTAssertEqual(record.targetWorkID, .jane)
                XCTAssertEqual(record.catalogID, "1840081736")
                XCTAssertEqual(record.outcome, .succeeded)
                XCTAssertEqual(record.verification, verification)
                XCTAssertEqual(record.completedAt, completedAt)
                XCTAssertEqual(record.observedAt, observedAt)
                let issuedAt = try XCTUnwrap(record.issuedAt)
                XCTAssertGreaterThanOrEqual(issuedAt, beforeIssue)
                XCTAssertLessThanOrEqual(issuedAt, afterIssue)
                XCTAssertEqual(record.originEntryID, "history-origin", "A later observed track must not replace the command's origin")
                library.flushPendingWritesBeforeTermination()
                let disk = try LibraryPersistence(defaults: defaults, catalog: catalog).load()
                XCTAssertEqual(disk.playbackOperations, [record])

                let restoredClient = PlaybackClientSpy(snapshot: snapshot(track: nil, status: .stopped))
                library.flushPendingWritesBeforeTermination()
                let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: restoredClient)
                defer { restoredClient.stopObserving() }
                XCTAssertEqual(restored.playbackOperations, [record])
                XCTAssertNil(restored.currentTrack)
                XCTAssertNil(restored.currentEntryID)
                XCTAssertNil(restored.next)
                XCTAssertNil(restored.pendingSong)
                XCTAssertNil(restored.activePlaybackCommand)
                XCTAssertFalse(restored.isPlaying)
                XCTAssertTrue(restoredClient.calls.isEmpty)
                restored.startServices()
                XCTAssertNil(restored.currentTrack)
                XCTAssertNil(restored.next)
                XCTAssertFalse(restored.isPlaying)
                XCTAssertTrue(restoredClient.calls.isEmpty, "Reading history must not replay authorization or transport commands")
                XCTAssertEqual(client.calls.count, 1)
            }
        }
    }

    func testFailureAndUncertainAcceptancePersistTheirActualOutcomes() async throws {
        let variants: [(MusicPlaybackReceipt.Verification?, PlaybackOperationRecord.Outcome)] = [
            (nil, .failed), (.unconfirmed, .uncertain), (.acceptedBySystem, .uncertain)
        ]
        for (verification, outcome) in variants {
            let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "history-origin")))
            client.holdCommands = true
            try await withLibrary(client: client) { library, catalog, defaults in
                library.startServices()
                library.queueNext(.jane)
                await waitUntil { client.calls.count == 1 }
                let completedAt = Date()
                let failure = MusicPlaybackFailure(.notConfirmed, "请先查看 Apple Music", diagnostic: "fixture diagnostic")
                if let verification {
                    client.complete(.uncertain(.init(command: .insertNext, catalogID: "1840081736", verification: verification,
                                                     completedAt: completedAt), failure))
                } else { client.complete(.failure(failure)) }
                await waitUntil { !library.playbackBusy }
                let returnedAt = Date()
                let record = try XCTUnwrap(library.playbackOperations.first)
                XCTAssertEqual(record.outcome, outcome)
                XCTAssertEqual(record.verification, verification)
                XCTAssertEqual(record.targetWorkID, .jane)
                XCTAssertEqual(record.catalogID, "1840081736")
                XCTAssertEqual(record.failureCode, .notConfirmed)
                XCTAssertEqual(record.failureMessage, failure.message)
                XCTAssertNil(record.observedAt)
                if verification != nil { XCTAssertEqual(record.completedAt, completedAt) }
                else {
                    XCTAssertGreaterThanOrEqual(record.completedAt, completedAt)
                    XCTAssertLessThanOrEqual(record.completedAt, returnedAt)
                }
                XCTAssertNil(library.next)
                XCTAssertEqual(library.currentTrack, .pool)
                XCTAssertEqual(library.isPlaybackUncertain(for: .jane, command: .insertNext), outcome == .uncertain)
                library.flushPendingWritesBeforeTermination()
                let disk = try LibraryPersistence(defaults: defaults, catalog: catalog).load()
                XCTAssertEqual(disk.playbackOperations, [record])
                XCTAssertEqual(client.calls.count, 1, "Logging a failure or uncertainty cannot retry the mutation")
            }
        }
    }

    func testContradictorySuccessIsRecordedAsUncertaintyAndDoesNotCreateNext() async throws {
        let variants: [(MusicPlaybackCommand, String, MusicPlaybackReceipt.Verification)] = [
            (.insertNext, "1840081736", .unconfirmed),
            (.playNow, "1840081736", .observed),
            (.insertNext, "1837522108", .acceptedBySystem)
        ]
        for (command, catalogID, verification) in variants {
            let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "history-origin")))
            client.holdCommands = true
            try await withLibrary(client: client) { library, catalog, defaults in
                library.startServices()
                library.queueNext(.jane)
                await waitUntil { client.calls.count == 1 }
                let beforeReturn = Date()
                client.complete(.success(.init(command: command, catalogID: catalogID, verification: verification)))
                await waitUntil { !library.playbackBusy }
                let returnedAt = Date()
                let record = try XCTUnwrap(library.playbackOperations.first)
                XCTAssertEqual(record.command, .insertNext)
                XCTAssertEqual(record.targetWorkID, .jane)
                XCTAssertEqual(record.catalogID, "1840081736")
                XCTAssertEqual(record.outcome, .uncertain)
                XCTAssertEqual(record.verification, .unconfirmed)
                XCTAssertEqual(record.failureCode, .notConfirmed)
                XCTAssertNil(record.observedAt)
                XCTAssertGreaterThanOrEqual(record.completedAt, beforeReturn)
                XCTAssertLessThanOrEqual(record.completedAt, returnedAt)
                XCTAssertNil(library.next)
                XCTAssertTrue(library.playbackUncertain)
                XCTAssertTrue(library.isPlaybackUncertain(for: .jane, command: .insertNext))
                library.queueNext(.jane)
                XCTAssertEqual(client.calls.count, 1, "A contradictory receipt cannot unlock a duplicate insertion")
                library.flushPendingWritesBeforeTermination()
                let disk = try LibraryPersistence(defaults: defaults, catalog: catalog).load()
                XCTAssertEqual(disk.playbackOperations, [record])
            }
        }
    }

    func testUncertainInsertionRemainsBlockedAcrossLibraryRecreation() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "persisted-origin")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, catalog, defaults in
            library.startServices()
            library.queueNext(.jane)
            await waitUntil { client.calls.count == 1 }
            client.complete(uncertain(.insertNext, catalogID: "1840081736"))
            await waitUntil { !library.playbackBusy }
            let history = library.playbackOperations

            let restoredClient = PlaybackClientSpy(snapshot: snapshot(track: nil, status: .stopped))
            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: restoredClient)
            defer { restoredClient.stopObserving() }
            XCTAssertEqual(restored.playbackOperations, history)
            XCTAssertTrue(restored.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertNil(restored.currentTrack)
            XCTAssertNil(restored.next)
            restored.startServices()
            restored.queueNext(.jane)
            await waitUntil { !restored.playbackBusy }
            XCTAssertTrue(restored.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertTrue(restoredClient.calls.isEmpty, "A restart cannot unlock an ambiguous queue mutation")
            XCTAssertNil(restored.next)
            XCTAssertEqual(restored.playbackOperations, history, "A blocked duplicate is not a new submitted operation")
            XCTAssertEqual(client.calls.count, 1)
        }
    }

    func testAcknowledgedUncertaintyDoesNotReappearOrReplayFromHistoricalReceipt() async throws {
        let client = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "persisted-origin")))
        client.holdCommands = true
        try await withLibrary(client: client) { library, catalog, defaults in
            library.startServices()
            library.queueNext(.jane)
            await waitUntil { client.calls.count == 1 }
            client.complete(uncertain(.insertNext, catalogID: "1840081736"))
            await waitUntil { !library.playbackBusy }
            let history = library.playbackOperations
            library.acknowledgePlaybackCheck(for: .jane, command: .insertNext)
            XCTAssertFalse(library.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertEqual(library.playbackOperations, history, "Acknowledgment does not rewrite the uncertain historical result")

            let restoredClient = PlaybackClientSpy(snapshot: snapshot(track: song(entry: "persisted-origin")))
            library.flushPendingWritesBeforeTermination()
            let restored = Library(defaults: defaults, arguments: [], catalog: catalog, music: restoredClient)
            defer { restoredClient.stopObserving() }
            XCTAssertEqual(restored.playbackOperations, history)
            XCTAssertFalse(restored.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertNil(restored.currentTrack)
            XCTAssertNil(restored.next)
            XCTAssertTrue(restoredClient.calls.isEmpty)
            restored.startServices()
            XCTAssertFalse(restored.isPlaybackUncertain(for: .jane, command: .insertNext))
            XCTAssertTrue(restoredClient.calls.isEmpty, "An uncertain history row is not an instruction to replay")
            restored.queueNext(.jane)
            await waitUntil { restoredClient.calls.count == 1 && !restored.playbackBusy }
            XCTAssertEqual(restoredClient.calls.map(\.command), [.insertNext], "Only this new explicit action may reach the player")
            XCTAssertEqual(restored.playbackOperations.count, 2)
            XCTAssertTrue(restored.playbackOperations.contains { $0.id == history.first?.id && $0.outcome == .uncertain })
        }
    }

    func testReadTimeoutReleasesGateButExpiredReadCannotMutateOrClearANewerCommand() async {
        let firstDeadline = SuspendedPlaybackCall()
        let secondDeadline = SuspendedPlaybackCall()
        var deadlineCount = 0
        let executor = MusicPlaybackCommandExecutor {
            deadlineCount += 1
            await (deadlineCount == 1 ? firstDeadline : secondDeadline).wait()
        }
        let oldRead = SuspendedPlaybackCall()
        let oldFinished = PlaybackTestLatch()
        var mutationCount = 0
        let first = Task { @MainActor in
            await executor.run(.insertNext, catalogID: "1837522108") { context in
                defer { oldFinished.signal() }
                await oldRead.wait() // Deliberately ignores cancellation, like an SDK request may.
                try context.beginMutation()
                mutationCount += 1
                return .success(.init(command: .insertNext, catalogID: "1837522108", verification: .acceptedBySystem))
            }
        }
        await oldRead.entered.wait()
        await firstDeadline.entered.wait()
        firstDeadline.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .failure(.init(.timedOut, "Apple Music 响应超时，请稍后再试")))
        XCTAssertFalse(executor.hasUnsettledOperation, "An expired read cannot hold the mutation gate")

        let newWrite = SuspendedPlaybackCall()
        let second = Task { @MainActor in
            await executor.run(.resume) { context in
                try context.beginMutation()
                mutationCount += 1
                await newWrite.wait()
                try context.checkCancellation()
                return .success(.init(command: .resume, catalogID: nil, verification: .observed))
            }
        }
        await newWrite.entered.wait()
        oldRead.release()
        await oldFinished.wait()
        XCTAssertEqual(mutationCount, 1, "A late catalog response must never write after expiry")
        XCTAssertTrue(executor.hasUnsettledOperation, "The old worker cannot clear the newer command's gate")
        let beforeCompletion = Date()
        newWrite.release()
        let secondResult = await second.value
        let returnedAt = Date()
        if case .success(let receipt) = secondResult {
            assertReceipt(receipt, command: .resume, catalogID: nil, verification: .observed,
                          completedBetween: beforeCompletion...returnedAt)
        } else { XCTFail("The resumed operation should return observed success") }
        XCTAssertFalse(executor.hasUnsettledOperation)
        secondDeadline.release()
    }

    func testMutationTimeoutReturnsUncertaintyAndKeepsGateUntilSDKActuallySettles() async {
        let deadline = SuspendedPlaybackCall()
        let sdk = SuspendedPlaybackCall()
        let finished = PlaybackTestLatch()
        let executor = MusicPlaybackCommandExecutor { await deadline.wait() }
        var mutationCount = 0
        var selectedEntry = false
        let command = Task { @MainActor in
            await executor.run(.playNow, catalogID: "1837522108") { context in
                defer { finished.signal() }
                try context.beginMutation()
                mutationCount += 1
                await sdk.wait()
                context.mutationAccepted()
                try context.beginMutation() // Selecting the inserted entry is a second side effect.
                selectedEntry = true
                return .success(.init(command: .playNow, catalogID: "1837522108", verification: .observed))
            }
        }
        await sdk.entered.wait()
        await deadline.entered.wait()
        let beforeTimeout = Date()
        deadline.release()
        let result = await command.value
        let returnedAt = Date()
        if case let .uncertain(receipt, failure) = result {
            assertReceipt(receipt, command: .playNow, catalogID: "1837522108", verification: .unconfirmed,
                          completedBetween: beforeTimeout...returnedAt)
            XCTAssertEqual(failure, .init(.timedOut, "Apple Music 响应超时，请先确认播放或队列"))
        } else { XCTFail("A timed-out mutation must retain uncertainty") }
        XCTAssertTrue(executor.hasUnsettledOperation)
        let blocked = await executor.run(.insertNext, catalogID: "1840081736") { context in
            try context.beginMutation()
            mutationCount += 1
            return .success(.init(command: .insertNext, catalogID: "1840081736", verification: .acceptedBySystem))
        }
        XCTAssertEqual(blocked, .failure(.init(.busy, "上一项播放操作尚未结束，请先查看 Apple Music")))
        XCTAssertEqual(mutationCount, 1, "Another song or an acknowledgment cannot bypass an unsettled write")
        sdk.release()
        await finished.wait()
        XCTAssertFalse(executor.hasUnsettledOperation)
        XCTAssertFalse(selectedEntry, "A late insertion must not begin playback after the user's request expired")
        XCTAssertEqual(mutationCount, 1, "Settling the old write must not trigger an automatic retry")
    }

    func testTimeoutAfterAcceptanceDoesNotClaimAnObservedPlaybackOccurrence() async {
        let deadline = SuspendedPlaybackCall()
        let readback = SuspendedPlaybackCall()
        let finished = PlaybackTestLatch()
        let executor = MusicPlaybackCommandExecutor { await deadline.wait() }
        let command = Task { @MainActor in
            await executor.run(.playNow, catalogID: "1837522108") { context in
                defer { finished.signal() }
                try context.beginMutation()
                context.mutationAccepted()
                await readback.wait()
                try context.checkCancellation()
                return .success(.init(command: .playNow, catalogID: "1837522108", verification: .observed))
            }
        }
        await readback.entered.wait()
        await deadline.entered.wait()
        let beforeTimeout = Date()
        deadline.release()
        let result = await command.value
        let returnedAt = Date()
        if case let .uncertain(receipt, failure) = result {
            assertReceipt(receipt, command: .playNow, catalogID: "1837522108", verification: .acceptedBySystem,
                          completedBetween: beforeTimeout...returnedAt)
            XCTAssertEqual(failure, .init(.timedOut, "Apple Music 响应超时，请先确认播放或队列"))
        } else { XCTFail("Acceptance without completed read-back must remain uncertain") }
        readback.release()
        await finished.wait()
        XCTAssertFalse(executor.hasUnsettledOperation)
    }

    func testCancellationBeforeMutationReturnsPromptlyAndRejectsLateWrite() async {
        let deadline = SuspendedPlaybackCall()
        let lookup = SuspendedPlaybackCall()
        let finished = PlaybackTestLatch()
        let executor = MusicPlaybackCommandExecutor { await deadline.wait() }
        var didWrite = false
        let command = Task { @MainActor in
            await executor.run(.insertNext) { context in
                defer { finished.signal() }
                await lookup.wait()
                try context.beginMutation()
                didWrite = true
                return .success(.init(command: .insertNext, catalogID: nil, verification: .acceptedBySystem))
            }
        }
        await lookup.entered.wait()
        await deadline.entered.wait()
        command.cancel()
        let result = await command.value
        XCTAssertEqual(result, .failure(.init(.cancelled, "操作已取消；如已提交，请先查看 Apple Music")))
        XCTAssertFalse(executor.hasUnsettledOperation)
        lookup.release()
        deadline.release()
        await finished.wait()
        XCTAssertFalse(didWrite)
    }

    func testCancellationDuringMutationRemainsUncertainAndCannotUnlockAnotherWrite() async {
        let deadline = SuspendedPlaybackCall()
        let sdk = SuspendedPlaybackCall()
        let finished = PlaybackTestLatch()
        let executor = MusicPlaybackCommandExecutor { await deadline.wait() }
        let command = Task { @MainActor in
            await executor.run(.skipToNext) { context in
                defer { finished.signal() }
                try context.beginMutation()
                await sdk.wait()
                try context.checkCancellation()
                return .success(.init(command: .skipToNext, catalogID: nil, verification: .observed))
            }
        }
        await sdk.entered.wait()
        await deadline.entered.wait()
        let beforeCancellation = Date()
        command.cancel()
        let result = await command.value
        let returnedAt = Date()
        if case let .uncertain(receipt, failure) = result {
            assertReceipt(receipt, command: .skipToNext, catalogID: nil, verification: .unconfirmed,
                          completedBetween: beforeCancellation...returnedAt)
            XCTAssertEqual(failure, .init(.cancelled, "操作已取消；如已提交，请先查看 Apple Music"))
        } else { XCTFail("Cancellation after mutation must remain uncertain") }
        XCTAssertTrue(executor.hasUnsettledOperation)
        var duplicateStarted = false
        let blocked = await executor.run(.skipToNext) { _ in
            duplicateStarted = true
            return .success(.init(command: .skipToNext, catalogID: nil, verification: .observed))
        }
        if case let .failure(error) = blocked { XCTAssertEqual(error.code, .busy) }
        else { XCTFail("Cancellation must not permit a concurrent system mutation") }
        XCTAssertFalse(duplicateStarted)
        sdk.release()
        deadline.release()
        await finished.wait()
        XCTAssertFalse(executor.hasUnsettledOperation)
    }

    private func song(entry: String) -> MusicNowPlayingMetadata {
        .init(id: entry, catalogID: "1837522108", title: "in the pool", artist: "牛尾宪辅",
              albumTitle: nil, artworkURL: nil, duration: 245, source: .musicKit)
    }

    private func unresolvedSong(entry: String) -> MusicNowPlayingMetadata {
        .init(id: entry, catalogID: nil, title: "in the pool", artist: "牛尾宪辅",
              albumTitle: nil, artworkURL: nil, duration: nil, source: .musicKit, kind: .unknown)
    }

    private func snapshot(track: MusicNowPlayingMetadata?, subscribed: Bool = true,
                          status: MusicPlaybackStatus = .playing, elapsed: TimeInterval = 10) -> MusicPlaybackSnapshot {
        .init(availability: .ready, authorization: .authorized,
              subscription: .available(.init(canPlayCatalogContent: subscribed, canBecomeSubscriber: !subscribed, hasCloudLibraryEnabled: subscribed)),
              nowPlaying: track, status: status, elapsedTime: elapsed, capturedAt: Date(), currentEntryID: track?.id)
    }

    private func uncertain(_ command: MusicPlaybackCommand, catalogID: String? = nil) -> MusicPlaybackActionResult {
        .uncertain(.init(command: command, catalogID: catalogID, verification: .unconfirmed),
                   .init(.notConfirmed, "Check Apple Music before retrying"))
    }

    private func assertReceipt(_ receipt: MusicPlaybackReceipt, command: MusicPlaybackCommand,
                               catalogID: String?, verification: MusicPlaybackReceipt.Verification,
                               completedBetween bounds: ClosedRange<Date>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(receipt.command, command, file: file, line: line)
        XCTAssertEqual(receipt.catalogID, catalogID, file: file, line: line)
        XCTAssertEqual(receipt.verification, verification, file: file, line: line)
        XCTAssertGreaterThanOrEqual(receipt.completedAt, bounds.lowerBound, file: file, line: line)
        XCTAssertLessThanOrEqual(receipt.completedAt, bounds.upperBound, file: file, line: line)
        if verification == .observed {
            if let observedAt = receipt.observedAt {
                XCTAssertGreaterThanOrEqual(observedAt, bounds.lowerBound, file: file, line: line)
                XCTAssertLessThanOrEqual(observedAt, receipt.completedAt, file: file, line: line)
            } else { XCTFail("Observed receipt must carry its read-back time", file: file, line: line) }
        } else { XCTAssertNil(receipt.observedAt, file: file, line: line) }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Asynchronous test action did not settle", file: file, line: line)
    }

    private func withLibrary(client: (any MusicPlaybackClient)? = nil,
                             _ body: @MainActor (Library, CatalogStore) async throws -> Void) async throws {
        try await withLibrary(client: client) { library, catalog, _ in
            try await body(library, catalog)
        }
    }

    private func withLibrary(client: (any MusicPlaybackClient)? = nil,
                             _ body: @MainActor (Library, CatalogStore, UserDefaults) async throws -> Void) async throws {
        let suite = "Pianwai.MusicContracts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = Self.offlineSession
        let catalog = CatalogStore(cacheURL: nil, service: AppleCatalogService(session: session),
                                   bundle: Bundle(for: Self.self), knowledgeService: KnowledgeGraphService(session: session))
        let library = Library(defaults: defaults, arguments: [], catalog: catalog, music: client ?? MusicPlaybackService())
        defer { library.music.stopObserving() }
        try await body(library, catalog, defaults)
    }
}

/// Manual scheduling avoids wall-clock sleeps and makes cancellation-ignoring
/// SDK behavior reproducible. Each suspended call is explicitly released.
@MainActor
private final class PlaybackTestLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class SuspendedPlaybackCall {
    let entered = PlaybackTestLatch()
    private let released = PlaybackTestLatch()

    func wait() async {
        entered.signal()
        await released.wait()
    }

    func release() { released.signal() }
}

@MainActor
private final class PlaybackClientSpy: MusicPlaybackClient {
    struct Call { let command: MusicPlaybackCommand; let catalogID: String? }
    var snapshot: MusicPlaybackSnapshot
    var commandInFlight: MusicPlaybackCommand?
    var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    var holdCommands = false
    private(set) var calls: [Call] = []
    private var continuation: CheckedContinuation<MusicPlaybackActionResult, Never>?

    init(snapshot: MusicPlaybackSnapshot) { self.snapshot = snapshot }
    func emit(_ value: MusicPlaybackSnapshot) { snapshot = value; onSnapshot?(value) }
    func startObserving() { isObserving = true; onSnapshot?(snapshot) }
    func stopObserving() { isObserving = false; onSnapshot = nil }
    func refresh() async { onSnapshot?(snapshot) }
    func requestAuthorization() async -> MusicPlaybackActionResult { await perform(.requestAuthorization) }
    func pause() async -> MusicPlaybackActionResult { await perform(.pause) }
    func resume() async -> MusicPlaybackActionResult { await perform(.resume) }
    func skipToNext() async -> MusicPlaybackActionResult { await perform(.skipToNext) }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { await perform(.insertNext, catalogID: catalogID) }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { await perform(.playNow, catalogID: catalogID) }
    func complete(_ result: MusicPlaybackActionResult) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
    private func perform(_ command: MusicPlaybackCommand, catalogID: String? = nil) async -> MusicPlaybackActionResult {
        calls.append(.init(command: command, catalogID: catalogID))
        commandInFlight = command
        defer { commandInFlight = nil }
        if holdCommands {
            return await withCheckedContinuation { continuation = $0 }
        }
        return .success(.init(command: command, catalogID: catalogID,
                              verification: command == .insertNext ? .acceptedBySystem : .observed))
    }
}

private final class NoNetworkMusicContractURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
