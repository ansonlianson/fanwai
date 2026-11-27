import SwiftUI
import UIKit

/// The lamp and record keep their animation state in the hero alone. Their
/// staged updates never invalidate the article, crate inventory or page menu.
struct ShopHeroScene: View {
    let heroPart: String
    let heroEntity: SeedGraph.Entity
    let catalogID: WorkID
    let k: CGFloat
    let r: CGFloat
    let showsPlaying: Bool
    let reduceMotion: Bool
    @State private var light: Double = 0
    @State private var discOut = false
    @State private var lampTask: Task<Void, Never>?
    @State private var cover = ArtworkPresentation()

    var body: some View {
        scene
            .onAppear { light = showsPlaying ? 1 : 0; discOut = showsPlaying }
            .onChange(of: showsPlaying) { _, on in switchLamp(on) }
            .onDisappear { lampTask?.cancel() }
    }

    /// Layer order is fixed: wall → record → sleeve → ledge lip. Each layer has
    /// an unlit and a lit rendering, so the record stays behind the sleeve.
    /// While the lamp is on it also lights what a real spot would (ShopLampLight): a sheen on the
    /// vinyl under the sleeve, a glint on the sleeve, dust in the air in front of everything.
    @ViewBuilder private var scene: some View {
        if heroPart == "lp" {
            let tuck = discOut ? 0 : -74 * r
            let lp = ShopPlates.shared.main("lp")
            let follows = showsPlaying && !reduceMotion
            ZStack(alignment: .topLeading) {
                bgLayer("lp_paused")
                bgLayer("lp").opacity(light)
                slotLayer("lp_paused", "disc").offset(x: tuck)
                slotLayer("lp", "disc").opacity(light).offset(x: tuck)
                if let disc = lp?.slots["disc"] {
                    LampVinylSheen(disc: disc, k: k, light: light, shift: tuck, follows: follows).lampTilt(follows)
                }
                slotLayer("lp_paused", "hero")
                slotLayer("lp", "hero").opacity(light)
                if let hero = lp?.slots["hero"] { LampSleeveGlint(hero: hero, k: k, light: light, follows: follows) }
                frontLayer("lp_paused")
                frontLayer("lp").opacity(light)
                if !reduceMotion { LampDust(k: k, light: light, running: showsPlaying) }
            }
        } else {
            ZStack(alignment: .topLeading) {
                bgLayer(heroPart)
                slotLayer(heroPart, "hero")
                frontLayer(heroPart)
            }
        }
    }

    /// Playing warms the lamp before drawing the record out. Pausing returns
    /// the record before the lamp dims, preserving the existing staged timing.
    private func switchLamp(_ on: Bool) {
        lampTask?.cancel()
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { light = on ? 1 : 0; discOut = on }
            return
        }
        lampTask = Task { @MainActor in
            if on {
                withAnimation(.timingCurve(0.55, 0, 0.9, 0.35, duration: 0.16)) { light = 0.62 }
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.42)) { light = 1 }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.75, dampingFraction: 0.85)) { discOut = true }
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.92)) { discOut = false }
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.1)) { light = 0.3 }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.1, 0.6, 0.3, 1, duration: 0.9)) { light = 0 }
            }
        }
    }

    @ViewBuilder private func bgLayer(_ name: String) -> some View {
        if let manifest = ShopPlates.shared.main(name), let background = manifest.bg {
            ShopLayerImage(image: ShopPlates.shared.image(name, background),
                frame: CGRect(x: 0, y: 0, width: manifest.size[0], height: manifest.size[1]), k: k)
        }
    }
    @ViewBuilder private func frontLayer(_ name: String) -> some View {
        if let front = ShopPlates.shared.main(name)?.front {
            ShopLayerImage(image: ShopPlates.shared.image(name, front.over), frame: front.frame.rect, k: k)
        }
    }
    /// A cover and its photographed shell are drawn together, so the lit copy
    /// fully covers the unlit one at every point in the animation.
    @ViewBuilder private func slotLayer(_ name: String, _ slot: String) -> some View {
        if let manifest = ShopPlates.shared.main(name)?.slots[slot] {
            ZStack(alignment: .topLeading) {
                if let quad = manifest.quadPoints {
                    ShopOnQuad(quad: quad.map { CGPoint(x: $0.x * k, y: $0.y * k) }) { _ in
                        ShopCover(artwork: heroEntity.artworkAsset, title: heroEntity.title, workID: catalogID, sharedPresentation: cover)
                            .clipShape(slot == "disc" ? AnyShape(Circle()) : AnyShape(Rectangle()))
                    }
                }
                if let overlay = manifest.over, let frame = manifest.frame {
                    ShopLayerImage(image: ShopPlates.shared.image(name, overlay), frame: frame.rect, k: k)
                }
            }
            .frame(width: ShopPlates.plateWidth * k, height: ShopPlates.plateHeight * k, alignment: .topLeading)
        }
    }
}
