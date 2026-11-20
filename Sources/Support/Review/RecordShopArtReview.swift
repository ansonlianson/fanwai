import SwiftUI
import UIKit

/// Executable art proposals. Release builds always use the user's existing
/// design; these simulator variants change materials, never native controls.
enum RecordShopArtReview: String, CaseIterable {
    case walnut, oxblood, olive
    static var current: Self? {
        #if DEBUG && targetEnvironment(simulator)
        if RecordStoreConcept.current != nil { return .walnut }
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-shop-art=") }) else { return nil }
        return Self(rawValue: String(flag.dropFirst("--ui-shop-art=".count)))
        #else
        return nil
        #endif
    }
    var title: String {
        switch self { case .walnut: "01 · 暖胡桃木"; case .oxblood: "02 · 酒红红木"; case .olive: "03 · 墨绿烟熏木" }
    }
    var base: Color {
        switch self {
        case .walnut: Color(red: 0.105, green: 0.072, blue: 0.049)
        case .oxblood: Color(red: 0.125, green: 0.040, blue: 0.044)
        case .olive: Color(red: 0.055, green: 0.082, blue: 0.068)
        }
    }
    var light: Color {
        switch self {
        case .walnut: Color(red: 0.48, green: 0.30, blue: 0.14)
        case .oxblood: Color(red: 0.46, green: 0.19, blue: 0.13)
        case .olive: Color(red: 0.33, green: 0.35, blue: 0.22)
        }
    }
    var woodTint: UIColor {
        switch self {
        case .walnut: UIColor(red: 0.53, green: 0.32, blue: 0.16, alpha: 1)
        case .oxblood: UIColor(red: 0.49, green: 0.22, blue: 0.17, alpha: 1)
        case .olive: UIColor(red: 0.43, green: 0.42, blue: 0.28, alpha: 1)
        }
    }
    var accent: Color {
        switch self {
        case .walnut: Color(red: 0.94, green: 0.76, blue: 0.48)
        case .oxblood: Color(red: 0.95, green: 0.71, blue: 0.51)
        case .olive: Color(red: 0.82, green: 0.84, blue: 0.63)
        }
    }
}

struct RecordShopReviewBackdrop: View {
    let art: RecordShopArtReview
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                art.base
                RadialGradient(colors: [art.light.opacity(0.78), art.base.opacity(0)],
                    center: UnitPoint(x: 0.12, y: 0.23), startRadius: 10, endRadius: geometry.size.width*1.25)
                RadialGradient(colors: [art.light.opacity(0.30), .clear],
                    center: UnitPoint(x: 0.72, y: 0.73), startRadius: 0, endRadius: geometry.size.width*0.92)
                Image(uiImage: PrintedTexture.fibres).resizable(resizingMode: .tile).opacity(0.035)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
