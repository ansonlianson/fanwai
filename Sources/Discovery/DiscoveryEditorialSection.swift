import SwiftUI

/// Existing sourced editorial leads the page. Linked names retain their exact
/// catalog identities; the optional graph shortcut appears only once.
struct DiscoveryEditorialSection: View {
    let id: WorkID
    let stories: [EditorialStory]
    var showsConnections = false
    @Environment(Library.self) private var library
    @State private var selectedSourceStory: EditorialStory?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(stories.enumerated()), id: \.element.id) { index, story in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(story.title)
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index == 0 && showsConnections {
                            NavigationLink(value: Route.connections(id)) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.body)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("关系图")
                        }
                    }
                    EntityLinkedText(story.body, entities: story.entityLinks)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(library.visualDirection.accent)
                    Button { selectedSourceStory = story } label: {
                        Label(story.source.title, systemImage: "text.quote").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(library.visualDirection.secondary)
                    .accessibilityLabel(story.source.title + "，查看出处")
                }
            }
        }
        .sheet(item: $selectedSourceStory) { story in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(story.title).font(.title3.weight(.semibold))
                        SourceEvidenceView(source: story.source, claim: story.body)
                    }.padding(22)
                }
                .navigationTitle("来源").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { selectedSourceStory = nil }
                    }
                }
            }.presentationDetents([.medium, .large])
        }
    }
}
