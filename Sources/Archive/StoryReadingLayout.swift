import UIKit

/// Measure the complete story on a fixed reading canvas. Names retain their
/// ordinary text metrics and remain links; no body text is truncated.
struct StoryReadingLayout {
    let bodySize: CGFloat
    let lineSpacing: CGFloat
    let gap: CGFloat
    let inset: CGFloat
    let measuredHeight: CGFloat

    static func fitting(story: Story, size: CGSize, preferredBody: CGFloat) -> Self {
        let inset: CGFloat = size.width < 350 ? 20 : 24
        let width = max(100, size.width - inset * 2)
        let bodySize = min(21, max(16, preferredBody))
        let lineSpacing: CGFloat = 9, gap: CGFloat = 20
        let height = measure(story.body, font: .systemFont(ofSize: bodySize), width: width, spacing: lineSpacing)
            + gap * 3 + inset * 2 + 40
        return .init(bodySize: bodySize, lineSpacing: lineSpacing, gap: gap, inset: inset, measuredHeight: height)
    }
    static func previewFits(_ text: String, width: CGFloat, lines: Int) -> Bool {
        let font = UIFont.systemFont(ofSize: 14.5)
        let available = ceil(font.lineHeight) * CGFloat(lines) + CGFloat(max(0, lines - 1)) * 3
        return measure(text, font: font, width: max(1, width), spacing: 3) <= available + 1
    }
    private static func measure(_ text: String, font: UIFont, width: CGFloat, spacing: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = spacing
        return ceil((StoryTextPresentation.clean(text) as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph], context: nil).height)
    }
}
