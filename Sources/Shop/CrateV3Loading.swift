import UIKit

enum CrateLoadingCategories {
    static func forKind(_ kind: SeedGraph.Kind) -> [String] {
        switch kind {
        case .song: ["作曲","作词","演唱","收录","出自"]
        case .album: ["艺人","曲目","配乐"]
        case .film,.tv,.video,.game: ["原作","导演","配乐","主题曲"]
        case .book,.manga: ["作者","改编"]
        case .person,.group: ["作品","合作"]
        }
    }
}
extension CrateV3Materials {
    static func blank(category:String,index:Int) -> UIImage {
        image(key:"blank:\(category):\(index)",size:CGSize(width:208,height:230)) { c in
            c.translateBy(x:6,y:28)
            let r=CGRect(x:0,y:0,width:196,height:196)
            let kraft=index%2 == 0
            let stock=kraft ? UIColor(red:0.70,green:0.55,blue:0.36,alpha:1) : paper
            stock.setFill(); c.fill(r); fibre(c,rect:r)
            let tab=CGRect(x:18+CGFloat((index*53)%120),y:-21,width:48,height:24)
            UIBezierPath(roundedRect:tab,cornerRadius:4).fill()
            text(category,in:tab.insetBy(dx:5,dy:3),size:11,serif:true,centered:true)
            if !kraft {
                UIColor(white:0.055,alpha:1).setFill(); c.fillEllipse(in:CGRect(x:48,y:48,width:100,height:100))
                UIColor(red:0.63,green:0.29,blue:0.19,alpha:1).setFill(); c.fillEllipse(in:CGRect(x:77,y:77,width:42,height:42))
                UIColor(white:0.1,alpha:1).setFill(); c.fillEllipse(in:CGRect(x:96,y:96,width:4,height:4))
            }
            gradient(c,r,[.white.withAlphaComponent(0.07),.clear,.black.withAlphaComponent(0.35)])
            c.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); c.setLineWidth(1)
            c.stroke(CGRect(x:5,y:1,width:186,height:193))
        }
    }
}
extension CrateV3Scene {
    func resetLoading() {
        loadingTask?.cancel(); loadingTask=nil; arrivalTask?.cancel(); arrivalTask=nil
        blanks.values.forEach { $0.layer.removeFromSuperlayer() }; blanks=[:]
        pendingArrivals=[]; arrivingID=nil; loadingStarted=false
    }
    func beginLoading(categories:[String]) {
        loadingStarted=true
        Task { await P17Metrics.shared.event("placeholders",entity:entityID,count:categories.count) }
        for (i,category) in categories.prefix(5).enumerated() {
            // Single layer, like the real objects: the 208x230 face with the
            // 196pt sleeve standing on its bottom edge (6pt side, 28pt tab room).
            let l=CALayer(); l.bounds=CGRect(x:0,y:0,width:208,height:230)
            l.anchorPoint=CGPoint(x:0.5,y:(28+196)/230); l.position=CGPoint(x:182.5,y:312); l.contentsScale=3
            l.contents=CrateV3Materials.blank(category:category,index:i).cgImage
            let home=CrateV3Pose(x:CGFloat([-30,22,-8,30,-18][i]),z:-156+CGFloat(i)*36,rx:7,rz:i%2 == 0 ? -0.8 : 0.8)
            l.transform=CrateV3Camera.project(home.transform,at:l.position); l.zPosition=home.z; stage.addSublayer(l)
            blanks[i]=Blank(layer:l,home:home,category:category)
        }
        loadingTask=Task { @MainActor [weak self] in
            while let self,!Task.isCancelled,self.isLoading,!self.blanks.isEmpty {
                if !self.reduceMotion {
                    let indexes=self.blanks.keys.sorted().reversed()
                    for (n,index) in indexes.enumerated() {
                        guard !Task.isCancelled,self.isLoading else { return }
                        if let b=self.blanks[index] { var p=b.home; p.rx = -46+CGFloat(n)*6; p.y += 2; self.animateBlank(b,pose:p,stiffness:260,damping:0.62) }
                        try? await Task.sleep(for:.milliseconds(210))
                    }
                    try? await Task.sleep(for:.milliseconds(260))
                    for index in self.blanks.keys.sorted() {
                        guard !Task.isCancelled else { return }
                        if let b=self.blanks[index] { self.animateBlank(b,pose:b.home,stiffness:240,damping:0.6) }
                        try? await Task.sleep(for:.milliseconds(70))
                    }
                }
                try? await Task.sleep(for:.milliseconds(420))
            }
        }
    }
    func animateBlank(_ blank:Blank,pose:CrateV3Pose,stiffness:CGFloat=180,damping:CGFloat=0.8) {
        let previous=blank.layer.presentation()?.transform ?? blank.layer.transform
        let transform=CrateV3Camera.project(pose.transform,at:blank.layer.position)
        CATransaction.begin(); CATransaction.setDisableActions(true); blank.layer.transform=transform; blank.layer.zPosition=pose.z; CATransaction.commit()
        guard !reduceMotion else { return }
        let spring=CASpringAnimation(keyPath:"transform"); spring.stiffness=stiffness; spring.damping=2*damping*sqrt(stiffness)
        spring.fromValue=NSValue(caTransform3D:previous); spring.toValue=NSValue(caTransform3D:transform)
        spring.duration=spring.settlingDuration; blank.layer.add(spring,forKey:"pose")
    }
    func queueArrival(_ id:String) {
        guard let o=objects[id] else { return }
        pendingArrivals.append(id); fade(o.layer,to:0,duration:0)
        var start=o.home; start.y += 320; start.rx=0; setPose(id,start,animated:false)
        guard arrivalTask == nil else { return }
        arrivalTask=Task { @MainActor [weak self] in
            // Let configure install all faces before the first drop.
            await Task.yield()
            while let self,!Task.isCancelled,!self.pendingArrivals.isEmpty {
                let next=self.pendingArrivals.removeFirst()
                guard let o=self.objects[next] else { continue }; self.arrivingID=next
                let index=self.blanks.keys.sorted().first { self.blanks[$0].map { o.item.relation.contains($0.category) } ?? false } ?? self.blanks.keys.sorted().first
                if let index,let blank=self.blanks.removeValue(forKey:index) {
                    var out=blank.home; out.y += 240; out.rx=0
                    self.animateBlank(blank,pose:out); self.fade(blank.layer,to:0,duration:self.reduceMotion ? 0.2 : 0.26)
                    self.later(0.4) { blank.layer.removeFromSuperlayer() }
                }
                if !self.measuredFirst { self.measuredFirst=true; Task { await P17Metrics.shared.event("first",entity:self.entityID,count:1) } }
                self.fade(o.layer,to:1,duration:self.reduceMotion ? 0.2 : 0.14)
                self.setPose(next,o.home,animated:true,stiffness:230,damping:0.64)
                try? await Task.sleep(for:.milliseconds(self.reduceMotion ? 200 : 340))
                if Task.isCancelled { return }; self.jiggle(next); self.arrivingID=nil
                self.updateAccessibility()
            }
            guard let self,!Task.isCancelled else { return }; self.arrivalTask=nil
            if !self.isLoading { self.finishLoading(); self.measureVisible() }; self.updateAccessibility()
        }
    }
    func measureVisible() {
        guard !items.isEmpty else { return }
        if !measuredFirst { measuredFirst=true; Task { await P17Metrics.shared.event("first",entity:entityID,count:items.count) } }
        if !isLoading && !measuredFull { measuredFull=true; Task { await P17Metrics.shared.event("full",entity:entityID,count:items.count) } }
    }
    func finishLoading() {
        loadingTask?.cancel(); loadingTask=nil
        for blank in blanks.values {
            var down=blank.home; down.y = -120
            animateBlank(blank,pose:down,stiffness:120,damping:0.9); fade(blank.layer,to:0,duration:reduceMotion ? 0.2 : 0.4)
            later(0.4) { blank.layer.removeFromSuperlayer() }
        }
        blanks=[:]
    }
}
