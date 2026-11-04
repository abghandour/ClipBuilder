import CoreGraphics

/// Display compression never writes back to the user's preferred widths.
nonisolated enum TranscriptQAColumns {
    enum Column {
        case list, transcript

        var defaultWidth: CGFloat { self == .list ? 220 : 360 }
        var bounds: ClosedRange<CGFloat> { self == .list ? 160...420 : 260...820 }
        /// Below this, display compression shares the squeeze with the player.
        var usableWidth: CGFloat { self == .list ? 90 : 140 }
    }

    static let dividerWidth: CGFloat = 8
    static let playerMinimum: CGFloat = 320

    static func widths(available: CGFloat, list: CGFloat = 220,
                       transcript: CGFloat = 360) -> (list: CGFloat, transcript: CGFloat) {
        let list = bounded(list, column: .list)
        let transcript = bounded(transcript, column: .transcript)
        let space = max(0, available - 2 * dividerWidth - playerMinimum)
        let scale = min(1, space / (list + transcript))
        if list * scale >= Column.list.usableWidth, transcript * scale >= Column.transcript.usableWidth {
            return (list * scale, transcript * scale)
        }
        // Too narrow for the text columns to stay usable next to a 320 pt
        // player (the Express settings column can be 480 pt): every column
        // gives up width in proportion instead, so none is squeezed to a
        // sliver whose content is clipped on both sides.
        let whole = max(0, available - 2 * dividerWidth)
        let share = whole / (list + transcript + playerMinimum)
        return (list * share, transcript * share)
    }

    /// Columns as fixed shares of the page (the Full wizard's footage review:
    /// list, transcript and player as 1 : 2 : 1). The shares are normalized
    /// with the player's, so (1, 2, 1) and (0.25, 0.5, 0.25) are the same.
    static func proportional(available: CGFloat, list: CGFloat, transcript: CGFloat,
                             player: CGFloat) -> (list: CGFloat, transcript: CGFloat) {
        let total = list + transcript + player
        guard total > 0 else { return widths(available: available) }
        let whole = max(0, available - 2 * dividerWidth)
        return (whole * list / total, whole * transcript / total)
    }

    /// The opposite column stays put during a drag. If even this column's
    /// minimum cannot fit, leave its preference intact and use display scaling.
    static func resizedWidth(_ proposed: CGFloat, column: Column,
                             available: CGFloat, otherWidth: CGFloat) -> CGFloat? {
        let maximum = min(column.bounds.upperBound,
                          available - 2 * dividerWidth - playerMinimum - otherWidth)
        guard maximum >= column.bounds.lowerBound else { return nil }
        return min(maximum, bounded(proposed, column: column))
    }

    private static func bounded(_ width: CGFloat, column: Column) -> CGFloat {
        let width = width.isFinite ? width : column.defaultWidth
        return min(column.bounds.upperBound, max(column.bounds.lowerBound, width))
    }
}
