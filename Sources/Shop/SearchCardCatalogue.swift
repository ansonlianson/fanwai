import SwiftUI
import UIKit

struct SearchCardCatalogue: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduced
    func makeUIView(context:Context) -> SearchDrawerScene { SearchDrawerScene() }
    func updateUIView(_ view:SearchDrawerScene,context:Context) { view.setRiffle(!reduced) }
}
final class SearchDrawerScene: UIView {
    private let stage=CATransformLayer()
    private var cards:[CALayer]=[]
    private var riffling=false
    override init(frame:CGRect) {
        super.init(frame:frame); accessibilityIdentifier="search-drawer"; isAccessibilityElement=true
        accessibilityLabel="歌曲、专辑、艺人、影视、书"
        layer.addSublayer(stage); stage.anchorPoint = .zero
        stage.bounds=CGRect(x:0,y:0,width:330,height:190)
        var camera=CATransform3DIdentity; camera.m34 = -1/800; camera.m31 = -165/800; camera.m32 = 100/800
        stage.sublayerTransform=camera
        func board(_ name:String,_ frame:CGRect,_ z:CGFloat,_ rx:CGFloat=0,_ ry:CGFloat=0) {
            let l=CALayer(); l.anchorPoint = .zero; l.position=frame.origin; l.bounds=CGRect(origin:.zero,size:frame.size)
            var t=CATransform3DMakeTranslation(0,0,z); t=CATransform3DRotate(t,rx * .pi/180,1,0,0); t=CATransform3DRotate(t,ry * .pi/180,0,1,0)
            l.transform=t; l.contents=CrateV3Materials.board("search-"+name,size:frame.size,shade:0.25).cgImage
            stage.addSublayer(l)
            if name == "front" {
                let fitting=CALayer(); fitting.frame=CGRect(x:118,y:8,width:94,height:34)
                fitting.contents=CrateV3Materials.image(key:"drawer-pull",size:fitting.frame.size) { c in
                    CrateV3Materials.gradient(c,CGRect(x:0,y:0,width:94,height:34),[UIColor(red:0.80,green:0.68,blue:0.43,alpha:1),UIColor(red:0.42,green:0.31,blue:0.15,alpha:1)])
                    UIColor(white:0.12,alpha:1).setFill(); c.fill(CGRect(x:10,y:4,width:74,height:12))
                    UIColor(red:0.86,green:0.77,blue:0.54,alpha:1).setStroke(); c.setLineWidth(4)
                    c.stroke(CGRect(x:23,y:23,width:48,height:8))
                }.cgImage
                l.addSublayer(fitting)
            }
        }
        board("floor",CGRect(x:10,y:186,width:310,height:160),12,-90)
        board("back",CGRect(x:10,y:60,width:310,height:126),-148)
        board("left",CGRect(x:10,y:60,width:160,height:126),12,0,90)
        board("right",CGRect(x:320,y:60,width:160,height:126),12,0,90)
        for (i,title) in ["歌曲","专辑","艺人","影视","书","歌曲","专辑"].enumerated() {
            let card=CALayer(); card.bounds=CGRect(x:0,y:0,width:280,height:120); card.anchorPoint=CGPoint(x:0.5,y:1); card.position=CGPoint(x:165,y:184)
            let face=CALayer(); face.frame=CGRect(x:0,y:-20,width:280,height:140)
            face.contents=CrateV3Materials.image(key:"index-card-\(i)",size:face.frame.size) { c in
                CrateV3Materials.paper.setFill(); c.fill(CGRect(x:0,y:20,width:280,height:120))
                let tab=CGRect(x:16+CGFloat(i*47%190),y:0,width:50,height:24); UIBezierPath(roundedRect:tab,cornerRadius:4).fill()
                CrateV3Materials.text(title,in:tab.insetBy(dx:5,dy:4),size:12,serif:true,centered:true)
                UIColor(red:0.60,green:0.21,blue:0.16,alpha:0.5).setFill(); c.fill(CGRect(x:0,y:37,width:280,height:1))
                CrateV3Materials.gradient(c,CGRect(x:0,y:70,width:280,height:70),[.clear,.black.withAlphaComponent(0.35)])
            }.cgImage
            card.addSublayer(face); var t=CATransform3DMakeTranslation(0,0,-150+CGFloat(i)*24); t=CATransform3DRotate(t,8 * .pi/180,1,0,0); card.transform=t
            cards.append(card); stage.addSublayer(card)
        }
        board("front-rim",CGRect(x:0,y:144,width:330,height:10),24,-90)
        board("front",CGRect(x:0,y:144,width:330,height:46),24)
        for x:CGFloat in [0,320] { board("rim-\(x)",CGRect(x:x,y:144,width:10,height:186),24,-116) }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); let k=min(bounds.width/330,bounds.height/190)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.position=CGPoint(x:(bounds.width-330*k)/2,y:bounds.height-190*k); stage.transform=CATransform3DMakeScale(k,k,k); CATransaction.commit()
    }
    func setRiffle(_ enabled:Bool) {
        guard enabled != riffling else { return }; riffling=enabled
        for (i,card) in cards.enumerated() {
            card.removeAnimation(forKey:"riffle"); guard enabled else { continue }
            let animation=CAKeyframeAnimation(keyPath:"transform.rotation.x")
            animation.values=[8 * Double.pi/180,(-58+Double(cards.count-1-i)*3)*Double.pi/180,8 * Double.pi/180,8 * Double.pi/180]
            animation.keyTimes=[0,0.25,0.60,1]; animation.duration=1.25
            animation.beginTime=CACurrentMediaTime()+Double(cards.count-1-i)*0.07
            animation.repeatCount = .infinity; card.add(animation,forKey:"riffle")
        }
    }
}

struct SearchCardArrival: ViewModifier {
    var index:Int
    var revision:UUID
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var shown=false
    func body(content:Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y:shown || reduced ? 0 : -24)
            .task(id:revision) {
                shown=false
                if !reduced { try? await Task.sleep(for:.seconds(Double(min(index,8))*0.12)) }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration:0.2)) { shown=true }
            }
    }
}
