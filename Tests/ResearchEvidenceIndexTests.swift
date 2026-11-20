import XCTest
@testable import Pianwai

final class ResearchEvidenceIndexTests: XCTestCase {
    private func packet(sourceID: String = "S1") -> ResearchMaterialPacket {
        let source = ResearchSource(id: sourceID, url: "https://example.org/aurora", title: "Aurora",
            publisher: "Example", text: "Aurora\n編曲：Mira\n原曲：Dawn、Dusk\n原作：Aster、Birch\nAurora\n原作：Iris（Example Press）\nAurora（原作:Other）している原作を元に。\n", purposes: [.lineage])
        return .init(topic: .init(id: "test:aurora", title: "Aurora (Live)", creator: "Mira", album: "Live", layer: "recording"),
            queries: [], sources: [source], fetchedAt: Date(), searchSeconds: 0, fetchSeconds: 0, searches: 0, fetches: 0)
    }

    func testReferenceCopiesRealTextAndSurvivesRenumberedSources() throws {
        let first = ResearchEvidenceIndex.spans(packet()), renumbered = ResearchEvidenceIndex.spans(packet(sourceID: "S8"))
        XCTAssertEqual(first.map(\.id), renumbered.map(\.id))
        let span = try XCTUnwrap(first.first)
        let bound = try XCTUnwrap(ResearchEvidenceIndex.bind([span.id], in: first))
        XCTAssertEqual(bound.first?.text, packet().sources.first?.text)
        XCTAssertNil(ResearchEvidenceIndex.bind([span.id, "invented"], in: first))
    }

    func testUnresolvedOriginalNamesBecomeQuestionsWithoutInventedMediaOrEdges() {
        let known = [ResearchKnownSubject(ref: "current", name: "Aurora (Live)", layer: "recording")]
        let questions = ResearchEvidenceIndex.originalIdentityQuestions(packet(), known: known)
        XCTAssertEqual(questions.map(\.name), ["Aster", "Birch"])
        let index = ResearchEvidenceIndex.spans(packet())
        for question in questions { XCTAssertNotNil(ResearchEvidenceIndex.bind([question.evidenceID], in: index)) }
        XCTAssertTrue(ResearchEvidenceIndex.originalIdentityQuestions(packet(), known: known + [
            .init(ref: "a", name: "Aster", layer: "game"), .init(ref: "b", name: "Birch", layer: "book"), .init(ref: "p", name: "Iris", layer: "person")
        ]).isEmpty)
    }
}
