import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rasterizes static overlays into a full-frame transparent PNG. Tracked
/// overlays use a sticker-sized raster and are positioned by ffmpeg each frame.
nonisolated struct ImageOverlayRenderer {
    var videoWidth = 1080
    var videoHeight = 1920
    var safeArea: PlatformSafeArea? = PlatformSafeArea.resolve(RenderContext.settings)

    enum RenderError: Error {
        case unreadableImage(String)
        case contextCreationFailed
    }

    func render(_ item: ImageOverlayItem, to directory: URL) throws -> URL {
        let tracked = item.track?.isEmpty == false
        let targetWidth = max(1, Double(videoWidth) * (item.track?.first?.wFrac ?? item.wFrac))
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  // Thumbnail-with-transform bakes in EXIF rotation; cap the
                  // decode at 2x the target width so huge photos stay cheap.
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(targetWidth * 2),
              ] as CFDictionary) else {
            throw RenderError.unreadableImage(item.path)
        }

        let aspect = Double(image.height) / Double(max(1, image.width))
        let width = targetWidth
        let height = width * aspect
        let canvasWidth = tracked ? Int(ceil(width)) : videoWidth
        let canvasHeight = tracked ? Int(ceil(height)) : videoHeight
        guard let context = CGContext(data: nil, width: canvasWidth, height: canvasHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.contextCreationFailed
        }
        context.interpolationQuality = .high
        context.setAlpha(item.opacity)
        // xFrac/yFrac are the item's center measured from the top-left;
        // Core Graphics' origin is bottom-left, so flip y.
        var center = (x: item.xFrac, y: item.yFrac)
        // Hand-placed items (Express overlay, watermark) are never nudged clear of platform chrome.
        if let safeArea, !item.keepsPlacement, !tracked {
            center = safeArea.clampedCenter(x: item.xFrac, y: item.yFrac,
                                            width: width / Double(videoWidth), height: height / Double(videoHeight))
        }
        let rect = CGRect(x: Double(videoWidth) * center.x - width / 2,
                          y: Double(videoHeight) * (1 - center.y) - height / 2,
                          width: width, height: height)
        context.draw(image, in: tracked ? CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight) : rect)

        guard let rendered = context.makeImage() else { throw RenderError.contextCreationFailed }
        let url = directory.appendingPathComponent("imgoverlay-\(item.uid.uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw RenderError.contextCreationFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.contextCreationFailed
        }
        return url
    }
}
