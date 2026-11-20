import UIKit

/// All IDs keep a place in the same bin. Only nearby covers need a full face;
/// distant objects retain a named sleeve edge instead of a fabricated filler.
enum CrateStackLayout {
    static func interpolate(_ from: CrateV3Pose, _ to: CrateV3Pose, progress: CGFloat) -> CrateV3Pose {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return .init(x: mix(from.x, to.x), y: mix(from.y, to.y), z: mix(from.z, to.z),
                     rx: mix(from.rx, to.rx), ry: mix(from.ry, to.ry), rz: mix(from.rz, to.rz), scale: mix(from.scale, to.scale))
    }

    static func contained(_ pose: CrateV3Pose, kind: SeedGraph.Kind) -> CrateV3Pose {
        var pose = pose
        let halfWidth = CrateV3Materials.size(kind).width * pose.scale / 2
        let limit = max(0, 158 - halfWidth)
        pose.x = min(limit, max(-limit, pose.x))
        return pose
    }

    static func resting(index: Int, count: Int) -> CrateV3Pose {
        let t = CGFloat(index) / CGFloat(max(1, count - 1))
        return .init(x: -48 + 96 * t, z: -156 + 54 * t,
                     rx: 11 - 4 * t, rz: -2 + 4 * t, scale: 0.86)
    }

    static func browsing(index: Int, cursor: CGFloat) -> CrateV3Pose {
        let d = CGFloat(index) - cursor, a = abs(d), side: CGFloat = d < 0 ? -1 : 1
        // Open a gap around the finger; compress the rest into actual layers.
        let x = side * (83 * min(1, a) + 28 * min(1, max(0, a - 1)) + 9 * (1 - exp(-max(0, a - 2) / 4)))
        let depth = -12 - 48 * min(2, a) - 44 * (1 - exp(-max(0, a - 2) / 5))
        return .init(x: x, z: depth, rx: 4 + 5 * min(3, a),
                     ry: -side * 7 * min(1, a), rz: side * min(5, a * 2),
                     scale: 0.96 - 0.12 * min(2, a))
    }
}

extension CrateV3Materials {
    static func stockFace(_ item: CrateItem) -> UIImage {
        let size = size(item.entity.kind)
        return image(key: "stock:\(item.id):\(item.entity.title):\(item.relation)", size: faceSize(size), scale: 1.5) { c in
            c.translateBy(x: faceInset.left, y: faceInset.top)
            let rect = CGRect(origin: .zero, size: size)
            c.setShadow(offset: .init(width: 0, height: 3), blur: 3, color: UIColor.black.withAlphaComponent(0.65).cgColor)
            let colors: [UIColor] = [UIColor(red: 0.29, green: 0.33, blue: 0.29, alpha: 1),
                UIColor(red: 0.43, green: 0.29, blue: 0.23, alpha: 1),
                UIColor(red: 0.25, green: 0.31, blue: 0.35, alpha: 1)]
            colors[Int(hash(item.id) % 3)].setFill(); c.fill(rect)
            c.setShadow(offset: .zero, blur: 0)
            paper.setFill(); c.fill(CGRect(x: 1, y: -3, width: size.width-2, height: 3))
            gradient(c, rect, [.white.withAlphaComponent(0.12), .clear, .black.withAlphaComponent(0.5)])
            // This is a store's plain protective sleeve, labelled with a real
            // work, not an invented cover image for missing art.
            paper.withAlphaComponent(0.90).setFill()
            c.fill(CGRect(x: 7, y: 6, width: size.width-14, height: 21))
            text(item.entity.title, in: CGRect(x: 12, y: 8, width: size.width-24, height: 18), size: 11)
            c.setStrokeColor(UIColor.white.withAlphaComponent(0.2).cgColor); c.setLineWidth(0.7)
            c.stroke(rect.insetBy(dx: 1, dy: 1))
        }
    }

    static func indexPaper(size: CGSize, tab: Bool = false) -> UIImage {
        image(key: "crate-paper-index:\(size):\(tab)", size: size, scale: 3) { c in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            c.setShadow(offset: .init(width: 0, height: 2), blur: 2, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            paper.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: tab ? 4 : 1).fill()
            c.setShadow(offset: .zero, blur: 0)
            gradient(c, rect, [.white.withAlphaComponent(0.16), .clear, ink.withAlphaComponent(0.12)])
            fibre(c, rect: rect)
            c.setStrokeColor(ink.withAlphaComponent(0.15).cgColor); c.setLineWidth(0.6)
            c.stroke(rect.insetBy(dx: 2, dy: 2))
            if tab {
                // Fold and two stitch holes attach the index to the rim.
                c.setFillColor(ink.withAlphaComponent(0.18).cgColor)
                c.fill(CGRect(x: rect.minX, y: rect.maxY-8, width: rect.width, height: 1))
                for x in [rect.minX+8, rect.maxX-9] { c.fillEllipse(in: CGRect(x: x, y: rect.maxY-5, width: 1.5, height: 1.5)) }
            }
        }
    }
}
