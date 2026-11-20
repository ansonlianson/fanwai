import SwiftUI

/// Developer-only inventory, opened explicitly with -designGallery.
struct DesignGallery: View {
    private let graph = SeedGraph.bundled
    private let palettes = ["pool", "jane", "utada"]
    private var examples: [SeedGraph.Entity] {
        ["pool", "film", "manga"].compactMap { graph[$0] } + [
            .init(id: "novel", kind: .book, title: "红辣椒", subtitle: "筒井康隆", artworkAsset: "design-novel", fallbackGlyph: nil, hook: "", actions: [])
        ] + ["utada", "animenzv"].compactMap { graph[$0] }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("设计系统").font(.title2.bold())
                ForEach(palettes, id: \.self) { id in
                    let entity = graph[id]!
                    let palette = ArtworkPalette.asset(entity.artworkAsset)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(entity.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            ForEach(0..<3) { i in
                                Circle().fill([palette.bg.color, palette.bg2.color, palette.ac.color][i])
                                    .frame(width: 16, height: 16)
                            }
                        }
                        inventory(palette: palette, missing: false)
                        inventory(palette: palette, missing: true)
                        ObjectLabel(relation: "配乐出自", title: "电锯人 蕾塞篇")
                    }
                    .padding(12).background(palette.bg.color, in: .rect(cornerRadius: 14))
                }
            }.padding(.horizontal, 22).padding(.vertical, 16)
        }
        .foregroundStyle(ArtworkPalette.tx)
        .background(ArtworkBackdrop(artwork: "pool", palette: .asset("pool")))
        .preferredColorScheme(.dark)
        .task { DesignFonts.shared.prepare() }
        .accessibilityIdentifier("design-gallery")
    }
    private func inventory(palette: ArtworkPalette, missing: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(examples) { entity in
                VStack(alignment: .leading, spacing: 5) {
                    PhysicalObject(kind: entity.kind, title: entity.title, subtitle: entity.subtitle,
                                   artwork: missing ? nil : entity.artworkAsset,
                                   scale: 0.60, palette: palette, isPlaying: entity.id == "pool" && !missing)
                        .frame(height: 51, alignment: .bottom)
                    Text(missing ? "无图" : entity.kind.rawValue).font(.system(size: 10)).foregroundStyle(ArtworkPalette.tx2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
