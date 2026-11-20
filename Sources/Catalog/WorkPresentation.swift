import Foundation

/// Display names can follow a verified local article without renaming the
/// catalog identity, its credits, recordings, or source labels.
enum WorkPresentation {
    static func title(for work: Work, context: WorkContext?) -> String {
        guard work.id.rawValue.hasPrefix("wikidata:"),
              let qid = work.knowledgeID, context?.qid == qid,
              context?.article?.qid == qid, context?.displayTitleSource != nil,
              let title = context?.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return work.title }
        return title
    }

    static func detail(for work: Work) -> String {
        // The Chinese interface need not repeat an English database gloss such
        // as "2021 film directed by ...". The verified type remains available.
        guard work.id.rawValue.hasPrefix("wikidata:"),
              work.detail.range(of: "[A-Za-z]", options: .regularExpression) != nil,
              work.detail.range(of: "\\p{Han}", options: .regularExpression) == nil else { return work.detail }
        return work.kind
    }
}

extension WorkID {
    @MainActor var displayTitle: String {
        let item = work
        let context = item.knowledgeID.flatMap { WorkContextStore.shared.values[$0] }
        return SongTitlePresentation(WorkPresentation.title(for: item, context: context), isSong: item.isSong).title
    }
    @MainActor var displayDetail: String { WorkPresentation.detail(for: work) }
}
