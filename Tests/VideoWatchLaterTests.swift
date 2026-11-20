import XCTest
@testable import Pianwai

/// URL and local intent contracts only. These tests neither open another app
/// nor prove that Bilibili/YouTube honors a timestamp after the handoff.
@MainActor
final class VideoWatchLaterTests: XCTestCase {
    func testPublishedAnimenzCuesBuildDestinationsForTheVerifiedUpload() throws {
        let cues = VideoCues.animenz
        XCTAssertEqual(cues.map(\.seconds), [76, 215])
        XCTAssertEqual(cues.map(\.timeLabel), ["1:16", "3:35"])
        XCTAssertEqual(cues.map(\.duration), [324, 324])
        XCTAssertEqual(cues.map(\.title), ["向上流动的琶音", "高音区的水光"])
        for cue in cues {
            XCTAssertTrue(cue.isValid)
            XCTAssertEqual(cue.video.id, "bilibili:BV1QHyZBbEnT:p1")
            XCTAssertEqual(cue.source, .animenz)
            let destination = try XCTUnwrap(cue.video.destination(seconds: cue.seconds))
            XCTAssertEqual(destination.host, "www.bilibili.com")
            XCTAssertEqual(destination.absoluteString, "https://www.bilibili.com/video/BV1QHyZBbEnT/?t=\(cue.seconds)")
            XCTAssertEqual(query(destination, "t"), String(cue.seconds))
        }
    }

    func testYouTubeURLFormsAndTrackingResolveToOneUpload() throws {
        let urls = [
            "https://youtu.be/sPLqsLsooJY?si=tracking&t=76",
            "https://www.youtube.com/watch?v=sPLqsLsooJY&t=215&list=playlist",
            "https://m.youtube.com/watch?v=sPLqsLsooJY",
            "https://youtube.com/shorts/sPLqsLsooJY?feature=share",
            "https://www.youtube.com/embed/sPLqsLsooJY?start=12"
        ]
        let videos = try urls.map { try XCTUnwrap(VideoReference(url: $0)) }
        XCTAssertEqual(Set(videos).count, 1)
        let video = try XCTUnwrap(videos.first)
        XCTAssertEqual(video.provider, .youtube)
        XCTAssertEqual(video.assetID, "sPLqsLsooJY")
        XCTAssertEqual(video.canonicalURL, "https://www.youtube.com/watch?v=sPLqsLsooJY")
        let destination = try XCTUnwrap(video.destination(seconds: 76))
        XCTAssertEqual(query(destination, "v"), "sPLqsLsooJY")
        XCTAssertEqual(query(destination, "t"), "76")
        XCTAssertNil(query(destination, "si"))
        XCTAssertNil(query(destination, "list"))
    }

    func testBilibiliPartsAndUploadsRemainSeparateWhileTimeAndTrackingDoNot() throws {
        let original = try XCTUnwrap(VideoReference(url: Source.animenz.url))
        let firstPart = try XCTUnwrap(VideoReference(url: Source.animenz.url + "?p=1&t=215&spm_id_from=tracking"))
        let secondPart = try XCTUnwrap(VideoReference(url: Source.animenz.url + "?p=2&t=76"))
        let anotherUpload = try XCTUnwrap(VideoReference(url: "https://www.bilibili.com/video/BV0000000001/"))
        XCTAssertEqual(original, firstPart)
        XCTAssertNotEqual(original.id, secondPart.id)
        XCTAssertNotEqual(original.id, anotherUpload.id)
        let destination = try XCTUnwrap(secondPart.destination(seconds: 215))
        XCTAssertEqual(query(destination, "p"), "2")
        XCTAssertEqual(query(destination, "t"), "215")
        XCTAssertNil(query(destination, "spm_id_from"))
        for suffix in ["?p=0", "?p=-1", "?p=two", "?p=1&p=2"] {
            XCTAssertNil(VideoReference(url: Source.animenz.url + suffix))
        }
    }

    func testUnknownHTTPSVideoRetainsExactQueryAndFragmentWithoutInventingTimeSupport() throws {
        let raw = "https://video.example.org/performance?edition=original&t=already-present#movement-2"
        let video = try XCTUnwrap(VideoReference(url: raw))
        XCTAssertEqual(video.provider, .web)
        XCTAssertEqual(video.assetID, raw)
        XCTAssertEqual(video.canonicalURL, raw)
        XCTAssertEqual(video.destination()?.absoluteString, raw)
        XCTAssertNil(video.destination(seconds: 0))
        XCTAssertNil(video.destination(seconds: 76))
        XCTAssertFalse(VideoCue(video: video, seconds: 76, title: "听点", source: .animenz, duration: 324).isValid)
        XCTAssertNil(VideoReference(url: "http://video.example.org/performance"))
        XCTAssertNil(VideoReference(url: "file:///private/video.mp4"))
    }

    func testSavingUpdatingAndRestartingKeepOneIntentForTheExactVideo() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            let firstCue = try XCTUnwrap(VideoCues.animenz.first)
            let secondCue = try XCTUnwrap(VideoCues.animenz.last)
            library.toggleLater(.animenz)
            XCTAssertEqual(library.watchLaterEntries.count, 1)
            XCTAssertNil(library.watchLaterEntry(for: .animenz)?.cue)

            library.saveForLater(.animenz, cue: firstCue)
            let first = try XCTUnwrap(library.watchLaterEntry(for: .animenz))
            XCTAssertEqual(first.cue, firstCue)
            XCTAssertEqual(first.subtitle, "1:16 · 向上流动的琶音")
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            library.flushPendingWritesBeforeTermination()
            let beforeDuplicate = try XCTUnwrap(defaults.data(forKey: persistence.key))
            library.saveForLater(.animenz, cue: firstCue)
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), beforeDuplicate,
                           "Repeating the same intent must not rewrite its time or duplicate it")

            library.saveForLater(.animenz, cue: secondCue)
            XCTAssertEqual(library.watchLaterEntries.count, 1)
            XCTAssertEqual(library.watchLaterEntry(for: .animenz)?.id, first.id)
            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertNil(restored.persistenceError)
            XCTAssertEqual(restored.watchLaterEntries.count, 1)
            XCTAssertEqual(restored.watchLaterEntry(for: .animenz)?.cue, secondCue)
            XCTAssertEqual(restored.watchLaterEntry(for: .animenz)?.subtitle, "3:35 · 高音区的水光")
            XCTAssertEqual(restored.later, [.animenz])
            XCTAssertTrue(restored.watchedIDs.isEmpty)
        }
    }

    func testInvalidOrDifferentUploadCuesCannotReplaceAnExistingIntent() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            let valid = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(.animenz, cue: valid)
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            library.flushPendingWritesBeforeTermination()
            let original = try XCTUnwrap(defaults.data(forKey: persistence.key))
            let differentUpload = try XCTUnwrap(VideoReference(url: "https://www.bilibili.com/video/BV0000000001/"))
            let differentPart = try XCTUnwrap(VideoReference(url: Source.animenz.url + "?p=2"))
            let rejected = [
                VideoCue(video: differentUpload, seconds: 76, title: "另一个上传", source: .animenz, duration: 324),
                VideoCue(video: differentPart, seconds: 76, title: "另一个分P", source: .animenz, duration: 324),
                VideoCue(video: valid.video, seconds: 324, title: "到结尾", source: .animenz, duration: 324),
                VideoCue(video: valid.video, seconds: 325, title: "超过时长", source: .animenz, duration: 324),
                VideoCue(video: valid.video, seconds: -1, title: "负时间", source: .animenz, duration: 324),
                VideoCue(video: valid.video, seconds: 76, title: " ", source: .animenz, duration: 324)
            ]
            for cue in rejected { library.saveForLater(.animenz, cue: cue) }
            library.saveForLater(.pool, cue: valid) // A song is not the performance video.
            XCTAssertEqual(library.watchLaterEntries.count, 1)
            XCTAssertEqual(library.watchLaterEntry(for: .animenz)?.cue, valid)
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), original)
        }
    }

    func testLegacyMissingCatalogEntrySurvivesMigrationAndUnrelatedSaves() throws {
        try withStorage { defaults, catalog in
            let missing = try XCTUnwrap(WorkID(rawValue: "local:unavailable-video"))
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            let old = Data(#"{"version":1,"saved":[],"listenLater":[],"watchLater":["local:unavailable-video"],"recent":[],"checkpoints":{},"startedBrowsing":false,"country":"jp"}"#.utf8)
            defaults.set(old, forKey: persistence.key)
            let library = makeLibrary(defaults, catalog)
            XCTAssertNil(catalog.works[missing])
            XCTAssertEqual(library.later, [missing])
            XCTAssertEqual(library.watchLaterEntries.count, 1)
            XCTAssertEqual(library.watchLaterEntry(for: missing)?.workID, missing)
            XCTAssertNil(library.watchLaterEntry(for: missing)?.video)
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), old,
                           "Loading legacy state should not eagerly rewrite it")

            library.toggleSaved(.film)
            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.later, [missing])
            XCTAssertEqual(restored.watchLaterEntries.count, 1)
            XCTAssertEqual(restored.saved, [.film])
            XCTAssertTrue(restored.watchedIDs.isEmpty)
        }
    }

    func testLegacyGenericIntentUpgradesWhenItsExactVideoBecomesKnown() throws {
        try withStorage { defaults, catalog in
            let id = try XCTUnwrap(WorkID(rawValue: "local:resolved-video"))
            try LibraryPersistence(defaults: defaults, catalog: catalog).save(LibrarySnapshot(watchLater: [id]))
            let library = makeLibrary(defaults, catalog)
            let unresolved = try XCTUnwrap(library.watchLaterEntry(for: id))
            XCTAssertNil(unresolved.video)

            try installVideo(id, url: Source.animenz.url, into: catalog)
            XCTAssertNotNil(library.watchLaterEntry(for: id), "Resolving metadata must not hide the earlier pending intention")
            let cue = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(id, cue: cue)
            XCTAssertEqual(library.watchLaterEntries.count, 1, "Upgrade the unresolved intent instead of adding a second row")
            XCTAssertEqual(library.watchLaterEntry(for: id)?.video, cue.video)
            XCTAssertEqual(library.watchLaterEntry(for: id)?.cue, cue)
            XCTAssertFalse(library.watchLaterEntries.contains { $0.id == unresolved.id })
            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.watchLaterEntries.count, 1)
            XCTAssertEqual(restored.watchLaterEntry(for: id)?.cue, cue)
        }
    }

    func testPreparingExternalDestinationAndOpeningPendingVideoDoNotMarkItWatched() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            let cue = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(.animenz, cue: cue)
            let entry = try XCTUnwrap(library.watchLaterEntry(for: .animenz))
            XCTAssertNotNil(entry.video?.destination(seconds: entry.cue?.seconds))
            library.openWatchLater(entry)
            XCTAssertEqual(library.videoCueFocus?.entry, entry)
            XCTAssertNil(library.savedVideoSheet)
            XCTAssertEqual(library.watchLaterEntries, [entry])
            XCTAssertTrue(library.watchedIDs.isEmpty)
            XCTAssertNil(library.currentTrack)

            library.removeWatchLater(entry.id)
            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertTrue(restored.watchLaterEntries.isEmpty)
            XCTAssertTrue(restored.watchedIDs.isEmpty, "Removing a pending intention is not completion")
        }
    }

    func testCueFocusCanOnlyBeClaimedByTheVisibleExactDestinationInItsOwnTab() throws {
        try withStorage { defaults, catalog in
            let library = makeLibrary(defaults, catalog)
            let cue = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(.animenz, cue: cue)
            let entry = try XCTUnwrap(library.watchLaterEntry(for: .animenz))
            library.explore(.pool)
            library.open(.animenz)
            let oldNowPath = library.path
            library.collectionPath = [.work(.animenz), .work(.film)]
            library.tab = .collection
            library.openWatchLater(entry)

            let request = try XCTUnwrap(library.videoCueFocus)
            let targetPath: [Route] = [.work(.animenz), .work(.film), .work(.animenz)]
            XCTAssertEqual(request.ownerTab, .collection)
            XCTAssertEqual(request.destinationPath, targetPath, "Capture the stack after opening the destination")
            XCTAssertNil(library.takeVideoCueFocus(for: .animenz, ownerTab: .now,
                                                   destinationPath: oldNowPath, isVisible: true),
                         "The same work left in the other tab cannot steal the request")
            XCTAssertNil(library.takeVideoCueFocus(for: .animenz, ownerTab: .collection,
                                                   destinationPath: [.work(.animenz)], isVisible: true),
                         "An earlier occurrence of this work in the same stack cannot claim a deeper destination")
            XCTAssertNil(library.takeVideoCueFocus(for: .animenz, ownerTab: .collection,
                                                   destinationPath: targetPath, isVisible: false))
            XCTAssertEqual(library.videoCueFocus?.id, request.id)

            library.collectionPath = [.work(.animenz)]
            XCTAssertNil(library.takeVideoCueFocus(for: .animenz, ownerTab: .collection,
                                                   destinationPath: targetPath, isVisible: true),
                         "A delayed task cannot scroll after navigation has moved elsewhere")
            XCTAssertEqual(library.videoCueFocus?.id, request.id)
            library.collectionPath = targetPath
            let claimed = library.takeVideoCueFocus(for: .animenz, ownerTab: .collection,
                                                    destinationPath: targetPath, isVisible: true)
            XCTAssertEqual(claimed?.id, request.id)
            XCTAssertEqual(claimed?.entry.cue, cue)
            XCTAssertNil(library.videoCueFocus)
            XCTAssertNil(library.takeVideoCueFocus(for: .animenz, ownerTab: .collection,
                                                   destinationPath: targetPath, isVisible: true),
                         "The request is a one-shot navigation intention")
            XCTAssertEqual(library.watchLaterEntry(for: .animenz), entry)
            XCTAssertTrue(library.watchedIDs.isEmpty)
        }
    }

    func testChangedWorkURLKeepsTwoUploadsAndExactRemovalPreservesTheOther() throws {
        try withStorage { defaults, catalog in
            let id = try XCTUnwrap(WorkID(rawValue: "local:changed-video"))
            try installVideo(id, url: Source.animenz.url, into: catalog)
            let library = makeLibrary(defaults, catalog)
            let originalCue = try XCTUnwrap(VideoCues.animenz.first)
            library.saveForLater(id, cue: originalCue)
            let original = try XCTUnwrap(library.watchLaterEntry(for: id))

            let replacementURL = "https://www.youtube.com/watch?v=sPLqsLsooJY"
            try installVideo(id, url: replacementURL, into: catalog)
            XCTAssertEqual(catalog.work(id).url, replacementURL)
            let replacementVideo = try XCTUnwrap(VideoReference(url: replacementURL))
            let replacementCue = VideoCue(video: replacementVideo, seconds: 12, title: "另一个视频的听点",
                                          source: Source(title: "测试视频说明", detail: "测试夹具", url: replacementURL), duration: 200)
            library.saveForLater(id, cue: replacementCue)
            let replacement = try XCTUnwrap(library.watchLaterEntry(for: id))
            XCTAssertNotEqual(original.id, replacement.id)
            XCTAssertEqual(library.watchLaterEntries.count, 2)
            XCTAssertEqual(library.later, [id], "The legacy projection stays work-level")

            library.openWatchLater(original)
            XCTAssertEqual(library.savedVideoSheet, original)
            XCTAssertNil(library.videoCueFocus, "The old cue cannot move onto the work's replacement upload")
            XCTAssertTrue(library.watchedIDs.isEmpty)

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(Set(restored.watchLaterEntries.map(\.id)), [original.id, replacement.id])
            restored.removeWatchLater(original.id)
            XCTAssertEqual(restored.watchLaterEntries, [replacement])
            XCTAssertTrue(restored.watchedIDs.isEmpty)
            restored.flushPendingWritesBeforeTermination()
            let removed = makeLibrary(defaults, catalog)
            XCTAssertEqual(removed.watchLaterEntries, [replacement])
        }
    }

    func testExactCompletionLeavesAnotherUploadPendingAndOtherListsUnchanged() throws {
        try withStorage { defaults, catalog in
            let id = try XCTUnwrap(WorkID(rawValue: "local:two-video-parts"))
            try installVideo(id, url: Source.animenz.url, into: catalog)
            let library = makeLibrary(defaults, catalog)
            library.toggleSaved(.film)
            library.toggleSaved(id)
            library.toggleListenLater(.distance)
            library.toggleLater(id)
            let firstPart = try XCTUnwrap(library.watchLaterEntry(for: id))
            try installVideo(id, url: Source.animenz.url + "?p=2", into: catalog)
            library.toggleLater(id)
            let secondPart = try XCTUnwrap(library.watchLaterEntry(for: id))
            let savedBefore = library.saved
            let listeningBefore = library.listenLater
            XCTAssertEqual(library.watchLaterEntries.count, 2)

            library.markWatchLaterEntryWatched(firstPart.id)
            XCTAssertEqual(library.watchLaterEntries, [secondPart])
            XCTAssertEqual(library.watchedIDs, [id])
            XCTAssertEqual(library.saved, savedBefore)
            XCTAssertEqual(library.listenLater, listeningBefore)
            XCTAssertNil(library.currentTrack)
            let persistence = LibraryPersistence(defaults: defaults, catalog: catalog)
            library.flushPendingWritesBeforeTermination()
            let once = try XCTUnwrap(defaults.data(forKey: persistence.key))
            library.markWatchLaterEntryWatched(firstPart.id)
            library.flushPendingWritesBeforeTermination()
            XCTAssertEqual(defaults.data(forKey: persistence.key), once, "A stale completion must not complete the other upload")

            library.flushPendingWritesBeforeTermination()
            let restored = makeLibrary(defaults, catalog)
            XCTAssertEqual(restored.watchLaterEntries, [secondPart])
            XCTAssertEqual(restored.watchedIDs, [id])
            XCTAssertEqual(restored.saved, savedBefore)
            XCTAssertEqual(restored.listenLater, listeningBefore)
        }
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func installVideo(_ id: WorkID, url: String, into catalog: CatalogStore) throws {
        let item = Work(id: id, title: "视频测试夹具", creator: "演奏者", kind: "演奏视频", art: "",
                        detail: "仅验证上传身份与本机意图", url: url)
        try catalog.merge(CatalogSnapshot(works: [item], relations: []), persist: false)
    }

    private func withStorage(_ body: (UserDefaults, CatalogStore) throws -> Void) throws {
        let suite = "Pianwai.VideoWatchLater.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, CatalogStore(cacheURL: nil, bundle: Bundle(for: Self.self)))
    }

    private func makeLibrary(_ defaults: UserDefaults, _ catalog: CatalogStore) -> Library {
        Library(defaults: defaults, arguments: [], catalog: catalog, music: VideoWatchLaterMusicStub())
    }
}

@MainActor
private final class VideoWatchLaterMusicStub: MusicPlaybackClient {
    let snapshot = MusicPlaybackSnapshot(availability: .authorizationRequired, authorization: .notDetermined,
                                         subscription: .unknown, nowPlaying: nil, status: .stopped,
                                         elapsedTime: 0, capturedAt: Date(timeIntervalSince1970: 0))
    let commandInFlight: MusicPlaybackCommand? = nil
    var isObserving = false
    var onSnapshot: (@MainActor (MusicPlaybackSnapshot) -> Void)?
    func startObserving() { isObserving = true }
    func stopObserving() { isObserving = false }
    func refresh() async { }
    func requestAuthorization() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func pause() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func resume() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func skipToNext() async -> MusicPlaybackActionResult { unexpectedCommand() }
    func insertNext(catalogID: String) async -> MusicPlaybackActionResult { unexpectedCommand() }
    func playNow(catalogID: String) async -> MusicPlaybackActionResult { unexpectedCommand() }
    private func unexpectedCommand() -> MusicPlaybackActionResult {
        XCTFail("Video discovery and watch-later actions must not issue Apple Music commands")
        return .failure(.init(.configuration, "Playback is disabled for this test"))
    }
}
