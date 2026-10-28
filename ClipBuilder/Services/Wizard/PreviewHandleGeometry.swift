import CoreGraphics

/// Preview coordinates only; independent of SwiftUI and the stored crop format.
nonisolated enum PreviewHandleGeometry {
    /// `aspect` is height over width, matching the resize grips. Free frames
    /// retain their current ratio too: zoom always scales both axes uniformly.
    static func scaled(_ rect: CGRect, by factor: CGFloat, aspect: CGFloat?, bounds: CGRect, minimum: CGSize) -> CGRect {
        guard factor.isFinite, factor > 0, rect.width > 0, rect.height > 0,
              bounds.width > 0, bounds.height > 0 else { return rect }
        let ratio = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? rect.height / rect.width
        let minimumWidth = max(minimum.width, minimum.height / ratio)
        let maximumWidth = min(bounds.width, bounds.height / ratio)
        // Source bounds win if the available source is smaller than the minimum.
        let width = min(maximumWidth, max(minimumWidth, rect.width * factor))
        let height = width * ratio
        return CGRect(x: min(max(bounds.minX, rect.midX - width / 2), bounds.maxX - width),
            y: min(max(bounds.minY, rect.midY - height / 2), bounds.maxY - height),
            width: width, height: height)
    }

    /// Keep edge grips inside the visible canvas without changing drag geometry.
    /// Only sides touching (within one point) or exceeding the canvas are inset.
    static func insetForDisplay(_ rect: CGRect, visible: CGRect, inset: CGFloat) -> CGRect {
        let intersection = rect.intersection(visible)
        guard !intersection.isNull, !intersection.isEmpty else { return rect }
        let dx = min(max(0, inset), intersection.width / 2)
        let dy = min(max(0, inset), intersection.height / 2)
        let left = rect.minX <= visible.minX + 1 ? visible.minX + dx : rect.minX
        let right = rect.maxX >= visible.maxX - 1 ? visible.maxX - dx : rect.maxX
        let top = rect.minY <= visible.minY + 1 ? visible.minY + dy : rect.minY
        let bottom = rect.maxY >= visible.maxY - 1 ? visible.maxY - dy : rect.maxY
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}
