import AVFoundation
import SwiftUI

/// The green limb and impact highlight over a player, following the
/// player's clock. Sits on top of a `PlayerView` of the same size.
struct StrikeHighlightOverlay: View {
    let player: AVPlayer?
    let track: StrikeHighlightRules.Track

    var body: some View {
        SwiftUI.TimelineView(.animation) { timeline in
            // Reading the date ties the canvas to every tick.
            let tick = timeline.date
            Canvas { context, size in
                _ = tick
                guard let player,
                      let sample = StrikeHighlightRules.sample(track, at: player.currentTime().seconds) else { return }
                let rect = StrikeHighlightPainter.videoRect(aspect: track.aspect, in: size)
                context.withCGContext { cg in
                    StrikeHighlightPainter.draw(sample.highlight, opacity: sample.opacity, in: cg,
                                                rect: rect, topLeftOrigin: true)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
