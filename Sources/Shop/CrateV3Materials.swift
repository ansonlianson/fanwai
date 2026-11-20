import UIKit

/// Static faces are rasterized once at display scale. Animation only transforms
/// these images; paper fibres and walnut grain never run in a frame callback.
@MainActor enum CrateV3Materials {
    static let cache = NSCache<NSString, UIImage>()
    static let artworkCache = NSCache<NSString, UIImage>()
    static let paper = UIColor(red: 238/255, green: 232/255, blue: 218/255, alpha: 1)
    static let ink = UIColor(red: 43/255, green: 36/255, blue: 28/255, alpha: 1)
    nonisolated static func size(_ kind: SeedGraph.Kind) -> CGSize {
        switch kind {
        case .album: CGSize(width: 214, height: 214)
        case .film, .tv, .video, .game: CGSize(width: 138, height: 176)
        case .book, .manga: CGSize(width: 114, height: 180)
        case .person, .group: CGSize(width: 226, height: 162)
        case .song: CGSize(width: 152, height: 136)
        }
    }
    static func hash(_ id: String) -> UInt64 {
        id.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    /// Faces are drawn above screen scale: an object in hand is shown at about
    /// 1.5x, and the perspective and stage scale enlarge the front row too.
    static let faceScale: CGFloat = 4
    /// The face image carries room around the sleeve for index tabs, the
    /// clipped photo above the card and a soft shadow below it.
    nonisolated static let faceInset = UIEdgeInsets(top: 72, left: 14, bottom: 14, right: 14)
    nonisolated static func faceSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width+faceInset.left+faceInset.right, height: size.height+faceInset.top+faceInset.bottom)
    }
    /// The sleeve's bottom centre, where it stands on the crate floor.
    nonisolated static func faceAnchor(_ size: CGSize) -> CGPoint {
        CGPoint(x: 0.5, y: (faceInset.top+size.height)/(size.height+faceInset.top+faceInset.bottom))
    }
    static func image(key: String, size: CGSize, scale: CGFloat = 3, draw: (CGContext) -> Void) -> UIImage {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        let result = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
        cache.totalCostLimit = 160_000_000
        cache.setObject(result, forKey: key as NSString, cost: Int(size.width*size.height*scale*scale*4))
        return result
    }
    static func gradient(_ context: CGContext, _ rect: CGRect, _ colors: [UIColor], horizontal: Bool = false) {
        context.saveGState(); context.clip(to: rect)
        let cg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
        context.drawLinearGradient(cg, start: rect.origin,
            end: CGPoint(x: horizontal ? rect.maxX : rect.minX, y: horizontal ? rect.minY : rect.maxY), options: [])
        context.restoreGState()
    }
    static func text(_ value: String, in rect: CGRect, size: CGFloat, color: UIColor = ink,
                     serif: Bool = false, centered: Bool = false, italic: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        let font = serif ? (UIFont(name: DesignFonts.editorialName, size: size) ?? .systemFont(ofSize: size, weight: .semibold)) : .systemFont(ofSize: size, weight: .medium)
        let displayFont = italic ? UIFont.italicSystemFont(ofSize: size) : font
        (value as NSString).draw(in: rect, withAttributes: [.font: displayFont, .foregroundColor: color, .paragraphStyle: style])
    }
    static func art(_ image: UIImage?, in rect: CGRect, context: CGContext) {
        guard let image else { return }
        let scale = max(rect.width/image.size.width, rect.height/image.size.height)
        context.saveGState(); context.clip(to: rect)
        image.draw(in: CGRect(x: rect.midX-image.size.width*scale/2, y: rect.minY,
                             width: image.size.width*scale, height: image.size.height*scale))
        context.restoreGState()
    }
    static func fibre(_ context: CGContext, rect: CGRect) {
        var state: UInt32 = 0x5049414e
        for _ in 0..<800 {
            state = state &* 1664525 &+ 1013904223
            let x = CGFloat(state % 1000)/1000*rect.width
            state = state &* 1664525 &+ 1013904223
            let y = CGFloat(state % 1000)/1000*rect.height
            context.setFillColor(UIColor.white.withAlphaComponent(0.04).cgColor)
            context.fill(CGRect(x: rect.minX+x, y: rect.minY+y, width: 0.4, height: 2))
        }
    }
    /// Index-tab position on an artist divider, in sleeve coordinates.
    nonisolated static func tabRect(slot: Int, width: CGFloat) -> CGRect {
        let w: CGFloat = 76, x: CGFloat = [8, (width-w)/2, width-w-8][max(0, min(2, slot))]
        return CGRect(x: x, y: -32, width: w, height: 36)
    }
    nonisolated static let portraitRect = CGRect(x: 10, y: -62, width: 206, height: 224)
    /// A lifted portrait becomes the object itself. It uses the same padded
    /// canvas/anchor as the divider so the physical flight remains continuous.
    static func portrait(_ item: CrateItem, artwork: UIImage, artworkKey: String) -> UIImage {
        image(key: "portrait:\(item.id):\(artworkKey)", size: faceSize(size(item.entity.kind)), scale: faceScale) { c in
            c.translateBy(x: faceInset.left, y: faceInset.top)
            let r = portraitRect
            c.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1).setFill(); c.fill(r)
            c.setShadow(offset: .zero, blur: 0)
            art(artwork, in: CGRect(x: r.minX+6, y: r.minY+6, width: 194, height: 194), context: c)
        }
    }
    static func board(_ name: String, size: CGSize, shade: CGFloat, vertical: Bool = false, front: Bool = false) -> UIImage {
        image(key: "board:\(name):\(size):\(RecordShopArtReview.current?.rawValue ?? "original")", size: size) { c in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.29, green: 0.18, blue: 0.11, alpha: 1).setFill(); c.fill(rect)
            if RecordShopArtReview.current != nil, let grain = UIImage(named: "p29-walnut-albedo") {
                c.saveGState(); c.clip(to: rect)
                let offset = CGFloat(hash(name)%120)
                if vertical {
                    c.translateBy(x: size.width, y: 0); c.rotate(by: .pi/2)
                    grain.draw(in: CGRect(x: -offset, y: -offset, width: 420, height: 420))
                } else { grain.draw(in: CGRect(x: -offset, y: -offset, width: 420, height: 420)) }
                c.restoreGState()
            } else if let grain = UIImage(named: vertical ? "crate-v3-walnut-vertical" : "crate-v3-walnut-horizontal") {
                for x in stride(from: 0, to: size.width, by: 240) {
                    for y in stride(from: 0, to: size.height, by: 240) { grain.draw(in: CGRect(x: x, y: y, width: 240, height: 240)) }
                }
            }
            if let art = RecordShopArtReview.current {
                c.setBlendMode(.color); art.woodTint.setFill(); c.fill(rect); c.setBlendMode(.normal)
                // One-time raster detail on the existing transformed panels:
                // edge bevels, box joints and slotted metal heads, not a photo
                // of a box that cannot participate in sleeve interactions.
                gradient(c, rect, [UIColor.white.withAlphaComponent(0.18), .clear, UIColor.black.withAlphaComponent(0.18)])
                UIColor.white.withAlphaComponent(0.34).setStroke(); c.setLineWidth(0.6)
                c.move(to: CGPoint(x: 1, y: 1)); c.addLine(to: CGPoint(x: size.width-1, y: 1)); c.strokePath()
                if front || name.hasPrefix("side") {
                    for x: CGFloat in [1, size.width-8] {
                        for y in stride(from: CGFloat(7), to: size.height, by: 13) {
                            UIColor.black.withAlphaComponent(0.28).setFill(); c.fill(CGRect(x: x, y: y, width: 7, height: 6))
                            UIColor.white.withAlphaComponent(0.14).setFill(); c.fill(CGRect(x: x, y: y+6, width: 7, height: 0.6))
                        }
                    }
                }
            }
            UIColor.black.withAlphaComponent(RecordShopArtReview.current == nil ? shade : shade*0.72).setFill(); c.fill(rect)
            gradient(c, rect, [UIColor.white.withAlphaComponent(front ? 0.10 : 0.15), .clear, UIColor.black.withAlphaComponent(0.22)])
            if front {
                UIColor.black.withAlphaComponent(0.45).setFill(); c.fill(CGRect(x: 0, y: 27, width: size.width, height: 0.7))
                for x: CGFloat in [0, size.width-20] {
                    let corner = CGRect(x: x, y: 0, width: 20, height: 22)
                    c.saveGState(); UIBezierPath(roundedRect: corner, cornerRadius: 5).addClip()
                    gradient(c, corner, [UIColor(red: 0.88, green: 0.78, blue: 0.56, alpha: 1), UIColor(red: 0.60, green: 0.46, blue: 0.24, alpha: 1)])
                    c.restoreGState(); UIColor(white: 0.3, alpha: 1).setFill()
                    c.fillEllipse(in: CGRect(x: x+7, y: 8, width: 5, height: 5))
                    if RecordShopArtReview.current != nil {
                        c.setStrokeColor(UIColor(white: 0.08, alpha: 0.8).cgColor); c.setLineWidth(0.75)
                        c.move(to: CGPoint(x: x+8, y: 9)); c.addLine(to: CGPoint(x: x+11, y: 12)); c.strokePath()
                    }
                }
                for x: CGFloat in [26, size.width-30] {
                    UIColor(white: 0.48, alpha: 1).setFill(); c.fillEllipse(in: CGRect(x: x, y: size.height-12, width: 4, height: 4))
                }
            }
        }
    }
    static func face(_ item: CrateItem, artwork: UIImage?, artworkKey: String, alternateName: String = "", depth: CGFloat = 0, tabSlot: Int = 0, rasterScale: CGFloat = faceScale) -> UIImage {
        let size = size(item.entity.kind), kind = item.entity.kind
        let key = "face:\(item.id):\(item.relation):\(item.entity.title):\(artworkKey):\(alternateName):\(depth):\(tabSlot):\(rasterScale)"
        return image(key: key, size: faceSize(size), scale: rasterScale) { c in
            c.translateBy(x: faceInset.left, y: faceInset.top)
            let r = CGRect(origin: .zero, size: size)
            let isPerson = kind == .person || kind == .group
            let isFilm = [.film, .tv, .video].contains(kind)
            // The sleeve's own shadow is part of the image: one textured quad
            // per object, nothing for Core Animation to flatten at runtime.
            c.setShadow(offset: CGSize(width: 0, height: 5), blur: 9, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            paper.setFill(); UIBezierPath(roundedRect: r, cornerRadius: isFilm ? 6 : 2).fill()
            c.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            paper.setFill(); UIBezierPath(roundedRect: r, cornerRadius: isFilm ? 6 : 2).fill(); c.setShadow(offset: .zero, blur: 0)
            if isPerson {
                gradient(c, r, [UIColor(red: 0.75, green: 0.62, blue: 0.44, alpha: 1), UIColor(red: 0.66, green: 0.52, blue: 0.33, alpha: 1)])
                fibre(c, rect: r)
                // Shop dividers cut their index tabs at different positions so
                // every tab in a bin stays readable: left, middle, right.
                let tab = tabRect(slot: tabSlot, width: size.width)
                UIColor(red: 0.77, green: 0.65, blue: 0.47, alpha: 1).setFill(); UIBezierPath(roundedRect: tab, cornerRadius: 6).fill()
                paper.setFill(); c.fill(tab.insetBy(dx: 5, dy: 4).offsetBy(dx: 0, dy: -1))
                text(item.relation, in: CGRect(x: tab.minX+9, y: tab.minY+5, width: tab.width-18, height: 12), size: 8.5, color: UIColor(red: 0.49, green: 0.44, blue: 0.37, alpha: 1))
                text(item.entity.title, in: CGRect(x: tab.minX+9, y: tab.minY+16, width: tab.width-18, height: 17), size: 12.5, serif: true)
                if let artwork {
                    // A real print, big enough to recognise the face.
                    let left = tabSlot == 2
                    c.saveGState(); c.translateBy(x: left ? 10 : size.width-114, y: -62); c.rotate(by: .pi*(left ? -3 : 3.5)/180)
                    c.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.45).cgColor)
                    UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 104, height: 124))
                    c.setShadow(offset: .zero, blur: 0)
                    art(artwork, in: CGRect(x: 6, y: 6, width: 92, height: 92), context: c)
                    UIColor(white: 0.1, alpha: 1).setFill(); UIBezierPath(roundedRect: CGRect(x: 38, y: -7, width: 28, height: 13), cornerRadius: 2).fill()
                    UIColor(white: 0.6, alpha: 1).setStroke(); c.setLineWidth(1.5)
                    c.stroke(CGRect(x: 43, y: -13, width: 18, height: 9)); c.restoreGState()
                } else {
                    text(item.entity.title, in: CGRect(x: 12, y: 20, width: size.width-24, height: 40), size: 29, serif: true, centered: true)
                    if !alternateName.isEmpty { text(alternateName, in: CGRect(x: 15, y: 62, width: size.width-30, height: 20), size: 12, centered: true, italic: true) }
                    ink.withAlphaComponent(0.35).setFill(); c.fill(CGRect(x: 48, y: 88, width: 130, height: 1.5))
                }
            } else {
                let inks: [UIColor] = [.init(red: 0.29, green: 0.14, blue: 0.13, alpha: 1), .init(red: 0.13, green: 0.23, blue: 0.19, alpha: 1), .init(red: 0.12, green: 0.17, blue: 0.25, alpha: 1)]
                inks[Int(hash(item.id)%3)].setFill(); c.fill(r)
                var artRect = r
                if isFilm {
                    UIColor(red: 0.10, green: 0.35, blue: 0.65, alpha: 1).setFill(); UIBezierPath(roundedRect: r, cornerRadius: 6).fill()
                    text("Blu-ray", in: CGRect(x: 0, y: 3, width: size.width, height: 14), size: 9.5, color: .white, centered: true)
                    artRect = CGRect(x: 5, y: 17, width: size.width-10, height: size.height-22)
                } else if kind == .song {
                    artRect = CGRect(x: 11, y: 3, width: size.width-14, height: size.height-6)
                    for y in stride(from: 0, to: size.height, by: 4) {
                        UIColor(white: 0.7, alpha: 0.4).setFill(); c.fill(CGRect(x: 0, y: y, width: 10, height: 1))
                    }
                }
                art(artwork, in: artRect, context: c)
                if artwork == nil { text(item.entity.title, in: CGRect(x: 14, y: size.height*0.42, width: size.width-28, height: 62), size: 16, color: paper, serif: true, centered: true) }
                if kind == .book || kind == .manga || kind == .album {
                    paper.setFill(); c.fill(CGRect(x: 2, y: -3, width: size.width-3, height: 3))
                    gradient(c, CGRect(x: 0, y: 0, width: 8, height: size.height), [.black.withAlphaComponent(0.5), .clear], horizontal: true)
                }
                if kind == .album || kind == .song || isFilm {
                    c.saveGState(); c.clip(to: r)
                    let gloss = UIBezierPath(); gloss.move(to: CGPoint(x: size.width*0.8, y: 0)); gloss.addLine(to: CGPoint(x: size.width, y: 0)); gloss.addLine(to: CGPoint(x: size.width*0.23, y: size.height)); gloss.addLine(to: CGPoint(x: 0, y: size.height)); gloss.close()
                    UIColor.white.withAlphaComponent(kind == .album ? 0.12 : 0.17).setFill(); gloss.fill(); c.restoreGState()
                }
                let sticker = CGRect(x: 10, y: isFilm ? 24 : 10, width: min(size.width-20, 140), height: 37)
                paper.setFill(); UIBezierPath(roundedRect: sticker, cornerRadius: 1.5).fill()
                text(item.relation, in: sticker.insetBy(dx: 7, dy: 3), size: 9.5, color: UIColor(red: 0.49, green: 0.44, blue: 0.37, alpha: 1))
                text(item.entity.title, in: CGRect(x: sticker.minX+7, y: sticker.minY+17, width: sticker.width-14, height: 18), size: 12.5, serif: true)
            }
            gradient(c, CGRect(x: 0, y: size.height*0.5, width: size.width, height: size.height*0.5), [.clear, .black.withAlphaComponent(0.45)])
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.2).cgColor); c.setLineWidth(0.65); c.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            c.setBlendMode(.sourceAtop)
            UIColor.black.withAlphaComponent(max(0, -depth/36)*0.06).setFill()
            c.fill(CGRect(x: -faceInset.left, y: -faceInset.top, width: faceSize(size).width, height: faceSize(size).height))
        }
    }
}
