import XCTest
@testable import Pianwai

@MainActor
final class KnowledgeAnchorTests: XCTestCase {
    func testSeedAndEditorialPeopleReceiveTheirVerifiedIdentity() throws {
        let store = CatalogStore(cacheURL: nil)
        XCTAssertNil(store.storageError)
        let expected: [(WorkID, String)] = [
            (.ushio, "Q11190062"), (.yonezu, "Q11604296"), (.utada, "Q234598"),
            (.yoshihara, "Q125871279"), (.fujimoto, "Q24864023"),
            (.ravel, "Q1178"), (.debussy, "Q4700"), (.animenzPerson, "Q61102629"),
            (anchorID("editorial:ryuichi-sakamoto"), "Q345494"),
            (anchorID("editorial:hideaki-anno"), "Q23261"),
            (anchorID("editorial:david-sylvian"), "Q519273"),
            (anchorID("editorial:satoshi-kon"), "Q333643"),
            (anchorID("editorial:nagisa-oshima"), "Q55403"),
            (anchorID("editorial:yasutaka-tsutsui"), "Q719250"),
            (anchorID("editorial:susumu-hirasawa"), "Q930143")
        ]
        for (id, qid) in expected {
            let person = try XCTUnwrap(store.works[store.canonicalID(for: id)], id.rawValue)
            XCTAssertTrue(person.isPerson, id.rawValue)
            XCTAssertEqual(person.knowledgeID, qid, id.rawValue)
        }
    }

    func testStoryNamesStillOpenTheCorrectCreatorAndExistingUtadaAlias() throws {
        let store = CatalogStore(cacheURL: nil)
        let checks: [(String, String, WorkID, String)] = [
            ("editorial:story-one-last-kiss-remote-mv", "宇多田光", .utada, "Q234598"),
            ("editorial:story-one-last-kiss-remote-mv", "庵野秀明", anchorID("editorial:hideaki-anno"), "Q23261"),
            ("editorial:story-sakamoto-asked-to-score", "坂本龙一", anchorID("editorial:ryuichi-sakamoto"), "Q345494"),
            ("editorial:story-sakamoto-asked-to-score", "大岛渚", anchorID("editorial:nagisa-oshima"), "Q55403"),
            ("editorial:story-kon-lotus-reference", "今敏", anchorID("editorial:satoshi-kon"), "Q333643"),
            ("editorial:story-kon-lotus-reference", "平泽进", anchorID("editorial:susumu-hirasawa"), "Q930143"),
            ("editorial:story-paprika-two-voices", "筒井康隆", anchorID("editorial:yasutaka-tsutsui"), "Q719250"),
            ("editorial:story-lawrence-vocal-version", "David Sylvian", anchorID("editorial:david-sylvian"), "Q519273")
        ]
        for (storyID, phrase, personID, qid) in checks {
            let story = try XCTUnwrap(store.stories.first { $0.id == storyID })
            let linked = try XCTUnwrap(story.entityLinks[phrase])
            XCTAssertEqual(store.canonicalID(for: linked), personID, phrase)
            XCTAssertTrue(store.work(linked).isPerson, phrase)
            XCTAssertEqual(store.work(linked).knowledgeID, qid, phrase)
        }
        let editorialUtada = anchorID("editorial:hikaru-utada")
        XCTAssertEqual(store.canonicalID(for: editorialUtada), .utada)
        XCTAssertEqual(store.work(editorialUtada).knowledgeID, "Q234598")
        XCTAssertEqual(store.works.values.filter { $0.knowledgeID == "Q234598" }.map(\.id), [.utada])
    }

    func testTechniqueReferencesPointToPeopleWithoutRelabelingThePerformance() throws {
        let store = CatalogStore(cacheURL: nil)
        for (person, qid) in [(WorkID.ravel, "Q1178"), (.debussy, "Q4700")] {
            let edge = try XCTUnwrap(store.edges.first {
                $0.from == .animenz && $0.to == person && $0.predicate == .techniqueReference
            })
            XCTAssertEqual(store.work(edge.to).knowledgeID, qid)
            XCTAssertTrue(store.work(edge.to).isPerson)
            XCTAssertEqual(edge.source, .animenz, "Identity enrichment must preserve the original relationship source")
        }
        XCTAssertEqual(store.work(.animenzPerson).knowledgeID, "Q61102629")
        XCTAssertTrue(store.work(.animenz).isVideo)
        XCTAssertNil(store.work(.animenz).knowledgeID, "A pianist identity must not be assigned to their performance")
        for work in [WorkID.jane, .distance, .janeAlbum, .distanceAlbum] {
            XCTAssertNil(store.work(work).knowledgeID, "A creator identity must not be assigned to a song or release")
        }
    }

    func testSameNameImportDoesNotInheritOrMergeADeclaredPersonIdentity() throws {
        let store = CatalogStore(cacheURL: nil)
        let id = anchorID("editorial:unverified-utada-namesake")
        let namesake = Work(id: id, title: "宇多田光", creator: "音乐人", kind: "创作者",
                            art: "", detail: "", url: nil, linkedCreatorIDs: [])
        try store.merge(CatalogSnapshot(works: [namesake], relations: []), persist: false)
        XCTAssertEqual(store.canonicalID(for: id), id)
        XCTAssertNotEqual(store.canonicalID(for: id), store.canonicalID(for: .utada))
        XCTAssertNil(store.work(id).knowledgeID)
        XCTAssertEqual(store.work(.utada).knowledgeID, "Q234598")
    }
}

private func anchorID(_ rawValue: String) -> WorkID { WorkID(rawValue: rawValue)! }
