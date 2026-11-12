import AppKit
import SwiftUI

/// Distinct colours that tie each saved pick in the list to its words in
/// the transcript: the list row carries a thick bar of the colour and the
/// pick's words sit on a block of the same colour. The Express reel List
/// repeats the bar on each row.
///
/// Colours are addressed by slot (0..<18). Each Footage section draws from
/// its own `Family` of six slots, so Q&A, Transcript and Highlights never
/// share a colour: the 18 hues sit 20 degrees apart and a family takes every
/// third one, ordered so neighbouring picks land far apart on the wheel.
enum RangeReviewPalette {
    /// The Footage section a colour belongs to. Fight metrics shares Q&A's
    /// family: a source offers Q&A (podcast or interview) or Fight metrics
    /// (fight or training), never both.
    enum Family: Int, Sendable {
        case qa = 0, transcript = 1, highlights = 2

        init(_ kind: MiniWizardFlow.FootageKind) {
            switch kind {
            case .qa, .fightMetrics: self = .qa
            case .transcript: self = .transcript
            case .highlights: self = .highlights
            }
        }
    }

    static let slotCount = 18

    /// Hue steps (of 60 degrees) in pick order: orange-ish, then its
    /// opposite, then a third away, and so on.
    private static let order = [0, 3, 1, 4, 2, 5]

    /// The slot of the pick at `index` in its section's list.
    static func slot(_ index: Int, family: Family) -> Int {
        let step = order[((index % order.count) + order.count) % order.count]
        return family.rawValue * order.count + step
    }

    /// The bar colour for `slot`.
    static func bar(_ slot: Int) -> Color {
        if slot == RangeReviewMarkedRange.draftSlot { return .accentColor }
        return Color(nsColor: hue(slot))
    }

    /// The block behind a saved pick's words: the slot's hue toned down
    /// over the window background, the same colour as its list row's bar.
    /// Opaque, so adjoining word rectangles join without seams.
    static func block(_ slot: Int) -> Color {
        if slot == RangeReviewMarkedRange.draftSlot { return TranscriptQAWordCursor.draftColor }
        let hue = hue(slot)
        return Color(nsColor: hue.blended(withFraction: 0.7, of: .windowBackgroundColor) ?? hue.withAlphaComponent(0.3))
    }

    /// Width of the bar on the list row.
    static let barWidth: CGFloat = 4

    /// Hue 25 degrees (orange) for slot 0; a family shifts by 20 degrees and
    /// each step by 60. Families also differ a little in depth so two hues
    /// 20 degrees apart still read as different colours.
    private static func hue(_ slot: Int) -> NSColor {
        let slot = ((slot % slotCount) + slotCount) % slotCount
        let family = slot / order.count, step = slot % order.count
        let degrees = 25 + Double(family) * 20 + Double(step) * 60
        let (saturation, brightness): (Double, Double) = switch family {
        case 0: (0.70, 0.95)
        case 1: (0.52, 1.00)
        default: (0.85, 0.85)
        }
        return NSColor(calibratedHue: (degrees.truncatingRemainder(dividingBy: 360)) / 360,
                       saturation: saturation, brightness: brightness, alpha: 1)
    }
}

/// A saved pick's range with the palette index its list row shows.
nonisolated struct RangeReviewMarkedRange: Hashable, Sendable {
    var range: ClosedRange<Double>
    var paletteIndex: Int

    /// Not a saved item: another passage of the selection being composed.
    static let draftSlot = -1
}

/// One passage of a selection made of several (Transcript picks, Shift-drag),
/// numbered from 1 in the order they were marked.
nonisolated struct TranscriptDraftSpan: Hashable, Sendable {
    var number: Int
    var range: ClosedRange<Double>
}

/// A draft item made of several passages: the others beside the one being
/// adjusted, and what the transcript's controls do to them.
struct RangeReviewDraftSpans {
    var others: [TranscriptDraftSpan]
    /// The adjusted passage's number; nil while it is the only one.
    var currentNumber: Int?
    /// Shift pressed in the transcript: the next span is another passage.
    var begin: () -> Void
    var select: (Int) -> Void
    var delete: (Int) -> Void
    var clear: () -> Void
}
