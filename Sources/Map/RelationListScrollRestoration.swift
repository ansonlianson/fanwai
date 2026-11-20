import SwiftUI

struct RelationListScrollRestoration: ViewModifier {
    @Binding var offset: CGFloat
    @State private var position = ScrollPosition()
    @State private var didRequestRestoration = false
    @State private var canSavePosition = false
    @State private var visibleOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                visibleOffset = value
                if didRequestRestoration, value > 0 || offset == 0 { canSavePosition = true }
                if canSavePosition { offset = value }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    canSavePosition = true
                    offset = visibleOffset
                }
            }
            .task {
                guard !didRequestRestoration else { return }
                didRequestRestoration = true
                canSavePosition = offset == 0
                position.scrollTo(y: offset)
            }
    }
}

