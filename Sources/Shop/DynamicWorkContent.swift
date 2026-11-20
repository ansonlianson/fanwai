import SwiftUI

struct DynamicWorkContent: View {
    let id: WorkID
    @Environment(Library.self) private var library
    @State private var contexts = WorkContextStore.shared
    @State private var backgrounds = WorkBackgroundStore.shared
    @State private var enrichmentFinishedFor: WorkID?
    private var related: [RelationEdge] { Relations.displayEdges(for: id) }
    private var stories: [EditorialStory] { library.catalog.stories.filter { $0.workID == id } }
    private var canonicalID: WorkID { library.catalog.canonicalID(for: id) }
    private var currentWork: Work { library.catalog.work(id) }
    private var context: WorkContext? { currentWork.knowledgeID.flatMap { contexts.values[$0] } }

    private var continuationState: WorkContinuationState {
        let catalog = library.catalog
        let catalogFailed = catalog.lookupErrors[canonicalID] != nil || catalog.knowledgeErrors[canonicalID] != nil
            || catalog.knowledgePartial.contains(canonicalID) || catalog.songDiscoveryErrors[canonicalID] != nil
        let catalogLoading = catalog.loading.contains(canonicalID) || catalog.knowledgeLoading.contains(canonicalID)
            || catalog.songDiscoveryLoading.contains(canonicalID)
        let catalogState: WorkContinuationState.LoadState = catalogFailed ? .failed
            : enrichmentFinishedFor != canonicalID || catalogLoading ? .pending : .succeeded
        let contextState: WorkContinuationState.LoadState
        let backgroundState: WorkContinuationState.LoadState
        var hasBackground = false
        if let qid = currentWork.knowledgeID {
            if contexts.errors[qid] != nil || context?.introductionUnavailable == true || context?.editionLookupUnavailable == true {
                contextState = .failed
            } else if contexts.loading.contains(qid) || context == nil {
                contextState = .pending
            } else {
                contextState = .succeeded
            }
            if let article = context?.article {
                let response = backgrounds.values[article.cacheKey]
                hasBackground = !(response?.excerpts.isEmpty ?? true)
                if backgrounds.errors[article.cacheKey] != nil { backgroundState = .failed }
                else if backgrounds.loading.contains(article.cacheKey) || response?.article != article { backgroundState = .pending }
                else { backgroundState = .succeeded }
            } else {
                // A completed context with no article has no background source
                // to request. Missing/failed context must remain non-empty-state.
                backgroundState = contextState
            }
        } else {
            contextState = .succeeded
            backgroundState = .succeeded
        }
        let moreStatus = catalog.knowledgeMoreStatus(for: id)
        let hasMoreWorks = moreStatus == .unqueried || moreStatus == .more || moreStatus == .limited
            || catalog.knowledgeMoreLoading.contains(canonicalID) || catalog.knowledgeMoreErrors[canonicalID] != nil
        // These actions are already displayed by WorkPage/HeroPanel. Provider
        // links such as Wikipedia and Douban are not new discovery destinations.
        let hasOtherEntry = currentWork.canFindCatalogVersion || hasMoreWorks
            || (Work.seeds[id] == nil && currentWork.knowledgeID == nil)
        return WorkContinuationState(catalog: catalogState, context: contextState, background: backgroundState,
                                     hasRelations: !related.isEmpty, hasEditorial: !stories.isEmpty,
                                     hasBackgroundExcerpt: hasBackground, hasOtherEntryPoint: hasOtherEntry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !id.work.isVideo && !id.work.isSong && !id.work.canFindCatalogVersion {
                Button { library.toggleSaved(id) } label: {
                    Label(library.saved.contains(id) ? "已收藏" : ["电影", "电视剧", "演奏视频"].contains(id.work.kind) ? "想看" : ["书籍", "漫画", "文学作品"].contains(id.work.kind) ? "想读" : "收藏", systemImage: library.saved.contains(id) ? "checkmark" : "plus")
                }.buttonStyle(.glass).controlSize(.large)
            }
            if !stories.isEmpty {
                DiscoveryEditorialSection(id: id, stories: stories, showsConnections: !related.isEmpty)
            }
            WorkContextView(id: id, showsDestinations: false)
            if stories.isEmpty { WorkBackgroundView(id: id) }
            if !related.isEmpty {
                HStack {
                    Text("关联").font(.title2.bold()); Spacer()
                    if stories.isEmpty {
                        NavigationLink(value: Route.connections(id)) { Label("关系图", systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(.glass)
                    }
                }
                ForEach(related) { edge in
                    let other = edge.other(than: id)
                    if other.work.isSong { SongRow(id: other, subtitle: edge.label(from: id)) }
                    else {
                        NavigationLink(value: Route.work(other)) { EntityRow(id: other, relation: edge.label(from: id), showsChevron: true) }
                            .buttonStyle(.plain).accessibilityIdentifier("work-link-\(other.rawValue)")
                    }
                }
            }
            WorkContextView(id: id, showsIntroduction: false)
            if library.catalog.loading.contains(id) || library.catalog.knowledgeLoading.contains(id) || library.catalog.songDiscoveryLoading.contains(id) {
                HStack { ProgressView(); Text("正在查找关联").font(.subheadline).foregroundStyle(.secondary) }
            } else if let error = library.catalog.lookupErrors[id] ?? library.catalog.knowledgeErrors[id] ?? library.catalog.songDiscoveryErrors[id] {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("重试") { Task { await library.catalog.enrich(id, retry: true) } }.buttonStyle(.glass)
                }
            } else if continuationState.offersAnotherStartingPoint {
                Button("换个起点", systemImage: "safari") {
                    library.discoveryExcludedID = canonicalID
                    library.discoveryPresented = true
                }
                    .buttonStyle(.glass).controlSize(.large)
                    .accessibilityIdentifier("work-empty-discovery-\(id.rawValue)")
            }
            if library.catalog.knowledgeMoreStatus(for: id) == nil,
               library.catalog.knowledgePartial.contains(id), let qid = id.work.knowledgeID,
               let url = URL(string: "https://www.wikidata.org/wiki/\(qid)") {
                Link("查看完整资料", destination: url).font(.footnote).foregroundStyle(.secondary)
            }
            if let url = id.work.url.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label(id.work.externalLinkTitle, systemImage: "arrow.up.right")
                }.font(.subheadline).padding(.vertical, 8)
            }
        }
        .task(id: id) {
            guard !library.demoMode else { return }
            enrichmentFinishedFor = nil
            await library.catalog.enrich(id)
            guard !Task.isCancelled else { return }
            enrichmentFinishedFor = library.catalog.canonicalID(for: id)
        }
        // Loading belongs to this stable parent. An empty conditional content
        // view has no mounted element on which SwiftUI can start a .task.
        .task(id: currentWork.knowledgeID) {
            guard !library.demoMode, let qid = currentWork.knowledgeID else { return }
            await contexts.load(qid)
        }
        .task(id: context?.article) {
            guard !library.demoMode, stories.isEmpty, let article = context?.article else { return }
            await backgrounds.load(article)
        }
    }
}
