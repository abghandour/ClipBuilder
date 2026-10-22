import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// One still using the same rasterizers, canvas and placement rules as export.
nonisolated enum WizardPreviewComposite {
    enum Framing: Sendable, Hashable {
        case cover(face: CGRect?)
        case path(CameraPathKeyframe)
        case cells([Cell])

        func hash(into hasher: inout Hasher) {
            switch self {
            case .cover(let face):
                hasher.combine(0)
                hasher.combine(face.map { [$0.minX, $0.minY, $0.width, $0.height] })
            case .path(let key): hasher.combine(1); hasher.combine(key)
            case .cells(let cells): hasher.combine(2); hasher.combine(cells)
            }
        }
    }

    struct Cell: Sendable, Hashable {
        var source: CGRect
        var area: CGRect
        var person: PersonRecord? = nil
        var face: CGRect? = nil
        var isTalking = false

        func hash(into hasher: inout Hasher) {
            hasher.combine([source.minX, source.minY, source.width, source.height])
            hasher.combine([area.minX, area.minY, area.width, area.height])
            hasher.combine(person)
            hasher.combine(face.map { [$0.minX, $0.minY, $0.width, $0.height] })
            hasher.combine(isTalking)
        }
    }

    struct Scene: Sendable {
        var videoURL: URL
        var time: Double
        /// Source-frame fractions, measured from the top left.
        var faceRect: CGRect?
        var person: PersonRecord?
        var captionText: String?
        var words: [TranscriptWord]?
        var cameraPath: SceneCameraPath? = nil
        var contentIsWide = false
        var sourceSize = CGSize(width: 16, height: 9)
        var framing: Framing = .cover(face: nil)
        var framingWarning: String? = nil
    }

    struct Input: Sendable {
        var scene: Scene
        var options: WizardOptions
        var profile: BrandProfile
        var templates: [OverlayTemplate]
        var frameData: Data
    }

    enum PreviewError: LocalizedError {
        case unreadableFrame, contextCreationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableFrame: "Could not read the preview frame."
            case .contextCreationFailed: "Could not draw the preview."
            }
        }
    }

    static func render(_ input: Input) async throws -> CGImage {
        let base = try await prepareBase(input)
        return try render(input, baseFrame: base.image)
    }

    static func render(_ input: Input, baseFrame: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        return try RenderContext.$settings.withValue(input.options.renderSettings) {
            let settings = input.options.renderSettings
            let canvas = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
            let context = try makeContext(settings)
            context.draw(baseFrame, in: canvas)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wizard-preview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            func draw(_ url: URL, in rect: CGRect? = nil) throws {
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw PreviewError.unreadableFrame
                }
                context.draw(image, in: rect ?? canvas)
            }
            let textRenderer = TextOverlayRenderer(videoWidth: settings.width, videoHeight: settings.height)
            let imageRenderer = ImageOverlayRenderer(videoWidth: settings.width, videoHeight: settings.height)
            func drawBlock(_ block: OverlayBlockItem, at time: Double) throws {
                var document = TimelineDocument()
                document.overlayBlocks = [block]
                let expanded = document.expandingOverlayBlocks()
                // Production draws image overlays before text overlays.
                for item in expanded.imageOverlays where item.startTime <= time && time < item.endTime {
                    try draw(imageRenderer.render(item, to: scratch))
                }
                for item in expanded.textOverlays where item.startTime <= time && time < item.endTime {
                    try draw(textRenderer.render(item, to: scratch))
                }
            }
            let options = input.options
            let previewTime = max(0, options.fixedOverlayStart ?? 0)
            let duration = previewTime + max(3, options.fixedOverlayDuration ?? 3)
            if options.includeWatermark {
                if let block = WizardFixedOverlay.watermarkBlock(options: options, templates: input.templates,
                                                                 totalDuration: duration) {
                    try drawBlock(block, at: previewTime)
                } else if options.watermarkOverlayTemplate?.isEmpty != false,
                          let logo = input.profile.logoURL,
                          let png = BrandRenderer.watermark(logoURL: logo, to: scratch,
                              opacity: WizardFixedOverlay.effectiveWatermarkOpacity(options: options)) {
                    try draw(png)
                }
            }
            if let block = WizardFixedOverlay.block(options: options, templates: input.templates, totalDuration: duration) {
                try drawBlock(block, at: previewTime)
            }
            let style = input.profile.captionStyle(id: options.captionStyleID)
            if options.addCaptions {
                let renderer = CaptionRenderer(videoWidth: settings.width, videoHeight: settings.height, style: style,
                    safeArea: options.resolvedSafeArea, safeAreaOnly: options.safeAreaOnly == true)
                let text = input.scene.captionText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let start = input.scene.words?.first?.start ?? 0
                let end = max(start + 3, input.scene.words?.last?.end ?? 3)
                let segment = TranscriptSegment(start: start, end: end,
                    text: text.flatMap { $0.isEmpty ? nil : $0 } ?? CaptionPreviewImage.sampleText, words: input.scene.words)
                if let page = renderer.pages(for: segment).first {
                    let middleWord = page.text.split(whereSeparator: \.isWhitespace).count / 2
                    let position = options.captionPositionOverride ?? "auto"
                    // The production plan supplies emphasis, emoji and word reveal as well as highlighting.
                    let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: position,
                        language: options.effectiveCaptionLanguage ?? "")], style: style)
                    let middleTime = (page.start + page.end) / 2
                    if let overlay = plan.overlays.last(where: { $0.raster.activeIndex == middleWord })
                        ?? plan.overlays.first(where: { $0.start <= middleTime && middleTime < $0.end })
                        ?? plan.overlays.first {
                        let raster = overlay.raster
                        let caption = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                            emphasis: raster.emphasis, textColor: raster.textColor, frame: raster.frame, to: scratch)
                        let origin = renderer.position(for: caption, positionOverride: position)
                        try draw(caption.pngURL, in: CGRect(x: origin.x, y: settings.height - origin.y - caption.height,
                                                           width: caption.width, height: caption.height))
                    }
                }
            }
            if options.usesNameTags {
                let geometry = tagGeometry(scene: input.scene, canvas: canvas.size)
                let tagStyle = input.profile.tagStyle(id: options.nameTagStyleID)
                let imageAspects = TextOverlayRenderer.tagImages(tagStyle).mapValues { CGFloat($0.width) / CGFloat($0.height) }
                let tags = NameTagPlanner.plan(areas: geometry.areas, people: geometry.people,
                    settings: WizardNameTags.settings(options: options, captionStyle: style), style: tagStyle,
                    imageAspects: imageAspects)
                for tag in tags {
                    try draw(textRenderer.render(NameTagPlanner.overlay(tag, canvas: canvas.size, style: tagStyle), to: scratch))
                }
            }
            try Task.checkCancellation()
            guard let image = context.makeImage() else { throw PreviewError.contextCreationFailed }
            return image
        }
    }

    struct BaseFrame: Sendable {
        var image: CGImage
        var error: String? = nil
    }

    /// Called on the render worker, before overlays. EffectCatalog owns LUT escaping
    /// and the split/blend graph for partial intensity, exactly as it does for export.
    static func prepareBase(_ input: Input) async throws -> BaseFrame {
        let frame = try croppedFrame(input)
        guard let effect = WizardEngine.lookEffect(for: input.options) else { return BaseFrame(image: frame) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wizard-look-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let source = scratch.appendingPathComponent("source.png")
            let output = scratch.appendingPathComponent("graded.png")
            guard let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw PreviewError.unreadableFrame
            }
            CGImageDestinationAddImage(destination, frame, nil)
            guard CGImageDestinationFinalize(destination) else { throw PreviewError.unreadableFrame }
            let filter = EffectCatalog.filter(for: effect, width: frame.width, height: frame.height)
            try await FFmpeg.run(["-y", "-i", source.path, "-vf", filter, "-frames:v", "1", output.path])
            try Task.checkCancellation()
            // Decode from memory: an image created from the file URL decodes
            // lazily and draws black once the scratch directory is removed.
            let graded = try Data(contentsOf: output)
            guard let decoded = CGImageSourceCreateWithData(graded as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else { throw PreviewError.unreadableFrame }
            return BaseFrame(image: image)
        } catch {
            try Task.checkCancellation()
            Logger(subsystem: "ClipBuilder", category: "WizardPreview").error("Look preview failed: \(error.localizedDescription)")
            return BaseFrame(image: frame, error: "Look could not be previewed")
        }
    }

    private static func makeContext(_ settings: RenderSettings) throws -> CGContext {
        guard let context = CGContext(data: nil, width: settings.width, height: settings.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewError.contextCreationFailed }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: settings.width, height: settings.height))
        return context
    }

    static func croppedFrame(_ input: Input) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(input.frameData as CFData, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PreviewError.unreadableFrame }
        let settings = input.options.renderSettings
        let canvas = CGSize(width: settings.width, height: settings.height)
        let context = try makeContext(settings)
        switch input.scene.framing {
        case .cover(let face):
            context.draw(frame, in: coverRect(source: CGSize(width: frame.width, height: frame.height), canvas: canvas, face: face))
        case .path(let key):
            draw(frame, source: CGRect(x: key.x, y: key.y, width: key.w, height: key.h),
                 area: WizardPreviewFraming.full, canvas: canvas, context: context)
        case .cells(let cells):
            for cell in cells { draw(frame, source: cell.source, area: cell.area, canvas: canvas, context: context) }
        }
        guard let image = context.makeImage() else { throw PreviewError.contextCreationFailed }
        return image
    }

    private static func draw(_ frame: CGImage, source: CGRect, area: CGRect, canvas: CGSize, context: CGContext) {
        let target = CGRect(x: area.minX * canvas.width, y: (1 - area.maxY) * canvas.height,
                            width: area.width * canvas.width, height: area.height * canvas.height)
        let visible = visibleSource(source, frame: CGSize(width: frame.width, height: frame.height), canvas: target.size)
        guard visible.width > 0, visible.height > 0 else { return }
        let width = target.width / visible.width, height = target.height / visible.height
        let drawn = CGRect(x: target.minX - visible.minX * width,
                           y: target.minY - (1 - visible.maxY) * height, width: width, height: height)
        context.saveGState()
        context.clip(to: target)
        context.draw(frame, in: drawn)
        context.restoreGState()
    }

    /// Apply the cell's final cover crop to both its pixels and its face geometry.
    private static func visibleSource(_ source: CGRect, frame: CGSize, canvas: CGSize) -> CGRect {
        let drawn = coverRect(source: CGSize(width: source.width * frame.width, height: source.height * frame.height),
                              canvas: canvas, face: nil)
        return CGRect(x: source.minX - drawn.minX / drawn.width * source.width,
                      y: source.minY + (drawn.maxY - canvas.height) / drawn.height * source.height,
                      width: canvas.width / drawn.width * source.width,
                      height: canvas.height / drawn.height * source.height)
    }

    /// Planner geometry is top-left canvas pixels, including each cell's face and
    /// the caption band supplied by WizardNameTags.settings.
    static func tagGeometry(scene: Scene, canvas: CGSize) -> (areas: [NameTagPlanner.Area], people: [NameTagPlanner.Person]) {
        let cells: [Cell]
        switch scene.framing {
        case .cells(let values): cells = values
        case .path(let key):
            cells = [Cell(source: CGRect(x: key.x, y: key.y, width: key.w, height: key.h),
                          area: WizardPreviewFraming.full, person: scene.person, face: scene.faceRect)]
        case .cover(let face):
            // Match the same cover transform used to draw the base frame.
            let source = scene.sourceSize
            let drawn = coverRect(source: source, canvas: canvas, face: face)
            let crop = CGRect(x: -drawn.minX / drawn.width, y: (drawn.maxY - canvas.height) / drawn.height,
                              width: canvas.width / drawn.width, height: canvas.height / drawn.height)
            cells = [Cell(source: crop, area: WizardPreviewFraming.full, person: scene.person, face: scene.faceRect)]
        }
        var names: [NameTagPlanner.Person] = []
        let areas = cells.map { cell in
            let rect = CGRect(x: cell.area.minX * canvas.width, y: cell.area.minY * canvas.height,
                              width: cell.area.width * canvas.width, height: cell.area.height * canvas.height)
            let person = cell.person
            let key = person?.key ?? "preview"
            names.append(.init(key: key, name: person?.tagName ?? "Alex Morgan", role: person?.descriptor ?? "Guest"))
            let source = visibleSource(cell.source, frame: scene.sourceSize, canvas: rect.size)
            let face = cell.face.map {
                CGRect(x: rect.minX + ($0.minX - source.minX) / source.width * rect.width,
                       y: rect.minY + ($0.minY - source.minY) / source.height * rect.height,
                       width: $0.width / source.width * rect.width, height: $0.height / source.height * rect.height)
            }
            return NameTagPlanner.Area(rect: rect, spans: [.init(start: 0, end: 3, personKey: key, faceBox: face)])
        }
        return (areas, names)
    }

    /// The drawn source rect in Core Graphics coordinates, clamped so cover never exposes an edge.
    static func coverRect(source: CGSize, canvas: CGSize, face: CGRect?) -> CGRect {
        let scale = max(canvas.width / source.width, canvas.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let center = face.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
        let x = min(0, max(canvas.width - size.width, canvas.width / 2 - center.x * size.width))
        let top = min(0, max(canvas.height - size.height, canvas.height / 2 - center.y * size.height))
        return CGRect(x: x, y: canvas.height - top - size.height, width: size.width, height: size.height)
    }
}
