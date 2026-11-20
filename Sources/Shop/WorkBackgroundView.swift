import SwiftUI

/// Short, attributed source excerpts. These are never labelled generated stories.
struct WorkBackgroundView: View {
    let id: WorkID
    @Environment(Library.self) private var library
    @State private var contexts = WorkContextStore.shared
    @State private var backgrounds = WorkBackgroundStore.shared
    @State private var continuation = BackgroundContinuationSelection()
    @State private var activePreparationRequest: BackgroundContinuationRequest?
    private var checkpoint: ReadingCheckpoint? {
        library.checkpoints[library.catalog.canonicalID(for: id).rawValue]
    }
    private var showsMore: Bool { checkpoint?.backgroundExpanded == true }
    private var article: WikiArticleIdentity? {
        id.work.knowledgeID.flatMap { contexts.values[$0]?.article }
    }
    private var response: WorkBackgroundResponse? {
        article.flatMap { backgrounds.values[$0.cacheKey] }
    }
    private var hasVisibleContent: Bool {
        !(response?.excerpts.isEmpty ?? true) || article.flatMap { backgrounds.errors[$0.cacheKey] } != nil
    }
    private var firstExcerpt: WorkBackgroundExcerpt? { response?.excerpts.first }
    private var defaultSecond: WorkBackgroundExcerpt? {
        response?.excerpts.prefix(2).dropFirst().first { $0.id != firstExcerpt?.id }
    }
    private var availableSeconds: [WorkBackgroundExcerpt] {
        guard let response, let first = response.excerpts.first else { return [] }
        var seen: Set<String> = [first.id]
        return (Array(response.excerpts.prefix(2)) + Array((response.retainedContinuationCandidates ?? []).prefix(4))
                + Array((response.continuationCandidates ?? []).prefix(4)))
            .filter { seen.insert($0.id).inserted }
    }
    private var fixedSecond: WorkBackgroundExcerpt? {
        guard let savedID = checkpoint?.backgroundSecondExcerptID else { return nil }
        // A saved choice is valid only within this response. An old revision,
        // or a now-first excerpt, must never lend its body to the current page.
        return availableSeconds.first { $0.id == savedID }
    }
    private var continuationRequest: BackgroundContinuationRequest? {
        guard let first = firstExcerpt, let second = defaultSecond else { return nil }
        return .init(first: first, second: second, candidates: Array((response?.continuationCandidates ?? []).prefix(4)),
                     excludedQIDs: displayedQIDs,
                     originalCandidates: Array((response?.retainedContinuationCandidates ?? []).prefix(4)))
    }
    private var secondIsReady: Bool {
        if fixedSecond != nil { return true }
        guard let request = continuationRequest, activePreparationRequest == request else { return false }
        return continuation.hasPrepared
    }

    // DynamicWorkContent displays this exact neighbor collection below the
    // background cards. Existing destinations should not consume new slots.
    private var displayedQIDs: Set<String> {
        var ids = Set(Relations.displayEdges(for: id).compactMap { $0.other(than: id).work.knowledgeID })
        if let qid = article?.qid { ids.insert(qid) }
        return ids
    }

    var body: some View {
        Group {
            if hasVisibleContent {
                VStack(alignment: .leading, spacing: 22) {
                    if let first = firstExcerpt {
                        WorkBackgroundCard(excerpt: first, excludedQIDs: displayedQIDs)
                            .id(first.id)
                        if showsMore, let second = fixedSecond ?? defaultSecond {
                            WorkBackgroundCard(excerpt: second, excludedQIDs: displayedQIDs,
                                               showsHeading: second.heading != first.heading)
                                .id(second.id)
                        }
                        if fixedSecond != nil || defaultSecond != nil {
                            Button(action: toggleExpanded) {
                                HStack(spacing: 8) {
                                    Text(showsMore ? "收起" : "再读一段")
                                    if !secondIsReady {
                                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                                    }
                                }
                            }
                                .font(.subheadline)
                                .foregroundStyle(library.visualDirection.accent)
                                .frame(minHeight: 44, alignment: .leading)
                                .accessibilityIdentifier("background-more")
                                .accessibilityValue(secondIsReady ? "已就绪" : "正在准备")
                        }
                    }
                    if let article, let error = backgrounds.errors[article.cacheKey] {
                        HStack {
                            Text(error).font(.footnote).foregroundStyle(library.visualDirection.secondary)
                            Button("重试") { Task { await backgrounds.load(article, retry: true) } }
                                .font(.footnote).frame(minHeight: 44)
                        }
                    }
                }
                // This is attached to a visible content container, not the
                // empty conditional Group; the first excerpt renders immediately.
                .task(id: continuationRequest) {
                    guard let request = continuationRequest else {
                        continuation.cancel()
                        activePreparationRequest = nil
                        return
                    }
                    // Expanded legacy checkpoints have already shown the default
                    // second account. Freeze it before any asynchronous lookup.
                    if showsMore, fixedSecond == nil {
                        library.setBackgroundExpanded(id, expanded: true, secondID: request.second.id)
                    }
                    guard fixedSecond == nil else {
                        continuation.cancel()
                        activePreparationRequest = nil
                        return
                    }
                    activePreparationRequest = request
                    await continuation.prepare(request)
                }
                .onDisappear {
                    continuation.cancel()
                    activePreparationRequest = nil
                }
            }
        }
    }

    private func toggleExpanded() {
        if showsMore {
            library.setBackgroundExpanded(id, expanded: false)
            return
        }
        let preparedID = secondIsReady ? continuation.preparedSecondID : nil
        let prepared = availableSeconds.first { $0.id == preparedID }
        guard let second = fixedSecond ?? prepared ?? defaultSecond else { return }
        library.setBackgroundExpanded(id, expanded: true, secondID: second.id)
        // Clicking before preparation finishes commits the default immediately.
        // A late result or subsequent graph update cannot replace what was read.
        continuation.cancel()
        activePreparationRequest = nil
    }
}

struct WorkBackgroundCard: View {
    let excerpt: WorkBackgroundExcerpt
    var excludedQIDs: Set<String> = []
    var showsHeading = true
    @Environment(Library.self) private var library
    @State private var sourcePresented = false
    @State private var selection = BackgroundReferenceSelection()
    @State private var referenceAttempt = 0
    @State private var openingTask: Task<Void, Never>?
    private var request: BackgroundReferenceRequest {
        .init(sourceID: excerpt.id, candidates: excerpt.references ?? [], excludedQIDs: excludedQIDs)
    }
    private struct LoadKey: Hashable {
        let request: BackgroundReferenceRequest
        let attempt: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeading {
                Text(excerpt.heading + (excerpt.language == "en" ? " · 英文" : ""))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(excerpt.body)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("background-excerpt-\(excerpt.id)")
            if !selection.references.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(selection.references) { reference in
                            Button { open(reference) } label: {
                                HStack(spacing: 7) {
                                    Text(reference.article.label)
                                    if selection.openingID == reference.id {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.right").font(.caption2)
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(library.visualDirection.accent)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("background-reference-" + reference.qid)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if selection.hasFailures {
                Button("重新载入关联条目") { referenceAttempt += 1 }
                    .disabled(selection.isLoading)
                    .font(.footnote).foregroundStyle(library.visualDirection.secondary)
                    .frame(minHeight: 44)
            }
            if let openingError = selection.openingError {
                Text(openingError).font(.footnote).foregroundStyle(library.visualDirection.secondary)
            }
            Button { sourcePresented = true } label: {
                Label("维基百科", systemImage: "text.quote")
                    .font(.caption).foregroundStyle(library.visualDirection.secondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("创作资料来源与原段落")
            .sheet(isPresented: $sourcePresented) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(excerpt.sourceParagraph).font(.body).lineSpacing(5).textSelection(.enabled)
                            SourceEvidenceView(source: excerpt.source)
                            Text(excerpt.source.detail.hasPrefix("导语摘录")
                                 ? "导语摘录，保留原句；原段落与版本见来源。"
                                 : "章节摘录，保留原句；原段落与版本见来源。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Link("CC BY-SA 4.0", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                                .font(.footnote)
                        }.padding(22)
                    }
                    .navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sourcePresented = false } } }
                }.presentationDetents([.medium, .large])
            }
        }
        .task(id: LoadKey(request: request, attempt: referenceAttempt)) {
            await selection.load(request)
        }
        .onDisappear {
            selection.cancel()
            openingTask?.cancel(); openingTask = nil
        }
    }

    private func open(_ reference: ResolvedBackgroundReference) {
        openingTask?.cancel()
        let tab = library.tab
        let path = library.path
        let collectionPath = library.collectionPath
        let reading = library.reading
        openingTask = Task { @MainActor in
            await selection.open(reference, load: { qid in
                try await library.catalog.openKnowledgeCandidate(qid)
            }, isCurrent: {
                library.tab == tab && library.path == path
                    && library.collectionPath == collectionPath && library.reading == reading
            }, navigate: { library.open($0) })
        }
    }
}
