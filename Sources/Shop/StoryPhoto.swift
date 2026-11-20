import SwiftUI

/// One picture for a behind-the-scenes story (DOMESTIC-STORY-ART/DESIGN.md §二).
/// P1: only the verified cover of a work that is already a card on this page and
/// whose name the story itself prints. Identity is settled, so the picture can't
/// be the wrong film; with no such card the story simply has no picture.
struct StoryPhoto: Equatable {
    let url: URL
    let caption: String

    @MainActor static func pick(story: String, items: [CrateItem], library: Library) -> StoryPhoto? {
        let text = LeadMatch.norm(story)
        let visual: Set<SeedGraph.Kind> = [.film, .tv, .game, .book, .manga]
        let candidates = items.compactMap { item -> (Int, StoryPhoto)? in
            guard visual.contains(item.entity.kind) else { return nil }
            let work = library.catalog.work(library.catalog.canonicalID(for: SeedLibraryBridge.workID(item.entity.id)))
            guard let url = URL(string: work.art), url.scheme == "https" else { return nil }
            let names = Set([item.entity.title, work.title, work.discovery?.canonicalTitle ?? ""] + (work.discovery?.aliases ?? []))
                .map(LeadMatch.norm).filter { $0.count >= 2 }
            guard let first = names.compactMap({ text.range(of: $0)?.lowerBound }).min() else { return nil }
            let kind = switch item.entity.kind { case .book, .manga: "封面"; case .game: "游戏封面"; default: "海报" }
            // Read out by VoiceOver only; nothing is printed under the picture (anson 2026-11-18).
            return (text.distance(from: text.startIndex, to: first), StoryPhoto(url: url, caption: "《\(item.entity.title)》\(kind)"))
        }
        // The work the story names first is the one it is about.
        return candidates.min { $0.0 < $1.0 }?.1
    }
}

/// The picture in the opened article, shaped by the picture itself (anson 2026-11-18 13:00: the
/// paper print letterboxed every poster in beige). A wide picture spans the column; a poster or a
/// book cover stands at its own shape on a dimmed, blurred copy of itself, so the column stays
/// full without bars. Nothing written under it, nothing stuck on it.
struct StoryPrintPhoto: View {
    let photo: StoryPhoto
    /// Width ÷ height; posters until the picture arrives (every candidate is a film, show, game or book).
    private func ratio(_ image: Image?) -> CGFloat {
        guard image != nil, let size = ArtworkImageCache.shared.image(photo.url)?.size, size.width > 0, size.height > 0 else { return 2.0 / 3.0 }
        return size.width / size.height
    }
    var body: some View {
        CachedArtworkImage(url: photo.url) { image, loading in
            let ratio = ratio(image)
            // The base sets the size; pictures sit in overlays so a filled picture never widens the column.
            Group {
                if ratio >= 0.95 {
                    // Wide or square: the picture is the frame.
                    Color.white.opacity(0.04)
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 300)
                        .overlay { if let image { image.resizable().scaledToFill().transition(.opacity) } }
                } else {
                    // Tall: the poster on its own colours.
                    Color.white.opacity(0.04)
                        .frame(maxWidth: .infinity).frame(height: 300)
                        .overlay {
                            if let image {
                                image.resizable().scaledToFill()
                                    .blur(radius: 28, opaque: true).saturation(0.85)
                                    .overlay(Color.black.opacity(0.42))
                                    .transition(.opacity)
                            }
                        }
                        .overlay {
                            if let image {
                                image.resizable().aspectRatio(ratio, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: 4))
                                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                                    .padding(.vertical, 20)
                                    .transition(.opacity)
                            }
                        }
                }
            }
            .overlay { if loading { CoverSheen(strength: 0.07).transition(.opacity) } }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            // A wide picture changes the column's height; that change is not animated, so the
            // text below never runs under a shrinking frame. A poster keeps its size and fades in.
            .animation(nil, value: ratio >= 0.95)
            .modifier(CoverReveal(value: image != nil ? CoverState.picture : loading ? .waiting : .printed))
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(photo.caption)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("story-photo")
    }
}
