import Foundation

/// A static watermark can ride the clip encode. Keep a final
/// pass when later layers could cover it or a transition could move it.
nonisolated enum ExpressBatchWatermark {
    static func canFold(options: WizardOptions, plan: WizardPlan, hasPodcastDocument: Bool,
                        batchID: String?) -> Bool {
        guard batchID != nil, options.includeWatermark, hasPodcastDocument,
              plan.clips.count == 1, !options.includeOutro,
              options.fixedOverlayTemplate?.isEmpty != false,
              !(options.useBRoll && !options.brollInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else { return false }
        let framing = options.requestedFraming.subject == .auto ? plan.framing : options.requestedFraming.subject
        return framing != .vipFocus
    }

    /// Use the same expansion, placement and image-before-text order as the
    /// document renderer. Watermark styling removes animation and makes all
    /// items unbounded, so their rasters are independent of each reel's length.
    static func rasterize(_ block: OverlayBlockItem, settings: RenderSettings,
                          scratch: URL, textStyles: [NamedTextStyle] = [], log: @Sendable (String) -> Void) -> [RenderEngine.ClipOverlay] {
        var document = TimelineDocument()
        document.overlayBlocks = [block]
        document = document.expandingOverlayBlocks()
        // Dynamic stats require the final document's source binding and clock,
        // including templates whose placeholder text is empty.
        guard document.textOverlays.allSatisfy({ $0.stat == nil }) else { return [] }
        let safeArea = PlatformSafeArea.resolve(settings)
        let images = ImageOverlayRenderer(videoWidth: settings.width, videoHeight: settings.height, safeArea: safeArea)
        let texts = TextOverlayRenderer(videoWidth: settings.width, videoHeight: settings.height, safeArea: safeArea, textStyles: textStyles)
        var result: [RenderEngine.ClipOverlay] = []
        for item in document.imageOverlays {
            guard let png = try? images.render(item.keptClear(of: safeArea, frameAspectRatio: settings.aspectRatio), to: scratch) else {
                log("Watermark: \(item.displayName) skipped: unreadable image")
                continue
            }
            result.append(.init(png: png, x: 0, y: 0))
        }
        for item in document.textOverlays where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let png = try? texts.render(item.keptClear(of: safeArea), to: scratch) else {
                log("Watermark: \(item.text) skipped: unreadable text")
                continue
            }
            result.append(.init(png: png, x: 0, y: 0))
        }
        return result
    }
}
