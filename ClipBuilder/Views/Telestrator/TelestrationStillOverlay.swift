import SwiftUI

/// Attached to the source image before its crop, clipping, and placement.
struct TelestrationStillOverlay: View {
    let drawing: Telestration?

    var body: some View {
        if let drawing {
            Canvas { context, size in
                context.withCGContext { cg in
                    TelestrationPainter.draw(drawing, in: cg, rect: CGRect(origin: .zero, size: size),
                                             topLeftOrigin: true)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
