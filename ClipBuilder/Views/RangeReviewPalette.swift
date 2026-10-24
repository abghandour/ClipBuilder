import AppKit
import SwiftUI

/// Distinct colours that tie each saved pick in the list to its words in
/// the transcript: the list row carries a thick bar of the colour and every
/// wrapped line of the pick's words starts with the same bar. The words
/// themselves sit on one subtle block shared by all saved picks.
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

    /// The block behind every saved pick's words: a faint lift off the window
    /// background, the same for all picks, opaque so adjoining word
    /// rectangles join without seams.
    static let savedBlock = Color(nsColor:
        NSColor.labelColor.blended(withFraction: 0.9, of: .windowBackgroundColor) ?? .windowBackgroundColor)

    /// Width of the bar on the list row and at the start of each line of the pick.
    static let barWidth: CGFloat = 4
    /// Gap between a line's bar and its first word.
    static let barGap: CGFloat = 5
}

/// A saved pick's range with the palette index its list row shows.
nonisolated struct RangeReviewMarkedRange: Hashable, Sendable {
    var range: ClosedRange<Double>
    var paletteIndex: Int
}
