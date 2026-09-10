import SwiftUI

/// How the full-video strip steps back when a loupe sits above it: the loupe
/// is the control being worked, so the full strip is 25% shorter and 15%
/// narrower, centred. Pure numbers so the funnel connectors can map their
/// endpoints onto the narrowed strip and tests can pin the ratios.
nonisolated enum LoupeCompanionMetrics {
    static let widthFraction: CGFloat = 0.85
    static let heightFraction: CGFloat = 0.75

    static func stripHeight(_ base: CGFloat, loupeShown: Bool) -> CGFloat {
        loupeShown ? (base * heightFraction).rounded() : base
    }
    static func width(_ container: CGFloat, loupeShown: Bool) -> CGFloat {
        loupeShown ? container * widthFraction : container
    }
    /// Leading inset that centres the narrowed strip in its container.
    static func inset(_ container: CGFloat, loupeShown: Bool) -> CGFloat {
        (container - width(container, loupeShown: loupeShown)) / 2
    }
    /// Container x for a fraction (0…1) along the strip's time axis.
    static func x(fraction: CGFloat, container: CGFloat, loupeShown: Bool) -> CGFloat {
        inset(container, loupeShown: loupeShown)
            + min(1, max(0, fraction)) * width(container, loupeShown: loupeShown)
    }
}

/// Narrows and centres its content when `active`; passes it through unchanged
/// otherwise. The content keeps its own height (measured), so the surrounding
/// stack does not have to know what a strip is made of.
struct LoupeCompanion<Content: View>: View {
    var active: Bool
    @ViewBuilder var content: () -> Content
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        if active {
            GeometryReader { proxy in
                content()
                    .frame(width: LoupeCompanionMetrics.width(proxy.size.width, loupeShown: true))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measuredHeight = $0 }
                    .frame(width: proxy.size.width)
            }
            .frame(height: measuredHeight > 0 ? measuredHeight : nil)
        } else {
            content()
        }
    }
}
