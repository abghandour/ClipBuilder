import CoreGraphics

/// Display compression never writes back to the user's preferred widths.
nonisolated enum TranscriptQAColumns {
    enum Column {
        case list, transcript

        var defaultWidth: CGFloat { self == .list ? 220 : 360 }
        var bounds: ClosedRange<CGFloat> { self == .list ? 160...420 : 260...820 }
    }

    static let dividerWidth: CGFloat = 8
    static let playerMinimum: CGFloat = 320

    static func widths(available: CGFloat, list: CGFloat = 220,
                       transcript: CGFloat = 360) -> (list: CGFloat, transcript: CGFloat) {
        let list = bounded(list, column: .list)
        let transcript = bounded(transcript, column: .transcript)
        let space = max(0, available - 2 * dividerWidth - playerMinimum)
        let scale = min(1, space / (list + transcript))
        return (list * scale, transcript * scale)
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
