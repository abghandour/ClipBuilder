import Foundation
import CoreGraphics
import ImageIO

/// Export-faithful preview rasterization stays on the preview worker.
nonisolated enum TextOverlayPreviewImage {
    struct Output: Sendable {
        var png: Data
        /// The box the item occupies in canvas pixels from the top left, or
        /// nil for designs that lay themselves out. Stages use it for the
        /// selection frame and hit target so they match the drawn text.
        var box: CGRect?
    }

    static func render(item: TextOverlayItem, width: Int, height: Int) throws -> Output {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("text-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = TextOverlayRenderer(videoWidth: max(1, width), videoHeight: max(1, height), safeArea: nil)
        let png = try Data(contentsOf: renderer.render(item, to: directory))
        return Output(png: png, box: renderer.renderedBox(item))
    }

    /// The box plus breathing room, clamped to the canvas, so the inspector can
    /// show the text large instead of the whole frame. Nil when the design lays
    /// itself out (no box) and the full frame is the only honest preview.
    static func cropRect(box: CGRect?, width: Int, height: Int) -> CGRect? {
        guard let box, box.width > 0, box.height > 0 else { return nil }
        let pad = max(24, box.height * 0.35)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let rect = box.insetBy(dx: -pad, dy: -pad).intersection(canvas).integral
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// Crops the rendered PNG. Decoded from memory, so no scratch file is involved.
    static func cropped(png: Data, to rect: CGRect) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.cropping(to: rect)
    }
}

nonisolated extension TextOverlayItem {
    var usesTextDecor: Bool {
        decor != nil || sharedStyleID != nil || fontOverride != nil
            || tagStyle?.decor != nil || tagStyle?.sharedStyleID != nil
            || tagStyle?.name.decor != nil || tagStyle?.description.decor != nil
            || tagStyle?.name.fontOverride != nil || tagStyle?.description.fontOverride != nil
    }
}
