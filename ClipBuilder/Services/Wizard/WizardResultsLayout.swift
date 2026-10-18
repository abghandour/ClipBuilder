import CoreGraphics

/// Sheet chrome and grid spacing are shared with WizardResultsSheet.
nonisolated enum WizardResultsLayout {
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 32
    static let chromeHeight: CGFloat = 132

    static func idealSize(count: Int, cardSize: CGSize, screen: CGSize) -> CGSize {
        let widthLimit = max(520, screen.width * 0.92)
        let heightLimit = max(560, screen.height * 0.90)
        let width = max(1, cardSize.width)
        let height = max(1, cardSize.height)
        let count = max(1, count)
        let capacity = max(1, Int((widthLimit - horizontalPadding + spacing) / (width + spacing)))
        let columns = min(count, capacity)
        let rows = (count + columns - 1) / columns
        let visibleRows = max(1, Int((heightLimit - chromeHeight + spacing) / (height + spacing)))
        return CGSize(width: min(widthLimit, max(520, CGFloat(columns) * (width + spacing) - spacing + horizontalPadding)),
                      height: min(heightLimit, max(560, CGFloat(min(rows, visibleRows)) * (height + spacing) - spacing + chromeHeight)))
    }

    // MARK: Cards that follow the sheet

    /// The narrowest a result card gets; below this the rows wrap.
    static let minCardWidth: CGFloat = 320
    /// The card's inset around the player.
    static let cardPadding: CGFloat = 12
    /// Everything under the picture: transport, title, take, rating, note,
    /// actions. A single row of cards fits the sheet when the player leaves
    /// this much room.
    static let cardChromeHeight: CGFloat = 268

    struct Grid: Equatable, Sendable {
        var columns: Int
        /// One column's width; cards are centred in it.
        var columnWidth: CGFloat
        /// The tallest a player may be so one row of cards needs no scrolling.
        var playerMaxHeight: CGFloat
    }

    /// Split the scroll area into equal columns for `count` cards.
    static func grid(count: Int, available: CGSize) -> Grid {
        let count = max(1, count)
        let usable = max(minCardWidth, available.width - horizontalPadding)
        let columns = max(1, min(count, Int((usable + spacing) / (minCardWidth + spacing))))
        let columnWidth = ((usable - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let maxHeight = max(180, (available.height - cardChromeHeight - 2 * cardPadding).rounded(.down))
        return Grid(columns: columns, columnWidth: max(minCardWidth, columnWidth), playerMaxHeight: maxHeight)
    }

    /// The picture's size inside one column: as wide as the column allows,
    /// no taller than the sheet, in the video's own shape.
    static func playerSize(in grid: Grid, aspect: CGFloat) -> CGSize {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 9 / 16
        let maxWidth = grid.columnWidth - 2 * cardPadding
        let height = min(grid.playerMaxHeight, maxWidth / aspect).rounded(.down)
        return CGSize(width: min(maxWidth, (height * aspect).rounded(.down)), height: height)
    }

    /// The card's width for a player of that size: wraps the picture, never
    /// narrower than the minimum nor wider than the column.
    static func cardWidth(in grid: Grid, playerWidth: CGFloat) -> CGFloat {
        min(grid.columnWidth, max(minCardWidth, playerWidth + 2 * cardPadding))
    }
}
