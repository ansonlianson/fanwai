import Foundation

/// Search provenance is a ranking hint, never a claim that a catalog recording
/// is the same entity as the source work. It expires when the query/type changes.
struct RecordingSearchContext: Equatable, Sendable {
    let sourceID: WorkID
    let query: String
    let kind: CatalogSearchKind
    let title: String
    let artistNames: [String]
    let releaseTitles: [String]
    let editorialQueryHint: String?

    init(source: Work, creators: [Work], release: Work?, query: String, kind: CatalogSearchKind) {
        sourceID = source.id
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        title = source.title
        artistNames = ([source.creator] + creators.map(\.title)).filter { !$0.isEmpty }
        releaseTitles = release.map { [$0.title] } ?? []
        editorialQueryHint = source.versionSearchQuery.flatMap {
            let hint = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !hint.isEmpty && hint.count <= 200 ? hint : nil
        }
    }

    func applies(to query: String, kind: CatalogSearchKind) -> Bool {
        self.kind == kind && self.query == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func ranked(_ response: CatalogResponse) -> CatalogResponse {
        let works = Dictionary(response.snapshot.works.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = response.results.enumerated().map { index, id in
            (index: index, id: id, score: works[id].map { score($0, works: works) } ?? [0, 0, 0])
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return rhs.score.lexicographicallyPrecedes(lhs.score) }
            return lhs.index < rhs.index
        }.map(\.id)
        // Preserve every result and the exact original snapshot. Ranking neither
        // selects a result nor changes its recording/release/knowledge identity.
        return CatalogResponse(results: ranked, snapshot: response.snapshot)
    }

    private func score(_ candidate: Work, works: [WorkID: Work]) -> [Int] {
        guard kind.includes(workKind: candidate.kind) else { return [0, 0, 0] }
        let expected = Self.normalized(title)
        guard !expected.isEmpty else { return [0, 0, 0] }
        let titleMatch: Int
        if Self.normalized(candidate.title) == expected { titleMatch = 2 }
        else if Self.recordingBaseTitle(candidate.title) == expected { titleMatch = 1 }
        else { return [0, 0, 0] }

        let artist = Self.normalized(candidate.creator)
        let artistMatch = !artist.isEmpty && artistNames.contains(where: { Self.normalized($0) == artist })
            ? 2 : (hintContains(candidate.creator) ? 1 : 0)
        let album = candidate.isAlbum ? candidate.title : candidate.linkedAlbumID.flatMap { works[$0]?.title } ?? ""
        let releaseMatch = !album.isEmpty && releaseTitles.contains(where: { Self.normalized($0) == Self.normalized(album) })
            ? 2 : (hintContains(album) ? 1 : 0)
        // Once a title matches, the known performer matters more than whether
        // the title carries a live/version suffix. A namesake by another artist
        // must not displace this artist's alternate recording.
        return [artistMatch, titleMatch, releaseMatch]
    }

    private func hintContains(_ name: String) -> Bool {
        let name = Self.normalized(name)
        guard !name.isEmpty, let editorialQueryHint else { return false }
        // A complete candidate name appearing in an editor's search hint is
        // weaker than a structured creator/album link. Do not split arbitrary
        // prose into asserted metadata or use this signal for entity merging.
        return (" " + Self.normalized(editorialQueryHint) + " ").contains(" " + name + " ")
    }

    private static func recordingBaseTitle(_ title: String) -> String? {
        // Only recognize a recording/version annotation. A related composition
        // such as LOTUS-2 or Lotus Flower must not count as the same title.
        let delimiters = [" (", " [", "（", "【", " - "]
        let ranges = delimiters.compactMap { title.range(of: $0) }
        guard let boundary = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let suffix = " " + normalized(String(title[boundary.upperBound...])) + " "
        let versionWords = ["live", "remaster", "remastered", "remix", "acoustic", "demo", "instrumental", "edit", "mono", "stereo", "ライブ", "ライヴ", "リマスター"]
        guard versionWords.contains(where: { suffix.contains(" " + $0 + " ") }) else { return nil }
        return normalized(String(title[..<boundary.lowerBound]))
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
