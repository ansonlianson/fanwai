import SwiftUI
import UIKit

struct KraftWrapper: View {
    var body: some View {
        PaperStock()
            .colorMultiply(Color(red: 0.72, green: 0.57, blue: 0.36))
            .overlay {
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height, fold: CGFloat = 10
                    Canvas { context, size in
                        for i in 0..<2400 {
                            let x = CGFloat(i*73%997)/997*size.width, y = CGFloat(i*139%991)/991*size.height
                            var fiber = Path(); fiber.move(to:CGPoint(x:x,y:y))
                            fiber.addLine(to:CGPoint(x:x+1+CGFloat(i%4)*0.5,y:y+0.3))
                            context.stroke(fiber,with:.color(i%2 == 0 ? .black.opacity(0.035) : .white.opacity(0.035)),lineWidth:0.4)
                        }
                    }
                    ForEach(0..<3) { i in
                        LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.black.opacity(0.065),location:0.43),.init(color:.white.opacity(0.075),location:0.56),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom)
                            .frame(width:w*1.1,height:8)
                            .rotationEffect(.degrees(i == 1 ? -4 : 3))
                            .position(x:w/2,y:h*CGFloat(i+1)/4)
                    }
                    Path { path in
                        path.move(to:.zero); path.addLine(to:CGPoint(x:fold,y:0)); path.addLine(to:CGPoint(x:0,y:fold)); path.closeSubpath()
                        path.move(to:CGPoint(x:w,y:0)); path.addLine(to:CGPoint(x:w-fold,y:0)); path.addLine(to:CGPoint(x:w,y:fold)); path.closeSubpath()
                    }.fill(.black.opacity(0.16))
                    Path { path in
                        path.addRect(CGRect(x: fold, y: fold, width: max(0,w-2*fold), height: max(0,h-2*fold)))
                        for (a,b) in [(CGPoint.zero,CGPoint(x:fold,y:fold)),
                                      (CGPoint(x:w,y:0),CGPoint(x:w-fold,y:fold)),
                                      (CGPoint(x:0,y:h),CGPoint(x:fold,y:h-fold)),
                                      (CGPoint(x:w,y:h),CGPoint(x:w-fold,y:h-fold))] {
                            path.move(to:a); path.addLine(to:b)
                        }
                    }.stroke(.black.opacity(0.17), lineWidth: 0.7)
                    let tape = Path { path in
                        let x = w*0.62-10
                        path.move(to:CGPoint(x:x,y:1))
                        for i in 1...10 { path.addLine(to:CGPoint(x:x+CGFloat(i)*2,y:CGFloat(i%3)-1)) }
                        path.addLine(to:CGPoint(x:x+20,y:h-1))
                        for i in (0..<10).reversed() { path.addLine(to:CGPoint(x:x+CGFloat(i)*2,y:h-CGFloat(i%3))) }
                        path.closeSubpath()
                    }
                    tape.fill(Color(red:232/255,green:220/255,blue:192/255).opacity(0.85))
                    LinearGradient(colors:[.white.opacity(0.20),.clear,.white.opacity(0.06)],startPoint:.leading,endPoint:.trailing)
                        .mask(tape)
                }
            }
            .overlay(Rectangle().strokeBorder(Color(red:0.37,green:0.28,blue:0.17).opacity(0.5),lineWidth:1))
            .clipShape(.rect(cornerRadius: 2))
    }
}

/// Finds the existing UIKit tab and its real icon; never draws a substitute bar.
@MainActor final class CollectionTabTarget {
    let bar: CGRect
    let iconFrame: CGRect
    private weak var icon: UIView?
    private init(bar: CGRect, icon: UIView) {
        self.bar = bar; self.iconFrame = icon.convert(icon.bounds,to:nil); self.icon = icon
    }
    static func resolve() -> CollectionTabTarget? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter(\.isKeyWindow)
        for window in windows {
            for bar in descendants(window).compactMap({ $0 as? UITabBar }) where !bar.isHidden {
                let all = descendants(bar)
                let controls = all.compactMap { $0 as? UIControl }.filter { !$0.isHidden && $0.bounds.width > 30 }
                let target = controls.first { $0.accessibilityLabel == "收藏" }
                    ?? controls.sorted { $0.convert($0.bounds,to:nil).minX < $1.convert($1.bounds,to:nil).minX }
                    .enumerated().first { $0.offset == bar.items?.firstIndex(where: { $0.title == "收藏" }) }?.element
                if let target, let icon = descendants(target).first(where: { $0 is UIImageView && $0.bounds.width > 12 && !$0.isHidden }) {
                    return CollectionTabTarget(bar:bar.convert(bar.bounds,to:nil),icon:icon)
                }
            }
        }
        return nil
    }
    func acknowledge(reduceMotion: Bool) {
        guard let icon else { return }
        if reduceMotion {
            UIView.animate(withDuration:0.1,animations: { icon.alpha = 0.5 }) { _ in UIView.animate(withDuration:0.1) { icon.alpha = 1 } }
        } else {
            let original = icon.transform
            UIView.animate(withDuration:0.1,animations: { icon.transform = original.translatedBy(x:0,y:-2) }) { _ in
                UIView.animate(withDuration:0.1) { icon.transform = original }
            }
        }
    }
}

struct CollectionArrival: Identifiable {
    let id = UUID()
    let entity: SeedGraph.Entity
    let origin: CGRect
    let target: CollectionTabTarget?
}

/// One continuous, 1.06s journey into a receiver just above the native tab.
struct CollectionArrivalView: View {
    let arrival: CollectionArrival
    var completed: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1/60)) { timeline in
                let time = max(0,timeline.date.timeIntervalSince(started))
                let offset = proxy.frame(in:.global).origin
                let origin = arrival.origin.isEmpty ? CGRect(x:proxy.size.width/2-80,y:180,width:160,height:160)
                    : arrival.origin.offsetBy(dx:-offset.x,dy:-offset.y)
                if let target = arrival.target, !reduceMotion {
                    let x = target.iconFrame.midX-offset.x, barTop = target.bar.minY-offset.y
                    let rise = 1-smooth(time/0.22), retreat = smooth((time-0.82)/0.22)
                    let bounce = time >= 0.72 && time <= 0.88 ? 2*sin((time-0.72)/0.16 * .pi) : 0
                    let top = barTop-72+78*max(rise,retreat)+bounce
                    let t = min(1,max(0,(time-0.04)/0.76))
                    let size = CGSize(width:90,height:90*origin.height/max(1,origin.width))
                    let destination = CGRect(x:x-size.width/2,y:barTop-26,width:size.width,height:size.height)
                    ZStack(alignment:.topLeading) {
                        CrateLining().frame(width:108,height:72).position(x:x,y:top+36)
                        if time < 0.82 {
                            PhysicalObject(entity:arrival.entity,showsDisc:true,discLeading:0.18,size:origin.size)
                                .modifier(SleeveFlight(progress:t,start:origin,end:destination))
                                .opacity(min(1,time/0.08))
                        }
                        WallSidePanels().frame(width:120,height:72).position(x:x,y:top+36)
                        WallCrateFront().frame(width:120,height:32).position(x:x,y:top+58)
                    }
                    .frame(width:proxy.size.width,height:proxy.size.height,alignment:.topLeading)
                    // The native bar is in front of the receiver and the object.
                    .mask(alignment:.top) { Rectangle().frame(height:max(0,barTop)) }
                } else {
                    PhysicalObject(entity:arrival.entity,showsDisc:true,size:origin.size)
                        .position(x:origin.midX,y:origin.midY)
                        .opacity(sin(min(1,time/0.2) * .pi))
                }
            }
            .task {
                started = Date()
                #if DEBUG
                print("P15_COLLECTION_FLIGHT",Date().timeIntervalSince1970,"reduce",reduceMotion,"target",arrival.target?.iconFrame as Any,"bar",arrival.target?.bar as Any)
                #endif
                do {
                    try await Task.sleep(for:.milliseconds(reduceMotion ? 0 : 860))
                    arrival.target?.acknowledge(reduceMotion:reduceMotion)
                    try await Task.sleep(for:.milliseconds(200))
                    if !Task.isCancelled { completed() }
                } catch {}
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
    private func smooth(_ t: Double) -> Double { let t = min(1,max(0,t)); return t*t*(3-2*t) }
}

private struct SleeveFlight: AnimatableModifier {
    nonisolated var progress: CGFloat
    let start: CGRect
    let end: CGRect
    nonisolated var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let t = progress, u = 1-t
        let control = CGPoint(x:(start.midX+end.midX)/2+32,y:min(start.midY,end.midY)-40)
        let x = u*u*start.midX+2*u*t*control.x+t*t*end.midX
        let y = u*u*start.midY+2*u*t*control.y+t*t*end.midY
        return content
            .scaleEffect(x:(start.width+(end.width-start.width)*t)/max(1,start.width),
                         y:(start.height+(end.height-start.height)*t)/max(1,start.height))
            .rotationEffect(.degrees(Double(sin(t * .pi))*3))
            .shadow(color:.black.opacity(0.45),radius:8,y:8)
            .position(x:x,y:y)
    }
}
