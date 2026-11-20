import SwiftUI
import UIKit

/// Authored spaces are the only wrap opportunities; long words truncate.
struct SpaceWrappedTitle: View {
    let title: String
    let width: CGFloat
    var size: CGFloat = 13.5
    var weight: Font.Weight = .medium
    private var lines: [String] {
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [title] }
        if words.count == 2, title.contains(where: { !$0.isASCII }) { return words }
        let font = UIFont.systemFont(ofSize: size, weight: .medium)
        var first = words[0]
        var index = 1
        while index < words.count {
            let candidate = first + " " + words[index]
            guard (candidate as NSString).size(withAttributes: [.font: font]).width <= width else { break }
            first = candidate; index += 1
        }
        return index == words.count ? [first] : [first, words[index...].joined(separator: " ")]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: size, weight: weight)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: width, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}
