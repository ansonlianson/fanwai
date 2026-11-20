import SwiftUI

/// The original CC0 walnut diffuse map is bundled, so material never waits on
/// the network. Each board crops the same physical grain without stretching it.
struct WalnutSurface: View {
    var vertical = false
    var shade = 0.0
    var cut = 0.0

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height) * 1.55
            Image("walnut-grain")
                .resizable().interpolation(.high)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(vertical ? 0 : 90))
                .position(x: geometry.size.width / 2 + side * cut * 0.08,
                          y: geometry.size.height / 2 + side * cut * 0.12)
                .saturation(0.78)
                .colorMultiply(Color(red: 0.66, green: 0.56, blue: 0.49))
                .overlay(Color.black.opacity(shade))
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A thin solid-looking rail has a lit top bevel, a vertical face, and a
/// contact line. The grain belongs to the face, not to the lighting overlay.
struct WalnutRail: View {
    var lip: CGFloat = 5
    var joinery = false

    var body: some View {
        ZStack(alignment: .top) {
            WalnutSurface(cut: 0.3)
            LinearGradient(stops: [
                .init(color: .white.opacity(0.08), location: 0),
                .init(color: .clear, location: 0.25),
                .init(color: .black.opacity(0.24), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            WalnutSurface(cut: -0.7)
                .brightness(0.045)
                .overlay(LinearGradient(colors: [.white.opacity(0.12), .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                .frame(height: lip)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(red: 0.82, green: 0.68, blue: 0.51).opacity(0.32)).frame(height: 0.6)
                }
                .overlay(alignment: .bottom) { Color.black.opacity(0.36).frame(height: 0.7) }
            if joinery {
                HStack {
                    joint
                    Spacer()
                    joint.scaleEffect(x: -1)
                }.padding(.horizontal, 14).padding(.top, lip + 2).padding(.bottom, 2)
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .overlay(alignment: .bottom) { Color.black.opacity(0.55).frame(height: 1).padding(.horizontal, 3) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private var joint: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.30).frame(width: 0.7)
            Color.white.opacity(0.045).frame(width: 0.6)
        }.frame(width: 1.3)
    }
}

struct CabinetShelf: View {
    var body: some View {
        WalnutRail(lip: 5)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.clear, .black.opacity(0.48)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 7).offset(y: -7)
            }
            .shadow(color: .black.opacity(0.42), radius: 6, x: 0, y: 8)
    }
}

/// Folded metal label holder; small reflected edges frame the paper inset.
struct CrateLabelHolder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(LinearGradient(stops: [
                .init(color: Color(red: 0.64, green: 0.55, blue: 0.40), location: 0),
                .init(color: Color(red: 0.42, green: 0.35, blue: 0.25), location: 0.36),
                .init(color: Color(red: 0.32, green: 0.27, blue: 0.20), location: 0.7),
                .init(color: Color(red: 0.60, green: 0.51, blue: 0.37), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.white.opacity(0.16), lineWidth: 0.6))
            .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(.black.opacity(0.55), lineWidth: 0.7).padding(2))
    }
}
