import SwiftUI
import UIKit
import CoreText

@Observable @MainActor
final class DesignFonts {
    static let shared = DesignFonts()
    nonisolated static let songti = "STSongti-SC-Bold"
    static var editorialName: String { shared.songtiAvailable ? songti : "PingFangSC-Semibold" }
    private(set) var songtiAvailable = UIFont(name: songti, size: 23) != nil
    private(set) var attempted = false

    func prepare() {
        guard !attempted, !songtiAvailable else { return }
        attempted = true
        Self.matchFont()
    }

    nonisolated private static func matchFont() {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.songti] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, _ in
            if state == .didFinish || state == .didFailWithError {
                Task { @MainActor in
                    Self.shared.songtiAvailable = UIFont(name: Self.songti, size: 23) != nil
                    #if DEBUG
                    print("Design Songti available:", Self.shared.songtiAvailable, "matching state:", state.rawValue)
                    #endif
                }
            }
            return true
        }
    }
}

enum DesignType {
    case story, chapter, card, body, chapterBody, song, crateTitle, crateBody
    var size: CGFloat {
        switch self { case .story: 23; case .chapter: 21; case .card: 15.5; case .body: 15.5; case .chapterBody: 15; case .song: 31; case .crateTitle: 18.5; case .crateBody: 14 }
    }
    var lineHeight: CGFloat {
        switch self { case .story: 33; case .chapter: 30; case .card: 23; case .body: 27; case .chapterBody: 26.25; case .song: 34; case .crateTitle: 27.75; case .crateBody: 23.8 }
    }
    var isHeading: Bool { self == .story || self == .chapter || self == .card || self == .crateTitle }
    @MainActor var font: Font {
        if isHeading { return .custom(DesignFonts.editorialName, size: size, relativeTo: .headline) }
        if self == .song { return .system(size: size, weight: .bold) }
        return .custom("PingFangSC-Regular", size: size, relativeTo: .body)
    }
}

/// UILabel exposes UIKit's pushOut strategy and precise baseline spacing,
/// keeping long Chinese titles balanced without inserting manual line breaks.
struct EditorialText: UIViewRepresentable {
    let text: String
    var role: DesignType = .story
    var secondary = false
    var alignment: NSTextAlignment = .left
    var lineLimit = 0
    var entityLinks: [String: String] = [:]
    var onEntity: ((String) -> Void)?
    @Environment(\.sizeCategory) private var sizeCategory

    func makeUIView(context: Context) -> EditorialLabel {
        let label = EditorialLabel()
        label.numberOfLines = 0
        label.lineBreakStrategy = .pushOut
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.isAccessibilityElement = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: label, action: #selector(EditorialLabel.openEntity(_:))))
        return label
    }
    func updateUIView(_ label: EditorialLabel, context: Context) {
        let base: UIFont
        if role.isHeading {
            // SPEC §6.6: use PingFang Semibold until the exact Songti is available.
            base = UIFont(name: DesignFonts.editorialName, size: role.size)!
        } else if role == .song { base = .systemFont(ofSize: role.size, weight: .bold) }
        else { base = UIFont(name: "PingFangSC-Regular", size: role.size)! }
        let font = UIFontMetrics(forTextStyle: role.isHeading ? .headline : .body).scaledFont(for: base)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = role.lineHeight * font.pointSize / role.size
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakStrategy = .pushOut
        paragraph.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
        paragraph.alignment = alignment
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: UIColor(red: 242/255, green: 241/255, blue: 238/255, alpha: secondary ? 0.64 : 1)
        ])
        label.entityRanges = entityLinks.compactMap { name, id in
            let range = (text as NSString).range(of: name)
            guard range.location != NSNotFound else { return nil }
            attributed.addAttributes([
                .foregroundColor: UIColor(ArtworkPalette.tx),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: UIColor(ArtworkPalette.line)
            ], range: range)
            return (range, id)
        }
        label.textAlignment = alignment
        label.numberOfLines = lineLimit
        label.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
        label.attributedText = attributed
        label.onEntity = onEntity
        label.isUserInteractionEnabled = !label.entityRanges.isEmpty
        label.accessibilityCustomActions = entityLinks.map { name, id in
            UIAccessibilityCustomAction(name: name) { _ in onEntity?(id); return true }
        }
        label.accessibilityTraits = role.isHeading ? .header : .staticText
        label.accessibilityLabel = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorialLabel, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let textWidth = role.isHeading ? prettyWidth(for: uiView.attributedText, available: width, fontSize: role.size) : width
        uiView.typesetWidth = textWidth
        uiView.preferredMaxLayoutWidth = textWidth
        let result = uiView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(result.height))
    }
    private func prettyWidth(for text: NSAttributedString?, available: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard let text, text.length > 0 else { return available }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        func hasOrphan(at width: CGFloat) -> Bool {
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard lines.count > 1, let last = lines.last else { return false }
            let range = CTLineGetStringRange(last)
            let tail = (text.string as NSString).substring(with: NSRange(location: range.location, length: range.length))
            return tail.filter { !$0.isWhitespace && !$0.isPunctuation }.count <= 2
        }
        guard hasOrphan(at: available) else { return available }
        // Match CSS text-wrap:pretty without changing a single copy character.
        for reduction in stride(from: CGFloat(1), through: fontSize * 2, by: 1) {
            if !hasOrphan(at: available - reduction) { return available - reduction }
        }
        return available
    }
}

final class EditorialLabel: UILabel {
    var typesetWidth: CGFloat?
    var entityRanges: [(NSRange, String)] = []
    var onEntity: ((String) -> Void)?
    @objc func openEntity(_ recognizer: UITapGestureRecognizer) {
        guard let attributedText else { return }
        let storage = NSTextStorage(attributedString: attributedText)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        container.lineBreakMode = lineBreakMode
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let used = layout.usedRect(for: container)
        var point = recognizer.location(in: self)
        point.y -= max(0, (bounds.height - used.height) / 2)
        guard used.contains(point) else { return }
        let glyph = layout.glyphIndex(for: point, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return }
        let character = layout.characterIndexForGlyph(at: glyph)
        if let match = entityRanges.first(where: { NSLocationInRange(character, $0.0) }) { onEntity?(match.1) }
    }
    override func drawText(in rect: CGRect) {
        var rect = rect
        if let typesetWidth {
            if textAlignment == .center { rect.origin.x += max(0, (rect.width-typesetWidth)/2) }
            rect.size.width = min(rect.width, typesetWidth)
        }
        super.drawText(in: rect)
    }
}
