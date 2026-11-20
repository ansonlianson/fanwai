import SwiftUI

/// Existing identity typography, with ordinary navigation rather than a crate zoom.
struct DiscoveryContextRow: View {
    let entityID: String
    var onOpen: (StoryTextLinks.Target) -> Void
    @Environment(Library.self) private var library
    var body: some View {
        if let context = DiscoveryNavigation.context(from: entityID, catalog: library.catalog,
            provider: nil) {
            let current = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(entityID)))
            let sameName = DiscoveryNavigation.sameTitle(current, context.work)
            let text = context.isMembership ? "属于" + DiscoveryPathPresentation.quoted(context.work.title)
                : !sameName ? "演奏" + DiscoveryPathPresentation.quoted(context.work.title) + (context.otherVersions > 0 ? " · 另有 \(context.otherVersions) 个版本" : "")
                : context.otherVersions > 0 ? "另有 \(context.otherVersions) 个版本" : ""
            if !text.isEmpty {
                Button { onOpen(.init(name: context.work.title, entityID: context.work.id.rawValue)) } label: {
                    HStack(spacing: 4) { Text(text); Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)) }
                }.buttonStyle(.plain)
                .font(.system(size: 12)).foregroundStyle(ArtworkPalette.tx3)
                .lineLimit(1).truncationMode(.middle).accessibilityIdentifier("discovery-context")
            }
        }
    }
}
