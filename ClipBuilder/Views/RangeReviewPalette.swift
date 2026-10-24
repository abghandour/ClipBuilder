import AppKit
import SwiftUI

/// Muted pastel colours that tie each saved pick in the list to its words in
/// the transcript: the list row carries a thick bar of the colour, the
/// pick's first word the same bar, and its words a toned-down block of it.
enum RangeReviewPalette {
    /// Soft hues in list order, cycling past the end.
    private static let hues: [NSColor] = [
        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.56, alpha: 1), // apricot
        NSColor(calibratedRed: 0.62, green: 0.84, blue: 0.70, alpha: 1), // mint
        NSColor(calibratedRed: 0.76, green: 0.72, blue: 0.93, alpha: 1), // lavender
        NSColor(calibratedRed: 0.94, green: 0.80, blue: 0.52, alpha: 1), // sand
        NSColor(calibratedRed: 0.62, green: 0.82, blue: 0.90, alpha: 1), // sky
        NSColor(calibratedRed: 0.93, green: 0.70, blue: 0.78, alpha: 1), // rose
    ]

    /// The bar colour for the pick at `index`.
    static func bar(_ index: Int) -> Color {
        Color(nsColor: hues[((index % hues.count) + hues.count) % hues.count])
    }

    /// The word block colour: the hue toned down into the window background,
    /// opaque so adjoining word rectangles join without seams.
    static func block(_ index: Int) -> Color {
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return Color(nsColor: hue.blended(withFraction: 0.58, of: .windowBackgroundColor) ?? hue)
    }

    /// Width of the bar on the list row and on the pick's first word.
    static let barWidth: CGFloat = 4
}

/// A saved pick's range with the palette index its list row shows.
nonisolated struct RangeReviewMarkedRange: Hashable, Sendable {
    var range: ClosedRange<Double>
    var paletteIndex: Int
}
