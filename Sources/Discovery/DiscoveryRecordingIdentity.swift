import Foundation

/// Names suggest a recording; complete credits and an edition identify it.
/// These rules are shared by model output, local reuse and store matching.
enum DiscoveryRecordingIdentity {
    static func sameCredits(_ a: String, _ b: String) -> Bool {
        let left = creditKeys(a), right = creditKeys(b)
        return !left.isEmpty && left == right
    }
    static func creditKeys(_ value: String) -> Set<String> {
        let separated = value.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|featuring|with)\s+"#, with: "、", options: .regularExpression)
        return Set(separated.components(separatedBy: CharacterSet(charactersIn: ",，、/／&＆;；"))
            .map { LeadMatch.norm(LeadMatch.foldSmallKana($0)) }.filter { !$0.isEmpty })
    }

    static func aliasesCurrent(_ identity: DiscoveryIdentity, creator: String, subject: LeadSubject) -> Bool {
        guard sameCredits(creator, subject.creator) else { return false }
        let release = identity.releaseTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentRelease = subject.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !release.isEmpty {
            guard !currentRelease.isEmpty,
                  RecordingCatalogMatch.albumKey(release) == RecordingCatalogMatch.albumKey(currentRelease) else { return false }
        }
        let edition = identity.edition
        let currentEdition = subject.identity?.edition.isEmpty == false ? subject.identity!.edition : currentRelease
        if !edition.isEmpty {
            guard !currentEdition.isEmpty, LeadMatch.same(edition, currentEdition, loose: false) else { return false }
        }
        // Missing edition data is uncertainty, not evidence that two names are
        // the current recording. Keep the independent node and its real edges.
        return !release.isEmpty || !edition.isEmpty
    }
}
