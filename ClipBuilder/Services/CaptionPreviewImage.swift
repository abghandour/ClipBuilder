import Foundation
import CoreGraphics

nonisolated struct CaptionPreviewImage: Sendable {
    static let sampleText = "Every strong moment earns victory"

    let data: Data
    let size: CGSize
    let origin: CGPoint
    var start: Double = 0
    var end: Double = 3

    static func render(style: CaptionStyle) throws -> Self {
        try frames(style: style)[0]
    }

    static func frames(style: CaptionStyle) throws -> [Self] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let segment = TranscriptSegment(start: 0, end: 3, text: sampleText)
        let pages = CaptionOverlayPlan.pages(segments: [segment], renderer: renderer,
            sourceStart: 0, speed: 1, duration: 3, position: style.position,
            speakerTurns: [.init(videoID: 0, start: 0, end: 3, cluster: 0, confidence: 1)])
        let plan = try CaptionOverlayPlan.plan(pages: pages, style: style)
        var cache: [CaptionOverlayPlan.Raster: Self] = [:]
        return try plan.overlays.map { overlay in
            try Task.checkCancellation()
            if var hit = cache[overlay.raster] {
                hit.start = overlay.start
                hit.end = overlay.end
                return hit
            }
            let raster = overlay.raster
            let caption = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                emphasis: raster.emphasis, textColor: raster.textColor, frame: raster.frame, to: scratch)
            let position = renderer.position(for: caption)
            let image = Self(data: try Data(contentsOf: caption.pngURL),
                             size: CGSize(width: caption.width, height: caption.height),
                             origin: CGPoint(x: position.x, y: position.y), start: overlay.start, end: overlay.end)
            cache[raster] = image
            return image
        }
    }
}
