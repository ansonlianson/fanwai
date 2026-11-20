import SwiftUI
import UIKit

enum ObjectInk {
    static let hex = [0x4A2422, 0x213A31, 0x1F2A40, 0x4A3620, 0x2B2D30]
    static func index(_ id: String) -> Int {
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Int(hash % UInt64(hex.count))
    }
    static func indices(_ ids: [String]) -> [String: Int] {
        var result: [String: Int] = [:], previous: Int?
        for id in ids {
            var value = index(id)
            if value == previous { value = (value+1) % hex.count }
            result[id] = value; previous = value
        }
        return result
    }
    static func color(_ index: Int) -> Color {
        let value = hex[index % hex.count]
        return Color(red: Double(value>>16)/255, green: Double((value>>8)&255)/255, blue: Double(value&255)/255)
    }
}

@MainActor enum PrintedTexture {
    static let fibres:UIImage = {
        let format=UIGraphicsImageRendererFormat(); format.scale=2
        return UIGraphicsImageRenderer(size:CGSize(width:160,height:160),format:format).image { renderer in
            let c=renderer.cgContext
            for i in 0..<500 {
                let x=CGFloat((i*73)%997)/997*160,y=CGFloat((i*139)%991)/991*160
                UIColor.white.setFill(); c.fill(CGRect(x:x,y:y,width:0.8,height:0.4))
            }
        }
    }()
}
struct InkStock: View {
    let index: Int
    var body: some View {
        ObjectInk.color(index).overlay { Image(uiImage:PrintedTexture.fibres).resizable(resizingMode:.tile).opacity(0.035) }
    }
}
struct PaperStock: View {
    var dark = false
    var body: some View {
        LinearGradient(colors:dark
            ? [Color(red:0.21,green:0.21,blue:0.20),Color(red:0.13,green:0.14,blue:0.14)]
            : [Color(red:0.91,green:0.89,blue:0.83),Color(red:0.95,green:0.93,blue:0.88)],startPoint:.topLeading,endPoint:.bottomTrailing)
            .overlay { Image(uiImage:PrintedTexture.fibres).resizable(resizingMode:.tile).colorMultiply(.black).opacity(dark ? 0.045 : 0.035) }
    }
}

struct WhiteLabelSleeve: View {
    var body: some View {
        ZStack(alignment: .top) {
            PaperStock()
            Text("在关系图里点 \(Image(systemName: "star"))，\n唱片会放到这里").font(.custom(DesignFonts.editorialName, size: 14))
                .foregroundStyle(ArtworkPalette.paperInk).multilineTextAlignment(.center)
                .lineSpacing(3).padding(.horizontal, 16).padding(.top, 12)
            // The record sits behind a die-cut opening in the paper jacket.
            RecordDisc(size: 102, label: Color(red: 0.97, green: 0.96, blue: 0.92))
                .clipShape(.circle).frame(width: 76, height: 76).clipped()
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.black.opacity(0.34), lineWidth: 1.5))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5).padding(-1))
                .padding(.top, 64)
            RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.6), lineWidth: 1)
            Rectangle().fill(.brown.opacity(0.14)).frame(width: 1).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 176, height: 176).clipShape(.rect(cornerRadius: 3))
            .shadow(color: .black.opacity(0.6), radius: 7, x: 3, y: 6)
    }
}

struct WallSidePanels: View {
    var body: some View {
        HStack(spacing: 0) {
            panel
            Spacer(minLength: 0)
            panel.scaleEffect(x: -1)
        }
    }
    private var panel: some View {
        WalnutSurface(vertical: true, shade: 0.10, cut: 0.6)
            .frame(width: 12)
            .overlay(LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.28)], startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.5)).frame(width: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.09)).frame(width: 1) }
    }
}

/// A lower front board leaves the jackets visible; the handle is a recess,
/// with its upper edge in shadow and a worn lower lip catching the light.
struct WallCrateFront: View {
    var body: some View {
        CrateWoodPanel()
            .overlay {
                Capsule().fill(LinearGradient(colors: [Color(red: 0.07, green: 0.055, blue: 0.04), Color(red: 0.16, green: 0.11, blue: 0.07)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 68, height: 10)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.55), lineWidth: 1))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color(red: 0.54, green: 0.40, blue: 0.27).opacity(0.65)).frame(width: 60, height: 0.7).offset(y: 0.7)
                    }
                    .offset(y: 2)
            }
    }
}
