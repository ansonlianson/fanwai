#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit offline replay of U19's public responses. The work deliberately
/// has the legacy blank credit; its typed composer edge must repair the lookup.
enum OriginalRecordingFixture {
    static var directory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains("--ui-u19-original-recording"),
              let path = ProcessInfo.processInfo.environment["PIANWAI_U19_PUBLIC"],
              path.hasSuffix("/Design/review/U19-original-recording/public") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func database(_ subject: LeadSubject) -> [DatabaseDiscoveryResult]? {
        guard let directory, subject.id == "apple:song:6827420367",
              let bytes = try? Data(contentsOf: directory.appendingPathComponent("musicbrainz-work.json")),
              let composition = try? JSONDecoder().decode(PublicMBRelation.Work.self, from: bytes),
              let composer = composition.relations?.first(where: { $0.type == "composer" })?.artist,
              let metadata = try? Data(contentsOf: directory.appendingPathComponent("itunes-hata.json")),
              let catalog = try? JSONDecoder().decode(ITunesCatalogPayload.self, from: metadata).materialize(country: "jp"),
              let song = catalog.snapshot.works.first(where: { $0.id.rawValue == subject.id }) else { return nil }
        let root = SeedLibraryBridge.workID(subject.id)
        let work = Work(id: WorkID(rawValue: "musicbrainz:work:" + composition.id)!, title: composition.title,
            creator: "", kind: "音乐作品", art: "", detail: "", url: "https://musicbrainz.org/work/" + composition.id)
        let person = Work(id: WorkID(rawValue: "musicbrainz:artist:" + composer.id)!, title: composer.name,
            creator: "", kind: "创作者", art: "", detail: "", url: "https://musicbrainz.org/artist/" + composer.id)
        let relations = [RelationEdge(from: root, to: work.id, predicate: .coverOf, label: "原曲", inverseLabel: "翻唱版本",
                source: .init(title: "MusicBrainz", url: "https://musicbrainz.org/recording/502d9484-996a-4398-8f1c-9bba9e77e3c9"), researchRoot: root),
            RelationEdge(from: work.id, to: person.id, predicate: .composedBy, label: "作曲", inverseLabel: "作品",
                source: .init(title: "MusicBrainz", url: work.url!), researchRoot: root)]
        let album = song.albumID.flatMap { id in catalog.snapshot.works.first { $0.id == id } }
        return [.init(snapshot: .init(works: [song, work, person] + [album].compactMap { $0 }, relations: relations))]
    }

    static func response(_ request: URLRequest) throws -> (Data, String)? {
        guard let directory, let url = request.url else { return nil }
        if url.host == "itunes.apple.com", url.path == "/search" {
            let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value ?? ""
            let name = term == "鱗 秦基博" ? "itunes-hata.json" : "itunes-title-only.json"
            return (try Data(contentsOf: directory.appendingPathComponent(name)), "application/json")
        }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("IMAGE-MANIFEST.json"))
        let images = try JSONDecoder().decode([String: String].self, from: bytes)
        if let name = images[url.absoluteString] {
            return (try Data(contentsOf: directory.appendingPathComponent(name)), "image/jpeg")
        }
        return nil
    }
}
#endif
