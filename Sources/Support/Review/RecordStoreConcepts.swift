import SwiftUI
import UIKit

/// Complete, executable store directions. All use the selected warm walnut;
/// the differences are spatial composition and editorial hierarchy.
enum RecordStoreConcept: String, CaseIterable {
    case counter, listening, notes
    static var current: Self? {
        #if DEBUG && targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-isolate-data"), args.contains(where: { $0.hasPrefix("--ui-state=") }),
              let flag = args.first(where: { $0.hasPrefix("--ui-store-design=") }) else { return nil }
        return Self(rawValue: String(flag.dropFirst("--ui-store-design=".count)))
        #else
        return nil
        #endif
    }
    var title: String {
        switch self { case .counter: "柜台选片"; case .listening: "爵士聆听室"; case .notes: "唱片内页" }
    }
    var isPaper: Bool { self != .listening }
    var colorScheme: ColorScheme { isPaper ? .light : .dark }
    var ink: Color { isPaper ? ArtworkPalette.paperInk : ArtworkPalette.tx }
    var accent: Color { isPaper ? Color(red: 0.48, green: 0.22, blue: 0.08) : Color(red: 0.94, green: 0.77, blue: 0.49) }
}

struct RecordStoreConceptBackdrop: View {
    let concept: RecordStoreConcept
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if concept == .listening {
                    Color(red: 0.055, green: 0.067, blue: 0.064)
                    // Acoustic wall, not a photograph of an imagined room.
                    Canvas { context, size in
                        for x in stride(from: CGFloat(0), to: size.width, by: 14) {
                            context.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(.white.opacity(0.035)))
                        }
                    }
                    RadialGradient(colors: [Color(red: 0.64, green: 0.40, blue: 0.18).opacity(0.58), .clear],
                        center: UnitPoint(x: 0.32, y: 0.13), startRadius: 10, endRadius: geometry.size.width*1.03)
                } else {
                    Color(red: 0.93, green: 0.91, blue: 0.86)
                    Image(uiImage: PrintedTexture.fibres).resizable(resizingMode: .tile).opacity(0.08)
                    if concept == .counter {
                        LinearGradient(colors: [.white.opacity(0.72), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        Canvas { context, size in
                            let x: CGFloat = 21
                            context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 90)); p.addLine(to: CGPoint(x: x, y: size.height*0.54)) },
                                with: .color(Color(red: 0.63, green: 0.31, blue: 0.13).opacity(0.32)), lineWidth: 0.7)
                        }
                    }
                }
                // The counter is a separate physical plane beneath the crate.
                // Native glass reads the actual material behind its controls.
                if concept != .notes {
                    ZStack(alignment: .top) {
                        Image("p29-walnut-albedo").resizable().scaledToFill()
                        LinearGradient(colors: [.black.opacity(0.20), .black.opacity(concept == .listening ? 0.65 : 0.35)], startPoint: .top, endPoint: .bottom)
                        Rectangle().fill(.black.opacity(0.35)).frame(height: 1)
                        Rectangle().fill(.white.opacity(0.32)).frame(height: 0.6).offset(y: 1)
                    }.frame(height: geometry.size.height*0.31).clipped()
                } else {
                    LinearGradient(colors: [.clear, Color(red: 0.47, green: 0.35, blue: 0.23).opacity(0.14)], startPoint: .top, endPoint: .bottom)
                        .frame(height: geometry.size.height*0.45)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
