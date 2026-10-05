import Foundation
import CoreGraphics
import ImageIO

nonisolated struct TagPreviewImage: Sendable {
    var image: CGImage
    var geometry: TagLayout.Result
    var offset: CGPoint
    static let canvas = CGSize(width: 1080, height: 600)

    static func render(style: TagStyle) throws -> Self {
        let sample: String
        switch style.description.field.lowercased() {
        case "mma record": sample = "18 wins · 2 losses"
        case "profession": sample = "Sports journalist"
        case "team": sample = "Team Morgan"
        case "nationality": sample = "Canadian"
        default: sample = "Host"
        }
        let renderer = TextOverlayRenderer(videoWidth: 1080, videoHeight: 600, safeArea: nil)
        var item = TextOverlayItem(text: "Alex Morgan\n" + sample)
        item.fontsize = 160
        item.design = "nameTag"
        item.tagStyle = style
        let layout = renderer.nameTagLayout(item, maxWidth: 960, imageAspects: TextOverlayRenderer.tagImages(style)
            .mapValues { CGFloat($0.width) / CGFloat($0.height) })
        guard let geometry = layout.geometry else { throw CocoaError(.fileReadUnknown) }
        item.fontsize = layout.fontSize
        item.text = layout.lines.joined(separator: "\n")
        let offset = CGPoint(x: (canvas.width - geometry.textBlock.width) / 2,
                             y: (canvas.height - geometry.textBlock.height) / 2)
        item.xFrac = (offset.x + geometry.bounds.midX) / canvas.width
        item.yFrac = (offset.y + geometry.bounds.midY) / canvas.height
        item.wFrac = layout.size.width / canvas.width
        item.hFrac = layout.size.height / canvas.height
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try renderer.render(item, to: directory)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw CocoaError(.fileReadUnknown) }
        return Self(image: image, geometry: geometry, offset: offset)
    }
}
