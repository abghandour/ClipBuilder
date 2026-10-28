import Foundation

/// Shared extraction for every wizard cut. Transient burn-in and mute settings
/// never alter the editable Builder document; source clocks stay in MultitrackRenderer.
nonisolated enum ExpressPodcastRenderer {
    @concurrent
    static func extract(document: TimelineDocument, scenes: [SceneRecord], profile: BrandProfile,
                        database: Database, render: RenderEngine, camera: String,
                        overlays: [RenderEngine.ClipOverlay], look: EffectSpec?, mute: Bool,
                        clipNumber: Int, duration: Double, output: URL,
                        contentSource: URL? = nil, contentBox: RenderEngine.ContentBox? = nil,
                        cache: RenderSegmentCache = .shared,
                        emit: @escaping @Sendable (String) -> Void) async throws {
        var extraction = MultitrackRenderer.windowed(document, from: 0, to: duration)
        for index in extraction.videoTrack.indices { extraction.videoTrack[index].captions = "none" }
        extraction.textOverlays.removeAll { $0.design == "nameTag" }
        let contentWindows: [String: FreeCropRect]
        if let source = contentSource, let box = contentBox {
            contentWindows = [source.path: FreeCropRect(xFrac: box.x, yFrac: box.y, wFrac: box.w, hFrac: box.h)]
        } else {
            contentWindows = [:]
        }
        let legacy = ExpressRenderTesting.twoPassExtract
        try await FFmpeg.$renderLog.withValue(emit) {
            try await RenderContext.$settings.withValue(document.renderSettings) {
                let framed = try await MultitrackRenderer(render: render, segmentCache: cache).render(
                    document: extraction, scenes: scenes, profile: profile, database: database,
                    centerStageCamera: camera, preview: true, contentWindows: contentWindows, burnIns: legacy ? [] : overlays,
                    muteSource: !legacy && mute, compositeEffect: legacy ? nil : look, emit: emit)
                defer { try? FileManager.default.removeItem(at: framed.url) }
                if legacy {
                    emit("Clip \(clipNumber): legacy extract decode/encode for look and overlays")
                    try await render.extractClip(source: framed.url, start: 0, duration: duration,
                        overlays: overlays, effect: look, mute: mute, intermediateSource: true, output: output)
                } else {
                    try FileManager.default.copyItemReplacing(at: framed.url, to: output)
                    emit("Clip \(clipNumber): extraction complete; look and \(overlays.count) overlays applied")
                }
            }
        }
    }
}
