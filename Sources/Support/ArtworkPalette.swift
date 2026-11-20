import SwiftUI
import UIKit

/// Artwork is sampled in perceptual OKLab space. No entity-kind colors are used.
struct ArtworkPalette: Sendable {
    struct RGB: Sendable, Equatable {
        let r: Double
        let g: Double
        let b: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
        var luminance: Double { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        func contrast(with other: Self) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
        var lab: Lab {
            let rr = linear(r), gg = linear(g), bb = linear(b)
            let l = cbrt(0.4122214708 * rr + 0.5363325363 * gg + 0.0514459929 * bb)
            let m = cbrt(0.2119034982 * rr + 0.6806995451 * gg + 0.1073969566 * bb)
            let s = cbrt(0.0883024619 * rr + 0.2817188376 * gg + 0.6299787005 * bb)
            return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                       a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                       b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        private func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    }
    struct Lab: Sendable {
        var l: Double
        var a: Double
        var b: Double
        var chroma: Double { hypot(a, b) }
        var hue: Double { atan2(b, a) }
        func distance(_ other: Self) -> Double { pow(l - other.l, 2) + pow(a - other.a, 2) + pow(b - other.b, 2) }
        static func lch(_ l: Double, _ c: Double, _ h: Double) -> Self { Self(l: l, a: c * cos(h), b: c * sin(h)) }
        var rgb: RGB {
            let ll = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let mm = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let ss = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            func srgb(_ v: Double) -> Double { min(1, max(0, v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)) }
            return RGB(r: srgb(4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss),
                       g: srgb(-1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss),
                       b: srgb(-0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss))
        }
    }

    let bg: RGB
    let bg2: RGB
    let ac: RGB
    static let tx = RGB(r: 242 / 255, g: 241 / 255, b: 238 / 255).color
    static let tx2 = tx.opacity(0.64)
    static let tx3 = tx.opacity(0.40)
    static let line = tx.opacity(0.16)
    static let paper = RGB(r: 232 / 255, g: 227 / 255, b: 216 / 255).color
    static let paperInk = RGB(r: 42 / 255, g: 38 / 255, b: 34 / 255).color
    static let border = RGB(r: 239 / 255, g: 237 / 255, b: 232 / 255).color
    static let fallback = make(dominant: RGB(r: 22/255, g: 26/255, b: 28/255).lab,
                               accent: RGB(r: 231/255, g: 192/255, b: 138/255).lab)

    @MainActor static func asset(_ name: String?) -> Self {
        guard let name, !name.isEmpty else { return fallback }
        return ArtworkTint.shared.palette(name) ?? fallback
    }
    static func extract(_ image: UIImage) -> Self {
        let measurement = EvalPerformance.begin("Palette.extract")
        defer { measurement?.end() }
        guard let cg = image.cgImage else { return fallback }
        let side = 40
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return fallback }
        let samples = stride(from: 0, to: bytes.count, by: 4).compactMap { i -> Lab? in
            let alpha = Double(bytes[i + 3]) / 255
            guard alpha > 0.5 else { return nil }
            return RGB(r: Double(bytes[i]) / 255 / alpha, g: Double(bytes[i+1]) / 255 / alpha,
                       b: Double(bytes[i+2]) / 255 / alpha).lab
        }
        guard let first = samples.first else { return fallback }
        var centers = [first]
        for _ in 1..<6 {
            guard let next = samples.max(by: { a, b in
                centers.map { a.distance($0) }.min()! < centers.map { b.distance($0) }.min()!
            }) else { break }
            centers.append(next)
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<12 {
            var sums = [Lab](repeating: Lab(l: 0, a: 0, b: 0), count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for sample in samples {
                let closest = centers.indices.min { sample.distance(centers[$0]) < sample.distance(centers[$1]) }!
                counts[closest] += 1
                sums[closest].l += sample.l; sums[closest].a += sample.a; sums[closest].b += sample.b
            }
            for i in centers.indices where counts[i] > 0 {
                let n = Double(counts[i])
                centers[i] = Lab(l: sums[i].l/n, a: sums[i].a/n, b: sums[i].b/n)
            }
        }
        let dominant = counts.indices.max { counts[$0] < counts[$1] }!
        let significant = centers.indices.filter { counts[$0] >= max(1, samples.count / 33) }
        let accent = significant.max { centers[$0].chroma < centers[$1].chroma } ?? dominant
        return make(dominant: centers[dominant], accent: centers[accent])
    }
    private static func make(dominant: Lab, accent: Lab) -> Self {
        var lightness = min(0.20, max(0.17, dominant.l))
        let chroma = min(0.03, dominant.chroma)
        var bg = Lab.lch(lightness, chroma, dominant.hue).rgb
        var ac = Lab.lch(0.82, min(0.12, max(0.08, accent.chroma)), accent.hue).rgb
        if ac.contrast(with: bg) < 4.5 {
            lightness = 0.17
            bg = Lab.lch(lightness, chroma, dominant.hue).rgb
            ac = Lab.lch(0.84, min(0.12, max(0.08, accent.chroma)), accent.hue).rgb
        }
        return Self(bg: bg, bg2: Lab.lch(lightness + 0.04, chroma, dominant.hue).rgb, ac: ac)
    }
}
