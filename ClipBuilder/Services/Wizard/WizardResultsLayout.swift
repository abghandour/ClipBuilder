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
}
