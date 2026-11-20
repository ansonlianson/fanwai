import SwiftUI

struct MoreWorksView: View {
    let id: WorkID
    @Environment(Library.self) private var library

    var body: some View {
        if let status = library.catalog.knowledgeMoreStatus(for: id) {
            MoreWorksControl(status: status,
                             loading: library.catalog.knowledgeMoreLoading.contains(id),
                             error: library.catalog.knowledgeMoreErrors[id],
                             sourceURL: id.work.knowledgeID.flatMap { URL(string: "https://www.wikidata.org/wiki/\($0)") }) {
                Task { await library.catalog.loadMoreKnowledge(id) }
            }
        }
    }
}

/// Shared by the work page, the final map group, and the bottom of the list.
/// Loading never replaces the existing neighbors or changes the current center.
struct MoreWorksControl: View {
    let status: KnowledgeMoreStatus
    var loading = false
    var error: String?
    var sourceURL: URL?
    var load: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在查找").font(.subheadline).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试", systemImage: "arrow.clockwise", action: load)
                    .buttonStyle(.glass).controlSize(.large)
            } else {
                switch status {
                case .unqueried, .more:
                    Button("更多作品", systemImage: "plus", action: load)
                        .buttonStyle(.glass).controlSize(.large)
                        .accessibilityHint("继续查找这位创作者的作品")
                case .exhausted:
                    Text("暂时没有更多作品").font(.footnote).foregroundStyle(.secondary)
                case .limited:
                    if let sourceURL {
                        Link("更多资料", destination: sourceURL)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
