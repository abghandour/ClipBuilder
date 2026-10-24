import Foundation
import CoreGraphics

nonisolated struct CaptionPreviewImage: Sendable {
    static let sampleText = "Every strong moment earns victory"
    /// Seconds of speech per word in the sample line, so a longer phrase
    /// plays at a natural pace instead of being squeezed into three seconds.
    static let secondsPerWord = 0.6

    /// The line the preview speaks: the user's phrase, or the stock sample
    /// when it is blank.
    static func text(_ custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? sampleText : trimmed
    }

    /// How long the preview loop lasts for a line: at least three seconds.
    static func duration(of text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return max(3, Double(words) * secondsPerWord)
    }

    let data: Data
    let size: CGSize
    let origin: CGPoint
    var start: Double = 0
    var end: Double = 3

    /// One word in each styling state the editor controls, so a change to
    /// the Text, Highlight or Emphasis group shows up on its own swatch.
    struct WordState: Sendable, Identifiable {
        enum Kind: String, CaseIterable, Sendable { case text = "Text", highlight = "Highlight", emphasis = "Emphasis" }
        var kind: Kind
        var image: CaptionPreviewImage
        var id: Kind { kind }
    }

    /// The three word states rendered with `style`: the plain word, the
    /// spoken (highlighted) word and the emphasis word.
    static func wordStates(style: CaptionStyle) throws -> [WordState] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        return try WordState.Kind.allCases.map { kind in
            try Task.checkCancellation()
            let caption = try renderer.render(text: kind.rawValue,
                                              activeIndex: kind == .highlight ? 0 : nil,
                                              emphasis: kind == .emphasis ? [0] : [], to: scratch)
            let image = Self(data: try Data(contentsOf: caption.pngURL),
                             size: CGSize(width: caption.width, height: caption.height), origin: .zero)
            return WordState(kind: kind, image: image)
        }
    }

    static func render(style: CaptionStyle, text: String? = nil) throws -> Self {
        try frames(style: style, text: text)[0]
    }

    static func frames(style: CaptionStyle, text custom: String? = nil) throws -> [Self] {
        let sampleText = text(custom)
        let length = duration(of: sampleText)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let renderer = CaptionRenderer(videoWidth: 1080, videoHeight: 1920, style: style, safeArea: nil)
        let segment = TranscriptSegment(start: 0, end: length, text: sampleText)
        let pages = CaptionOverlayPlan.pages(segments: [segment], renderer: renderer,
            sourceStart: 0, speed: 1, duration: length, position: style.position,
            speakerTurns: [.init(videoID: 0, start: 0, end: length, cluster: 0, confidence: 1)])
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
