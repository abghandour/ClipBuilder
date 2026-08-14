import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rasterizes an image overlay to a full-frame transparent PNG — the image
/// counterpart of TextOverlayRenderer. The PNG is video-sized and overlaid at
/// 0:0, so the ffmpeg fade/slide expressions that animate text overlays work
/// on image overlays unchanged.
nonisolated struct ImageOverlayRenderer {
    var videoWidth = 1080
    var videoHeight = 1920

    enum RenderError: Error {
        case unreadableImage(String)
        case contextCreationFailed
    }

    func render(_ item: ImageOverlayItem, to directory: URL) throws -> URL {
        let targetWidth = max(1, Double(videoWidth) * item.wFrac)
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
        guard let context = CGContext(data: nil, width: videoWidth, height: videoHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.contextCreationFailed
        }
        context.interpolationQuality = .high
        context.setAlpha(item.opacity)
        // xFrac/yFrac are the item's center measured from the top-left;
        // Core Graphics' origin is bottom-left, so flip y.
        let rect = CGRect(x: Double(videoWidth) * item.xFrac - width / 2,
                          y: Double(videoHeight) * (1 - item.yFrac) - height / 2,
                          width: width, height: height)
        context.draw(image, in: rect)

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
