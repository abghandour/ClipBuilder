import CoreGraphics

/// Pixel-space safety correction; top-left coordinates throughout.
nonisolated enum FaceGuard {
    static let margin = 0.12
    static let headroom = 0.10

    static func contain(_ crop: CGRect, faces: [CGRect], bounds: CGRect) -> CGRect {
        let faces = faces.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let first = faces.first, crop.width > 0, crop.height > 0,
              !bounds.isEmpty else { return crop }
        let union = faces.dropFirst().reduce(first) { $0.union($1) }
        let padded = faces.map { $0.insetBy(dx: -$0.width * margin, dy: -$0.height * margin) }
            .reduce(CGRect.null) { $0.union($1) }.intersection(bounds)
        guard !padded.isNull else { return crop }
        let aspect = crop.width / crop.height
        let maxHeight = min(bounds.height, bounds.width / aspect)
        let neededHeight = max(padded.height, padded.width / aspect,
                               (padded.maxY - union.minY) / (1 - headroom))
        let height = min(maxHeight, max(crop.height, neededHeight))
        let width = height * aspect
        // Move first, grow only as needed. At source edges, margin/headroom
        // are clipped to the available pixels. Impossible unions saturate at
        // the largest crop of this aspect that fits the source.
        let top = max(bounds.minY, min(padded.minY, union.minY - height * headroom))
        func origin(_ preferred: CGFloat, low: CGFloat, high: CGFloat,
                    boundLow: CGFloat, boundHigh: CGFloat) -> CGFloat {
            let value = low <= high ? min(high, max(low, preferred)) : (low + high) / 2
            return min(boundHigh, max(boundLow, value))
        }
        return CGRect(
            x: origin(crop.minX, low: padded.maxX - width, high: padded.minX,
                      boundLow: bounds.minX, boundHigh: bounds.maxX - width),
            y: origin(crop.minY, low: padded.maxY - height, high: top,
                      boundLow: bounds.minY, boundHigh: bounds.maxY - height),
            width: width, height: height)
    }
}
