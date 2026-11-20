import SwiftUI

struct SourcesView: View {
    let id: WorkID
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @State private var artworkStore = WorkArtworkStore.shared
    private var work: Work { library.catalog.work(library.catalog.canonicalID(for: id)) }
    private var artwork: WorkArtwork? { artworkStore.metadata(for: work) }
    var sources: [Source] {
        var values = Relations.sources(for: id)
        if let source = id.work.knowledgeIdentitySource, !values.contains(where: { $0.id == source.id }) { values.append(source) }
        return values
    }
    private func claims(for source: Source) -> String {
        let relations = Relations.forEntity(id).filter { $0.source.id == source.id }.map {
            id.displayTitle + " · " + $0.label(from: id) + " · " + $0.other(than: id).displayTitle
        }
        let stories = library.catalog.stories.filter { $0.workID == id && $0.source.id == source.id }.map(\.body)
        let values = relations + stories
        return values.isEmpty ? id.displayTitle : values.joined(separator: "\n\n")
    }
    private func evidence(_ source: Source, claim: String) -> some View {
        ScrollView { SourceEvidenceView(source: source, claim: claim).padding(22) }
            .navigationTitle("出处").navigationBarTitleDisplayMode(.inline)
    }
    var body: some View {
        NavigationStack {
            List {
                if let artwork {
                    Section("封面") {
                        NavigationLink("图片来源") {
                            evidence(Source(title: "图片来源", detail: artwork.credit ?? "", url: artwork.sourcePageURL),
                                     claim: id.displayTitle + " · 封面")
                        }.accessibilityIdentifier("artwork-source-entry")
                        if let artist = artwork.artist { Text(artist).font(.subheadline) }
                        if let credit = artwork.credit, credit != artwork.artist { Text(credit).font(.subheadline) }
                        if let name = artwork.licenseName {
                            if let raw = artwork.licenseURL, let url = URL(string: raw) { Link(name, destination: url) }
                            else { Text(name).font(.footnote).foregroundStyle(.secondary) }
                        }
                        if artwork.isNonFree == true {
                            Text("非自由图片").font(.footnote).foregroundStyle(.secondary)
                        }
                        NavigationLink("所属条目") {
                            evidence(Source(title: "所属条目", detail: "", url: artwork.articleURL), claim: id.displayTitle + " · 封面所属条目")
                        }
                    }
                }
                if let qid = id.work.knowledgeID, artworkStore.errors[qid] != nil {
                    Button("重新载入图片资料") { Task { await artworkStore.load(qid, retry: true) } }
                }
                ForEach(sources) { source in
                        NavigationLink {
                            evidence(source, claim: claims(for: source))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(source.title).font(.headline)
                                    Text(source.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                        }
                }
            }
            .navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: id.work.knowledgeID) {
                guard !library.demoMode, id.work.art.isEmpty,
                      ["电影", "电视剧"].contains(id.work.kind), let qid = id.work.knowledgeID else { return }
                await artworkStore.load(qid)
            }
        }
    }
}

