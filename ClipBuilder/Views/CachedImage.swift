import AppKit
import ImageIO
import SwiftUI

/// Process-wide cache of downsampled images keyed by file and target size,
/// so grids and tables never decode a full-resolution file on the main
/// thread and scrolling back to a cell is a dictionary hit.
nonisolated enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private static func key(_ url: URL, maxPixel: Int) -> NSString {
        "\(url.path)|\(maxPixel)" as NSString
    }

    /// The cached image if it was decoded before, without touching disk.
    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel: maxPixel))
    }

    /// Decode (off the calling executor) a thumbnail no larger than
    /// `maxPixel` on its longest side, store it, and return it.
    static func image(for url: URL, maxPixel: Int) async -> NSImage? {
        let key = key(url, maxPixel: maxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return decode(source, maxPixel: maxPixel)
        }.value
        if let decoded { store(decoded, key: key) }
        return decoded
    }

    /// Decode a JPEG/PNG payload off the calling executor and cache it
    /// under an arbitrary key (video-frame thumbnails are keyed by file and
    /// time rather than by a file URL).
    static func image(data: Data, key: String, maxPixel: Int) async -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return decode(source, maxPixel: maxPixel)
        }.value
        if let decoded { store(decoded, key: key as NSString) }
        return decoded
    }

    /// A cached image stored under an arbitrary key, without touching disk.
    static func cached(key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    private static func decode(_ source: CGImageSource, maxPixel: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func store(_ image: NSImage, key: NSString) {
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
    }
}

/// An image file shown at thumbnail size: decoded once, downsampled, cached
/// in memory, never read inside `body`. Renders `placeholder` until (or
/// unless) the file decodes.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var maxPixel: Int = 400
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadedKey: String?

    init(url: URL?, maxPixel: Int = 400, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    private var key: String { "\(url?.path ?? "")|\(maxPixel)" }

    var body: some View {
        Group {
            // Synchronous cache hit avoids a placeholder flash when a cell
            // scrolls back into view.
            if let image = image ?? url.flatMap({ ImageCache.cached($0, maxPixel: maxPixel) }) {
                if contentMode == .fill {
                    Color.clear.overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard loadedKey != key else { return }
            // A new key means a different file: never keep the old picture.
            image = nil
            loadedKey = nil
            guard let url else { return }
            if let loaded = await ImageCache.image(for: url, maxPixel: maxPixel) {
                image = loaded
                loadedKey = key
            }
        }
    }
}

extension CachedImage where Placeholder == AnyShapeStyleFill {
    /// Convenience with the standard quaternary placeholder.
    init(url: URL?, maxPixel: Int = 400, contentMode: ContentMode = .fill) {
        self.init(url: url, maxPixel: maxPixel, contentMode: contentMode) { AnyShapeStyleFill() }
    }
}

/// Neutral rectangle placeholder for `CachedImage`.
struct AnyShapeStyleFill: View {
    var body: some View { Rectangle().fill(.quaternary) }
}
