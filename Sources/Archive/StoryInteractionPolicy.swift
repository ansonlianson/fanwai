import Foundation

@MainActor enum StoryInteractionPolicy {
    /// Names in a story are entry points (AHA-PLAN §5): tapping one offers to open, search
    /// or copy it. They never become relation cards and never start research. The page's
    /// own work is left plain; the 「提到 X 件作品」 index line stays gone.
    static func links(_ story: Story, subjectID: String?, library: Library) -> StoryTextLinks {
        let page = subjectID ?? story.entityID
        guard !page.isEmpty else { return StoryTextLinks(story: story) }
        let own = library.catalog.canonicalID(for: SeedLibraryBridge.workID(page))
        let work = library.catalog.work(own)
        let names = Set([work.title, work.discovery?.canonicalTitle ?? "", SongTitlePresentation(work.title, isSong: work.isSong).title]
            .map(LeadMatch.norm).filter { !$0.isEmpty })
        return StoryTextLinks(story: story, excludingNames: names, excludingEntities: [own.rawValue, page])
    }
    static func mentionsCaption(_ links: StoryTextLinks, library: Library) -> String {
        return ""
    }
}
