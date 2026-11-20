import SwiftUI

enum VisualDirection: String, CaseIterable, Identifiable {
    case spectrum, atlas, orbit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spectrum: "光谱"
        case .atlas: "图录"
        case .orbit: "唱片店"
        }
    }

    var preferredScheme: ColorScheme { self == .atlas ? .light : .dark }

    var background: Color {
        switch self {
        case .spectrum: Self.color(0x07191C)
        case .atlas: Self.color(0xF2EBDD)
        case .orbit: Self.color(0x171816)
        }
    }

    var foreground: Color {
        switch self {
        case .spectrum: Self.color(0xEFF7F2)
        case .atlas: Self.color(0x29261F)
        case .orbit: Self.color(0xF1EBDD)
        }
    }

    var secondary: Color {
        switch self {
        case .spectrum: Self.color(0x9BAFA8)
        case .atlas: Self.color(0x7E7769)
        case .orbit: Self.color(0xA6A397)
        }
    }

    var accent: Color {
        switch self {
        case .spectrum: Self.color(0xB9EAD6)
        case .atlas: Self.color(0xB6533C)
        case .orbit: Self.color(0xD3DBA4)
        }
    }

    var surface: Color {
        switch self {
        case .spectrum: Self.color(0x112D30)
        case .atlas: Self.color(0xFFFAEF)
        case .orbit: Self.color(0x252620)
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}
