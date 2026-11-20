import SwiftUI

/// Search is an explicit choice of entity, never an automatic join by title.
struct KnowledgeSearchView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var candidates: [KnowledgeCandidate] = []
    @State private var loading = false
    @State private var opening: String?
    @State private var searched = false
    @State private var error: String?
    @State private var request = UUID()
    @State private var task: Task<Void, Never>?
    @State private var failedCandidate: KnowledgeCandidate?
    private let storySource: Source?
    private let initialName: String
    @State private var sourcePage: StorySourcePage?
    let onSelect: (WorkID) -> Void

    init(query: String, storySource: Source? = nil, onSelect: @escaping (WorkID) -> Void) {
        _query = State(initialValue: query); self.onSelect = onSelect
        self.storySource = storySource; initialName = query
    }

    var body: some View {
        NavigationStack {
            List {
                if let storySource, let url = URL(string: storySource.url) {
                    Section {
                        Text("选择故事里提到的作品或创作者").font(.subheadline).foregroundStyle(.secondary)
                        Button("原文：" + storySource.title) { sourcePage = .init(url: url) }
                    }
                }
                ForEach(candidates) { candidate in
                    Button { open(candidate) } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(candidate.title).font(.headline)
                                if !candidate.detail.isEmpty {
                                    Text(candidate.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if opening == candidate.qid { ProgressView() }
                            else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 10)
                        // Plain buttons otherwise leave the spacer and row
                        // padding outside their tappable content.
                        .contentShape(.rect)
                    }.buttonStyle(.plain).disabled(opening != nil)
                        .accessibilityIdentifier("knowledge-candidate-" + candidate.qid)
                }
                if loading { HStack { ProgressView(); Text("正在查找").foregroundStyle(.secondary) } }
                if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") {
                            if let candidate = failedCandidate { open(candidate) } else { search() }
                        }
                    }
                } else if searched && candidates.isEmpty && !loading {
                    ContentUnavailableView.search(text: query)
                } else if !searched && !query.isEmpty {
                    Button("查找", systemImage: "magnifyingglass") { search() }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(library.visualDirection.background)
            .navigationTitle(storySource == nil ? "查找关联" : "查找「" + initialName + "」").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "作品或创作者原名")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, _ in
                task?.cancel(); request = UUID(); loading = false; opening = nil
                searched = false; candidates = []; error = nil; failedCandidate = nil
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark") { dismiss() } } }
            .task { if !searched { search() } }
            .onDisappear { task?.cancel(); request = UUID() }
            .sheet(item: $sourcePage) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
        }
    }

    private func search() {
        task?.cancel(); let token = UUID(); request = token
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        loading = true; searched = true; opening = nil; error = nil; candidates = []; failedCandidate = nil
        task = Task { @MainActor in
            do {
                let result = try await library.catalog.knowledgeService.searchCandidates(term)
                try Task.checkCancellation()
                guard request == token else { return }
                candidates = result
            } catch { if request == token && !Task.isCancelled { self.error = KnowledgeError.message(error) } }
            if request == token && !Task.isCancelled { loading = false }
        }
    }

    private func open(_ candidate: KnowledgeCandidate) {
        guard opening == nil else { return }
        task?.cancel(); let token = UUID(); request = token
        opening = candidate.qid; error = nil; failedCandidate = nil
        task = Task { @MainActor in
            do {
                let id = try await library.catalog.openKnowledgeCandidate(candidate.qid)
                try Task.checkCancellation()
                guard request == token else { return }
                onSelect(id)
            } catch {
                if request == token && !Task.isCancelled {
                    self.error = KnowledgeError.message(error); failedCandidate = candidate
                }
            }
            if request == token && !Task.isCancelled { opening = nil }
        }
    }
}

struct KnowledgeProgress: View {
    let id: WorkID
    @Environment(Library.self) private var library
    var body: some View {
        if library.catalog.knowledgeLoading.contains(id) {
            HStack { ProgressView(); Text("正在查找关联").font(.subheadline).foregroundStyle(.secondary) }
        } else if let message = library.catalog.knowledgeErrors[id] {
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await library.catalog.expandKnowledge(id, retry: true) } }.buttonStyle(.glass)
            }
        } else if library.catalog.knowledgeMoreStatus(for: id) == nil,
                  library.catalog.knowledgePartial.contains(id), let qid = id.work.knowledgeID,
                  let url = URL(string: "https://www.wikidata.org/wiki/\(qid)") {
            Link("查看完整资料", destination: url).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
