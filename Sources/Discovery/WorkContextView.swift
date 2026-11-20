import SwiftUI

/// Compact source material supplements, rather than replaces, the relationship
/// journey. Every external destination is named as its actual provider.
struct WorkContextView: View {
    let id: WorkID
    var showsIntroduction = true
    var showsDestinations = true
    @Environment(Library.self) private var library
    @State private var store = WorkContextStore.shared
    private var qid: String? { id.work.knowledgeID }
    private var context: WorkContext? { qid.flatMap { store.values[$0] } }
    private var entityLinks: [String: WorkID] {
        ContextEntityLinks.make(current: id.work,
                                neighbors: Relations.displayEdges(for: id).map { $0.other(than: id).work })
    }

    var body: some View {
        WorkContextContent(context: context, entityLinks: entityLinks, error: showsIntroduction ? qid.flatMap { store.errors[$0] } : nil,
                           showsIntroduction: showsIntroduction, showsDestinations: showsDestinations, retry: {
            guard let qid else { return }
            Task { await store.load(qid, retry: true) }
        })
    }
}

struct WorkContextContent: View {
    let context: WorkContext?
    var entityLinks: [String: WorkID] = [:]
    var error: String?
    var showsIntroduction = true
    var showsDestinations = true
    var retry: () -> Void = {}
    @Environment(Library.self) private var library
    @State private var expanded = false
    @State private var selectedEvidence: EvidenceSelection?
    @State private var fullHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    private var style: VisualDirection { library.visualDirection }
    private var visibleDestinations: [WorkDestination] {
        showsDestinations ? (context?.destinations ?? []).filter { URL(string: $0.url) != nil } : []
    }
    private var visibleEditions: [EditionDestination] {
        showsDestinations ? (context?.editions ?? []).filter { URL(string: $0.destination.url) != nil } : []
    }
    private var hasVisibleContent: Bool {
        if error != nil || !visibleDestinations.isEmpty || !visibleEditions.isEmpty { return true }
        guard showsIntroduction, let context else { return false }
        return !context.facts.isEmpty || (context.introduction != nil && context.introductionSource != nil)
    }
    private struct EvidenceSelection: Identifiable {
        let id = UUID()
        let source: Source
        var claim: String?
        var licenseNote: String?
    }

    var body: some View {
        Group {
            if hasVisibleContent {
                VStack(alignment: .leading, spacing: 16) {
                    if let context {
                        if showsIntroduction, !context.facts.isEmpty {
                            HStack(spacing: 16) {
                                ForEach(context.facts) { fact in
                                    Button(fact.value) {
                                        selectedEvidence = .init(source: fact.source, claim: fact.label + " · " + fact.value)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.subheadline).foregroundStyle(style.secondary)
                                    .accessibilityLabel(fact.label + "，" + fact.value + "，查看出处")
                                }
                            }
                        }
                        if showsIntroduction, let text = context.introduction, let source = context.introductionSource {
                            let excerpt = context.readingExcerpt ?? text
                            let displayText = expanded ? text : excerpt
                            VStack(alignment: .leading, spacing: 10) {
                                Text(context.language == "en" ? "简介 · 英文" : "简介")
                                    .font(.title3.weight(.semibold))
                                EntityLinkedText(displayText, entities: entityLinks)
                                    .font(.body).lineSpacing(5)
                                    .lineLimit(expanded ? nil : 4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                                    .background(alignment: .topLeading) {
                                        EntityLinkedText(displayText, entities: entityLinks)
                                            .font(.body).lineSpacing(5)
                                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                            .hidden().accessibilityHidden(true)
                                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                                    }
                                if expanded || excerpt != text || fullHeight > visibleHeight + 1 {
                                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                                        .font(.subheadline).foregroundStyle(style.accent)
                                        .frame(minHeight: 44, alignment: .leading)
                                        .accessibilityLabel(expanded ? "收起简介" : "展开完整简介")
                                }
                                Button {
                                    selectedEvidence = .init(source: source, claim: text,
                                        licenseNote: excerpt == text ? "导语摘录" : "导语摘录，省略了标题后的外文别名；展开可读原文。")
                                } label: {
                                    Label("维基百科", systemImage: "text.quote")
                                        .font(.caption).foregroundStyle(style.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("简介来源与许可")
                            }
                        }
                        if !visibleDestinations.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { destinationLinks(visibleDestinations) }
                                VStack(alignment: .leading, spacing: 12) { destinationLinks(visibleDestinations) }
                            }
                        }
                        if !visibleEditions.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(visibleEditions) { edition in
                                    if let url = URL(string: edition.destination.url) {
                                        Link(destination: url) { Label(edition.destination.title, systemImage: "arrow.up.right") }
                                            .buttonStyle(.glass).font(.subheadline)
                                            .contextMenu {
                                                Button("版本资料") {
                                                    selectedEvidence = .init(source: edition.destination.source,
                                                        claim: edition.destination.title)
                                                }
                                                Button("原作对应关系") {
                                                    selectedEvidence = .init(source: edition.correspondenceSource,
                                                        claim: [context.displayTitle, edition.destination.title].compactMap { $0 }.joined(separator: " · "))
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    if let error {
                        HStack {
                            Text(error).font(.footnote).foregroundStyle(style.secondary)
                            Button("重试", action: retry)
                                .font(.footnote).frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedEvidence) { evidence in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SourceEvidenceView(source: evidence.source, claim: evidence.claim)
                        if let note = evidence.licenseNote {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                            Link("CC BY-SA 4.0", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                                .font(.footnote)
                        }
                    }.padding(22)
                }
                .navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { selectedEvidence = nil }
                    }
                }
            }.presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func destinationLinks(_ links: [WorkDestination]) -> some View {
        ForEach(links) { link in
            if let url = URL(string: link.url) {
                Link(destination: url) { Label(link.title, systemImage: "arrow.up.right") }
                    .buttonStyle(.glass).font(.subheadline)
                    .contextMenu {
                        Button("查看链接出处") {
                            selectedEvidence = .init(source: link.source, claim: link.title + "\n" + link.url)
                        }
                    }
            }
        }
    }
}
