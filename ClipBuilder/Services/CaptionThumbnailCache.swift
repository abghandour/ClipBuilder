import Foundation

/// A gallery may request dozens of previews at once. Serialize Core Text work
/// off the main actor and share each rendered swatch between the library and picker.
actor CaptionThumbnailCache {
    static let shared = CaptionThumbnailCache()
    private var images: [CaptionStyle: CaptionPreviewImage] = [:]

    func image(for style: CaptionStyle) throws -> CaptionPreviewImage {
        try Task.checkCancellation()
        if let image = images[style] { return image }
        let image = try CaptionPreviewImage.render(style: style)
        if images.count >= 128 { images.removeAll(keepingCapacity: true) }
        images[style] = image
        return image
    }
}
