import Foundation

/// This path has no model client or credential. A store result supplies a playback
/// address; an independently read source supplies the original's attribution.
struct OriginalRecordingLookup: Sendable {
    typealias ReadSource = @Sendable (String, ResearchTopic) async -> (sources: [ResearchSource], requests: Int)
    let catalog: any CatalogFetching
    var readSource: ReadSource = Self.readSource

    struct Result: Sendable {
        var snapshot = CatalogSnapshot(works: [], relations: [])
        var catalogRequests = 0
        var sourceRequests = 0
        var transientFailure = false
    }

    func resolve(topic: ResearchTopic, country: String, sources: [ResearchSource], sourceURL: String?) async -> Result {
        var result = Result(), sources = sources
        if sources.isEmpty, let sourceURL {
            let read = await readSource(sourceURL, topic)
            sources = read.sources; result.sourceRequests = read.requests
            if sources.isEmpty { result.transientFailure = true; return result }
        }
        guard !sources.isEmpty, !Task.isCancelled else { return result }
        do {
            result.catalogRequests = 1
            let name = RecordingVersion.searchTitle(topic.title)
            let response: CatalogResponse
            if let service = catalog as? ITunesCatalogService {
                response = try await service.searchCandidates(name, country: country, kind: .song)
            } else { response = try await catalog.search(name, country: country, kind: .song, recordingContext: nil) }
            try Task.checkCancellation()
            let works = Dictionary(response.snapshot.works.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let matches = response.results.compactMap { id -> (Work, Proof)? in
                guard let candidate = works[id], candidate.id.rawValue != topic.id,
                      candidate.isSong, candidate.appleMusicURL != nil, candidate.storeCountry == country,
                      ResearchMaterials.normalized(candidate.title) == ResearchMaterials.normalized(name),
                      !RecordingVersion.isDerivative(candidate.title),
                      !RecordingVersion.isDerivative(candidate.albumID.flatMap { works[$0]?.title } ?? ""),
                      let proof = Self.proof(candidate: candidate, topic: topic, sources: sources) else { return nil }
                return (candidate, proof)
            }
            // Conflicting original performers are uncertainty, not an invitation to pick the oldest.
            let artists = Set(matches.map { ResearchMaterials.normalized($0.0.creator) })
            guard artists.count == 1,
                  let (record, proof) = matches.sorted(by: {
                      ($0.0.releaseDate ?? "9999", $0.0.id.rawValue) < ($1.0.releaseDate ?? "9999", $1.0.id.rawValue)
                  }).first,
                  let root = WorkID(rawValue: topic.id) else { return result }
            let keep = Set([record.id] + record.creatorIDs + (record.albumID.map { [$0] } ?? []))
            var edges = response.snapshot.relations.filter { keep.contains($0.from) && keep.contains($0.to) }
            edges.append(.init(from: root, to: record.id,
                predicate: .coverOf,
                label: proof.selfPerformance ? "原版录音" : "原曲",
                inverseLabel: proof.selfPerformance ? "现场版本" : "翻唱版本",
                source: .init(title: "原版出处", detail: proof.quote, url: proof.source.url,
                              evidenceQuote: proof.quote), researchRoot: root))
            result.snapshot = .init(works: response.snapshot.works.filter { keep.contains($0.id) }, relations: edges)
        } catch { result.transientFailure = true }
        return result
    }

    struct Proof: Sendable { let source: ResearchSource; let quote: String; let selfPerformance: Bool }
    static func proof(candidate: Work, topic: ResearchTopic, sources: [ResearchSource]) -> Proof? {
        let song = RecordingVersion.searchTitle(topic.title)
        let artist = ResearchMaterials.normalized(candidate.creator)
        guard !artist.isEmpty else { return nil }
        let sameArtist = DiscoveryRecordingIdentity.sameCredits(candidate.creator, topic.creator)
        let releaseYear = candidate.releaseDate.flatMap { Int($0.prefix(4)) }
        for source in sources {
            guard ResearchMaterials.safeURL(source.url) != nil,
                  StorySourceDocument.containsName(source.title + "\n" + source.text, names: [song]),
                  StorySourceDocument.containsName(source.title + "\n" + String(source.text.prefix(1200)), names: [topic.creator])
                    || RecordingVersion.isFirstTake(source.title + " " + source.text) else { continue }
            // Keep the actual paragraph. Names merely sharing a long page cannot prove a version.
            for paragraph in source.text.components(separatedBy: .newlines) where !paragraph.isEmpty {
                let windows = localized(paragraph, name: song)
                for quote in windows {
                    let key = ResearchMaterials.normalized(quote)
                    guard key.contains(ResearchMaterials.normalized(song)) else { continue }
                    let explicitlyNamed = key.contains(artist)
                    let ownAttribution = sameArtist && StorySourceDocument.containsName(source.title, names: [topic.creator])
                    guard explicitlyNamed || ownAttribution else { continue }
                    let original = quote.range(of: #"(?i)原曲|原唱|原版|オリジナル|original(?:ly)?|first\s+(?:released|recorded)|デビューシングル"#, options: .regularExpression) != nil
                    let published = quote.range(of: #"(?i)(?:19|20)\d{2}年?[^。\n]{0,65}(?:リリース|発表|発売|发行|發行|released|recorded)|(?:リリース|発表|発売|发行|發行|released|recorded)[^。\n]{0,35}(?:19|20)\d{2}"#, options: .regularExpression) != nil
                    let groupCredit = quote.range(of: NSRegularExpression.escapedPattern(for: candidate.creator) + #"\s*(?:として|名義(?:で|の|として)?)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    let coverAttribution = quote.range(of: NSRegularExpression.escapedPattern(for: candidate.creator)
                        + #"\s*(?:の|による)[^。\n]{0,80}"# + NSRegularExpression.escapedPattern(for: song)
                        + #"[^。\n]{0,50}(?:をカバー|をカヴァー|翻唱)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    let candidateCovers = quote.range(of: NSRegularExpression.escapedPattern(for: candidate.creator)
                        + #"\s*(?:(?:が|は)[^。\n]{0,120}(?:カバー|カヴァー|翻唱)|(?:の|による)\s*(?:カバー|カヴァー|翻唱))"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
                    if !sameArtist && !groupCredit && candidateCovers { continue }
                    let originalCredit = explicitlyNamed && (original || published && (sameArtist || groupCredit) || coverAttribution)
                    guard originalCredit || ownAttribution && (original || published) else { continue }
                    // When the source supplies a release year, require that studio issue in the
                    // store. A later unmarked self re-recording must not become the default.
                    if published {
                        guard let releaseYear, quote.contains(String(releaseYear)) else { continue }
                    }
                    let selfCover = source.text.range(of: NSRegularExpression.escapedPattern(for: topic.creator)
                        + #"\s*[（(]?\s*(?:セルフ[・\s]?カバー|self[ -]?cover|自己翻唱)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    return .init(source: source, quote: quote,
                                 selfPerformance: sameArtist || groupCredit || selfCover)
                }
            }
        }
        return nil
    }
    private static func localized(_ paragraph: String, name: String) -> [String] {
        guard paragraph.count > 500 else { return [paragraph] }
        var output: [String] = [], start = paragraph.startIndex
        while start < paragraph.endIndex, output.count < 4,
              let found = paragraph.range(of: name, options: [.caseInsensitive, .widthInsensitive], range: start..<paragraph.endIndex) {
            let left = paragraph.index(found.lowerBound, offsetBy: -200, limitedBy: paragraph.startIndex) ?? paragraph.startIndex
            let right = paragraph.index(found.upperBound, offsetBy: 200, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
            output.append(String(paragraph[left..<right])); start = found.upperBound
        }
        return output
    }

    private static func readSource(_ address: String, topic: ResearchTopic) async -> (sources: [ResearchSource], requests: Int) {
        guard let normalized = ResearchMaterials.safeURL(address), let url = URL(string: normalized) else { return ([], 0) }
        let transport = StoryMaterialTransport(limit: 2)
        let page = await transport.page(url, purpose: "现场版原版署名", allowedHosts: [url.host ?? ""])
        let requests = await transport.audit().0.count
        guard let (data, finalURL) = page, let html = StorySourceDocument.decode(data),
              let document = try? StorySourceDocument.parse(html: html, url: finalURL,
                names: [RecordingVersion.searchTitle(topic.title)], neighbors: [], pageAnchored: true),
              !document.restricted else { return ([], requests) }
        return ([.init(id: "O1", url: finalURL.absoluteString, title: document.title,
                       publisher: finalURL.host ?? "", text: String(document.paragraphs.map(\.text).joined(separator: "\n").prefix(24_000)), purposes: [.lineage])], requests)
    }
}
