import Foundation
import CoreGraphics

nonisolated struct CaptionPreviewImage: Sendable {
    let data: Data
    let size: CGSize
    let origin: CGPoint

    static func render(style: CaptionStyle) throws -> Self {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let caption = try renderer.render(text: "Every moment has a story. Make yours stand out.", to: scratch)
        let position = renderer.position(for: caption)
        return Self(data: try Data(contentsOf: caption.pngURL),
                    size: CGSize(width: caption.width, height: caption.height),
                    origin: CGPoint(x: position.x, y: position.y))
    }
}
