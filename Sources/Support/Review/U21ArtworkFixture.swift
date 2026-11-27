#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Explicit, isolated visual replay of late artwork metadata and the next song.
/// This uses the actual hero/lamp/sleeve views; no music or model is requested.
struct U21ArtworkFixture: View {
    @State private var phase = 0
    var body: some View {
        GeometryReader { geo in
            let id = WorkID(rawValue: phase < 2 ? "local:u21-first" : "local:u21-next")!
            let source = phase == 0 ? "pool" : phase == 1 ? "https://127.0.0.1:9/u21-late-cover.jpg" : "jane"
            let entity = SeedGraph.Entity(id: id.rawValue, kind: .song, title: phase < 2 ? "in the pool" : "JANE DOE", subtitle: "", artworkAsset: source, fallbackGlyph: nil, hook: "", actions: [])
            ZStack(alignment: .topLeading) {
                ShopStyle.base
                ShopHeroScene(heroPart: "lp", heroEntity: entity, catalogID: id,
                    k: geo.size.width / ShopPlates.plateWidth, r: geo.size.width / 402,
                    showsPlaying: true, reduceMotion: true)
                VStack {
                    Spacer()
                    Text(String(phase)).accessibilityIdentifier("u21-cover-phase")
                    Button("更新封面地址") { phase = 1 }.accessibilityIdentifier("u21-cover-enrich")
                    Button("下一首") { phase = 2 }.accessibilityIdentifier("u21-cover-next")
                }
                .foregroundStyle(.white).padding(32).frame(maxWidth: .infinity)
            }
        }.ignoresSafeArea()
    }
}
#endif
