import AppKit
import SwiftUI

/// Distinct colours that tie each saved pick in the list to its words in
/// the transcript: the list row carries a thick bar of the colour and the
/// pick's words sit on a block of the same colour.
enum RangeReviewPalette {
    /// Clearly separated hues in list order, cycling past the end: orange,
    /// green, violet, yellow, blue, pink. Saturated enough to tell apart at
    /// a 4 pt bar on a dark or light window.
    private static let hues: [NSColor] = [
        NSColor(calibratedRed: 0.98, green: 0.56, blue: 0.22, alpha: 1), // orange
        NSColor(calibratedRed: 0.33, green: 0.78, blue: 0.42, alpha: 1), // green
        NSColor(calibratedRed: 0.63, green: 0.50, blue: 0.96, alpha: 1), // violet
        NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.18, alpha: 1), // yellow
        NSColor(calibratedRed: 0.28, green: 0.64, blue: 0.96, alpha: 1), // blue
        NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.66, alpha: 1), // pink
    ]

    /// The bar colour for the pick at `index`.
    static func bar(_ index: Int) -> Color {
        Color(nsColor: hues[((index % hues.count) + hues.count) % hues.count])
    }

    /// The block behind a saved pick's words: the pick's own hue toned down
    /// over the window background, the same colour as its list row's bar.
    /// Opaque, so adjoining word rectangles join without seams.
    static func block(_ index: Int) -> Color {
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return Color(nsColor: hue.blended(withFraction: 0.7, of: .windowBackgroundColor) ?? hue.withAlphaComponent(0.3))
    }

    /// Width of the bar on the list row.
    static let barWidth: CGFloat = 4
}

/// A saved pick's range with the palette index its list row shows.
nonisolated struct RangeReviewMarkedRange: Hashable, Sendable {
    var range: ClosedRange<Double>
    var paletteIndex: Int
}
