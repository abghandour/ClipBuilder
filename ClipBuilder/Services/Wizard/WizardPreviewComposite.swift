import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// One still using the same rasterizers, canvas and placement rules as export.
nonisolated enum WizardPreviewComposite {
    enum Framing: Sendable, Hashable {
        case original
        case cover(face: CGRect?)
        case path(CameraPathKeyframe)
        case cells([Cell])

        func hash(into hasher: inout Hasher) {
            switch self {
            case .original: hasher.combine(3)
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
        var sourcePath: String? = nil
        var sourceTime: Double? = nil
        var mask: ScreenCropArea? = nil
        var role: ScreenCropArea.Role? = nil
        var trackingRegion: FreeCropRect? = nil
        var focus: AreaFocus? = nil

        var frameKey: String { "\(sourcePath ?? "")@\(sourceTime ?? 0)" }

        func hash(into hasher: inout Hasher) {
            hasher.combine([source.minX, source.minY, source.width, source.height])
            hasher.combine([area.minX, area.minY, area.width, area.height])
            hasher.combine(person)
            hasher.combine(face.map { [$0.minX, $0.minY, $0.width, $0.height] })
            hasher.combine(isTalking)
            hasher.combine(sourcePath)
            hasher.combine(sourceTime)
            hasher.combine(mask)
            hasher.combine(role)
            hasher.combine(trackingRegion)
            hasher.combine(focus)
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
        var contentBox: RenderEngine.ContentBox? = nil
        var sourceSize = CGSize(width: 16, height: 9)
        var framing: Framing = .cover(face: nil)
        var framingWarning: String? = nil
        var speakerTurns: [SpeakerTurn] = []
        var speakerRows: [TranscriptRow] = []
        var captionSegment: TranscriptSegment? = nil
        var roster: [String: String] = [:]
        var speakingPeople: Set<String> = []
        /// Full-wizard source order; nil resolves from this recording's snapshot.
        var captionOrdinals: [String: Int]? = nil

        var resolvedCaptionOrdinals: [String: Int] {
            captionOrdinals ?? CaptionSpeakerOrder.ordinals(turns: speakerTurns, rows: speakerRows, roster: Array(roster.keys))
        }
    }

    struct Input: Sendable {
        var scene: Scene
        var options: WizardOptions
        var profile: BrandProfile
        var templates: [OverlayTemplate]
        var frameData: Data
        /// People whose captions the preview draws. nil draws the moment's
        /// speaker only (no chips); a set draws exactly those people, with the
        /// moment's speaker on top when listed. Speech with no person always shows.
        var shownSpeakers: Set<String>? = nil
        var cellFrames: [String: Data] = [:]
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

    /// Where the draggable elements landed, in canvas pixels from the top
    /// left, so the preview can offer them as handles.
    struct Layout: Sendable, Equatable {
        /// Where the uncropped, oriented recording maps into canvas pixels, y down.
        /// It can extend beyond the canvas when the current picture is cropped.
        var sourceRect: CGRect?
        var captions: [CaptionBox] = []
        var tags: [CGRect] = []
        var overlay: CGRect?
        /// Every component of the overlay design (texts as the box they
        /// rendered in, grown or wrapped; images at their file's aspect) so
        /// the preview can offer each one to move and resize.
        var overlayComponents: [ComponentBox] = []
        /// How far a legacy dragged position moved the whole design, in
        /// canvas pixels; a placed component is stored without this shift.
        var overlayShift: CGPoint = .zero
    }

    struct ComponentBox: Sendable, Equatable {
        var component: OverlayComponent
        var rect: CGRect
        /// Height over width for images, which keep their file's aspect.
        var aspect: CGFloat?
    }

    struct CaptionBox: Sendable, Equatable {
        var rect: CGRect
        var personKey: String?
        var name: String
        var isTalking: Bool
    }

    static func render(_ input: Input) async throws -> CGImage {
        let base = try await prepareBase(input)
        return try render(input, baseFrame: base.image)
    }

    static func render(_ input: Input, baseFrame: CGImage) throws -> CGImage {
        try renderWithLayout(input, baseFrame: baseFrame).image
    }

    static func renderWithLayout(_ input: Input, baseFrame: CGImage) throws -> (image: CGImage, layout: Layout) {
        try Task.checkCancellation()
        var layout = Layout()
        layout.sourceRect = sourceRect(input)
        let image = try RenderContext.$settings.withValue(input.options.renderSettings) {
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
            let textRenderer = TextOverlayRenderer(videoWidth: settings.width, videoHeight: settings.height, textStyles: input.profile.textStyles ?? [])
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
                if let box = WizardFixedOverlay.bounds(of: block.composition, canvasAspect: settings.aspectRatio) {
                    layout.overlay = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height,
                                            width: box.width * canvas.width, height: box.height * canvas.height)
                }
                func pixels(_ box: CGRect) -> CGRect {
                    CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height,
                           width: box.width * canvas.width, height: box.height * canvas.height)
                }
                // Indexed by template position (what OverlayEdits uses), with
                // the block's exact placement applied as expansion does: it
                // turns the safe-area nudge off, so the footprint must see it.
                layout.overlayComponents = block.composition.texts.enumerated().map { index, template in
                    var item = template
                    item.keepsPlacement = item.keepsPlacement || block.exactPlacement
                    return ComponentBox(component: .text(index),
                                        rect: textRenderer.renderedBox(item) ?? pixels(WizardFixedOverlay.designBox(of: item)))
                } + block.composition.images.enumerated().map { index, item in
                    let aspect = imageAspect(item.url)
                    return ComponentBox(component: .image(index),
                                        rect: pixels(WizardFixedOverlay.designBox(of: item, aspect: aspect)), aspect: aspect)
                }
                if let custom = CustomPosition(options.fixedOverlayPosition),
                   let template = input.templates.first(where: { $0.name.caseInsensitiveCompare(block.name) == .orderedSame }) {
                    let shift = WizardFixedOverlay.shift(of: WizardFixedOverlay.designComposition(options: options, template: template),
                                                         center: custom, canvasAspect: settings.aspectRatio)
                    layout.overlayShift = CGPoint(x: shift.x * canvas.width, y: shift.y * canvas.height)
                }
            }
            let style = input.profile.renderCaptionStyle(id: options.captionStyleID)
            if options.addCaptions {
                let base = CaptionRenderer(videoWidth: settings.width, videoHeight: settings.height, style: style,
                    safeArea: options.resolvedSafeArea, safeAreaOnly: options.safeAreaOnly == true)
                let renderers = CaptionRendererSet(base: base,
                    speakerStyles: input.profile.speakerCaptionStyles(runStyleID: options.captionStyleID))
                let moment = TranscriptSegment(start: input.scene.time, end: input.scene.time.nextUp, text: "")
                let speakers = CaptionSpeakerColors.Sorted(turns: input.scene.speakerTurns, rows: input.scene.speakerRows)
                let talking = CaptionSpeakerColors.personKey(CaptionSpeakerColors.speakerKey(for: moment,
                    sorted: speakers))
                let ordinals = input.scene.resolvedCaptionOrdinals
                func drawCaption(person: String?, isTalking: Bool) throws {
                    let styleID = person.flatMap { renderers.perSpeaker[$0] == nil ? nil : $0 }
                    let renderer = renderers.renderer(styleID: styleID)
                    var colorMoment = moment
                    if !isTalking, let person {
                        let times = (input.scene.speakerTurns.map(\.start) + input.scene.speakerRows.map(\.startTime)).sorted()
                        if let time = times.first(where: { time in
                            CaptionSpeakerColors.personKey(CaptionSpeakerColors.speakerKey(
                                for: .init(start: time, end: time.nextUp, text: ""),
                                sorted: speakers)) == person
                        }) { colorMoment = .init(start: time, end: time.nextUp, text: "") }
                    }
                    let color = renderer.style.resolvedSpeakerColors
                        ? CaptionSpeakerColors.color(for: colorMoment, sorted: speakers) : nil
                    let text = input.scene.captionText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = input.scene.words?.first?.start ?? 0
                    let end = max(start + 3, input.scene.words?.last?.end ?? 3)
                    let segment = isTalking
                        ? (input.scene.captionSegment ?? TranscriptSegment(start: start, end: end,
                            text: text.flatMap { $0.isEmpty ? nil : $0 } ?? CaptionPreviewImage.sampleText, words: input.scene.words))
                        : TranscriptSegment(start: 0, end: 3, text: CaptionPreviewImage.sampleText)
                    let pages = renderer.pages(for: segment)
                    let selectedPage = isTalking
                        ? pages.first(where: { $0.start <= input.scene.time && input.scene.time < $0.end }) ?? pages.first
                        : pages.first
                    guard let page = selectedPage else { return }
                    let middleWord = page.text.split(whereSeparator: \.isWhitespace).count / 2
                    let position = CaptionSpeakerOrder.position(forPerson: person, ordinals: ordinals,
                        positions: options.speakerCaptionPositions, runPosition: options.captionPositionOverride ?? "auto")
                    // The production plan supplies emphasis, emoji and word reveal as well as highlighting.
                    let plan = try CaptionOverlayPlan.plan(pages: [.init(caption: page, position: position,
                        language: options.effectiveCaptionLanguage ?? "", textColor: color, styleID: styleID)],
                        style: style, styles: renderers.styles)
                    let middleTime = (page.start + page.end) / 2
                    let current = isTalking ? plan.overlays.first(where: {
                        $0.start <= input.scene.time && input.scene.time < $0.end
                    }) : nil
                    if let overlay = current ?? plan.overlays.last(where: { $0.raster.activeIndex == middleWord })
                        ?? plan.overlays.first(where: { $0.start <= middleTime && middleTime < $0.end })
                        ?? plan.overlays.first {
                        let raster = overlay.raster
                        let caption = try renderer.render(text: raster.text, activeIndex: raster.activeIndex,
                            emphasis: raster.emphasis, textColor: raster.textColor, frame: raster.frame, to: scratch)
                        let origin = renderer.position(for: caption, positionOverride: position)
                        layout.captions.append(CaptionBox(
                            rect: CGRect(x: origin.x, y: origin.y, width: caption.width, height: caption.height),
                            personKey: person, name: person.map { input.scene.roster[$0] ?? $0 } ?? "Caption", isTalking: isTalking))
                        try draw(caption.pngURL, in: CGRect(x: origin.x, y: settings.height - origin.y - caption.height,
                                                           width: caption.width, height: caption.height))
                    }
                }
                for person in (input.shownSpeakers ?? []).sorted() where person != talking {
                    let hasPosition = ordinals[person].flatMap { options.speakerCaptionPositions?[CaptionSpeakerOrder.slot($0)] } != nil
                    if renderers.perSpeaker[person] != nil || hasPosition || input.scene.roster[person] != nil {
                        try drawCaption(person: person, isTalking: false)
                    }
                }
                // The current speaker sits above the samples; a chip can hide them.
                if talking == nil || input.shownSpeakers?.contains(talking!) != false {
                    try drawCaption(person: talking, isTalking: true)
                }
            }

            if options.usesNameTags {
                let geometry = tagGeometry(scene: input.scene, canvas: canvas.size, options: input.options)
                let tagStyle = input.profile.tagStyle(id: options.nameTagStyleID)
                let imageAspects = TextOverlayRenderer.tagImages(tagStyle).mapValues { CGFloat($0.width) / CGFloat($0.height) }
                let tags = NameTagPlanner.plan(areas: geometry.areas, people: geometry.people,
                    settings: WizardNameTags.settings(options: options, captionStyle: style), style: tagStyle.applyingSharedStyle(input.profile.textStyles ?? []),
                    imageAspects: imageAspects)
                for tag in tags {
                    layout.tags.append(tag.rect)
                    try draw(textRenderer.render(NameTagPlanner.overlay(tag, canvas: canvas.size, style: tagStyle), to: scratch))
                }
            }
            try Task.checkCancellation()
            guard let image = context.makeImage() else { throw PreviewError.contextCreationFailed }
            return image
        }
        return (image, layout)
    }

    struct BaseFrame: Sendable {
        var image: CGImage
        var error: String? = nil
    }

    /// Height over width of an image file from its header; 1 (square, as
    /// `WizardFixedOverlay.bounds` assumes) when it cannot be read.
    static func imageAspect(_ url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return 1 }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? width / height : height / width
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
        case .original:
            let spec = fitSpec(input, frame: frame, canvas: canvas)
            if input.options.requestedFraming.focusFrame != nil, spec.fit == .fill,
               let cropped = frame.cropping(to: spec.pixels) {
                // A static focus frame is the timeline's free crop, including its exact edges.
                context.draw(cropped, in: CGRect(origin: .zero, size: canvas))
            } else {
                try FitDrawer.draw(frame, spec: spec, in: context)
            }
        case .cover(let face):
            if input.options.requestedFraming.fit == .blurredFill {
                try FitDrawer.draw(frame, spec: fitSpec(input, frame: frame, canvas: canvas), in: context)
            } else {
                context.draw(frame, in: coverRect(source: CGSize(width: frame.width, height: frame.height), canvas: canvas, face: face))
            }
        case .path(let key):
            var spec = fitSpec(input, frame: frame, canvas: canvas)
            spec.sourceWindow = FreeCropRect(xFrac: key.x, yFrac: key.y, wFrac: key.w, hFrac: key.h)
            try FitDrawer.draw(frame, spec: spec, in: context)
        case .cells(let cells):
            for cell in cells {
                let cellFrame: CGImage
                if let data = input.cellFrames[cell.frameKey],
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) { cellFrame = decoded }
                else { cellFrame = frame }
                var spec = fitSpec(input, frame: cellFrame, canvas: canvas)
                spec.mask = cell.mask
                spec.sourceWindow = FreeCropRect(xFrac: cell.source.minX, yFrac: cell.source.minY,
                    wFrac: cell.source.width, hFrac: cell.source.height)
                spec.destination = CGRect(x: cell.area.minX * canvas.width, y: cell.area.minY * canvas.height,
                    width: cell.area.width * canvas.width, height: cell.area.height * canvas.height)
                try FitDrawer.draw(cellFrame, spec: spec, in: context)
                if let role = cell.role {
                    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(10, canvas.width * 0.025), nil)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: role.label, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
                    let bounds = CTLineGetBoundsWithOptions(line, [])
                    let origin = CGPoint(x: spec.destination.minX + 8,
                        y: canvas.height - spec.destination.minY - bounds.height - 10)
                    context.setFillColor(CGColor(gray: 0, alpha: 0.65))
                    context.fill(CGRect(x: origin.x - 4, y: origin.y - 4, width: bounds.width + 8, height: bounds.height + 8))
                    context.textPosition = origin
                    CTLineDraw(line, context)
                }
            }
        }
        guard let image = context.makeImage() else { throw PreviewError.contextCreationFailed }
        return image
    }

    private static func fitSpec(_ input: Input, frame: CGImage, canvas: CGSize) -> FitSpec {
        let framing = input.options.requestedFraming
        return FitSpec(sourceWindow: FocusFrame.sourceWindow(framing.subject == .layout ? FreeCropRect() : framing.focusFrame ?? FreeCropRect(),
                contentBox: input.scene.contentBox),
            sourceSize: CGSize(width: frame.width, height: frame.height),
            destination: CGRect(origin: .zero, size: canvas), canvasSize: canvas,
            fit: framing.fit, feather: framing.feather, blur: framing.blur)
    }

    /// The inverse of the actual foreground placement, used by the focus handle.
    static func sourceRect(_ input: Input) -> CGRect? {
        let settings = input.options.renderSettings
        let canvas = CGSize(width: settings.width, height: settings.height)
        var sourceSize = input.scene.sourceSize
        if let source = CGImageSourceCreateWithData(input.frameData as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            sourceSize = CGSize(width: width.doubleValue, height: height.doubleValue)
        }
        let framing = input.options.requestedFraming
        guard framing.subject != .layout else { return nil }
        var window = FocusFrame.sourceWindow(framing.focusFrame ?? FreeCropRect(), contentBox: input.scene.contentBox)
        var destination = CGRect(origin: .zero, size: canvas)
        var staticCrop = false
        switch input.scene.framing {
        case .original: staticCrop = framing.focusFrame != nil
        case .path(let key): window = FreeCropRect(xFrac: key.x, yFrac: key.y, wFrac: key.w, hFrac: key.h)
        case .cells(let cells):
            guard let cell = cells.first else { return nil }
            window = FocusFrame.window(cell.source)
            destination = CGRect(x: cell.area.minX * canvas.width, y: cell.area.minY * canvas.height,
                width: cell.area.width * canvas.width, height: cell.area.height * canvas.height)
        case .cover(let face):
            if framing.fit == .fill {
                let drawn = coverRect(source: sourceSize, canvas: canvas, face: face)
                return CGRect(x: drawn.minX, y: canvas.height - drawn.maxY, width: drawn.width, height: drawn.height)
            }
        }
        let spec = FitSpec(sourceWindow: window, sourceSize: sourceSize,
            destination: destination, canvasSize: canvas, fit: framing.fit)
        let drawn: CGRect
        if staticCrop && framing.fit == .fill { drawn = destination }
        else if framing.fit == .blurredFill { drawn = spec.foreground }
        else {
            let scale = max(destination.width / spec.pixels.width, destination.height / spec.pixels.height)
            let size = CGSize(width: spec.pixels.width * scale, height: spec.pixels.height * scale)
            drawn = CGRect(x: destination.midX - size.width / 2, y: destination.midY - size.height / 2,
                width: size.width, height: size.height)
        }
        return CGRect(x: drawn.minX - window.xFrac / window.wFrac * drawn.width,
            y: drawn.minY - window.yFrac / window.hFrac * drawn.height,
            width: drawn.width / window.wFrac, height: drawn.height / window.hFrac)
    }

    private static func containRect(source: CGSize, canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / max(1, source.width), canvas.height / max(1, source.height))
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
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
    static func tagGeometry(scene: Scene, canvas: CGSize, options: WizardOptions? = nil) -> (areas: [NameTagPlanner.Area], people: [NameTagPlanner.Person]) {
        var cells: [Cell]
        switch scene.framing {
        case .original:
            let drawn = options == nil ? containRect(source: scene.sourceSize, canvas: canvas)
                : CGRect(origin: .zero, size: canvas)
            let source = options?.requestedFraming.focusFrame.map { FocusFrame.rect(FocusFrame.sourceWindow($0, contentBox: scene.contentBox)) }
                ?? WizardPreviewFraming.full
            cells = [Cell(source: source,
                area: CGRect(x: drawn.minX / canvas.width, y: drawn.minY / canvas.height,
                    width: drawn.width / canvas.width, height: drawn.height / canvas.height),
                person: scene.person, face: scene.faceRect)]
        case .cells(let values): cells = values
        case .path(let key):
            cells = [Cell(source: CGRect(x: key.x, y: key.y, width: key.w, height: key.h),
                          area: WizardPreviewFraming.full, person: scene.person, face: scene.faceRect)]
        case .cover(let face):
            // Match the same cover transform used to draw the base frame.
            let source = scene.sourceSize
            let drawn = options?.requestedFraming.fit == .blurredFill
                ? CGRect(origin: .zero, size: canvas)
                : coverRect(source: source, canvas: canvas, face: face)
            let crop = CGRect(x: -drawn.minX / drawn.width, y: (drawn.maxY - canvas.height) / drawn.height,
                              width: canvas.width / drawn.width, height: canvas.height / drawn.height)
            cells = [Cell(source: crop, area: WizardPreviewFraming.full, person: scene.person, face: scene.faceRect)]
        }
        if options?.requestedFraming.fit == .blurredFill {
            cells = cells.map { cell in
                var cell = cell
                let spec = FitSpec(sourceWindow: FreeCropRect(xFrac: cell.source.minX, yFrac: cell.source.minY,
                    wFrac: cell.source.width, hFrac: cell.source.height), sourceSize: scene.sourceSize,
                    destination: CGRect(x: cell.area.minX * canvas.width, y: cell.area.minY * canvas.height,
                        width: cell.area.width * canvas.width, height: cell.area.height * canvas.height), canvasSize: canvas)
                cell.area = CGRect(x: spec.foreground.minX / canvas.width, y: spec.foreground.minY / canvas.height,
                    width: spec.foreground.width / canvas.width, height: spec.foreground.height / canvas.height)
                return cell
            }
        }
        var names: [NameTagPlanner.Person] = []
        let areas = cells.map { cell in
            let rect = CGRect(x: cell.area.minX * canvas.width, y: cell.area.minY * canvas.height,
                              width: cell.area.width * canvas.width, height: cell.area.height * canvas.height)
            // A planned cell whose feed maps to nobody (saturated portraits,
            // no tile owner) still shows the scene's resolved person, the way
            // the single-feed path does, instead of the sample name.
            let person = cell.person ?? (cells.count == 1 || cell.isTalking ? scene.person : nil)
            let key = person?.key ?? "preview"
            // The person's own corner wins over the run's, as in the export.
            names.append(.init(key: key, name: person?.tagName ?? "Alex Morgan", role: person?.descriptor ?? "Guest",
                               position: person?.tagPosition))
            let source: CGRect
            if case .original = scene.framing, options?.requestedFraming.focusFrame != nil {
                source = cell.source
            } else { source = visibleSource(cell.source, frame: scene.sourceSize, canvas: rect.size) }
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
