import SwiftUI
import Observation
import UIKit

struct PullOutStorySnapshot {
    let story: Story
    let scope: String?
    let subject: String?
    let allowsRoot: Bool
    var key: String { story.id + "|" + story.body }
}

/// Reading state survives navigation; it never controls playback or research.
@MainActor @Observable final class PullOutReader {
    enum Phase: String { case rest, tracking, expanded, collapsing }
    var phase = Phase.rest { didSet { updateReadingState() } }
    var offset: CGFloat = 0 { didSet { updateReadingState() } }
    var cabinet: CGFloat = 0
    var travel: CGFloat = 165 { didSet { updateReadingState() } }
    private(set) var isReading = false
    var scrollOffset: CGFloat = 0
    var canExpand = false
    var pinned: PullOutStorySnapshot?
    var hasUpdate = false
    var openRequest = 0
    var closeRequest = 0
    var feedback = 0
    @ObservationIgnored var afterClose: (() -> Void)?
    @ObservationIgnored var dragOrigin: CGFloat?
    @ObservationIgnored var samples: [(time: TimeInterval, y: CGFloat)] = []
    @ObservationIgnored var generation = 0
    @ObservationIgnored var presentedOffset: CGFloat = 0
    @ObservationIgnored var presentedCabinet: CGFloat = 0
    @ObservationIgnored var cabinetLocked = true
    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored var lastGesture = "none"

    var progress: CGFloat { min(1, max(0, offset / max(1, travel))) }
    private func updateReadingState() {
        let next = phase != .rest || progress > 0.1
        if isReading != next { isReading = next }
    }
    func move(to value: CGFloat) { if abs(offset - value) > 0.01 { offset = value } }
    func recordScroll(_ value: CGFloat) { if abs(scrollOffset - value) > 0.01 { scrollOffset = value } }
    func moveCabinet(to value: CGFloat) {
        let next = Self.clamped(value)
        if abs(cabinet - next) > 0.0001 { cabinet = next }
    }
    static func clamped(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    static let response: Double = 0.42
    static let damping: Double = 0.88

    static func rubber(_ distance: CGFloat, length: CGFloat) -> CGFloat {
        let x = max(0, distance), d = max(1, length)
        return (1 - 1 / (x * 0.55 / d + 1)) * d
    }
    static func follows(_ raw: CGFloat, travel: CGFloat, length: CGFloat) -> CGFloat {
        if raw < 0 { return 0 }
        if raw > travel { return travel + rubber(raw - travel, length: length) }
        return raw
    }
    static func shouldExpand(offset: CGFloat, velocity: CGFloat, travel: CGFloat) -> Bool {
        offset + velocity * 0.25 >= 0.33 * travel
    }
    static func returning(pull: CGFloat, travel: CGFloat, length: CGFloat) -> CGFloat {
        let down = max(0, pull)
        return travel - (down > travel ? travel + rubber(down - travel, length: length) : down)
    }
    static func shouldCollapse(pull: CGFloat, downwardVelocity: CGFloat, travel: CGFloat = 165) -> Bool {
        pull >= 8 && pull + downwardVelocity * 0.25 >= 0.33 * travel
    }
    func spring(to target: CGFloat, velocity: CGFloat = 0, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.2) }
        let omega = 2 * Double.pi / Self.response
        let difference = target - offset
        let normalized = abs(difference) > 1 ? Double(velocity / difference) : 0
        return .interpolatingSpring(mass: 1, stiffness: omega * omega,
            damping: 2 * Self.damping * omega, initialVelocity: max(-12, min(12, normalized)))
    }
    func requestClose(then action: (() -> Void)? = nil) {
        afterClose = action; closeRequest += 1
    }
    func reset() {
        generation += 1; phase = .rest; offset = 0; cabinet = 0
        presentedOffset = 0; presentedCabinet = 0; scrollOffset = 0
        pinned = nil; hasUpdate = false; dragOrigin = nil; samples = []
    }
}

/// Keep per-frame transforms outside the article's content builder. Passing an
/// already-built value means motion doesn't rebuild links or TextKit content.
struct PullOutArticleSurface<Content: View>: View {
    let reader: PullOutReader
    let origin: CGFloat
    let width: CGFloat
    let height: CGFloat
    let content: Content
    init(reader: PullOutReader, origin: CGFloat, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        self.reader = reader; self.origin = origin; self.width = width; self.height = height; self.content = content()
    }
    var body: some View {
        content.background {
            LinearGradient(colors: [Color(red: 0.024, green: 0.008, blue: 0), Color(red: 0.071, green: 0.043, blue: 0.012)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) { Color.white.opacity(0.06 * reader.progress).frame(height: 0.5) }
        }
        .frame(width: width, height: height, alignment: .top).clipped()
        .modifier(PullOutArticlePosition(offset: reader.offset, origin: origin, reader: reader, generation: reader.generation))
    }
}

struct PullOutHeroHitArea<Content: View>: View {
    let reader: PullOutReader
    let content: Content
    init(reader: PullOutReader, @ViewBuilder content: () -> Content) { self.reader = reader; self.content = content() }
    var body: some View { content.allowsHitTesting(!reader.isReading) }
}

/// Capture presentation position, not the already-assigned spring destination,
/// when a finger interrupts an in-flight animation. No published state is mutated
/// during rendering, and callbacks from an older interaction are ignored.
struct PullOutArticlePosition: AnimatableModifier {
    nonisolated var offset: CGFloat
    let origin: CGFloat
    let reader: PullOutReader
    let generation: Int
    nonisolated var animatableData: CGFloat {
        get { offset }
        set {
            offset = newValue
            let state = reader, token = generation, value = newValue
            Task { @MainActor in
                if state.generation == token { state.presentedOffset = value }
            }
        }
    }
    func body(content: Content) -> some View { content.offset(y: origin - offset) }
}

@MainActor @Observable final class PullOutReaders {
    var active: PullOutReader?
    @ObservationIgnored private var entries: [String: PullOutReader] = [:]
    @ObservationIgnored private var recent: [String] = []
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func reader(for id: String) -> PullOutReader {
        if let value = entries[id] { return value }
        let value = PullOutReader(); entries[id] = value
        recent.removeAll { $0 == id }; recent.append(id)
        while recent.count > 40 { entries.removeValue(forKey: recent.removeFirst()) }
        return value
    }
    func leave(_ reader: PullOutReader) { if active === reader { active = nil; reader.afterClose = nil } }
    func closeThen(_ action: @escaping () -> Void) {
        guard let active, active.isReading else { action(); return }
        active.requestClose(then: action)
    }
    func claimHint() -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") { return false }
        #endif
        let key = "pianwai.reader-hints.v1", count = defaults.integer(forKey: key)
        guard count < 3 else { return false }
        defaults.set(count + 1, forKey: key); return true
    }
}

/// Each scene layer uses the same interpolated progress, without a second
/// smoothstep timeline that starts the cabinet late and stops it early.
struct PullOutSceneMotion: AnimatableModifier {
    enum Layer { case hero, cabinet, fade }
    nonisolated var progress: CGFloat
    let layer: Layer
    let travel: CGFloat
    let cabinetExit: CGFloat
    let reduceMotion: Bool
    var reader: PullOutReader? = nil
    var generation: Int = 0
    nonisolated var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            if layer == .cabinet, let state = reader {
                let token = generation, value = newValue
                Task { @MainActor in if state.generation == token { state.presentedCabinet = Self.bound(value) } }
            }
        }
    }
    nonisolated static func bound(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    nonisolated static func displacement(progress: CGFloat, layer: Layer, travel: CGFloat, cabinetExit: CGFloat) -> CGFloat {
        let p = bound(progress)
        return layer == .hero ? -0.55 * travel * p : layer == .cabinet ? cabinetExit * p : 0
    }
    func body(content: Content) -> some View {
        let p = min(1, max(0, progress))
        switch layer {
        case .hero:
            content.offset(y: reduceMotion ? 0 : Self.displacement(progress: progress, layer: layer, travel: travel, cabinetExit: cabinetExit))
                .overlay(Color.black.opacity(0.45 * p).allowsHitTesting(false))
        case .cabinet:
            content.offset(y: reduceMotion ? 0 : Self.displacement(progress: progress, layer: layer, travel: travel, cabinetExit: cabinetExit))
                .opacity(reduceMotion ? 1 - p : 1 - max(0, (p - 0.9) / 0.1))
        case .fade: content.opacity(1 - min(1, p / 0.35))
        }
    }
}

struct PullOutSceneLayer<Content: View>: View {
    let reader: PullOutReader
    let layer: PullOutSceneMotion.Layer
    let travel: CGFloat
    let cabinetExit: CGFloat
    let reduceMotion: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().modifier(PullOutSceneMotion(progress: layer == .hero ? reader.progress : reader.cabinet, layer: layer,
            travel: travel, cabinetExit: cabinetExit, reduceMotion: reduceMotion, reader: reader, generation: reader.generation))
            .allowsHitTesting(layer == .cabinet ? reader.cabinet < 0.3 : layer == .hero ? reader.progress < 0.02 : false)
            .accessibilityHidden(layer == .cabinet && reader.cabinet >= 0.3)
    }
}

struct PullOutToolbarAction: View {
    let reader: PullOutReader
    let hasGraph: Bool
    let onGraph: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One button that stays in the toolbar with a fixed size. Only its symbol changes, as a
    /// symbol replacement inside the same glass, so the capsule never jumps in width when the
    /// story opens or closes or when the bin fills in (Apple's Liquid Glass guidance: keep
    /// toolbar items stable and let content change inside them).
    var body: some View {
        let reading = reader.isReading
        Button { if reading { reader.requestClose() } else { onGraph() } } label: {
            Image(systemName: reading ? "chevron.down" : "point.3.connected.trianglepath.dotted")
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 28, height: 28)
                .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: reading)
        }
        .disabled(!reading && !hasGraph)
        .accessibilityLabel(reading ? "收起故事" : "关系图")
        .accessibilityIdentifier(reading ? "story-collapse" : "now-graph")
    }
}

struct PullOutMore: View {
    let reader: PullOutReader
    let width: CGFloat
    let y: CGFloat
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    var body: some View {
        if reader.canExpand {
            let size = min(22, max(14, bodySize - 1)), row = max(25, size * 1.5625)
            Text("更多").font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color(red: 0.86, green: 0.80, blue: 0.65)).fixedSize()
                .padding(.leading, 52).frame(height: row + 8)
                .background {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, Color(red: 0.071, green: 0.043, blue: 0.012)], startPoint: .leading, endPoint: .trailing).frame(width: 52)
                        Color(red: 0.071, green: 0.043, blue: 0.012)
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 4 / (row + 8)),
                    .init(color: .white, location: (row + 4) / (row + 8)), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(width: width - 52, alignment: .trailing)
                .opacity(1 - min(1, max(reader.progress, reader.cabinet) / 0.2))
                .position(x: width / 2, y: y - reader.offset)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct PullOutFade: View {
    let reader: PullOutReader
    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    let reduceMotion: Bool
    var body: some View {
        if reader.canExpand {
            VStack(spacing: 0) {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                .init(color: Color(red: 0.071, green: 0.043, blue: 0.012).opacity(0.55), location: 0.45),
                .init(color: Color(red: 0.071, green: 0.043, blue: 0.012).opacity(0.93), location: 0.76),
                .init(color: Color(red: 0.071, green: 0.043, blue: 0.012), location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: max(1, bottom - top))
                // The cabinet has transparent gaps above the dividers. Keep
                // the remaining article hidden there instead of revealing a
                // bright line of text below the end of the gradient.
                Color(red: 0.071, green: 0.043, blue: 0.012).frame(height: max(0, height - bottom))
            }.frame(width: width).offset(y: top)
                .modifier(PullOutSceneMotion(progress: reader.cabinet, layer: .fade,
                    travel: reader.travel, cabinetExit: 0, reduceMotion: reduceMotion))
                .allowsHitTesting(false)
        }
    }
}
