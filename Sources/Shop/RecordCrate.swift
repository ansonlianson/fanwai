import SwiftUI
import UIKit

struct RecordCrateLayout {
    let frontHeight: CGFloat
    let exposedFront: CGFloat
    let gap: CGFloat
    let height: CGFloat
    init(count: Int, availableHeight: CGFloat?) {
        let count = min(count, 5)
        frontHeight = availableHeight == nil ? 72 : 52
        if let availableHeight {
            exposedFront = max(48, min(110, availableHeight-frontHeight-CGFloat(max(count-1, 0))*32))
            gap = min(42, max(32, (availableHeight-frontHeight-exposedFront) / CGFloat(max(count-1, 1))))
        } else {
            exposedFront = 110
            gap = RecordCrate.layerGap(count: count)
        }
        height = CGFloat(max(count-1, 0))*gap + exposedFront + frontHeight
    }
    func visibleHeight(at index: Int) -> CGFloat { index == 0 ? exposedFront : gap }
}

struct RecordCrate: View {
    let items: [CrateItem]
    let palette: ArtworkPalette
    var arrived = Int.max
    var recognized = Int.max
    var searching = false
    var variantB = false
    var removedID: String?
    var pressedID: String?
    var availableHeight: CGFloat?
    var entityID = ""
    var graphEnabled = true
    @State private var measuredFrame = CGRect.zero
    @State private var windowID: String?
    @State private var gestureStartID: String?
    @State private var settled = Set<String>()
    @State private var didAppear = false
    @State private var incoming: CrateItem?
    @State private var yielding = false
    @State private var waiting: [CrateItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onGraph: () -> Void
    var onChanged: (CrateItem, CGRect, DragGesture.Value) -> Void
    var onEnded: (CrateItem, CGRect, DragGesture.Value) -> Void
    var onTap: (CrateItem, CGRect) -> Void
    nonisolated static func layerGap(count: Int) -> CGFloat { min(46, max(40, 46 - CGFloat(max(count-2, 0))*2)) }
    private var layout: RecordCrateLayout { .init(count: items.count, availableHeight: availableHeight) }
    private var frontHeight: CGFloat { layout.frontHeight }
    private var exposedFront: CGFloat { layout.exposedFront }
    private var gap: CGFloat { layout.gap }
    private var height: CGFloat { layout.height }
    private var pages: [CrateWindow.Page] { CrateWindow.pages(items) }
    private var positionDefaults: UserDefaults { RelationTrailStore().defaults }
    private var inks: [String: Int] { ObjectInk.indices(items.filter { [.film, .book, .manga].contains($0.entity.kind.objectKind) }.map(\.id)) }
    private var arrivedIDs: [String] { Array(items.prefix(arrived == .max ? items.count : arrived)).map(\.id) }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 24 - 32)
            ZStack(alignment: .topLeading) {
                crateInterior(width: proxy.size.width)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(pages) { page in
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(page.items.enumerated()), id: \.element.id) { index, item in
                                    if page.start + index < arrived {
                                        let offsetY = height-frontHeight-exposedFront-CGFloat(index)*gap
                                        if removedID == item.id {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                                                .frame(width: width, height: index == 0 ? exposedFront : gap)
                                                .offset(x: 28, y: offsetY).zIndex(Double(5-index)).allowsHitTesting(false)
                                        }
                                        CrateLayer(item: item, width: width, visibleHeight: index == 0 ? exposedFront : gap,
                                                   known: page.start + index < recognized, compact: gap < 40, inkIndex: inks[item.id],
                                                   palette: palette, pressed: pressedID == item.id, hidden: removedID == item.id || didAppear && !settled.contains(item.id),
                                                   onChanged: onChanged, onEnded: onEnded, onTap: onTap)
                                            .scaleEffect(variantB ? pow(0.97, CGFloat(index)) : 1, anchor: .topLeading)
                                            .offset(x: 28, y: offsetY + (yielding && !reduceMotion ? 3 : 0)).zIndex(Double(5-index))
                                            .transition(.opacity)
                                    }
                                }
                            }.frame(width: proxy.size.width, height: height-frontHeight, alignment: .topLeading)
                                .id(page.id)
                        }
                    }.scrollTargetLayout()
                }
                .scrollIndicators(.hidden).scrollTargetBehavior(.paging)
                .scrollPosition(id: $windowID, anchor: .leading)
                .scrollDisabled(removedID != nil || pages.count < 2)
                .frame(height: height-frontHeight).clipped()
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                    if gestureStartID == nil { gestureStartID = windowID ?? pages.first?.id }
                }.onEnded { value in
                    defer { gestureStartID = nil }
                    guard removedID == nil, pages.count > 1,
                          abs(value.translation.width) > 45,
                          abs(value.translation.width) > abs(value.translation.height)*1.5 else { return }
                    let current = pages.firstIndex { $0.id == gestureStartID } ?? 0
                    let next = min(pages.count-1, max(0, current + (value.translation.width < 0 ? 1 : -1)))
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { windowID = pages[next].id }
                })
                .accessibilityIdentifier("crate-window")
                if let incoming, let index = items.firstIndex(where: { $0.id == incoming.id }) {
                    let targetY = height-frontHeight-exposedFront-CGFloat(index % 5)*gap
                    let visible = index % 5 == 0 ? exposedFront : gap
                    let base = PhysicalObject.baseSize(for: incoming.entity.kind)
                    let objectHeight = width*base.height/base.width
                    ArrivalParcel(item: incoming, width: width, objectHeight: objectHeight,
                                  visibleHeight: visible, targetY: targetY, containerSize: CGSize(width:proxy.size.width,height:height),
                                  palette:palette, compact:gap < 40, inkIndex:inks[incoming.id],
                                  onYield:{ yielding = $0 }, onFinished: {
                                      settled.insert(incoming.id); self.incoming = nil
                                      startNextArrival()
                                  })
                        .id(incoming.id).zIndex(8).allowsHitTesting(false).accessibilityHidden(true)
                }
                front.frame(height: frontHeight).padding(.horizontal, 12).offset(y: height-frontHeight).zIndex(10)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-crate")
        .accessibilityValue(reviewState)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measuredFrame = $0 }
        .onAppear {
            windowID = CrateWindowPosition.read(entityID: entityID, items: items, defaults: positionDefaults)
            settled = Set(arrivedIDs); didAppear = true
        }
        .onChange(of: arrivedIDs) { _, _ in animateArrivals() }
        .onDisappear { incoming = nil; waiting = []; didAppear = false }
        .onChange(of: windowID) { _, value in
            if let value { CrateWindowPosition.save(value, entityID: entityID, defaults: positionDefaults) }
        }
        .onChange(of: entityID) { _, _ in
            incoming = nil; waiting = []; settled = []
            windowID = CrateWindowPosition.read(entityID: entityID, items: items, defaults: positionDefaults)
            animateArrivals()
        }
    }
    private var reviewState: String {
        #if DEBUG
        let state: [String:Any] = ["frame": [measuredFrame.minX, measuredFrame.minY, measuredFrame.width, measuredFrame.height],
                                  "settled": incoming == nil && waiting.isEmpty && Set(arrivedIDs).isSubset(of: settled),
                                  "reduceMotion": reduceMotion, "systemReduceMotion": UIAccessibility.isReduceMotionEnabled]
        return String(data: try! JSONSerialization.data(withJSONObject: state), encoding: .utf8)!
        #else
        return variantB ? "B" : "A"
        #endif
    }
    private func animateArrivals() {
        guard didAppear else { return }
        for item in items where arrivedIDs.contains(item.id) && !settled.contains(item.id)
            && incoming?.id != item.id && !waiting.contains(where: { $0.id == item.id }) { waiting.append(item) }
        startNextArrival()
    }
    private func startNextArrival() {
        guard incoming == nil, !waiting.isEmpty else { return }
        let item = waiting.removeFirst()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { incoming = items.first { $0.id == item.id } ?? item }
    }
    private func crateInterior(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            CrateLining()
                .clipShape(.rect(cornerRadius: 3))
                .frame(width: width-36, height: height-30).offset(x: 18, y: 14)
            let left = Path { path in
                path.move(to: CGPoint(x: 12, y: 32)); path.addLine(to: CGPoint(x: 28, y: 12))
                path.addLine(to: CGPoint(x: 28, y: height-12)); path.addLine(to: CGPoint(x: 12, y: height-2)); path.closeSubpath()
            }
            let right = Path { path in
                path.move(to: CGPoint(x: width-12, y: 32)); path.addLine(to: CGPoint(x: width-28, y: 12))
                path.addLine(to: CGPoint(x: width-28, y: height-12)); path.addLine(to: CGPoint(x: width-12, y: height-2)); path.closeSubpath()
            }
            WalnutSurface(vertical: true, cut: -0.5).frame(width: width, height: height).mask(left)
            left.stroke(.white.opacity(0.11), lineWidth: 0.7)
            WalnutSurface(vertical: true, shade: 0.17, cut: 0.7).frame(width: width, height: height).mask(right)
            right.stroke(.black.opacity(0.35), lineWidth: 0.8)
            HStack {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
            }.frame(width: width-56, height: height-42).padding(.horizontal, 28).padding(.top, 18)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var front: some View {
        ZStack(alignment: .top) {
            CrateWoodPanel()
            Button(action: onGraph) {
                Label("关系图", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12.5, weight: .semibold))
                    .opacity(searching ? 0.55 : 1)
                .frame(width: 104, height: availableHeight == nil ? 34 : 28).foregroundStyle(ArtworkPalette.paperInk)
                .background(Color(red: 231/255, green: 224/255, blue: 207/255), in: .rect(cornerRadius: 1))
                .padding(3)
                .background { CrateLabelHolder() }
                .shadow(color: .black.opacity(0.60), radius: 0.7, y: 1)
            }.buttonStyle(CratePlaqueStyle()).padding(.top, (frontHeight-(availableHeight == nil ? 40 : 34))/2)
                .opacity(graphEnabled || searching ? 1 : 0).allowsHitTesting(graphEnabled).accessibilityHidden(!graphEnabled && !searching)
                .disabled(searching || items.isEmpty || !graphEnabled).accessibilityLabel("关系图").accessibilityIdentifier("now-graph")
            if !searching && !items.isEmpty {
                let page = pages.first { $0.id == windowID } ?? pages.first
                Text(pages.count > 1 ? "\((page?.start ?? 0)+1)–\((page?.start ?? 0)+(page?.items.count ?? 0)) / \(items.count)" : "\(items.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Color(red: 0.82, green: 0.76, blue: 0.64))
                    .padding(.trailing, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("crate-count")
            }
        }
    }

}

private struct ArrivalParcel: View {
    let item: CrateItem
    let width: CGFloat
    let objectHeight: CGFloat
    let visibleHeight: CGFloat
    let targetY: CGFloat
    let containerSize: CGSize
    let palette: ArtworkPalette
    let compact: Bool
    let inkIndex: Int?
    var onYield: (Bool) -> Void
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fall: CGFloat = 0
    @State private var appearance: CGFloat = 0.001
    @State private var unwrap: CGFloat = 0
    var body: some View {
        ZStack(alignment:.top) {
            PhysicalObject(entity:item.entity,palette:palette,showsDisc:false,
                size:CGSize(width:width,height:objectHeight),showsPersonName:false,
                relation:item.relation,labelTitle:item.entity.title,cratePresentation:true,
                compactLabel:compact,inkIndex:inkIndex)
                .opacity(reduceMotion ? 1 : unwrap).transition(.identity)
            if !reduceMotion { KraftWrapper().offset(y:-32*unwrap).opacity(1-unwrap).transition(.identity) }
        }
        .frame(width:width,height:objectHeight)
        .compositingGroup()
        .mask(alignment:.top) { Rectangle().frame(height:visibleHeight+(reduceMotion ? 0 : 56*(1-fall))) }
        .scaleEffect(reduceMotion ? 1 : 0.96+0.04*appearance,anchor:.top)
        .shadow(color:.black.opacity(0.4),radius:6*(1-fall),y:4*(1-fall))
        .offset(x:28,y:reduceMotion ? targetY : targetY-56*(1-fall))
        .opacity(appearance)
        .frame(width:containerSize.width,height:containerSize.height,alignment:.topLeading).clipped()
        .task {
            do {
                // A fresh, transparent parcel must be mounted before any
                // animated state changes; the parent never starts its timer.
                try await Task.sleep(for:.milliseconds(32))
                if reduceMotion {
                    fall = 1
                    withAnimation(.easeInOut(duration:0.2)) { appearance = 1 }
                    try await Task.sleep(for:.milliseconds(200))
                } else {
                    withAnimation(.linear(duration:0.12)) { appearance = 1 }
                    withAnimation(.timingCurve(0.26,0.02,0.27,1,duration:0.42)) { fall = 1 }
                    try await Task.sleep(for:.milliseconds(370))
                    withAnimation(.easeOut(duration:0.08)) { onYield(true) }
                    try await Task.sleep(for:.milliseconds(50))
                    withAnimation(.easeOut(duration:0.28)) { unwrap = 1 }
                    withAnimation(.spring(response:0.32,dampingFraction:0.86)) { onYield(false) }
                    try await Task.sleep(for:.milliseconds(280))
                }
                onFinished()
            } catch {}
        }
    }
}

private struct CrateLayer: View {
    let item: CrateItem
    let width: CGFloat
    let visibleHeight: CGFloat
    let known: Bool
    let compact: Bool
    let inkIndex: Int?
    let palette: ArtworkPalette
    let pressed: Bool
    let hidden: Bool
    var onChanged: (CrateItem, CGRect, DragGesture.Value) -> Void
    var onEnded: (CrateItem, CGRect, DragGesture.Value) -> Void
    var onTap: (CrateItem, CGRect) -> Void
    @State private var frame = CGRect.zero
    @State private var held = false
    @State private var verticalDrag = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var objectHeight: CGFloat {
        let base = PhysicalObject.baseSize(for: item.entity.kind)
        return width*base.height/base.width
    }
    var body: some View {
        ZStack {
            PhysicalObject(kind: item.entity.kind, title: item.entity.title, subtitle: item.entity.subtitle,
                           artwork: nil, palette: palette, showsDisc: false,
                           size: CGSize(width: width, height: objectHeight), showsPersonName: false,
                           relation: item.relation, labelTitle: item.entity.title, cratePresentation: true,
                           compactLabel: compact, fallbackID: item.id, inkIndex: inkIndex)
            if known {
                PhysicalObject(entity: item.entity, palette: palette, showsDisc: false,
                               size: CGSize(width: width, height: objectHeight), showsPersonName: false,
                               relation: item.relation, labelTitle: item.entity.title, cratePresentation: true,
                               compactLabel: compact, inkIndex: inkIndex).transition(.opacity)
            }
            if !known { KraftWrapper().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.28), value: known)
        .frame(width: width, height: objectHeight)
        .contentShape(.rect)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("crate-page")) } action: { frame = $0 }
        .frame(height: visibleHeight, alignment: .top).clipped()
        .overlay(alignment: .top) { Color(red: 233/255, green: 227/255, blue: 214/255).opacity(0.70).frame(height: 1).padding(.horizontal, 1).allowsHitTesting(false) }
        // Draw the contact band on the layer behind, outside this sleeve's
        // clipped face. A blurred drop shadow alone loses most of its opacity.
        .overlay(alignment: .top) {
            LinearGradient(colors: [.clear, .black.opacity(0.40)], startPoint: .top, endPoint: .bottom)
                .frame(height: 6).offset(y: -6).allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Color.black.opacity(0.55).frame(height: 0.5).offset(y: -0.5).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.40), radius: 6, x: 0, y: 3)
        .opacity(hidden ? 0 : 1)
        .offset(y: pressed || held ? -8 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: pressed)
        .onTapGesture { if known { onTap(item, frame) } }
        .onLongPressGesture(minimumDuration: 0.18, pressing: { held = $0 }, perform: {})
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("crate-page"))
            .onChanged {
                if !verticalDrag && abs($0.translation.height) > abs($0.translation.width)*1.25 { verticalDrag = true }
                if known && verticalDrag { onChanged(item, frame, $0) }
            }
            .onEnded { if known && verticalDrag { onEnded(item, frame, $0) }; verticalDrag = false; held = false })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(known ? item.entity.title + "，" + item.relation : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(!known || hidden)
        .accessibilityIdentifier("crate-item-" + item.id)
        .accessibilityAction {
            onTap(item, frame)
        }
    }
}

struct SearchingDot: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/20, paused: reduceMotion)) { context in
            Circle().fill(color).frame(width: 6, height: 6)
                .opacity(reduceMotion ? 1 : 0.625 + 0.375*cos(context.date.timeIntervalSinceReferenceDate * .pi*2/1.1))
        }.accessibilityHidden(true)
    }
}

struct CrateLining: View {
    var body: some View {
        WalnutSurface(vertical: true, shade: 0.40, cut: -0.8)
            .overlay(LinearGradient(colors: [.black.opacity(0.50), .clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom))
            .overlay(RadialGradient(colors: [.clear, .black.opacity(0.25)], center: .center, startRadius: 30, endRadius: 230))
    }
}


private struct CratePlaqueStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shared timber, grain, lip and joinery for discovery and the saved-record box.
struct CrateWoodPanel: View {
    var body: some View {
        WalnutRail(lip: 6, joinery: true)
            .shadow(color: .black.opacity(0.55), radius: 5, y: 6)
    }
}
