import SwiftUI
import SafariServices

struct StoryLinkedText: View {
    let text: String
    let links: StoryTextLinks
    var linkColor: Color? = nil
    var onName: (StoryTextLinks.Target) -> Void
    private var attributed: AttributedString {
        let text = StoryTextPresentation.clean(text)
        var value = AttributedString(text)
        for span in links.spans(in: text) {
            guard let range = Range(span.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value),
                  let target = links.targets.first(where: { $0.name == span.name }) else { continue }
            value[lower..<upper].link = target.url
            value[lower..<upper].foregroundColor = linkColor ?? Color(red: 0.93, green: 0.79, blue: 0.57)
            value[lower..<upper].underlineStyle = .single
        }
        return value
    }
    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                guard let target = links.target(for: url) else { return .discarded }
                onName(target); return .handled
            })
    }
}

struct NowStoryView: View {
    let story: Story
    var compact = false
    var loading = false
    var scopeCaption: String? = nil
    var subjectEntityID: String? = nil
    var allowsRootSubject = true
    /// 0.3: the page has room, so show the story itself, not a two-line teaser.
    var roomy = false
    var paperMode = false
    var horizontalInset: CGFloat = 26
    /// When set, show the full story up to this many lines (the page measured its room).
    var maxLines: Int? = nil
    var onName: (StoryTextLinks.Target) -> Void
    private struct Reading: Identifiable {
        let story: Story
        let scope: String?
        let subject: String?
        let allowsRoot: Bool
        var id: String { story.id }
    }
    @State private var reading: Reading?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pending: StoryTextLinks.Target?
    @State private var source: StorySourcePage?
    @State private var textWidth: CGFloat = 0
    @Environment(Library.self) private var library
    private var links: StoryTextLinks { StoryInteractionPolicy.links(story, subjectID: subjectEntityID, library: library) }
    private var excerpt: StoryExcerpt { StoryExcerpt(story.body) }
    private var showsMore: Bool {
        if let maxLines { return textWidth > 0 && !StoryReadingLayout.previewFits(story.body, width: textWidth, lines: maxLines) }
        return roomy ? StoryValidator.visualWidth(story.body) > (compact ? 85 : 150) : excerpt.hasMore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let scopeCaption {
                Text(scopeCaption).font(.system(size: 11.5)).foregroundStyle(paperMode ? ArtworkPalette.paperInk.opacity(0.6) : ArtworkPalette.tx3)
                    .lineLimit(1).accessibilityIdentifier("story-subject")
            }
            StoryLinkedText(text: roomy || maxLines != nil ? story.body : excerpt.text, links: links,
                linkColor: paperMode ? Color(red: 0.48, green: 0.22, blue: 0.08) : nil, onName: onName)
                .font(.system(size: 14.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                .lineSpacing(3).lineLimit(maxLines ?? (roomy ? (compact ? 4 : 7) : excerpt.hasMore ? (compact ? 2 : 3) : nil))
                .foregroundStyle(paperMode ? ArtworkPalette.paperInk.opacity(0.86) : ArtworkPalette.tx2).accessibilityIdentifier("story-preview")
            HStack(alignment: .center, spacing: 12) {
                if let url = story.sourceURL {
                    Button { source = .init(url: url) } label: {
                        Text(story.source.title).lineLimit(1)
                    }.font(.system(size: 11.5)).foregroundStyle(paperMode ? ArtworkPalette.paperInk.opacity(0.62) : ArtworkPalette.tx3)
                        .accessibilityLabel("原文：" + story.source.title).accessibilityIdentifier("story-source")
                }
                Spacer(minLength: 0)
                if showsMore {
                    Button { reading = Reading(story: story, scope: scopeCaption, subject: subjectEntityID, allowsRoot: allowsRootSubject) } label: {
                        HStack(spacing: 4) { Text("读完整"); Image(systemName: "chevron.right") }
                    }.font(.system(size: 12.5, weight: .medium)).foregroundStyle(paperMode ? ArtworkPalette.paperInk : ArtworkPalette.tx)
                        .accessibilityLabel("读完整故事").accessibilityIdentifier("story-read")
                } else if loading {
                    ProgressView().controlSize(.mini).accessibilityLabel("故事加载中")
                }
            }.frame(minHeight: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalInset).padding(.top, compact ? 0 : 16)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { appeared = true } }
        .sheet(item: $reading, onDismiss: {
            if let target = pending { pending = nil; onName(target) }
        }) { selected in
            StoryReadingView(story: selected.story, scopeCaption: selected.scope, subjectEntityID: selected.subject, allowsRootSubject: selected.allowsRoot) { target in pending = target; reading = nil }
        }
        .sheet(item: $source) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
    }
}

/// Real work owns this view's lifetime; it never simulates a percentage.
struct StoryLoadingView: View {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<(compact ? 2 : 3), id: \.self) { index in
                    GeometryReader { proxy in
                        Capsule().fill(ArtworkPalette.tx2.opacity(0.24))
                            .frame(width: proxy.size.width * [1.0, 0.92, 0.61][index], height: 9)
                    }.frame(height: 10)
                }
            }.padding(.vertical, 4)
                .opacity(reduceMotion ? 0.7 : breathing ? 1 : 0.38)
            Text("故事加载中").font(.system(size: 11.5)).foregroundStyle(ArtworkPalette.tx3)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26).padding(.top, compact ? 0 : 16)
        .accessibilityElement(children: .ignore).accessibilityLabel("故事加载中")
        .accessibilityIdentifier("story-loading")
        .onAppear {
            if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true } }
        }
    }
}

private struct StoryReadingView: View {
    let story: Story
    var scopeCaption: String? = nil
    var subjectEntityID: String? = nil
    var allowsRootSubject = true
    let onName: (StoryTextLinks.Target) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @ScaledMetric(relativeTo: .body) private var preferredBody: CGFloat = 17
    @State private var source: StorySourcePage?
    @State private var showMentions = false
    @State private var pendingMention: StoryTextLinks.Target?
    private var links: StoryTextLinks { StoryInteractionPolicy.links(story, subjectID: subjectEntityID, library: library) }
    private var subject: Work? {
        guard subjectEntityID != nil || allowsRootSubject else { return nil }
        let key = library.catalog.canonicalID(for: SeedLibraryBridge.workID(subjectEntityID ?? story.entityID))
        return library.catalog.works[key]
    }
    // The full-page subject heading already names the scope. Keep the compact
    // page's caption only when no resolved subject can supply that heading.
    private var readingCaption: String? { subject == nil ? scopeCaption : nil }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = StoryReadingLayout.fitting(story: story, size: CGSize(width: geometry.size.width, height: geometry.size.height - (readingCaption == nil ? 0 : 28)), preferredBody: preferredBody)
                ScrollView {
                VStack(alignment: .leading, spacing: layout.gap) {
                    if let readingCaption { Text(readingCaption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    if let subject {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subject.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(ArtworkPalette.tx).lineLimit(2)
                            let kind = subject.isMusicWork ? "乐曲" : subject.isSong ? "录音" : subject.kind
                            let detail = [subject.creator, kind, subject.releaseDate.map { String($0.prefix(4)) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                            Text(detail).font(.system(size: 13)).foregroundStyle(ArtworkPalette.tx2).lineLimit(2)
                        }.accessibilityIdentifier("story-full-subject")
                    }
                    StoryLinkedText(text: story.body, links: links, onName: onName)
                        .font(.system(size: layout.bodySize, weight: .regular)).lineSpacing(layout.lineSpacing)
                        .foregroundStyle(ArtworkPalette.tx)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("story-full-body")
                    Spacer(minLength: 0)
                    Divider()
                    HStack(spacing: 16) {
                        if let url = story.sourceURL {
                            Button { source = .init(url: url) } label: {
                                HStack {
                                    Text("原文 · " + story.source.title).multilineTextAlignment(.leading).lineLimit(2)
                                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                                }
                            }.accessibilityIdentifier("story-full-source")
                        }
                        if let additional = story.additionalSources, !additional.isEmpty {
                            Menu {
                                ForEach(Array(additional.enumerated()), id: \.offset) { _, item in
                                    if let url = URL(string: item.url), ["http", "https"].contains(url.scheme ?? "") {
                                        Button(item.title) { source = .init(url: url) }
                                    }
                                }
                            } label: { Text("等 \(additional.count + 1) 处").font(.system(size: 12)) }
                                .accessibilityLabel("更多出处")
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 14)).tint(Color(red: 0.93, green: 0.79, blue: 0.57))
                }.padding(layout.inset).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }.scrollBounceBehavior(.basedOnSize)
            }
            .background(ShopNowPage.base).navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("关闭", systemImage: "xmark") { dismiss() }.tint(.primary).accessibilityIdentifier("story-close")
            } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .sheet(item: $source) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: $showMentions, onDismiss: {
            if let target = pendingMention { pendingMention = nil; onName(target) }
        }) {
            NavigationStack {
                List(links.distinctTargets, id: \.name) { target in
                    Button { pendingMention = target; showMentions = false } label: {
                        HStack(spacing: 12) {
                            if let raw = target.entityID {
                                let id = library.catalog.canonicalID(for: SeedLibraryBridge.workID(raw)), work = library.catalog.work(id)
                                ShopCover(artwork: work.art, title: work.title, workID: id).frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 4))
                            }
                            Text(target.name).font(.system(size: 15, weight: .medium)).foregroundStyle(ArtworkPalette.tx)
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                }.scrollContentBackground(.hidden).background(ShopNowPage.base)
                    .navigationTitle("故事里提到的").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { showMentions = false }.tint(.primary) } }
            }.presentationDetents([.medium, .large])
        }
    }
}

struct StoryReadingFooter: View {
    let story: Story
    let links: StoryTextLinks
    let onName: (StoryTextLinks.Target) -> Void
    @Environment(Library.self) private var library
    @State private var source: StorySourcePage?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            // The names are opened where they stand in the text; the separate「故事里提到的」
            // list is gone, and with it the button that was left here without a title.
            sourceActions
        }.font(.system(size: 14)).tint(Color(red: 0.93, green: 0.79, blue: 0.57))
        .sheet(item: $source) { StorySourceBrowser(url: $0.url).ignoresSafeArea() }
    }
    private var sourceActions: some View {
        HStack(spacing: 12) {
                if let url = story.sourceURL {
                    Button { source = .init(url: url) } label: {
                        HStack(spacing: 4) {
                            Text("原文 · " + story.source.title).multilineTextAlignment(.leading).lineLimit(2)
                            Image(systemName: "arrow.up.right").font(.system(size: 11))
                        }
                    }.accessibilityIdentifier("story-full-source")
                }
                if let additional = story.additionalSources, !additional.isEmpty {
                    Menu {
                        ForEach(Array(additional.enumerated()), id: \.offset) { _, item in
                            if let url = URL(string: item.url), ["http", "https"].contains(url.scheme ?? "") {
                                Button(item.title) { source = .init(url: url) }
                            }
                        }
                    } label: { Text("等 \(additional.count + 1) 处").font(.system(size: 12)) }
                }
        }
    }
}

struct StorySourcePage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
struct StorySourceBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
