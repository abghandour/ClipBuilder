import Foundation
import CoreGraphics
import CoreImage

/// Still-frame twin of FitComposer. The destination is top-left canvas pixels;
/// the supplied CGContext uses CoreGraphics' normal bottom-left coordinates.
nonisolated enum FitDrawer {
    static func draw(_ image: CGImage, spec: FitSpec, in context: CGContext) throws {
        guard let source = image.cropping(to: spec.pixels) else { return }
        let destination = CGRect(x: spec.destination.minX, y: spec.canvasSize.height - spec.destination.maxY,
                                 width: spec.destination.width, height: spec.destination.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        context.clip(to: destination)
        if let area = spec.mask {
            let path = CGMutablePath()
            for (index, point) in area.points.enumerated() {
                let p = CGPoint(x: point.x * spec.canvasSize.width, y: (1 - point.y) * spec.canvasSize.height)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
        if spec.fit == .fill || (!spec.horizontalBars && !spec.verticalBars) {
            context.draw(source, in: cover(source: CGSize(width: source.width, height: source.height), destination: destination))
            return
        }
        let width = max(2, Int(destination.width)), height = max(2, Int(destination.height))
        guard let background = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadUnknown) }
        background.interpolationQuality = .high
        background.draw(source, in: cover(source: CGSize(width: source.width, height: source.height),
                                          destination: CGRect(x: 0, y: 0, width: width, height: height)))
        guard let scaled = background.makeImage() else { throw CocoaError(.fileReadUnknown) }
        let input = CIImage(cgImage: scaled)
        let radius = min(spec.blurRadius, Double(min(width, height)) / 2 - 1)
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0, radius)])
            .cropped(to: input.extent)
        let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: CGColorSpaceCreateDeviceRGB()])
        guard let result = ci.createCGImage(blurred, from: input.extent) else { throw CocoaError(.fileReadUnknown) }
        context.draw(result, in: destination)
        context.setFillColor(CGColor(gray: 0, alpha: 0.25))
        context.fill(destination)
        let foreground = CGRect(x: spec.foreground.minX, y: spec.canvasSize.height - spec.foreground.maxY,
                                width: spec.foreground.width, height: spec.foreground.height)
        if spec.featherPixels > 0 {
            // CG clips using an image's alpha; the exact same image is exported as PNG.
            context.clip(to: foreground, mask: try ScreenCropStore.gradientMask(spec: spec))
        }
        context.draw(source, in: foreground)
    }

    private static func cover(source: CGSize, destination: CGRect) -> CGRect {
        let scale = max(destination.width / max(1, source.width), destination.height / max(1, source.height))
        return CGRect(x: destination.midX - source.width * scale / 2, y: destination.midY - source.height * scale / 2,
                      width: source.width * scale, height: source.height * scale)
    }
}
