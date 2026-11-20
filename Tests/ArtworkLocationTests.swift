import XCTest
@testable import Pianwai

@MainActor final class ArtworkLocationTests: XCTestCase {
    func testOpaqueLibraryArtworkIsNotAFileOrPublicURL() {
        XCTAssertEqual(ArtworkLocation.stored("musicKit://artwork/library/TEST/800x800?aat=Music211%2Fcover.jpg"), "")
        XCTAssertEqual(ArtworkLocation.stored("file:///private/cover.jpg"), "")
        XCTAssertEqual(ArtworkLocation.stored("pool"), "pool")
        let remote = "https://is1-ssl.mzstatic.com/image/thumb/Music211/cover.jpg/800x800bb.jpg"
        XCTAssertEqual(ArtworkLocation.stored(remote), remote)
    }

    func testLegacyOpaqueArtworkIsRepairedWithoutLosingRecordingOrLibraryLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let id = WorkID(rawValue: "apple:song:1857886409")!
        let legacy = Work(id: id, title: "Actor", creator: "幾田りら", kind: "歌曲",
            art: "musicKit://artwork/library/TEST/800x800", detail: "Laugh",
            url: "https://music.apple.com/jp/song/1857886409", catalogID: "1857886409")
        try JSONEncoder().encode(CatalogSnapshot(works: [legacy], relations: [])).write(to: file)
        let store = CatalogStore(cacheURL: file)
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.work(id).art, "")
        XCTAssertEqual(store.work(id).catalogRecordingID, "1857886409")
        let cover = "https://is1-ssl.mzstatic.com/image/thumb/Music211/cover.jpg/800x800bb.jpg"
        let refreshed = Work(id: id, title: "Actor", creator: "幾田りら", kind: "歌曲", art: cover,
            detail: "Laugh", url: legacy.url, catalogID: "1857886409")
        try store.merge(CatalogSnapshot(works: [refreshed], relations: []))
        try store.merge(CatalogSnapshot(works: [legacy], relations: []))
        XCTAssertEqual(store.work(id).art, cover, "A later opaque playback observation must not replace the usable cover")
        store.save()
        await store.flushPendingWrites()
        XCTAssertEqual(CatalogStore(cacheURL: file).work(id).art, cover)
    }
}
