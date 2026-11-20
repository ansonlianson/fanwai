import SwiftUI
import UIKit
import CoreImage

struct ArtworkBackdrop: View {
    let artwork: String?
    let palette: ArtworkPalette
    var radial = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if let concept = RecordStoreConcept.current {
                    RecordStoreConceptBackdrop(concept: concept)
                } else if let art = RecordShopArtReview.current {
                    RecordShopReviewBackdrop(art: art)
                } else {
                if radial {
                    RadialGradient(colors: [Color(red: 34/255, green: 40/255, blue: 43/255), palette.bg.color],
                                   center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: geometry.size.height*0.7)
                } else { palette.bg.color }
                if let artwork, let image = Self.blurred(artwork) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width + 80, height: 560).clipped()
                        .opacity(0.9).transition(.opacity).id(artwork)
                        .overlay {
                            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                                   .init(color: palette.bg.color, location: 0.92)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .clipped()
                        .offset(y: -40)
                }
                Image(uiImage: Self.grain).resizable(resizingMode: .tile).opacity(0.018)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            .animation(.easeOut(duration: 0.6), value: (RecordStoreConcept.current == nil && RecordShopArtReview.current == nil) ? artwork.flatMap(Self.blurred) == nil : true)
            .animation(.easeOut(duration: 0.6), value: artwork)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
    private static let blurCache=NSCache<NSString,UIImage>()
    private static let context=CIContext(options:[.cacheIntermediates:false])
    @MainActor private static func blurred(_ asset:String) -> UIImage? {
        if asset.hasPrefix("https://") { return ArtworkTint.shared.backdrop(asset) }
        if let cached=blurCache.object(forKey:asset as NSString) { return cached }
        guard let source=ObservedArtwork.image(asset), let shaded=blur(source) else { return nil }
        blurCache.countLimit=16; blurCache.setObject(shaded,forKey:asset as NSString); return shaded
    }
    static func blur(_ source:UIImage) -> UIImage? {
        let image=UIGraphicsImageRenderer(size:CGSize(width:220,height:280)).image { _ in source.draw(in:CGRect(x:0,y:0,width:220,height:280)) }
        guard let input=CIImage(image:image), let filter=CIFilter(name:"CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(),forKey:kCIInputImageKey); filter.setValue(30,forKey:kCIInputRadiusKey)
        guard let output=filter.outputImage?.cropped(to:input.extent),let cg=context.createCGImage(output,from:input.extent) else { return nil }
        let blurred=UIImage(cgImage:cg)
        let shaded=UIGraphicsImageRenderer(size:blurred.size).image { c in
            blurred.draw(at:.zero); c.cgContext.setBlendMode(.sourceAtop)
            UIColor.black.withAlphaComponent(0.45).setFill(); c.fill(CGRect(origin:.zero,size:blurred.size))
        }
        return shaded
    }
    private static let grain: UIImage = {
        let side = 160
        var state: UInt32 = 0x5049414E
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 1664525 &+ 1013904223
            let gray = UInt8((state >> 24) & 255)
            bytes[i] = gray; bytes[i+1] = gray; bytes[i+2] = gray
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image)
    }()
}
