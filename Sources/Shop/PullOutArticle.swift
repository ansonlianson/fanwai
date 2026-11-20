import SwiftUI
import UIKit

struct PullOutArticle<Header: View, Empty: View>: View {
    let reader: PullOutReader
    let current: PullOutStorySnapshot?
    let width: CGFloat
    let height: CGFloat
    let restTitleTop: CGFloat
    let expandedTitleTop: CGFloat
    let fadeStart: CGFloat
    let bottomInset: CGFloat
    let onName: (StoryTextLinks.Target, Source) -> Void
    /// One verified picture for the story (StoryPhoto.pick); nil means none.
    var photo: StoryPhoto? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty
    @Environment(Library.self) private var library
    @Environment(PullOutReaders.self) private var readers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var preferredBody: CGFloat = 16
    @State private var position = ScrollPosition(y: 0)
    @State private var contentHeight: CGFloat = 0
    @State private var nativeScrollPhase = ScrollPhase.idle
    @State private var scrollToRestore: CGFloat?
    @State private var restoreTask: Task<Void, Never>?
    @State private var waitingForTop = false
    @State private var dragMode: ReaderVerticalPan.Mode?
    private var snapshot: PullOutStorySnapshot? { reader.pinned ?? current }
    private var cardTop: CGFloat { restTitleTop - 20 }
    private var travel: CGFloat { max(1, restTitleTop - expandedTitleTop) }
    private var bodySize: CGFloat { min(28, max(14, preferredBody)) }

    var body: some View {
        PullOutArticleSurface(reader: reader, origin: cardTop, width: width, height: max(1, height - (expandedTitleTop - 20))) {
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header()
                        if let selected = snapshot {
                            if let scope = selected.scope {
                                Text(scope).font(.system(size: 12)).foregroundStyle(ArtworkPalette.tx3)
                                    .padding(.top, 16).accessibilityIdentifier("story-subject")
                            }
                            let links = StoryInteractionPolicy.links(selected.story, subjectID: selected.subject, library: library)
                            PullOutLinkedText(text: selected.story.body, links: links, size: bodySize, onName: { onName($0, selected.story.source) })
                                .padding(.top, selected.scope == nil ? 16 : 6)
                            if let photo { StoryPrintPhoto(photo: photo).padding(.top, 24) }
                            StoryReadingFooter(story: selected.story, links: links, onName: { onName($0, selected.story.source) }).padding(.top, 22)
                            if reader.hasUpdate {
                                Text("资料已更新 · 收起后换成新版本").font(.system(size: 12.5)).foregroundStyle(ArtworkPalette.tx3).padding(.top, 14)
                            }
                        } else { empty().padding(.top, 16) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26).padding(.top, 20)
                    .background(ReaderScrollAnchor(reader: reader).allowsHitTesting(false))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; updateExpandability(); restoreAfterLayout() }
                    .padding(.bottom, bottomInset)
                }
                .scrollIndicators(.hidden).scrollBounceBehavior(.always)
                .scrollDisabled(reader.phase != .expanded)
                .scrollPosition($position)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, value in
                    if reader.phase == .expanded, nativeScrollPhase != .idle, scrollToRestore == nil { reader.recordScroll(max(0, value)) }
                    if waitingForTop && abs(value) < 1 { waitingForTop = false; settle(expanded: false) }
                }
                .onScrollPhaseChange { _, new, context in
                    nativeScrollPhase = new
                    if new == .interacting { restoreTask?.cancel(); scrollToRestore = nil }
                    if new == .idle, reader.phase == .expanded, scrollToRestore == nil {
                        reader.recordScroll(max(0, context.geometry.contentOffset.y + context.geometry.contentInsets.top))
                    }
                }
                // This tap surface shares the ancestor pan recognizer. A drag
                // starting in the dimmed lines remains a drag, never a button tap.
                PullOutExpandArea(reader: reader, width: width, y: fadeStart - cardTop, height: 66 * width / 402)
            }
            .contentShape(.rect)
            .gesture(ReaderVerticalPan(reader: reader, began: dragBegan, changed: dragChanged, ended: dragEnded))
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("pull-out-article")
        .accessibilityValue(accessibilityState).accessibilityHint(interactionHint)
        .accessibilityAction(named: "展开故事") { expand() }
        .accessibilityAction(named: "收起故事") { close() }
        .sensoryFeedback(.impact(weight: .light), trigger: reader.feedback)
        .onAppear {
            readers.active = reader; reader.travel = travel
            if let pinned = reader.pinned, pinned.key != current?.key { reader.reset() }
            if reader.phase == .tracking || reader.phase == .collapsing { reader.phase = reader.progress >= 0.5 ? .expanded : .rest }
            withoutAnimation {
                reader.move(to: reader.phase == .expanded ? travel : 0)
                reader.moveCabinet(to: reader.phase == .expanded ? 1 : 0)
            }
            scrollToRestore = reader.phase == .expanded ? reader.scrollOffset : nil
            restoreAfterLayout(); updateExpandability()
        }
        .onDisappear { restoreTask?.cancel(); readers.leave(reader) }
        .onChange(of: current?.key) { _, _ in
            if reader.isReading { reader.hasUpdate = current?.key != reader.pinned?.key }
            else { reader.pinned = nil; updateExpandability() }
        }
        .onChange(of: reader.openRequest) { _, _ in expand() }
        .onChange(of: reader.closeRequest) { _, _ in close() }
        .onChange(of: travel) { _, value in
            let p = reader.progress; reader.travel = value
            withoutAnimation { reader.move(to: p * value) }
        }
    }

    private func restoreAfterLayout() {
        guard let saved = scrollToRestore, contentHeight > 0 else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            position.scrollTo(y: saved)
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollToRestore = nil
        }
    }
    private func dragBegan(_ mode: ReaderVerticalPan.Mode, _ time: TimeInterval) {
        waitingForTop = false; restoreTask?.cancel(); scrollToRestore = nil
        reader.generation += 1; dragMode = mode
        reader.dragOrigin = reader.presentedOffset
        reader.cabinetLocked = mode != .closing && abs(reader.presentedCabinet - PullOutReader.clamped(reader.presentedOffset / travel)) < 0.02
        reader.samples = [(time, 0)]; reader.pinned = reader.pinned ?? current
        withoutAnimation {
            reader.move(to: reader.presentedOffset)
            reader.moveCabinet(to: reader.presentedCabinet)
            if mode == .closing { position.scrollTo(edge: .top) }
        }
        reader.phase = .tracking
    }
    private func dragChanged(_ translation: CGFloat, _ time: TimeInterval) {
        guard let mode = dragMode, let origin = reader.dragOrigin else { return }
        reader.samples.append((time, translation)); reader.samples.removeAll { time - $0.time > 0.08 }
        withoutAnimation {
            let value = mode == .closing
                ? PullOutReader.returning(pull: max(0, travel - origin + translation), travel: travel, length: height)
                : PullOutReader.follows(origin - translation, travel: travel, length: height)
            reader.move(to: value)
            if reader.cabinetLocked { reader.moveCabinet(to: reader.progress) }
        }
    }
    private func dragEnded(_ translation: CGFloat, _ time: TimeInterval, _ cancelled: Bool) {
        guard let mode = dragMode, let origin = reader.dragOrigin else { return }
        var downward: CGFloat = 0
        if let last = reader.samples.last, time - last.time < 0.05, let first = reader.samples.first, time > first.time {
            downward = (translation - first.y) / (time - first.time)
        }
        let expanded = cancelled ? mode == .closing : mode == .closing
            ? !PullOutReader.shouldCollapse(pull: max(0, travel - origin + translation), downwardVelocity: downward, travel: travel)
            : PullOutReader.shouldExpand(offset: reader.offset, velocity: -downward, travel: travel)
        reader.lastGesture = "mode=\(mode), drag=\(translation), offset=\(reader.offset), velocity=\(downward), expand=\(expanded)"
        reader.dragOrigin = nil; reader.samples = []; dragMode = nil
        settle(expanded: expanded, velocity: -downward)
    }
    private var interactionHint: String {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") { return reader.lastGesture }
        #endif
        return ""
    }
    private var accessibilityState: String {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") { return reader.phase.rawValue + "; " + reader.lastGesture }
        #endif
        return reader.phase.rawValue
    }
    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { action(); reader.presentedOffset = reader.offset; reader.presentedCabinet = reader.cabinet }
    }
    private func updateExpandability() {
        let can = current != nil && contentHeight > max(0, fadeStart - cardTop) + 2
        if reader.canExpand != can { reader.canExpand = can }
    }
    private func expand() {
        guard reader.canExpand else { return }
        reader.pinned = reader.pinned ?? current; settle(expanded: true)
    }
    private func close() {
        if reader.scrollOffset > 1 {
            waitingForTop = true
            withAnimation(.easeOut(duration: 0.18)) { position.scrollTo(edge: .top) }
        } else { settle(expanded: false) }
    }
    private func settle(expanded: Bool, velocity: CGFloat = 0) {
        reader.generation += 1; let generation = reader.generation
        let target = expanded ? travel : 0
        if expanded { reader.pinned = reader.pinned ?? current }
        reader.phase = expanded ? .tracking : .collapsing
        let reduced = PianwaiRuntime.reduceMotion(reduceMotion)
        let animation = reader.spring(to: target, velocity: velocity, reduceMotion: reduced)
        let locked = abs(reader.cabinet - reader.progress) < 0.02
        let cabinetAnimation = locked ? animation : reader.spring(to: target, velocity: 0, reduceMotion: reduced)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            reader.move(to: target)
            withTransaction(Transaction(animation: cabinetAnimation)) { reader.moveCabinet(to: expanded ? 1 : 0) }
        } completion: {
            guard reader.generation == generation else { return }
            reader.phase = expanded ? .expanded : .rest
            reader.presentedOffset = target; reader.presentedCabinet = expanded ? 1 : 0; reader.feedback += 1
            if !expanded {
                reader.pinned = nil; reader.hasUpdate = false; reader.scrollOffset = 0
                position.scrollTo(edge: .top)
                let action = reader.afterClose; reader.afterClose = nil; action?()
            }
        }
    }
}

struct PullOutExpandArea: View {
    let reader: PullOutReader
    let width: CGFloat
    let y: CGFloat
    let height: CGFloat
    var body: some View {
        if reader.canExpand {
            Color.clear.frame(width: width, height: height).contentShape(.rect)
                .onTapGesture { reader.openRequest += 1 }
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel("展开故事").accessibilityIdentifier("story-expand")
                .allowsHitTesting(max(reader.progress, reader.cabinet) < 0.05)
                .accessibilityHidden(max(reader.progress, reader.cabinet) >= 0.05)
                .offset(y: y)
        }
    }
}

/// Resolve only this article's native scroll ancestor, never another page's scroll.
struct ReaderScrollAnchor: UIViewRepresentable {
    let reader: PullOutReader
    func makeUIView(context: Context) -> Anchor { let view = Anchor(); view.reader = reader; return view }
    func updateUIView(_ view: Anchor, context: Context) { view.reader = reader; view.resolve() }
    final class Anchor: UIView {
        weak var reader: PullOutReader?
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }
        func resolve() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { reader?.scrollView = scroll; return }
                ancestor = view.superview
            }
        }
    }
}

/// The article's pan gets first refusal. Only a downwards gesture whose touch
/// began at the top is a close; a scroll that later reaches the top stays native.
struct ReaderVerticalPan: UIGestureRecognizerRepresentable {
    enum Mode { case opening, closing }
    let reader: PullOutReader
    let began: (Mode, TimeInterval) -> Void
    let changed: (CGFloat, TimeInterval) -> Void
    let ended: (CGFloat, TimeInterval, Bool) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(self) }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer(); pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator; return pan
    }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) { context.coordinator.parent = self }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let c = context.coordinator, translation = recognizer.location(in: nil).y - context.coordinator.touchY, time = CACurrentMediaTime()
        switch recognizer.state {
        case .began:
            guard let mode = c.mode else { return }
            // Remove only the recognition slop, not the whole first delivered
            // sample. A quick 25pt flick may arrive in one began event.
            c.start = translation.sign == .minus ? -min(10, abs(translation)) : min(10, abs(translation))
            began(mode, time); changed(translation - c.start, time)
        case .changed: changed(translation - c.start, time)
        case .ended, .cancelled:
            ended(translation - c.start, time, recognizer.state == .cancelled); c.mode = nil
        default: break
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReaderVerticalPan
        var atTopOnTouch = false
        var mode: Mode?
        var start: CGFloat = 0
        var touchY: CGFloat = 0
        init(_ parent: ReaderVerticalPan) { self.parent = parent }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchY = touch.location(in: nil).y
            if let scroll = parent.reader.scrollView {
                atTopOnTouch = scroll.contentOffset.y + scroll.adjustedContentInset.top <= 0.5
            } else { atTopOnTouch = false }
            return true
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard parent.reader.canExpand, let pan = recognizer as? UIPanGestureRecognizer else { return false }
            var v = pan.translation(in: nil); if v == .zero { v = pan.velocity(in: nil) }
            guard abs(v.y) > 1.5 * abs(v.x) else { return false }
            switch parent.reader.phase {
            case .rest: guard v.y < 0 else { return false }; mode = .opening
            case .expanded: guard atTopOnTouch, v.y > 0 else { return false }; mode = .closing
            case .tracking, .collapsing:
                let headingOpen = parent.reader.offset >= parent.reader.travel - 0.5
                mode = headingOpen && v.y > 0 ? .closing : .opening
            }
            return true
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === parent.reader.scrollView?.panGestureRecognizer
        }
    }
}

/// Native TextKit wrapping prevents CJK punctuation strategy from inserting a
/// conspicuous gap at a wrapped closing book-title bracket. Saved text is literal.
struct PullOutLinkedText: UIViewRepresentable {
    let text: String
    let links: StoryTextLinks
    let size: CGFloat
    let onName: (StoryTextLinks.Target) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator; view.accessibilityIdentifier = "story-full-body"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.text != text || context.coordinator.targets != links.targets || context.coordinator.size != size else { return }
        context.coordinator.text = text; context.coordinator.targets = links.targets; context.coordinator.size = size
        let clean = StoryTextPresentation.clean(text), value = NSMutableAttributedString(string: clean)
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = size * 1.5625; paragraph.maximumLineHeight = size * 1.5625
        paragraph.lineBreakStrategy = []; paragraph.lineBreakMode = .byWordWrapping
        value.addAttributes([.font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor(red: 0.93, green: 0.92, blue: 0.89, alpha: 0.88), .paragraphStyle: paragraph], range: NSRange(location: 0, length: value.length))
        for span in links.spans(in: clean) {
            if let target = links.targets.first(where: { $0.name == span.name }) { value.addAttribute(.link, value: target.url, range: span.range) }
        }
        // Names read as text; a quiet dotted underline says they can be opened (AHA-PLAN §5).
        view.linkTextAttributes = [.foregroundColor: UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1),
                                   .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                                   .underlineColor: UIColor(red: 0.86, green: 0.80, blue: 0.65, alpha: 0.75)]
        if view.attributedText != value { view.attributedText = value }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PullOutLinkedText
        var text: String?
        var targets: [StoryTextLinks.Target] = []
        var size: CGFloat = 0
        init(_ parent: PullOutLinkedText) { self.parent = parent }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if let target = parent.links.target(for: URL) { parent.onName(target) }
            return false
        }
    }
}
