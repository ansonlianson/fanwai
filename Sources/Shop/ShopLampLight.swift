import SwiftUI
import CoreMotion
import UIKit

// What the display spotlight does while the record plays (anson 11-18 20:00, 方案2 of
// Design/review/PLAYING-MOTION): dust drifting through its cone, a sheen across the vinyl's
// grooves and a glint on the PVC outer sleeve. The two reflections move a little as the phone
// moves in the hand. All of it is the lamp's own light: it scales with the lamp and is gone
// when the lamp is off. Numbers are plate pixels (1206 × 2622) and match render_motion3.py.

/// How far the phone has turned from the way it has recently been held, about ±1 at ±10°.
/// Only the reflections read it, so its 30 Hz updates redraw nothing else.
@MainActor @Observable final class LampTilt {
    static let shared = LampTilt()
    private(set) var value = CGPoint.zero
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var rest: CMQuaternion?
    @ObservationIgnored private var demo: Timer?

    func acquire() { users += 1; if users == 1 { start() } }
    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        motion.stopDeviceMotionUpdates(); demo?.invalidate(); demo = nil; rest = nil
        value = .zero
    }

    private func start() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-lamp-tilt-demo") {
            // The simulator has no gyroscope: the hand movement used in the approved mock.
            let start = Date()
            demo = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let ph = 2 * Double.pi * Date().timeIntervalSince(start) / 14.4
                    LampTilt.shared.value = CGPoint(x: 0.8 * sin(ph) + 0.25 * sin(3 * ph + 1),
                                                    y: 0.55 * cos(2 * ph + 0.5) + 0.2 * sin(5 * ph))
                }
            }
            return
        }
        #endif
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let q = data?.attitude.quaternion else { return }
            MainActor.assumeIsolated { LampTilt.shared.update(q) }
        }
    }

    /// The resting pose follows the hand over a few seconds, so whichever way the phone is held
    /// (standing, lying down) counts as straight on, and only turning it moves the light.
    private func update(_ q: CMQuaternion) {
        var r = rest ?? q
        if r.x * q.x + r.y * q.y + r.z * q.z + r.w * q.w < 0 { r = CMQuaternion(x: -r.x, y: -r.y, z: -r.z, w: -r.w) }
        let follow = (1.0 / 30) / 4.0
        r = Self.normalized(CMQuaternion(x: r.x + (q.x - r.x) * follow, y: r.y + (q.y - r.y) * follow,
                                         z: r.z + (q.z - r.z) * follow, w: r.w + (q.w - r.w) * follow))
        rest = r
        // Turn since rest, in the device's own axes: conj(rest) · now.
        let d = Self.multiply(CMQuaternion(x: -r.x, y: -r.y, z: -r.z, w: r.w), q)
        let sign: Double = d.w < 0 ? -1 : 1
        let aboutX = 2 * d.x * sign, aboutY = 2 * d.y * sign   // radians, small angles
        // Turning the right edge away puts the eye on the record's left, so the reflection
        // goes left; tipping the top edge towards you puts the eye above, so it goes up.
        let target = CGPoint(x: tanh(-aboutY / 0.175), y: tanh(-aboutX / 0.175))
        let next = CGPoint(x: value.x + (target.x - value.x) * 0.35, y: value.y + (target.y - value.y) * 0.35)
        if abs(next.x - value.x) > 0.002 || abs(next.y - value.y) > 0.002 { value = next }
    }
    private static func multiply(_ a: CMQuaternion, _ b: CMQuaternion) -> CMQuaternion {
        CMQuaternion(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                     y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                     z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                     w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }
    private static func normalized(_ q: CMQuaternion) -> CMQuaternion {
        let n = max(1e-9, (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot())
        return CMQuaternion(x: q.x / n, y: q.y / n, z: q.z / n, w: q.w / n)
    }
}

/// Holds the tilt sensor only while the lamp is on and the page is on screen.
private struct LampTiltSubscription: ViewModifier {
    let wanted: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var holding = false
    @State private var onScreen = false
    func body(content: Content) -> some View {
        let want = wanted && onScreen && scenePhase == .active
        content
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false; set(false) }
            .onChange(of: want, initial: true) { _, on in set(on) }
    }
    private func set(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        if on { LampTilt.shared.acquire() } else { LampTilt.shared.release() }
    }
}

enum LampLight {
    static let warm = Color(red: 1.0, green: 0.86, blue: 0.68)
    /// exp(-(x/w)²) sampled at x = 0, w/2, w, 1.5w, 2w, 3w.
    static let falloff: [(CGFloat, Double)] = [(0, 1), (0.5, 0.78), (1, 0.37), (1.5, 0.105), (2, 0.018), (3, 0)]
}

/// The lamp's sheen across the grooves: two narrow opposite wedges through the centre, the way a
/// record looks under one small light. It turns a little with the hand. Drawn on the record,
/// under the sleeve, so the sleeve still covers it.
struct LampVinylSheen: View {
    let disc: ShopMainLayers.Slot
    let k: CGFloat
    let light: Double
    let shift: CGFloat
    let follows: Bool
    var body: some View {
        let quad = disc.quadPoints ?? []
        let centre = quad.isEmpty ? CGPoint(x: 751, y: 583)
            : CGPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)
        let label = quad.count == 4 ? (quad[1].x - quad[0].x) / 2 : 99
        let outer = (disc.frame?.rect.width ?? 595) / 2 - 5.5      // the vinyl's edge
        let inner = label + 9                                       // just outside the label
        let tilt = follows ? LampTilt.shared.value : .zero
        let angle = Angle.degrees(-58 + 24 * tilt.x + 10 * tilt.y)
        AngularGradient(stops: Self.stops, center: .center)
            .rotationEffect(angle)
            .mask {
                // brighter towards the rim, soft at both edges (render_motion3: 0.2 + 0.8 · (r − 108) / 120)
                let f = { (r: CGFloat) in r / outer }
                RadialGradient(stops: [
                    .init(color: .white.opacity(0), location: f(inner)),
                    .init(color: .white.opacity(0.25), location: f(inner + 8)),
                    .init(color: .white.opacity(0.6), location: f(inner + 60)),
                    .init(color: .white, location: f(inner + 120)),
                    .init(color: .white, location: f(outer - 6)),
                    .init(color: .white.opacity(0), location: 1),
                ], center: .center, startRadius: 0, endRadius: outer * k)
            }
            .frame(width: outer * 2 * k, height: outer * 2 * k)
            .clipShape(.circle)
            .position(x: centre.x * k + shift, y: centre.y * k)
            .frame(width: ShopPlates.plateWidth * k, height: ShopPlates.plateHeight * k, alignment: .topLeading)
            // opacity and blend last, so nothing groups the sheen away from the record under it
            .opacity(0.26 * light)
            .blendMode(.screen)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    /// Peaks at 0°, 180° and 360° (= 0°), each exp(−(Δ/7°)²).
    private static let stops: [Gradient.Stop] = {
        let w = 7.0 / 360
        let tint = Color(red: 0.95, green: 0.9, blue: 0.85)
        var stops: [Gradient.Stop] = []
        for peak in [0.0, 0.5, 1.0] {
            for (x, v) in LampLight.falloff.reversed() where x > 0 && peak - Double(x) * w >= 0 {
                stops.append(.init(color: tint.opacity(v), location: peak - Double(x) * w))
            }
            stops.append(.init(color: tint, location: peak))
            for (x, v) in LampLight.falloff where x > 0 && peak + Double(x) * w <= 1 {
                stops.append(.init(color: tint.opacity(v), location: peak + Double(x) * w))
            }
        }
        return stops
    }()
}

/// The lamp's glint on the PVC outer sleeve: a soft, slightly stretched spot that slides across
/// the sleeve with the hand. Clipped to the sleeve.
struct LampSleeveGlint: View {
    let hero: ShopMainLayers.Slot
    let k: CGFloat
    let light: Double
    let follows: Bool
    var body: some View {
        let quad = (hero.quadPoints ?? []).map { CGPoint(x: $0.x * k, y: $0.y * k) }
        let tilt = follows ? LampTilt.shared.value : .zero
        let centre = CGPoint(x: 265 + 150 * tilt.x, y: 360 + 110 * tilt.y)
        Ellipse()
            .fill(EllipticalGradient(stops: Self.stops, center: .center))
            .frame(width: 150 * 2 * 3 * k, height: 85 * 2 * 3 * k)   // out to 3 × the 1/e radius
            .rotationEffect(.degrees(36.87))
            .position(x: centre.x * k, y: centre.y * k)
            .frame(width: ShopPlates.plateWidth * k, height: ShopPlates.plateHeight * k, alignment: .topLeading)
            .mask { QuadShape(points: quad).fill(.white) }
            .opacity(0.24 * light)
            .blendMode(.screen)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private static let stops = LampLight.falloff.map { Gradient.Stop(color: LampLight.warm.opacity($0.1), location: $0.0 / 3) }
}

private struct QuadShape: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
        return p
    }
}

/// Dust in the spotlight's cone. Sub-point motes, most barely there, carried together by one
/// slow air current and settling a little; they fade in and out at the edge of the light. The
/// lamp is in front, so over the white of a cover they all but vanish and show against the dark
/// wall and the vinyl, as they would in the shop.
struct LampDust: View {
    let k: CGFloat
    let light: Double
    let running: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var field = LampDustField()
    @State private var onScreen = false
    var body: some View {
        let live = running && onScreen && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { timeline in
            Canvas(rendersAsynchronously: false) { context, _ in
                if live { field.advance(to: timeline.date) }
                context.blendMode = .plusLighter
                let mote = context.resolve(Image(uiImage: LampDustField.mote))
                for m in field.visibleMotes() {
                    let side = m.sigma * 6 * k
                    context.opacity = m.alpha
                    context.draw(mote, in: CGRect(x: m.x * k - side / 2, y: m.y * k - side / 2, width: side, height: side))
                }
            }
        }
        .frame(width: ShopPlates.plateWidth * k, height: ShopPlates.plateHeight * k)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .opacity(light)
        .blendMode(.plusLighter)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Plain storage stepped from the Canvas: not observed, so moving motes invalidate nothing.
@MainActor final class LampDustField {
    struct Mote { var x, y: Double; var age: Double; let amp, sigma, turnW, turnP, jitW, jitP: Double }
    struct Visible { let x, y, sigma, alpha: Double }
    private var motes: [Mote] = []
    private var time = 0.0
    private var last: Date?
    private static let box = (x0: 30.0, y0: 110.0, x1: 1180.0, y1: 860.0)
    private static let apex = (x: 430.0, y: -520.0)
    private static let axis: (x: Double, y: Double) = { let dx = 40.0, dy = 1080.0, n = (dx * dx + dy * dy).squareRoot(); return (dx / n, dy / n) }()
    private static let cosHalf = cos(25 * Double.pi / 180), cosInner = cos(12.5 * Double.pi / 180)
    private static let modes: [(kx: Double, ky: Double, w: Double, ph: Double, a: Double)] = [
        (2 * .pi / 820, 2 * .pi / 1100, 2 * .pi / 37, 0.4, 1500),
        (-2 * .pi / 600, 2 * .pi / 700, 2 * .pi / 23, 2.1, 900),
        (2 * .pi / 1300, -2 * .pi / 520, 2 * .pi / 51, 4.0, 1100),
    ]
    /// A soft round mote in the lamp's colour, Gaussian falloff to 3σ at the edge.
    static let mote: UIImage = {
        let side = 32, sigma = Double(side) / 6
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { ctx in
            let colors = (0...8).map { i -> CGColor in
                let r = Double(i) / 8 * Double(side) / 2
                return UIColor(red: 1, green: 0.88, blue: 0.72, alpha: exp(-(r * r) / (2 * sigma * sigma))).cgColor
            }
            let locations = (0...8).map { CGFloat($0) / 8 }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
            let c = CGPoint(x: side / 2, y: side / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        }
    }()

    /// Nothing happens at init: SwiftUI builds a fresh initial value each time the parent redraws
    /// and keeps only the first, so the motes are made on first use.
    private var prepared = false
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let b = Self.box
        motes = (0..<160).map { _ in
            let u = Double.random(in: 0...1)
            let near = Double.random(in: 0...1) < 0.08
            let amp = (0.06 + 0.30 * u * u * u) * (near ? 0.55 : 1)    // most barely there, a few brighter
            return Mote(x: .random(in: b.x0...b.x1), y: .random(in: b.y0...b.y1), age: 99, amp: amp,
                        sigma: near ? .random(in: 1.8...2.8) : .random(in: 0.7...1.15),
                        turnW: .random(in: (2 * .pi / 8)...(2 * .pi / 3)), turnP: .random(in: 0...6.28),
                        jitW: .random(in: 0.2...0.5), jitP: .random(in: 0...6.28))
        }
        for _ in 0..<300 { step(1.0 / 30) }   // ten seconds of drift, so they start spread like dust
    }

    func advance(to date: Date) {
        prepare()
        defer { last = date }
        guard let last else { return }
        var dt = min(0.1, max(0, date.timeIntervalSince(last)))
        while dt > 0 { let s = min(dt, 1.0 / 30); step(s); dt -= s }
    }

    private func step(_ dt: Double) {
        time += dt
        let b = Self.box
        for i in motes.indices {
            var m = motes[i]
            var vx = 0.0, vy = 2.5                     // a slow settle
            for f in Self.modes {                      // velocity = curl of a stream function
                let c = cos(f.kx * m.x + f.ky * m.y + f.w * time + f.ph)
                vx += f.a * f.ky * c; vy -= f.a * f.kx * c
            }
            m.x += vx * dt + 4 * m.jitW * cos(m.jitW * time + m.jitP) * dt
            m.y += vy * dt + 4 * m.jitW * sin(m.jitW * time + m.jitP) * dt
            m.age += dt
            if m.x < b.x0 || m.x > b.x1 || m.y < b.y0 || m.y > b.y1 {
                // one that drifts off comes back somewhere else, fading in
                m.x = .random(in: b.x0...b.x1); m.y = .random(in: b.y0...b.y1); m.age = 0
            }
            motes[i] = m
        }
    }

    func visibleMotes() -> [Visible] {
        prepare()
        return motes.compactMap { m in
            let dx = m.x - Self.apex.x, dy = m.y - Self.apex.y
            let d = max(1e-6, (dx * dx + dy * dy).squareRoot())
            var e = ((dx * Self.axis.x + dy * Self.axis.y) / d - Self.cosHalf) / (Self.cosInner - Self.cosHalf)
            e = min(1, max(0, e))
            let beam = e * e * (3 - 2 * e) * min(1.4, 900 / d)          // nearer the lamp, a little brighter
            let ledge = min(1, max(0, (858 - m.y) / 10))                 // nothing below the ledge
            let alpha = m.amp * beam * ledge * min(1, m.age / 1.5) * (0.88 + 0.12 * sin(m.turnW * time + m.turnP))
            return alpha > 0.004 ? Visible(x: m.x, y: m.y, sigma: m.sigma, alpha: alpha) : nil
        }
    }
}

extension View {
    /// The tilt sensor runs only while `wanted` and the page is on screen in the foreground.
    func lampTilt(_ wanted: Bool) -> some View { modifier(LampTiltSubscription(wanted: wanted)) }
}
