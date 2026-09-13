import Foundation
import Synchronization

/// Multi-track builder render pipeline — the Swift port of clip_builder.py's
/// _generate_multitrack() + video.py's layered compositor. Slices the
/// timeline at clip boundaries into constant-membership segments, composites
/// each 1080x1920 segment with FFmpeg overlay chains (wide clips stack in
/// top/center/bottom slots), burns per-clip captions, concatenates with
/// transitions, then applies the music track and text overlays.
actor MultitrackRenderer {

    struct RenderResult: Sendable {
        var url: URL
        var duration: Double
    }

    /// One clip with every per-clip/track setting resolved to its effective
    /// value (clip override beats layer default; layer mute forces mute).
    nonisolated struct ResolvedClip: Codable, Sendable {
        var sourcePath: String
        var videoID: Int64?
        var sourceStart: Double
        var startTime: Double
        var duration: Double
        var track: Int
        var wide: Bool
        var bumper: Bool = false
        var missingBumper: Bool = false
        /// Ordinary footage or a cutaway (B-roll) drawn over its track.
        var role: ClipRole = .main
        /// Cutaways only: cover the whole canvas instead of the track's area.
        var coverAllAreas: Bool = false
        /// Scale to cover the whole frame (cover-all cutaways) instead of
        /// an area mask or a slot band.
        var fillCanvas: Bool = false
        /// Timeline extent before crop splitting, and the document's
        /// persisted origin identity. Together with the layer they are the
        /// one draw-order key, unchanged by any split.
        var originalStart: Double = 0
        var originalEnd: Double = 0
        var originKey: String = ""
        /// Cutaway dissolves in seconds, measured from `originalStart` and
        /// `originalEnd` so a split never restarts a fade.
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        /// Position in `document.videoTrack` — the last, total tie-break of
        /// the draw order (array order survives save and load).
        var documentIndex: Int = 0
        var volume: Int = 5
        var centerStage: Bool = false
        var muted: Bool
        var transIn: String?
        var transOut: String?
        var effectivePosition: String
        var effectiveCropXFrac: Double?
        var freeCrops: [FreeCrop]?
        /// Screen Crop reference ("Layout/Area") masking this clip.
        var screenCrop: String?
        /// Hand-placed source window for the area (nil = tracking camera).
        var areaWindow: FreeCropRect?
        var captionsPosition: String?     // nil = captions off for this clip
        /// Playback speed (1 = normal): `duration` is screen time; source
        /// consumption maps through this factor.
        var speed: Double = 1
        /// The scene's stored Center Stage camera path sliced to this clip's
        /// source range (t=0 at sourceStart, source seconds). When present,
        /// the reframe prepass replays it instead of re-tracking — the same
        /// path the curated preview and workbench show, so WYSIWYG holds.
        var cameraPath: [CameraPathKeyframe]?
        var staticAreaFilter: String?
        var effectiveEffect: EffectSpec? = nil
        /// Original input and framing parameters, before temporary paths replace them.
        var framingIdentity: String?
        var originalSourcePath: String?
        var sourceFingerprint: String?
        var cacheable = true
    }

    /// One alpha dissolve inside a segment, in segment-local seconds.
    nonisolated struct Fade: Sendable, Equatable {
        var start: Double
        var duration: Double
    }

    nonisolated struct Segment: Sendable {
        var start: Double
        var end: Double
        var clips: [ResolvedClip]
        var duration: Double { end - start }
    }

    /// One clip's contribution to a single composited segment.
    nonisolated struct Placement: Sendable {
        var sourcePath: String
        var sourceStart: Double
        var sourceDur: Double
        var isWide: Bool
        var bumper: Bool = false
        var volume: Int = 5
        var layer: Int
        var position: String
        var muted: Bool
        /// Ordinary footage or a cutaway — a cutaway's own sound takes the
        /// volume gain, like a bumper's.
        var role: ClipRole = .main
        /// Scale to cover the whole frame, centred.
        var fillCanvas: Bool = false
        /// Order key beside `layer`: the clip's start before crop splitting
        /// and its persisted identity.
        var originalStart: Double = 0
        var originKey: String = ""
        /// Alpha dissolves for this segment, in segment-local seconds. A
        /// start before 0 means the fade began in an earlier segment.
        var fadeIn: Fade?
        var fadeOut: Fade?
        /// Position in `document.videoTrack`: the final tie-break.
        var documentIndex: Int = 0
        /// Index of the clip this placement came from in the segment.
        var clipIndex: Int = 0
        /// Timeline start of the clip this placement came from. Clips that
        /// overlap on one track stack by start time — the later one on top.
        var startTime: Double
        var cropXFrac: Double?
        var freeCrops: [FreeCrop]?
        var screenCrop: String?
        var speed: Double = 1
        var staticAreaFilter: String?
        var effectiveEffect: EffectSpec? = nil
    }

    private static var width: Int { RenderEngine.outputWidth }
    private static var height: Int { RenderEngine.outputHeight }
    private static var slotHeight: Int { max(2, height / 3) }
    private static var slotY: [String: Int] {
        ["top": 0, "center": slotHeight, "bottom": slotHeight * 2]
    }

    private let segmentCache: RenderSegmentCache
    private let render: RenderEngine
    private let centerStageService = CenterStageService()

    init(render: RenderEngine, segmentCache: RenderSegmentCache = .shared) {
        self.segmentCache = segmentCache
        self.render = render
    }

    // MARK: - Entry point

    /// `preview: true` runs the IDENTICAL pipeline (same framing, crops,
    /// transitions, music, overlays, encode settings — pixel-for-pixel what
    /// a real render produces) but writes to a temporary file and records
    /// nothing in the Library. The curated wizard's Exact Preview uses it.
    func render(document: TimelineDocument, scenes: [SceneRecord],
                profile: BrandProfile, database: Database,
                centerStageCamera: String = "balanced",
                projectID: Int64? = nil,
                outputName: String? = nil,
                preview: Bool = false,
                emit: @escaping @Sendable (String) -> Void) async throws -> RenderResult {
        try await RenderContext.$settings.withValue(document.renderSettings) {
            try await renderConfigured(document: document, scenes: scenes, profile: profile,
                                       database: database, centerStageCamera: centerStageCamera,
                                       projectID: projectID, outputName: outputName,
                                       preview: preview, emit: emit)
        }
    }

    /// The base name of a Builder render: project, timeline (unless it is
    /// still the default name), and today's date as mm-dd-yy. The renderer
    /// appends " 2", " 3", … when the name is already taken that day.
    nonisolated static func outputBaseName(project: String?, timeline: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yy"
        var parts: [String] = []
        if let project = project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            parts.append(project)
        }
        if let timeline = timeline?.trimmingCharacters(in: .whitespacesAndNewlines), !timeline.isEmpty,
           !Self.isDefaultTimelineName(timeline) {
            parts.append(timeline)
        }
        parts.append(formatter.string(from: date))
        let joined = parts.joined(separator: " - ")
        // Keep the name filesystem-safe: no path separators or colons, no
        // leading dot, and a sane length.
        let unsafe = CharacterSet(charactersIn: "/\\:\u{0}").union(.newlines).union(.controlCharacters)
        let cleaned = joined.unicodeScalars.map { unsafe.contains($0) ? "-" : Character($0) }
        var name = String(cleaned).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? formatter.string(from: date) : String(name.prefix(120))
    }

    /// "Untitled Timeline", its duplicates ("Untitled Timeline Copy", "… Copy 2")
    /// and an empty name all count as the default and are left out of the file name.
    nonisolated static func isDefaultTimelineName(_ name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard lowered.hasPrefix("untitled timeline") else { return lowered.isEmpty }
        let rest = lowered.dropFirst("untitled timeline".count).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return true }
        // "copy", "copy 2", "2"
        let stripped = rest.hasPrefix("copy") ? rest.dropFirst(4).trimmingCharacters(in: .whitespaces) : rest
        return stripped.isEmpty || Int(stripped) != nil
    }

    private func renderConfigured(document: TimelineDocument, scenes: [SceneRecord],
                                  profile: BrandProfile, database: Database,
                                  centerStageCamera: String, projectID: Int64?,
                                  outputName: String? = nil, preview: Bool,
                                  emit: @escaping @Sendable (String) -> Void) async throws -> RenderResult {
        // Overlay blocks render as their flattened text/image items.
        let document = Self.removingMissingEdgeBumpers(document.expandingOverlayBlocks(), emit: emit)
        var bumperSpans = document.videoTrack.filter(\.bumper).map { $0.startTime..<($0.startTime + $0.duration) }
        var clips = Self.resolveClips(document: document, scenes: scenes)
        for index in clips.indices {
            if clips[index].bumper && !FileManager.default.fileExists(atPath: clips[index].sourcePath) {
                clips[index].missingBumper = true
                continue
            }
            clips[index].originalSourcePath = clips[index].sourcePath
            clips[index].sourceFingerprint = try SourceIdentityCache.shared.fingerprint(
                of: URL(fileURLWithPath: clips[index].sourcePath))
        }
        let framingScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb_areas_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: framingScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: framingScratch) }
        // Group only source/framing inputs, not timeline placement. A repeated
        // clip shares its intermediate. Permits remain in leaf media work.
        for areaPass in [false, true] {
            var groups: [String: [Int]] = [:]
            var areas: [String: ScreenCropArea] = [:]
            for index in clips.indices {
                let clip = clips[index]
                let area = ScreenCropStore.area(reference: clip.screenCrop)
                guard (areaPass ? (clip.freeCrops?.isEmpty != false && area != nil) : clip.centerStage) else { continue }
                if areaPass, let area, let window = clip.areaWindow {
                    clips[index].staticAreaFilter = AreaFramer.staticFilter(area: area, window: window)
                    clips[index].wide = false
                    clips[index].effectiveCropXFrac = nil
                    emit("Clip \(index + 1): static area fused; intermediates=0")
                    continue
                }
                let key = try Self.prepassKey(clip, area: areaPass ? area : nil, tuning: centerStageCamera)
                groups[key, default: []].append(index)
                if areaPass { areas[key] = area }
            }
            let jobs = groups.sorted { $0.key < $1.key }.map {
                (key: $0.key, indices: $0.value, clip: clips[$0.value[0]], area: areas[$0.key])
            }
            let results = try await BoundedConcurrency.map(jobs, limit: FFmpeg.jobLimit) { _, job -> PrepassArtifact? in
                try Task.checkCancellation()
                let clip = job.clip
                let source = URL(fileURLWithPath: clip.sourcePath)
                let fellBack = Mutex(false)
                do {
                    let framed: URL
                    if let area = job.area {
                        framed = try await AreaFramer.frame(source: source, start: clip.sourceStart,
                            duration: clip.duration * clip.speed, area: area,
                            tuning: .named(centerStageCamera), centerStage: self.centerStageService,
                            scratch: framingScratch, onFallback: { fellBack.withLock { $0 = true } }, log: emit)
                    } else {
                        // CenterStageService's synchronous tracking loop still
                        // serializes on its actor; only export/encode overlaps.
                        if let path = clip.cameraPath, CenterStageService.pathMatchesCanvas(path) {
                            framed = try await self.centerStageService.reframeClip(source: source,
                                start: clip.sourceStart, duration: clip.duration * clip.speed, path: path, log: emit)
                        } else {
                            framed = try await self.centerStageService.reframeClip(source: source,
                                start: clip.sourceStart, duration: clip.duration * clip.speed,
                                tuning: .named(centerStageCamera), log: emit)
                        }
                    }
                    let owned = framingScratch.appendingPathComponent(UUID().uuidString + ".mp4")
                    defer { try? FileManager.default.removeItem(at: framed) }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: framed, to: owned)
                    let intermediates = job.area == nil || fellBack.withLock({ $0 }) ? 1 : 2
                    emit("Framing prepass: intermediates=\(intermediates); uses=\(job.indices.count)")
                    return PrepassArtifact(url: owned, cacheable: !fellBack.withLock { $0 })
                } catch {
                    try Task.checkCancellation()
                    emit("Framing failed (\(error)) — using the static crop")
                    return nil
                }
            }
            for (job, result) in zip(jobs, results) {
                guard let result else {
                    for index in job.indices { clips[index].cacheable = false }
                    continue
                }
                for index in job.indices {
                    clips[index].framingIdentity = (clips[index].framingIdentity ?? "") + job.key
                    clips[index].sourcePath = result.url.path
                    clips[index].cacheable = clips[index].cacheable && result.cacheable
                    clips[index].sourceStart = 0
                    clips[index].wide = false
                    if areaPass {
                        clips[index].centerStage = false
                        clips[index].cameraPath = nil
                        clips[index].effectiveCropXFrac = nil
                    }
                }
            }
        }
        guard !clips.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No valid clips in the video track"])
        }
        guard FFmpeg.isAvailable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg not found — install it (e.g. brew install ffmpeg)"])
        }

        let totalDuration = clips.map { $0.startTime + $0.duration }.max() ?? 0
        let outputURL = preview
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("ExactPreview-\(UUID().uuidString).mp4")
            : try Self.outputFile(profile: profile, totalDuration: totalDuration, baseName: outputName)
        let scratch = try await render.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Slice the timeline into constant-membership segments + black gaps.
        let segments = Self.buildLayeredSegments(clips)
        var fullSegments: [Segment] = []
        var cursor = 0.0
        for segment in segments {
            if segment.start > cursor + 0.05 {
                fullSegments.append(Segment(start: cursor, end: segment.start, clips: []))
            }
            fullSegments.append(segment)
            cursor = segment.end
        }
        emit("Timeline: \(clips.count) clip(s) → \(fullSegments.count) segment(s), \(totalDuration.timecode) total")

        // Assemble clip list + transition list in the same order/rules as the
        // Python generator (pad/truncate at the end for exact parity).
        var clipPaths: [URL] = []
        var transitions: [String?] = []

        let captionRenderer = CaptionRenderer(videoWidth: Self.width, videoHeight: Self.height,
                                              style: profile.captions)
        let captionCache = CaptionPNGCache(renderer: captionRenderer, directory: scratch)
        let segmentCount = fullSegments.count

        // Text and image overlays — pre-rendered to full-frame PNGs and
        // composited in one pass (images first so text stays on top).
        func clampWindow(start: Double, end: Double) -> (Double, Double) {
            (start, min(end, totalDuration))
        }
        let textRenderer = TextOverlayRenderer(videoWidth: Self.width, videoHeight: Self.height)
        let imageRenderer = ImageOverlayRenderer(videoWidth: Self.width, videoHeight: Self.height)
        var overlays: [TimedOverlayPNG] = []
        for item in document.imageOverlays {
            let (start, end) = clampWindow(start: item.startTime, end: item.endTime)
            guard end > start, let png = try? imageRenderer.render(item, to: scratch) else { continue }
            let identity = try RenderSegmentCache.key(item) + SourceIdentityCache.shared.fingerprint(of: item.url)
            overlays.append(TimedOverlayPNG(png: png, startTime: start, endTime: end,
                transIn: item.transIn, transOut: item.transOut, identity: identity))
        }
        for item in document.textOverlays
        where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (start, end) = clampWindow(start: item.startTime, end: item.endTime)
            guard end > start, let png = try? textRenderer.render(item, to: scratch) else { continue }
            overlays.append(TimedOverlayPNG(png: png, startTime: start, endTime: end,
                transIn: item.transIn, transOut: item.transOut, identity: try RenderSegmentCache.key(item)))
        }
        // Include font-file identity as well as rendered pixels and style.
        // System-font output is represented by the raster PNG digest.
        let fontFingerprints = try? AssetStore.allFiles(of: .fonts).map {
            try SourceIdentityCache.shared.fingerprint(of: $0.url)
        }.sorted()
        let overlayPlan = Self.partitionOverlays(overlays, segments: fullSegments)
        let fusedOverlayCount = overlayPlan.bySegment.values.reduce(0) { $0 + $1.count }
        emit("Overlay plan: segment=\(fusedOverlayCount); timeline=\(overlayPlan.remaining.count)")

        // Render every segment concurrently (bounded) — each is one
        // independent ffmpeg job with captions burned in the same pass.
        try Task.checkCancellation()
        let artifacts = try await BoundedConcurrency.map(fullSegments,
                                                        limit: FFmpeg.jobLimit) { index, segment in
            try await self.renderSegment(segment, index: index, of: segmentCount,
                                         scratch: scratch, database: database,
                                         captionLanguage: profile.captionLanguages.first,
                                         captionRenderer: captionRenderer,
                                         captionCache: captionCache, captionStyle: profile.captions,
                                         fontFingerprints: fontFingerprints,
                                         overlays: overlayPlan.bySegment[index] ?? [], emit: emit)
        }
        for (index, segment) in fullSegments.enumerated() {
            clipPaths.append(artifacts[index].url)
            guard clipPaths.count > 1 else { continue }
            // Cutaways never take part in a join: a boundary a cutaway
            // introduced must not replay the main clip's transition, so
            // the incoming and outgoing clips are the lowest-layer main
            // clips and their ORIGINAL extent decides.
            let incoming = Self.joinClip(in: segment.clips)
            let outgoing = Self.joinClip(in: fullSegments[index - 1].clips)
            let entry = incoming.flatMap { abs($0.originalStart - segment.start) < 0.001 ? $0.transIn : nil }
            let exit = outgoing.flatMap { abs($0.originalEnd - segment.start) < 0.001 ? $0.transOut : nil }
            // A join takes the incoming clip's transition in, else the
            // outgoing clip's transition out — both gated on the clip's
            // original extent, so a cutaway's boundary triggers neither.
            transitions.append(entry ?? exit)
        }

        guard !clipPaths.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No segments could be rendered"])
        }
        while transitions.count < clipPaths.count - 1 { transitions.append(nil) }
        transitions = Array(transitions.prefix(max(0, clipPaths.count - 1)))

        try Task.checkCancellation()
        emit("Assembling \(clipPaths.count) segment(s)…")
        var complete = true
        var assembled = scratch.appendingPathComponent("assembled.mp4")
        if clipPaths.count == 1 {
            assembled = clipPaths[0]
        } else if !bumperSpans.isEmpty {
            bumperSpans = try await concatenateWithBumpers(paths: clipPaths, segments: fullSegments,
                transitions: transitions, scratch: scratch, output: assembled)
        } else {
            try await render.concatenate(clips: clipPaths, transitions: transitions, output: assembled)
        }

        let videoDuration = await FFmpeg.duration(of: assembled)

        // Music track (blocks with silence-filled gaps + original-audio ducking).
        if !document.soundTrack.isEmpty {
            let musicLookup = Dictionary(uniqueKeysWithValues:
                WizardEngine.availableMusic().map { ($0.name, $0.url) })
            var blocks: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)] = []
            for item in document.soundTrack.sorted(by: { $0.startTime < $1.startTime }) {
                guard let url = musicLookup[item.name], item.duration > 0 else { continue }
                blocks.append((item.startTime, item.duration, url, item.volume, 0))
            }
            // A bumper owns the sound as well as the picture: cut every
            // music block around the measured bumper spans. Each remaining
            // piece keeps its offset into the song so it continues, not restarts.
            blocks = blocks.flatMap { block in
                TimelineDocument.subtracting(bumperSpans, from: block.start..<(block.start + block.duration))
                    .map { (start: $0.lowerBound, duration: $0.upperBound - $0.lowerBound,
                            music: block.music, volume: block.volume, offset: $0.lowerBound - block.start) }
            }
            if !blocks.isEmpty {
                var filled: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)] = []
                var soundCursor = 0.0
                for block in blocks {
                    if block.start > soundCursor + 0.05 {
                        filled.append((soundCursor, block.start - soundCursor, nil, 0, 0))
                    }
                    filled.append(block)
                    soundCursor = block.start + block.duration
                }
                if soundCursor < videoDuration {
                    filled.append((soundCursor, videoDuration - soundCursor, nil, 0, 0))
                }
                emit("Building music track (\(blocks.count) block(s))…")
                let musicTrack = scratch.appendingPathComponent("music_track.m4a")
                do {
                    try await buildMusicTrack(segments: filled, totalDuration: videoDuration, output: musicTrack)
                    let withMusic = scratch.appendingPathComponent("with_music.mp4")
                    try await overlayMusicTrack(video: assembled, musicTrack: musicTrack,
                                                segments: filled, output: withMusic)
                    assembled = withMusic
                } catch {
                    try Task.checkCancellation()
                    complete = false
                    emit("Music overlay failed, continuing without music (\(error))")
                }
            }
        }

        let remainingOverlays = overlayPlan.remaining.compactMap { overlay -> TimedOverlayPNG? in
            var overlay = overlay
            overlay.endTime = min(overlay.endTime, videoDuration)
            return overlay.endTime > overlay.startTime ? overlay : nil
        }
        if !remainingOverlays.isEmpty {
            emit("Burning \(remainingOverlays.count) overlay(s)…")
            let withText = scratch.appendingPathComponent("with_overlays.mp4")
            do {
                try await addOverlays(video: assembled, overlays: remainingOverlays, excluding: bumperSpans, output: withText)
                assembled = withText
            } catch {
                try Task.checkCancellation()
                complete = false
                emit("Overlay burn failed, continuing without overlays (\(error))")
            }
        }

        try FileManager.default.copyItemReplacing(at: assembled, to: outputURL)
        let finalDuration = await FFmpeg.duration(of: outputURL)

        try Task.checkCancellation()
        if preview {
            if complete && finalDuration > 0 { await publishSegments(artifacts, clips: clips) }
            emit("Exact preview ready (\(finalDuration.timecode))")
            return RenderResult(url: outputURL, duration: finalDuration)
        }

        // Persist the COMPLETE editable document so "Open in Builder" (in
        // either app) restores every clip flag and layer setting.
        let encoder = JSONEncoder()
        let timelineJSON = (try? encoder.encode(document))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let recordID = try await database.insertGeneratedVideo(path: outputURL.path,
                                                               duration: (finalDuration * 10).rounded() / 10,
                                                               timelineJSON: timelineJSON,
                                                               wizardProvider: nil, wizardModel: nil,
                                                               projectID: projectID,
                                                               settings: WizardRunSettings(options: WizardOptions(renderSettings: document.renderSettings),
                                                                   sourceProfile: profile.profileName, sourceVideoPaths: Array(Set(scenes.map(\.videoPath))).sorted(),
                                                                   sourceSceneIDs: scenes.map(\.id), builderDocumentJSON: timelineJSON))
        try await database.saveGeneratedTraits(videoID: recordID,
                                               traits: .derive(document: document, scenes: scenes))
        await ReelTraitRecording.record(url: outputURL, id: recordID, database: database,
            document: document, scenes: scenes, log: emit)
        try Task.checkCancellation()
        if complete && finalDuration > 0 { await publishSegments(artifacts, clips: clips) }
        emit("Saved \(outputURL.lastPathComponent)")
        return RenderResult(url: outputURL, duration: finalDuration)
    }

    /// Join ordinary runs normally, then join each bumper boundary while
    /// measuring the resulting clock. This accounts for recipe bridges and
    /// hard-cut fallbacks as well as successful crossfades; final overlays
    /// must never use an estimated, pre-transition bumper position.
    private func concatenateWithBumpers(paths: [URL], segments: [Segment], transitions: [String?],
                                        scratch: URL, output: URL) async throws -> [Range<Double>] {
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1..<segments.count {
            let previous = segments[index - 1].clips.first
            let current = segments[index].clips.first
            let sameBumper = previous?.bumper == true && current?.bumper == true
                && previous?.sourcePath == current?.sourcePath && previous?.startTime == current?.startTime
            if !sameBumper && (previous?.bumper == true || current?.bumper == true) {
                runs.append(start..<index)
                start = index
            }
        }
        runs.append(start..<segments.count)
        var assembled: URL?
        var elapsed = 0.0
        var spans: [Range<Double>] = []
        for (index, run) in runs.enumerated() {
            let part = scratch.appendingPathComponent("bumper_run_\(index).mp4")
            try await render.concatenate(clips: Array(paths[run]),
                transitions: run.count > 1 ? Array(transitions[run.lowerBound..<(run.upperBound - 1)]) : [], output: part)
            let duration = await FFmpeg.duration(of: part)
            let isBumper = segments[run.lowerBound].clips.first?.bumper == true
            if let previous = assembled {
                let joined = scratch.appendingPathComponent("bumper_join_\(index).mp4")
                let outgoingDuration = segments[run.lowerBound - 1].duration
                let incomingDuration = segments[run.lowerBound].duration
                var transition = transitions[safe: run.lowerBound - 1] ?? nil
                if let name = transition, TransitionRecipes.isRecipe(name) {
                    let (tail, head) = TransitionRecipes.pieces(for: name)
                    if outgoingDuration - tail < 0.4 || incomingDuration - head < 0.4 { transition = nil }
                }
                // Grouping must not let a short adjacent clip borrow the
                // whole preceding run's duration for a longer crossfade.
                try await render.concatenate(clips: [previous, part], transitions: [transition], output: joined,
                    maximumOverlap: min(outgoingDuration, incomingDuration) * 0.4)
                let measured = await FFmpeg.duration(of: joined)
                let overlap = max(0, elapsed + duration - measured)
                let pieces = transition.map { TransitionRecipes.pieces(for: $0) } ?? (0.0, 0.0)
                if isBumper { spans.append(max(0, elapsed - max(overlap, pieces.0))..<measured) }
                if segments[run.lowerBound - 1].clips.first?.bumper == true, let last = spans.indices.last,
                   !isBumper {
                    spans[last] = spans[last].lowerBound..<min(measured, elapsed + max(0, pieces.1 - overlap))
                }
                elapsed = measured
                assembled = joined
            } else {
                assembled = part
                elapsed = duration
                if isBumper { spans.append(0..<duration) }
            }
        }
        if let assembled { try FileManager.default.copyItemReplacing(at: assembled, to: output) }
        return spans
    }

    /// Missing interior bumpers remain exclusive black spans. Only an
    /// uncovered leading/trailing edge is removed, keeping interior timing.
    nonisolated static func removingMissingEdgeBumpers(_ input: TimelineDocument,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        emit: (String) -> Void = { _ in }) -> TimelineDocument {
        var document = input
        let missing = input.videoTrack.filter { $0.bumper && !exists($0.videoFile ?? "") }
        var logged: Set<String> = []
        for clip in missing where logged.insert(clip.videoFile ?? clip.uid.uuidString).inserted {
            let name = clip.bumperName ?? URL(fileURLWithPath: clip.videoFile ?? "Bumper").deletingPathExtension().lastPathComponent
            emit("Bumper '\(name)' is missing; skipped")
        }
        guard !missing.isEmpty else { return input }
        let missingIDs = Set(missing.map(\.uid))
        let live = input.videoTrack.filter { !missingIDs.contains($0.uid) }
        let end = input.videoTrack.map { $0.startTime + $0.duration }.max() ?? 0
        let firstLive = live.map(\.startTime).min() ?? end
        let lastLive = live.map { $0.startTime + $0.duration }.max() ?? 0
        var lower = 0.0
        for clip in missing.sorted(by: { $0.startTime < $1.startTime }) {
            if clip.startTime <= lower + 0.001 {
                lower = min(firstLive, max(lower, clip.startTime + clip.duration))
            }
        }
        var upper = end
        for clip in missing.sorted(by: { $0.startTime > $1.startTime }) {
            if clip.startTime + clip.duration >= upper - 0.001 {
                upper = max(lastLive, min(upper, clip.startTime))
            }
        }
        upper = max(lower, upper)
        document.videoTrack = input.videoTrack.compactMap { item in
            let start = max(lower, item.startTime)
            let stop = min(upper, item.startTime + item.duration)
            guard stop > start else { return nil }
            var clip = item
            clip.sourceStart = (item.sourceStart ?? 0) + (start - item.startTime) * item.effectiveSpeed
            clip.startTime = start - lower
            clip.duration = stop - start
            return clip
        }
        document.soundTrack = input.soundTrack.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.startTime + item.duration)
            guard stop > start else { return nil }
            var item = item
            item.startTime = start - lower
            item.duration = stop - start
            return item
        }
        document.textOverlays = input.textOverlays.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            item.startTime = start - lower
            item.endTime = stop - lower
            return item
        }
        document.imageOverlays = input.imageOverlays.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            item.startTime = start - lower
            item.endTime = stop - lower
            return item
        }
        document.overlayBlocks = input.overlayBlocks.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            var item = item
            item.startTime = start - lower
            item.duration = stop - start
            return item
        }
        document.cropBlocks = input.cropBlocks.compactMap { item in
            let start = max(lower, item.startTime), stop = min(upper, item.endTime)
            guard stop > start else { return nil }
            return CropBlockItem(layout: item.layout, startTime: start - lower, duration: stop - start)
        }
        return document
    }

    // MARK: - Clip resolution

    /// Port of the resolve/effective-settings pass in _generate_multitrack.
    nonisolated static func resolveClips(document: TimelineDocument,
                                         scenes: [SceneRecord]) -> [ResolvedClip] {
        let scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let settings = document.trackSettings
        var resolved: [ResolvedClip] = []

        for (documentIndex, original) in document.videoTrack.enumerated() {
            var clip = original
            clip.enforceCutawayRules()
            var sourcePath: String?
            var videoID: Int64?
            var sourceStart = 0.0
            var duration = 0.0
            var cameraPath: [CameraPathKeyframe]?
            if let sceneID = clip.sceneID, let scene = scenesByID[sceneID] {
                sourcePath = scene.videoPath
                videoID = scene.videoID
                sourceStart = clip.sourceStart ?? scene.startTime
                duration = clip.duration > 0 ? clip.duration : (scene.duration * 10).rounded() / 10
                // Stored camera path (scene-relative source time) → this
                // clip's range, so the render replays exactly what the
                // preview showed instead of re-tracking.
                if clip.centerStage, clip.wide, let path = scene.centerStagePath,
                   path.keyframes.count >= 2 {
                    let sliced = CenterStageService.slice(
                        path.keyframes, from: sourceStart - scene.startTime,
                        duration: duration * clip.effectiveSpeed)
                    if sliced.count >= 2 { cameraPath = sliced }
                }
            } else if let file = clip.videoFile, let start = clip.sourceStart {
                sourcePath = file
                sourceStart = start
                duration = clip.duration > 0 ? clip.duration
                    : max(0, (clip.sourceEnd ?? start) - start)
            }
            guard let sourcePath, duration > 0 else { continue }

            let track = min(max(0, clip.track), TimelineDocument.maxTracks - 1)
            let trackSettings = settings[safe: track] ?? TrackSettings()
            let effectivePosition = clip.position ?? trackSettings.defaultPosition
            let effectiveCrop = clip.bumper ? nil : clip.cropXFrac ?? trackSettings.defaultCropXFrac
            let effect = clip.effect ?? trackSettings.effect
            let effectiveEffect = clip.bumper || effect?.preset == "none" ? nil : effect
            let muted = clip.muted || trackSettings.muted
            let captionsResolved = clip.captions == "inherit" ? trackSettings.captions : clip.captions

            resolved.append(ResolvedClip(sourcePath: sourcePath,
                                         videoID: videoID,
                                         sourceStart: sourceStart,
                                         startTime: clip.startTime,
                                         duration: duration,
                                         track: track,
                                         wide: clip.wide,
                                         bumper: clip.bumper,
                                         role: clip.role,
                                         coverAllAreas: clip.isCutaway && clip.coverAllAreas,
                                         originalStart: clip.startTime,
                                         originalEnd: clip.startTime + duration,
                                         originKey: clip.originKey,
                                         fadeIn: clip.isCutaway ? clip.fadeIn : 0,
                                         fadeOut: clip.isCutaway ? clip.fadeOut : 0,
                                         documentIndex: documentIndex,
                                         volume: clip.volume,
                                         centerStage: clip.centerStage && clip.wide,
                                         muted: muted,
                                         transIn: clip.transIn,
                                         transOut: clip.transOut,
                                         effectivePosition: effectivePosition,
                                         effectiveCropXFrac: clip.wide ? effectiveCrop : nil,
                                         freeCrops: clip.freeCrops,
                                         screenCrop: clip.screenCrop,
                                         areaWindow: clip.areaWindow,
                                         captionsPosition: captionsResolved == "none" ? nil : captionsResolved,
                                         speed: clip.effectiveSpeed,
                                         cameraPath: cameraPath, effectiveEffect: effectiveEffect))
        }
        return Self.applyCropBlocks(resolved, document: document).sorted {
            ($0.track, $0.startTime) < ($1.track, $1.startTime)
        }
    }

    /// The cropping row decides each clip's area: a clip is cut at every
    /// crop-block boundary it crosses, each piece masked to its track's area
    /// under that block (none under Full Screen), and pieces on a track the
    /// block gives no area to are dropped. Documents without a row keep the
    /// per-clip `screenCrop` they carry.
    nonisolated static func applyCropBlocks(_ clips: [ResolvedClip],
                                            document: TimelineDocument) -> [ResolvedClip] {
        let blocks = document.cropBlocks.sorted { $0.startTime < $1.startTime }
        guard !blocks.isEmpty else {
            // Legacy document without a Screen row: a cover-all cutaway
            // still fills the canvas instead of taking a legacy crop.
            return clips.map { clip in
                guard clip.coverAllAreas else { return clip }
                var piece = clip
                piece.screenCrop = nil
                piece.fillCanvas = true
                return piece
            }
        }
        var pieces: [ResolvedClip] = []
        for clip in clips {
            if clip.bumper { pieces.append(clip); continue }
            let clipEnd = clip.startTime + clip.duration
            var cursor = clip.startTime
            var covering = blocks.filter { $0.startTime < clipEnd - 0.001 && cursor < $0.endTime - 0.001 }
            // The row always tiles to the content end; anything past the
            // last block behaves like that block.
            if covering.isEmpty, let last = blocks.last { covering = [last] }
            for (index, block) in covering.enumerated() {
                let pieceStart = max(cursor, block.startTime)
                let isLast = index == covering.count - 1
                let pieceEnd = isLast ? clipEnd : min(clipEnd, block.endTime)
                guard pieceEnd - pieceStart >= 0.05 else { continue }
                cursor = pieceEnd
                let layout = block.layout
                // Track without an area under this block: not rendered. A
                // cover-all cutaway needs no area, so it survives anywhere.
                guard clip.track < layout.areaCount || clip.coverAllAreas else { continue }
                var piece = clip
                let offset = pieceStart - clip.startTime
                piece.startTime = pieceStart
                piece.duration = pieceEnd - pieceStart
                piece.sourceStart = clip.sourceStart + offset * clip.speed
                if clip.coverAllAreas {
                    // The whole canvas: no mask, scaled to fill.
                    piece.screenCrop = nil
                    piece.fillCanvas = true
                } else {
                    // A cutaway inherits its track's area like a main clip.
                    piece.screenCrop = layout.reference(forTrack: clip.track)
                }
                piece.transIn = pieceStart > clip.startTime + 0.001 ? nil : clip.transIn
                piece.transOut = pieceEnd < clipEnd - 0.001 ? nil : clip.transOut
                if let path = clip.cameraPath, offset > 0.001 {
                    let sliced = CenterStageService.slice(path, from: offset * clip.speed,
                                                          duration: piece.duration * clip.speed)
                    piece.cameraPath = sliced.count >= 2 ? sliced : nil
                }
                pieces.append(piece)
            }
        }
        return pieces
    }

    /// Every clip in a segment as a placement, in the one draw order the
    /// masks are keyed by. `compositeLayeredSegment` consumes this order
    /// as given.
    nonisolated static func placements(for segment: Segment) -> [Placement] {
        var placements: [Placement] = []
        for (clipIndex, clip) in segment.clips.enumerated() {
            // Timeline offsets map into the source through the clip's speed
            // — a 0.5× clip consumes half a source second per screen second.
            let clipOffset = (segment.start - clip.startTime) * clip.speed
            placements.append(Placement(sourcePath: clip.sourcePath,
                                        sourceStart: clip.sourceStart + clipOffset,
                                        sourceDur: segment.duration * clip.speed,
                                        isWide: clip.wide,
                                        bumper: clip.bumper, volume: clip.volume,
                                        layer: Self.placementLayer(for: clip),
                                        position: clip.effectivePosition,
                                        muted: clip.muted,
                                        role: clip.role,
                                        fillCanvas: clip.fillCanvas,
                                        originalStart: clip.originalStart,
                                        originKey: clip.originKey,
                                        fadeIn: Self.fade(into: segment, start: clip.originalStart,
                                                          seconds: clip.fadeIn),
                                        fadeOut: Self.fade(into: segment,
                                                           start: clip.originalEnd - clip.fadeOut,
                                                           seconds: clip.fadeOut),
                                        documentIndex: clip.documentIndex,
                                        clipIndex: clipIndex,
                                        startTime: clip.startTime,
                                        cropXFrac: clip.effectiveCropXFrac,
                                        freeCrops: clip.freeCrops,
                                        screenCrop: clip.screenCrop,
                                        speed: clip.speed, staticAreaFilter: clip.staticAreaFilter,
                                        effectiveEffect: clip.effectiveEffect))
        }

        return orderedPlacements(placements)
    }

    /// A dissolve that begins at absolute time `start` and runs `seconds`,
    /// expressed in this segment's local time. Nil when the window falls
    /// entirely outside the segment; a negative start means the fade began
    /// in an earlier segment and continues through this one.
    nonisolated static func fade(into segment: Segment, start: Double, seconds: Double) -> Fade? {
        guard seconds > 0.001 else { return nil }
        let local = start - segment.start
        guard local < segment.duration - 0.001, local + seconds > 0.001 else { return nil }
        return Fade(start: local, duration: seconds)
    }

    /// The dissolve step for one placement. It runs AFTER the mask: the
    /// clip chain ends without alpha, and alphamerge is what introduces it,
    /// so an alpha fade before that has nothing to fade.
    nonisolated static func fadeFilters(for placement: Placement, index: Int,
                                        masked: Bool) -> (filters: [String], label: String) {
        let input = masked ? "vm\(index)" : "v\(index)"
        var steps: [String] = []
        steps.append(contentsOf: envelope(for: placement.fadeIn, kind: "in"))
        steps.append(contentsOf: envelope(for: placement.fadeOut, kind: "out"))
        guard !steps.isEmpty else { return ([], input) }
        // Without a mask the frames have no alpha channel to fade.
        if !masked { steps.insert("format=yuva420p", at: 0) }
        let label = "vf\(index)"
        return (["[\(input)]" + steps.joined(separator: ",") + "[\(label)]"], label)
    }

    /// One dissolve as filter steps. `fade`'s `st` cannot be negative and
    /// the ramp always starts from transparent, so a dissolve that began in
    /// an earlier segment is not restarted: the segment is padded by the
    /// part that already happened, the WHOLE fade runs over that padded
    /// timeline, and the padding is trimmed away again. The frames that
    /// survive therefore carry the middle of the envelope, which is what
    /// continuing a dissolve means.
    private nonisolated static func envelope(for fade: Fade?, kind: String) -> [String] {
        guard let fade else { return [] }
        // A window that is already over contributes nothing.
        guard fade.start + fade.duration > 0.001 else { return [] }
        guard fade.start < -0.001 else {
            // A start a hair below zero is still zero: `st=-0.000` is not
            // something ffmpeg should ever be asked to parse.
            return [String(format: "fade=t=%@:alpha=1:st=%.3f:d=%.3f",
                           kind, max(0, fade.start), fade.duration)]
        }
        let lead = -fade.start
        return [String(format: "tpad=start_duration=%.3f:start_mode=clone", lead),
                String(format: "fade=t=%@:alpha=1:st=0.000:d=%.3f", kind, fade.duration),
                String(format: "trim=start=%.3f", lead),
                "setpts=PTS-STARTPTS"]
    }

    /// Screen-crop masks for an ordered placement list, keyed by the index
    /// into that same list (a placement with free crops draws its own
    /// rectangles and an unresolvable reference renders unmasked).
    nonisolated static func maskFiles(for ordered: [Placement], in scratch: URL) -> [Int: URL] {
        var masks: [Int: URL] = [:]
        for (index, placement) in ordered.enumerated() where placement.freeCrops?.isEmpty != false {
            masks[index] = ScreenCropStore.maskFile(reference: placement.screenCrop, in: scratch)
        }
        return masks
    }

    /// How the segment's audio streams become one. When a mixed-in cutaway
    /// is part of the segment the mix runs with `normalize=0`: amix would
    /// otherwise divide every input by their number, so adding the cutaway's
    /// sound would duck the dialogue underneath it. The fast preview keeps
    /// each source at its own gain, so the two agree. Segments without a
    /// cutaway keep amix's default, exactly as before B-roll existed.
    /// Whether the segment's mix has to run at unity gain: only when one of
    /// the streams actually going into it belongs to a mixed-in cutaway. A
    /// cutaway whose file carries no audio contributes nothing, so it must
    /// not change how everything else is mixed.
    nonisolated static func mixNeedsUnityGain(_ contributing: [Placement]) -> Bool {
        contributing.contains { !$0.muted && $0.role == .cutaway }
    }

    nonisolated static func audioMixFilter(labels: [String],
                                           cutawayAudio: Bool) -> (filters: [String], source: String) {
        if labels.isEmpty {
            return (["[1:a]asetpts=PTS-STARTPTS[asilent]"], "[asilent]")
        }
        if labels.count == 1 { return ([], labels[0]) }
        // Only a mixed-in cutaway needs the un-normalized mix; every other
        // segment keeps the levels it has had since before B-roll existed.
        let normalize = cutawayAudio ? ":normalize=0" : ""
        return ([labels.joined() + "amix=inputs=\(labels.count):duration=longest:"
                 + "dropout_transition=0" + normalize + "[amix]"], "[amix]")
    }

    /// The volume filter a placement's audio takes in the mix: bumpers and
    /// mixed-in cutaways honour the volume slider, ordinary clips do not.
    nonisolated static func audioGainFilter(for placement: Placement) -> String {
        guard placement.bumper || placement.role == .cutaway else { return "" }
        return String(format: "volume=%.3f,", Double(min(5, max(0, placement.volume))) / 5)
    }

    /// The clip a segment join belongs to: the lowest-layer main clip (or
    /// the bumper that owns the segment). Cutaways are never a join's
    /// incoming or outgoing clip.
    nonisolated static func joinClip(in clips: [ResolvedClip]) -> ResolvedClip? {
        clips.filter { $0.bumper || $0.role != .cutaway }
            .min { placementLayer(for: $0) < placementLayer(for: $1) }
    }

    /// Draw order for one resolved clip. Main clips on a track sit under
    /// that track's cutaways; a cover-all cutaway sits above every track;
    /// a bumper (which owns its segment outright anyway) sits above all.
    nonisolated static func placementLayer(for clip: ResolvedClip) -> Int {
        if clip.bumper { return TimelineDocument.maxTracks * 2 + 2 }
        if clip.role == .cutaway {
            return clip.coverAllAreas
                ? TimelineDocument.maxTracks * 2 + 1
                : clip.track * 2 + 1
        }
        return clip.track * 2
    }

    /// The one placement order: layer, then the clip's start before crop
    /// splitting, then its persisted identity. `renderSegment` computes it
    /// once, keys the masks by it, and `compositeLayeredSegment` consumes
    /// both without sorting again.
    nonisolated static func orderedPlacements(_ placements: [Placement]) -> [Placement] {
        placements.enumerated().sorted {
            ($0.element.layer, $0.element.originalStart, $0.element.originKey,
             $0.element.documentIndex, $0.offset)
                < ($1.element.layer, $1.element.originalStart, $1.element.originKey,
                   $1.element.documentIndex, $1.offset)
        }.map(\.element)
    }

    /// Port of _build_layered_segments: slice at every clip boundary so each
    /// segment has a constant active clip set (3dp boundaries, ≥0.05s
    /// intervals, 1e-3 coverage tolerance).
    nonisolated static func buildLayeredSegments(_ clips: [ResolvedClip]) -> [Segment] {
        guard !clips.isEmpty else { return [] }
        var boundaries = Set<Double>()
        for clip in clips {
            boundaries.insert((clip.startTime * 1000).rounded() / 1000)
            boundaries.insert(((clip.startTime + clip.duration) * 1000).rounded() / 1000)
        }
        let sorted = boundaries.sorted()
        var segments: [Segment] = []
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            guard end - start >= 0.05 else { continue }
            let active = clips.filter {
                $0.startTime <= start + 0.001 && $0.startTime + $0.duration >= end - 0.001
            }
            if !active.isEmpty {
                // A bumper owns the canvas regardless of track, layout, or
                // other clips. Later-starting bumpers win deterministically.
                let winner = active.filter(\.bumper).sorted {
                    ($0.startTime, $0.track) < ($1.startTime, $1.track)
                }.last
                segments.append(Segment(start: start, end: end, clips: winner.map { [$0] } ?? active))
            }
        }
        return segments
    }

    private nonisolated struct PrepassArtifact: Sendable {
        var url: URL
        var cacheable: Bool
    }

    private nonisolated static func prepassKey(_ clip: ResolvedClip, area: ScreenCropArea?,
                                               tuning: String) throws -> String {
        nonisolated struct Input: Encodable {
            var source: String
            var fingerprint: String
            var start: Double
            var duration: Double
            var path: [CameraPathKeyframe]?
            var area: ScreenCropArea?
            var tuning: String
        }
        return try RenderSegmentCache.key(Input(source: clip.framingIdentity ?? clip.sourcePath,
            fingerprint: clip.framingIdentity ?? SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: clip.sourcePath)),
            start: clip.sourceStart, duration: clip.duration * clip.speed,
            path: clip.cameraPath, area: area, tuning: tuning))
    }

    // MARK: - Segment rendering

    /// A caption PNG composited over a segment inside its enable window.
    nonisolated struct CaptionOverlay: Codable, Sendable {
        var png: URL
        var x: Int
        var y: Int
        var start: Double
        var end: Double
        var text: String?
    }

    /// Render one timeline segment to its own file: black gap placeholder, or
    /// layered composite with captions burned in the same encode pass.
    private func renderSegment(_ segment: Segment, index: Int, of total: Int,
                               scratch: URL, database: Database,
                               captionLanguage: String?,
                               captionRenderer: CaptionRenderer,
                               captionCache: CaptionPNGCache,
                               captionStyle: CaptionStyle, fontFingerprints: [String]?,
                               overlays: [TimedOverlayPNG],
                               emit: @escaping @Sendable (String) -> Void) async throws -> SegmentArtifact {
        let timing = PerfSignpost.begin("SegmentEncode", metadata: "segment=\(index)/\(total)")
        defer { PerfSignpost.end(timing) }
        if segment.clips.isEmpty || segment.clips.allSatisfy(\.missingBumper) {
            emit("Segment \(index + 1)/\(total): gap (\(String(format: "%.1fs", segment.duration)))")
            let gapPath = scratch.appendingPathComponent(String(format: "gap%03d.mp4", index))
            let input = RenderSegmentKey(start: segment.start, duration: segment.duration, clips: [],
                captions: [], overlays: [], masks: [:], fontFingerprints: [], captionStyle: CaptionStyle(),
                settings: RenderContext.settings, encoder: FFmpeg.encodeArgs)
            let key = try RenderSegmentCache.key(input)
            if await segmentCache.restore(key: key, to: gapPath) {
                emit("Segment \(index + 1): cache hit; encodes=0")
                return SegmentArtifact(url: gapPath, key: nil)
            }
            emit("Segment \(index + 1): encode pass")
            try await generatePlaceholder(duration: segment.duration, output: gapPath)
            try Task.checkCancellation()
            return SegmentArtifact(url: gapPath, key: key)
        }

        emit("Segment \(index + 1)/\(total): compositing \(segment.clips.count) clip(s)…")
        let placements = Self.placements(for: segment)

        // Captions ride the composite's filter graph — no second encode pass.
        var captions: [CaptionOverlay] = []
        var segmentComplete = true
        for clip in segment.clips {
            guard let captionPosition = clip.captionsPosition, let videoID = clip.videoID else { continue }
            let clipOffset = (segment.start - clip.startTime) * clip.speed
            let sourceStart = clip.sourceStart + clipOffset
            let sourceEnd = sourceStart + segment.duration * clip.speed
            let rows: [TranscriptSegment]
            do {
                rows = try await database.transcriptSegments(videoID: videoID,
                    start: sourceStart, end: sourceEnd, language: captionLanguage)
            } catch {
                try Task.checkCancellation()
                segmentComplete = false
                continue
            }
            for row in rows {
                // Shift to segment-local SCREEN time (slow motion stretches
                // it) and clamp to the window, like get_transcript_for_clip.
                let start = max(0, (row.start - sourceStart) / clip.speed)
                let end = min(segment.duration, (row.end - sourceStart) / clip.speed)
                guard end > start else { continue }
                let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard let rendered = try? await captionCache.rendered(text) else {
                    try Task.checkCancellation()
                    segmentComplete = false
                    continue
                }
                let (x, y) = captionRenderer.position(for: rendered, positionOverride: captionPosition)
                captions.append(CaptionOverlay(png: rendered.pngURL, x: x, y: y, start: start, end: end, text: text))
            }
        }

        let segmentPath = scratch.appendingPathComponent(String(format: "seg%03d_layered.mp4", index))
        let masks = Self.maskFiles(for: placements, in: scratch)
        var keyClips = segment.clips
        for index in keyClips.indices {
            keyClips[index].sourcePath = keyClips[index].originalSourcePath ?? keyClips[index].sourcePath
        }
        // The origin identity is a document-side tie-breaker, not pixels:
        // caching it would miss on every clip whose key differs. Its only
        // effect on the output is the draw order, so store that instead.
        for index in keyClips.indices { keyClips[index].documentIndex = 0 }
        for (rank, placement) in placements.enumerated() where keyClips.indices.contains(placement.clipIndex) {
            keyClips[placement.clipIndex].originKey = String(rank)
        }
        var keyCaptions = captions
        for index in keyCaptions.indices {
            let digest = try RenderSegmentCache.key(Data(contentsOf: captions[index].png))
            keyCaptions[index].png = URL(fileURLWithPath: "/" + digest)
        }
        var keyOverlays = overlays
        for index in keyOverlays.indices {
            let digest = try RenderSegmentCache.key(Data(contentsOf: overlays[index].png))
            keyOverlays[index].png = URL(fileURLWithPath: "/" + digest)
        }
        let maskKeys = try masks.reduce(into: [String: String]()) { result, entry in
            result[String(entry.key)] = try RenderSegmentCache.key(Data(contentsOf: entry.value))
        }
        let input = RenderSegmentKey(start: segment.start, duration: segment.duration, clips: keyClips,
            captions: keyCaptions, overlays: keyOverlays, masks: maskKeys,
            fontFingerprints: fontFingerprints ?? [], captionStyle: captionStyle,
            settings: RenderContext.settings, encoder: FFmpeg.encodeArgs)
        var key: String? = segmentComplete && fontFingerprints != nil && segment.clips.allSatisfy(\.cacheable)
            ? try RenderSegmentCache.key(input) : nil
        if let key, await segmentCache.restore(key: key, to: segmentPath) {
            emit("Segment \(index + 1): cache hit; encodes=0")
            return SegmentArtifact(url: segmentPath, key: nil)
        }
        do {
            emit("Segment \(index + 1): encode pass")
            try await compositeLayeredSegment(placements: placements, duration: segment.duration,
                captions: captions, overlays: overlays, maskFiles: masks, output: segmentPath)
        } catch where !captions.isEmpty {
            try Task.checkCancellation()
            key = nil // A degraded result must never satisfy the full key.
            emit("Segment \(index + 1): caption burn failed, retrying without captions; encode pass")
            try await compositeLayeredSegment(placements: placements, duration: segment.duration,
                captions: [], overlays: overlays, maskFiles: masks, output: segmentPath)
        }
        try Task.checkCancellation()
        return SegmentArtifact(url: segmentPath, key: key)
    }

    nonisolated struct SegmentArtifact: Sendable {
        var url: URL
        var key: String?
    }

    private func publishSegments(_ artifacts: [SegmentArtifact], clips: [ResolvedClip]) async {
        // Do not cache an encode whose source changed during the run.
        for clip in clips {
            guard let path = clip.originalSourcePath,
                  let fingerprint = try? SourceIdentityCache.shared.fingerprint(of: URL(fileURLWithPath: path)),
                  fingerprint == clip.sourceFingerprint else { return }
        }
        await segmentCache.store(artifacts.compactMap { artifact in
            artifact.key.map { RenderSegmentCache.Entry(key: $0, source: artifact.url) }
        })
    }

    // MARK: - FFmpeg stages

    /// Solid black 1080x1920 clip with silent audio (video.py generate_placeholder).
    private func generatePlaceholder(duration: Double, output: URL) async throws {
        try await FFmpeg.run(["-y",
                              "-f", "lavfi", "-i",
                              String(format: "color=c=black:s=%dx%d:d=%.2f:r=30",
                                     Self.width, Self.height, duration),
                              "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                              "-t", String(format: "%.2f", duration)]
                             + FFmpeg.encodeArgs + [output.path], timeout: 120, capture: .boundedStderrTail())
    }

    /// Splice a placement look before masks and fades, with unique graph pads.
    nonisolated static func insertEffect(_ effect: EffectSpec, label: String, width: Int,
                                        height: Int, filters: inout [String]) {
        let fragment = EffectCatalog.filter(for: effect, width: width, height: height, namespace: "fx_\(label)_")
        guard !fragment.isEmpty,
              let index = filters.firstIndex(where: { $0.hasSuffix("[\(label)]") }) else { return }
        let producer = String(filters[index].dropLast(label.count + 2))
        if fragment.contains(";") {
            filters[index] = producer + "[pre_\(label)]"
            filters.append("[pre_\(label)]\(fragment)[\(label)]")
        } else {
            filters[index] = producer + ",\(fragment)[\(label)]"
        }
    }

    /// Port of video.py composite_layered_segment(): black base canvas, each
    /// placement overlaid in (layer, stack order) order — non-wide clips fill
    /// the frame, cropped wides fill the frame through a 9:16 window, slot
    /// wides land in a 1080x640 band, free-crop rectangles composite in z
    /// order, caption PNGs overlay last inside their enable windows. Unmuted
    /// clip audio mixes via amix (silence when none).
    private func compositeLayeredSegment(placements: [Placement], duration: Double,
                                         captions: [CaptionOverlay] = [],
                                         overlays: [TimedOverlayPNG] = [],
                                         maskFiles: [Int: URL] = [:],
                                         output: URL) async throws {
        guard !placements.isEmpty else {
            try await generatePlaceholder(duration: duration, output: output)
            return
        }

        // Already in the one order `renderSegment` computed; the masks are
        // keyed by index into exactly this list, so it must not be re-sorted.
        let ordered = placements

        var arguments = ["-y",
                         "-f", "lavfi", "-i",
                         String(format: "color=c=black:s=%dx%d:d=%.3f:r=30",
                                Self.width, Self.height, duration),
                         "-f", "lavfi", "-i",
                         String(format: "anullsrc=r=44100:cl=stereo:d=%.3f", duration)]
        for placement in ordered {
            arguments += ["-ss", String(format: "%.3f", max(0, placement.sourceStart)),
                          "-t", String(format: "%.3f", placement.sourceDur),
                          "-i", placement.sourcePath]
        }
        for caption in captions { arguments += ["-i", caption.png.path] }
        // Screen-crop masks: one PNG input per masked placement (after the
        // captions), looped for the segment so alphamerge has a frame for
        // every video frame.
        var maskInputs: [Int: Int] = [:]   // placement index → input index
        for (index, placement) in ordered.enumerated() where placement.freeCrops?.isEmpty != false {
            guard let mask = maskFiles[index]
            else { continue }
            maskInputs[index] = 2 + ordered.count + captions.count + maskInputs.count
            arguments += ["-loop", "1", "-t", String(format: "%.3f", duration), "-i", mask.path]
        }

        var filters: [String] = []
        var freeCropOutputs: [Int: [(label: String, x: Int, y: Int)]] = [:]

        for (index, placement) in ordered.enumerated() {
            let sourceIndex = index + 2
            // Slow motion stretches this clip's timestamps inside the
            // segment; the audio atempo below matches.
            let pts = placement.speed == 1 ? "setpts=PTS-STARTPTS"
                : String(format: "setpts=(PTS-STARTPTS)/%.4f", placement.speed)
            if let crops = Self.normalizedFreeCrops(placement.freeCrops), !crops.isEmpty {
                let splitOuts = (0..<crops.count).map { "[s\(index)_\($0)]" }.joined()
                filters.append("[\(sourceIndex):v]\(pts),setsar=1,fps=30," +
                               "split=\(crops.count)\(splitOuts)")
                var outs: [(label: String, x: Int, y: Int, z: Int)] = []
                for (cropIndex, crop) in crops.enumerated() {
                    let dstW = max(2, Int((Double(Self.width) * crop.dw).rounded()))
                    let dstH = max(2, Int((Double(Self.height) * crop.dh).rounded()))
                    filters.append(String(format: "[s%d_%d]crop=iw*%.5f:ih*%.5f:iw*%.5f:ih*%.5f,scale=%d:%d[v%d_%d]",
                                          index, cropIndex, crop.sw, crop.sh, crop.sx, crop.sy,
                                          dstW, dstH, index, cropIndex))
                    outs.append(("v\(index)_\(cropIndex)",
                                 Int((Double(Self.width) * crop.dx).rounded()),
                                 Int((Double(Self.height) * crop.dy).rounded()),
                                 crop.z))
                }
                freeCropOutputs[index] = outs.sorted { $0.z < $1.z }.map { ($0.label, $0.x, $0.y) }
                continue
            }

            if let areaFilter = placement.staticAreaFilter {
                filters.append("[\(sourceIndex):v]\(areaFilter),\(pts)," +
                               "scale=\(Self.width):\(Self.height):force_original_aspect_ratio=decrease," +
                               "pad=\(Self.width):\(Self.height):(ow-iw)/2:(oh-ih)/2:color=black," +
                               "setsar=1,fps=30[v\(index)]")
                continue
            }

            if placement.fillCanvas {
                // Cover-all cutaway: crop to fill the whole canvas, centred
                // (scale up to cover, then take the middle of the frame).
                filters.append(String(format: "[%d:v]%@," +
                                      "scale=%d:%d:force_original_aspect_ratio=increase," +
                                      "crop=%d:%d,setsar=1,fps=30[v%d]",
                                      sourceIndex, pts, Self.width, Self.height,
                                      Self.width, Self.height, index))
                continue
            }

            let wideCropped = placement.isWide && placement.cropXFrac != nil
            if wideCropped {
                let fraction = max(0, min(1, placement.cropXFrac ?? 0.5))
                let aspect = RenderContext.settings.aspectRatio
                filters.append(String(format: "[%d:v]%@," +
                                      "crop='min(iw\\,ih*%.5f)':ih:(iw-min(iw\\,ih*%.5f))*%.4f:0," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceIndex, pts, aspect, aspect, fraction, Self.width, Self.height,
                                      Self.width, Self.height, index))
            } else {
                // Bumpers deliberately use fit, with black padding: no
                // content (including text baked into the video) is cropped.
                let targetHeight = placement.isWide ? Self.slotHeight : Self.height
                filters.append(String(format: "[%d:v]%@," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceIndex, pts, Self.width, targetHeight,
                                      Self.width, targetHeight, index))
            }
        }

        // All placement branches have produced their labels. Rewrite only
        // those producers, before any mask or fade can consume the result.
        for (index, placement) in ordered.enumerated() where !placement.bumper {
            guard let effect = placement.effectiveEffect else { continue }
            try EffectCatalog.validate(effect)
            guard EffectCatalog.isAvailable(effect.preset) else {
                throw BuilderCommandFailure.invalid("Effect unavailable in ffmpeg: \(effect.preset).")
            }
            if let crops = Self.normalizedFreeCrops(placement.freeCrops), !crops.isEmpty {
                for (cropIndex, crop) in crops.enumerated() {
                    Self.insertEffect(effect, label: "v\(index)_\(cropIndex)",
                        width: max(2, Int((Double(Self.width) * crop.dw).rounded())),
                        height: max(2, Int((Double(Self.height) * crop.dh).rounded())), filters: &filters)
                }
            } else {
                let slot = placement.isWide && placement.cropXFrac == nil
                    && !placement.fillCanvas && placement.staticAreaFilter == nil
                Self.insertEffect(effect, label: "v\(index)", width: Self.width,
                                  height: slot ? Self.slotHeight : Self.height, filters: &filters)
            }
        }

        // Screen crops: the mask's gray level becomes the clip's alpha, so
        // the overlay chain composites only the named area.
        for (index, inputIndex) in maskInputs {
            // alphamerge needs identical sizes: a wide clip that isn't
            // cropped sits in the 1080×640 slot, not the full frame.
            let placement = ordered[index]
            let maskHeight = placement.isWide && placement.cropXFrac == nil ? Self.slotHeight : Self.height
            filters.append("[\(inputIndex):v]format=gray,scale=\(Self.width):\(maskHeight)[mk\(index)]")
            filters.append("[v\(index)][mk\(index)]alphamerge[vm\(index)]")
        }

        // Overlay chain — bottom layer first.
        var overlaySteps: [(label: String, x: Int, y: Int)] = []
        for (index, placement) in ordered.enumerated() {
            if let outs = freeCropOutputs[index] {
                overlaySteps.append(contentsOf: outs)
                continue
            }
            let wideCropped = placement.isWide && placement.cropXFrac != nil
            let y = (placement.isWide && !wideCropped)
                ? (Self.slotY[placement.position] ?? 0) : 0
            // A masked slot-band clip still lands in its band; the mask is
            // full-frame, so it's shifted by the band's offset.
            // Dissolves come after the mask, which is what creates alpha.
            let fade = Self.fadeFilters(for: placement, index: index,
                                        masked: maskInputs[index] != nil)
            filters.append(contentsOf: fade.filters)
            overlaySteps.append((fade.label, 0, y))
        }
        var previous = "[0:v]"
        for (stepIndex, step) in overlaySteps.enumerated() {
            let isLast = stepIndex == overlaySteps.count - 1 && captions.isEmpty && overlays.isEmpty
            let outLabel = isLast ? "[vout]" : "[ov\(stepIndex)]"
            filters.append("\(previous)[\(step.label)]overlay=x=\(step.x):y=\(step.y):shortest=0\(outLabel)")
            previous = outLabel
        }

        // Caption overlays chain onto the composited frame (single-frame PNG
        // inputs persist via repeatlast, gated by their enable windows).
        let captionBase = 2 + ordered.count
        for (capIndex, caption) in captions.enumerated() {
            let outLabel = capIndex == captions.count - 1 && overlays.isEmpty ? "[vout]" : "[cap\(capIndex)]"
            filters.append("\(previous)[\(captionBase + capIndex):v]overlay=x=\(caption.x):y=\(caption.y):" +
                           String(format: "enable='between(t,%.3f,%.3f)'", caption.start, caption.end) + outLabel)
            previous = outLabel
        }

        if !overlays.isEmpty {
            previous = Self.appendOverlayFilters(overlays, firstInput: 2 + ordered.count + captions.count + maskInputs.count,
                previous: previous, arguments: &arguments, filters: &filters)
            filters.append("\(previous)null[vout]")
        }

        // Audio: mix unmuted clips that actually carry audio.
        var audioLabels: [String] = []
        var contributing: [Placement] = []
        for (index, placement) in ordered.enumerated() {
            guard !placement.muted else { continue }
            guard await FFmpeg.hasAudioStream(URL(fileURLWithPath: placement.sourcePath)) else { continue }
            contributing.append(placement)
            let tempo = placement.speed == 1 ? ""
                : String(format: "atempo=%.4f,", min(2, max(0.5, placement.speed)))
            // Bumpers and mixed-in cutaways honour the volume slider; a
            // muted cutaway never gets here (it resolves to muted).
            let gain = Self.audioGainFilter(for: placement)
            filters.append("[\(index + 2):a]\(tempo)\(gain)asetpts=PTS-STARTPTS[a\(index)]")
            audioLabels.append("[a\(index)]")
        }
        let mix = Self.audioMixFilter(labels: audioLabels,
                                      cutawayAudio: Self.mixNeedsUnityGain(contributing))
        filters.append(contentsOf: mix.filters)
        let audioSource = mix.source

        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[vout]", "-map", audioSource,
            "-t", String(format: "%.3f", duration),
        ] + FFmpeg.encodeArgs + [output.path], timeout: 600, capture: .boundedStderrTail())
    }

    private nonisolated struct NormalizedCrop {
        var sx: Double, sy: Double, sw: Double, sh: Double
        var dx: Double, dy: Double, dw: Double, dh: Double
        var z: Int
    }

    /// Clamp free-crop rectangles into the unit square, dropping degenerates
    /// (same guards as the Python renderer).
    private nonisolated static func normalizedFreeCrops(_ crops: [FreeCrop]?) -> [NormalizedCrop]? {
        guard let crops, !crops.isEmpty else { return nil }
        var normalized: [NormalizedCrop] = []
        for crop in crops {
            var sw = max(0.001, min(1, crop.src.wFrac))
            var sh = max(0.001, min(1, crop.src.hFrac))
            let sx = max(0, min(1, crop.src.xFrac))
            let sy = max(0, min(1, crop.src.yFrac))
            var dw = max(0.001, min(1, crop.dst.wFrac))
            var dh = max(0.001, min(1, crop.dst.hFrac))
            let dx = max(0, min(1, crop.dst.xFrac))
            let dy = max(0, min(1, crop.dst.yFrac))
            if sx + sw > 1 { sw = 1 - sx }
            if sy + sh > 1 { sh = 1 - sy }
            if dx + dw > 1 { dw = 1 - dx }
            if dy + dh > 1 { dh = 1 - dy }
            normalized.append(NormalizedCrop(sx: sx, sy: sy, sw: sw, sh: sh,
                                             dx: dx, dy: dy, dw: dw, dh: dh, z: crop.z))
        }
        return normalized
    }

    /// Port of video.py build_music_track(): concat per-block trimmed music
    /// (volume = level/5 × 0.7) and silence gaps, 2s fade-out at the end.
    private func buildMusicTrack(segments: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)],
                                 totalDuration: Double, output: URL) async throws {
        var arguments = ["-y"]
        var filters: [String] = []
        var index = 0
        for segment in segments where segment.duration > 0 {
            let musicVolume = Double(segment.volume) / 5.0 * 0.7
            if let music = segment.music, musicVolume > 0 {
                arguments += ["-stream_loop", "-1", "-i", music.path]
                filters.append(String(format: "[%d:a]atrim=%.3f:%.3f,asetpts=PTS-STARTPTS,volume=%.3f[s%d]",
                                      index, segment.offset, segment.offset + segment.duration, musicVolume, index))
            } else {
                arguments += ["-f", "lavfi", "-i",
                              String(format: "anullsrc=r=44100:cl=stereo:d=%.3f", segment.duration)]
                filters.append(String(format: "[%d:a]atrim=0:%.3f,asetpts=PTS-STARTPTS[s%d]",
                                      index, segment.duration, index))
            }
            index += 1
        }
        guard index > 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No music segments"])
        }
        if index == 1 {
            filters.append("[s0]asetpts=PTS-STARTPTS[aout]")
        } else {
            let joined = (0..<index).map { "[s\($0)]" }.joined()
            filters.append("\(joined)concat=n=\(index):v=0:a=1[aout]")
        }
        filters.append(String(format: "[aout]afade=t=out:st=%.2f:d=2.0[final]",
                              max(0, totalDuration - 2)))
        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[final]",
            "-c:a", "aac", "-b:a", "192k", output.path,
        ], timeout: 600, capture: .boundedStderrTail())
    }

    /// Port of video.py overlay_music_track(): duck the original audio per
    /// block (1 − level/5) and mix the pre-built music bed under it.
    private func overlayMusicTrack(video: URL, musicTrack: URL,
                                   segments: [(start: Double, duration: Double, music: URL?, volume: Int, offset: Double)],
                                   output: URL) async throws {
        if await FFmpeg.hasAudioStream(video) {
            let parts = segments.map { segment in
                String(format: "between(t\\,%.3f\\,%.3f)*%.3f",
                       segment.start, segment.start + segment.duration,
                       1.0 - Double(segment.volume) / 5.0)
            }
            let expression = parts.isEmpty ? "1.0" : parts.joined(separator: "+")
            try await FFmpeg.run(["-y", "-i", video.path, "-i", musicTrack.path,
                                  "-filter_complex",
                                  "[0:a]volume='\(expression)':eval=frame[orig];" +
                                  "[orig][1:a]amix=inputs=2:duration=first:dropout_transition=2[aout]",
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600, capture: .boundedStderrTail())
        } else {
            try await FFmpeg.run(["-y", "-i", video.path, "-i", musicTrack.path,
                                  "-map", "0:v", "-map", "1:a",
                                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600, capture: .boundedStderrTail())
        }
    }

    /// A pre-rendered full-frame overlay PNG with its window and transitions
    /// — text and image overlays share this once rasterized.
    nonisolated struct TimedOverlayPNG: Codable, Sendable {
        var png: URL
        var startTime: Double
        var endTime: Double
        var transIn: String
        var transOut: String
        var identity: String?
    }

    nonisolated struct OverlayPlan {
        var bySegment: [Int: [TimedOverlayPNG]] = [:]
        var remaining: [TimedOverlayPNG] = []
    }

    /// Conservatively fuse before the first transition. Crossfades can shorten
    /// all subsequent timeline positions (and can fall back to hard cuts), so
    /// those overlays retain their original absolute clock in the final pass.
    nonisolated static func partitionOverlays(_ overlays: [TimedOverlayPNG], segments: [Segment]) -> OverlayPlan {
        var plan = OverlayPlan()
        for overlay in overlays {
            // An intersecting overlay stays in the final pass, where its
            // visible windows are split around every bumper (including black
            // placeholders for missing mid-roll files).
            if segments.contains(where: { segment in
                segment.clips.contains(where: \.bumper) && overlay.startTime < segment.end && overlay.endTime > segment.start
            }) {
                plan.remaining.append(overlay)
                continue
            }
            var elapsed = 0.0
            var destination: Int?
            for (index, segment) in segments.enumerated() {
                if index > 0, segment.clips.first?.transIn != nil { break }
                guard abs(elapsed - segment.start) < 0.001 else { break }
                elapsed += segment.duration
                var safeEnd = segment.end
                if index + 1 < segments.count, let transition = segments[index + 1].clips.first?.transIn {
                    // xfade consumes at most 40% of either adjacent clip;
                    // recipe bridges consume their explicit tail piece.
                    let tail = TransitionRecipes.isRecipe(transition) ? TransitionRecipes.pieces(for: transition).0 : 0
                    safeEnd -= max(segment.duration * 0.4, tail)
                }
                if !segment.clips.isEmpty, !segment.clips.contains(where: \.bumper), overlay.startTime >= segment.start,
                   overlay.endTime < safeEnd || (index == segments.count - 1 && overlay.endTime <= safeEnd) {
                    destination = index
                    break
                }
            }
            // Images precede text. A lower layer left for the final pass must
            // not suddenly cover a higher overlapping layer fused below it.
            let overlapsRetained = plan.remaining.contains {
                $0.startTime <= overlay.endTime && overlay.startTime <= $0.endTime
            }
            if let index = destination, !overlapsRetained {
                var local = overlay
                local.startTime -= segments[index].start
                local.endTime -= segments[index].start
                plan.bySegment[index, default: []].append(local)
            } else {
                plan.remaining.append(overlay)
            }
        }
        return plan
    }

    /// Half-open visibility windows prevent an overlay from leaking onto
    /// the first bumper frame. Keep animations only at the original edges.
    nonisolated static func overlayWindows(_ overlays: [TimedOverlayPNG],
                                           excluding spans: [Range<Double>]) -> [TimedOverlayPNG] {
        overlays.flatMap { overlay in
            var windows = [overlay]
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                windows = windows.flatMap { item -> [TimedOverlayPNG] in
                    guard item.startTime < span.upperBound, item.endTime > span.lowerBound else { return [item] }
                    var result: [TimedOverlayPNG] = []
                    if item.startTime < span.lowerBound {
                        var head = item
                        head.endTime = span.lowerBound
                        head.transOut = "none"
                        result.append(head)
                    }
                    if item.endTime > span.upperBound {
                        var tail = item
                        tail.startTime = span.upperBound
                        tail.transIn = "none"
                        result.append(tail)
                    }
                    return result
                }
            }
            return windows
        }
    }

    /// Port of video.py add_multiple_text_overlays(): loop each pre-rendered
    /// full-frame PNG as an input and composite with fade/slide expressions
    /// inside its enable window.
    private func addOverlays(video: URL, overlays: [TimedOverlayPNG],
                             excluding bumperSpans: [Range<Double>] = [], output: URL) async throws {
        let overlays = Self.overlayWindows(overlays, excluding: bumperSpans)
        let timing = PerfSignpost.begin("OverlayBurn", metadata: "overlays=\(overlays.count)")
        defer { PerfSignpost.end(timing) }
        let videoDuration = await FFmpeg.duration(of: video)
        var arguments = ["-y", "-i", video.path]
        var filters: [String] = []
        let previous = Self.appendOverlayFilters(overlays, firstInput: 1, previous: "[0:v]",
                                                 arguments: &arguments, filters: &filters)

        guard !filters.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        // Overlay inputs can outlast the video; cap the output to the
        // measured length. A failed probe reports 0 — leave the length
        // alone rather than emit an empty file.
        let lengthCap: [String] = videoDuration > 0
            ? ["-t", String(format: "%.3f", videoDuration)] : []
        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", previous, "-map", "0:a?",
        ] + FFmpeg.videoEncodeArgs + [
            "-c:a", "copy", "-pix_fmt", "yuv420p",
        ] + lengthCap + [
            "-movflags", "+faststart", output.path,
        ], timeout: 900, capture: .boundedStderrTail())
    }

    /// Both segment and full-timeline burns use the identical animation graph.
    /// Wizard extractClip has a whole-clip animation API; Builder's independent
    /// entry/exit windows must remain intact here.
    private nonisolated static func appendOverlayFilters(_ overlays: [TimedOverlayPNG], firstInput: Int,
        previous: String, arguments: inout [String], filters: inout [String]) -> String {
        var previous = previous
        var inputIndex = firstInput - 1
        let animDuration = 0.4

        for (index, overlay) in overlays.enumerated() {
            let pngURL = overlay.png
            inputIndex += 1
            let start = overlay.startTime
            let end = overlay.endTime
            let duration = end - start
            let anim = min(animDuration, duration / 3)
            // The looped PNG's own clock starts at 0 like the main video's,
            // so it must run through `end` (not just the overlay's length)
            // and its fades are stamped in absolute time — otherwise a
            // faded overlay that starts after t=0 has already faded to
            // transparent by the time `enable` lets it through.
            arguments += ["-loop", "1", "-t", String(format: "%.2f", end + 1), "-i", pngURL.path]

            var current = "[\(inputIndex):v]"
            let fadeIn = overlay.transIn == "fade" || overlay.transIn == "pop"
            let fadeOut = overlay.transOut == "fade" || overlay.transOut == "pop"
            if fadeIn || fadeOut {
                var fadeParts = ["format=rgba"]
                if fadeIn { fadeParts.append(String(format: "fade=t=in:st=%.3f:d=%.3f:alpha=1", start, anim)) }
                if fadeOut { fadeParts.append(String(format: "fade=t=out:st=%.3f:d=%.3f:alpha=1",
                                                     end - anim, anim)) }
                let label = "[tf\(index)]"
                filters.append("\(current)\(fadeParts.joined(separator: ","))\(label)")
                current = label
            }

            let outLabel = "[txt\(index)]"
            let slideIn = overlay.transIn.hasPrefix("slide_") || overlay.transIn == "pop"
            let slideOut = overlay.transOut.hasPrefix("slide_") || overlay.transOut == "pop"
            if slideIn || slideOut {
                let enterX = slideIn ? Self.slideExpression(overlay.transIn, axis: "x", at: start, anim: anim, entering: true) : "0"
                let enterY = slideIn ? Self.slideExpression(overlay.transIn, axis: "y", at: start, anim: anim, entering: true) : "0"
                let exitX = slideOut ? Self.slideExpression(overlay.transOut, axis: "x", at: end, anim: anim, entering: false) : "0"
                let exitY = slideOut ? Self.slideExpression(overlay.transOut, axis: "y", at: end, anim: anim, entering: false) : "0"
                var xExpr = String(format: "if(lt(t,%.3f),%@,if(gt(t,%.3f),%@,0))",
                                   start + anim, enterX, end - anim, exitX)
                var yExpr = String(format: "if(lt(t,%.3f),%@,if(gt(t,%.3f),%@,0))",
                                   start + anim, enterY, end - anim, exitY)
                if enterX == "0" && exitX == "0" { xExpr = "0" }
                if enterY == "0" && exitY == "0" { yExpr = "0" }
                filters.append("\(previous)\(current)overlay=x='\(xExpr)':y='\(yExpr)':" +
                               String(format: "enable='gte(t,%.3f)*lt(t,%.3f)'", start, end) + outLabel)
            } else {
                filters.append("\(previous)\(current)overlay=0:0:" +
                               String(format: "enable='gte(t,%.3f)*lt(t,%.3f)':shortest=0", start, end) + outLabel)
            }
            previous = outLabel
        }

        return previous
    }

    /// Slide enter/exit x/y expressions (video.py _slide_enter/_slide_exit).
    private nonisolated static func slideExpression(_ transition: String, axis: String,
                                                    at time: Double, anim: Double,
                                                    entering: Bool) -> String {
        let direction = transition.split(separator: "_").last.map(String.init) ?? ""
        if entering {
            switch (axis, direction) {
            case ("x", "left"): return String(format: "if(lt(t-%.3f,%.3f),W-W*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("x", "right"): return String(format: "if(lt(t-%.3f,%.3f),-W+W*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("y", "up"): return String(format: "if(lt(t-%.3f,%.3f),H-H*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            case ("y", "down"): return String(format: "if(lt(t-%.3f,%.3f),-H+H*(t-%.3f)/%.3f,0)", time, anim, time, anim)
            // Rise-settle from 5% below with a cubic ease-out.
            case ("y", "pop"): return String(format: "if(lt(t-%.3f,%.3f),round(H*0.05*pow(1-(t-%.3f)/%.3f,3)),0)", time, anim, time, anim)
            default: return "0"
            }
        } else {
            let exitStart = time - anim
            switch (axis, direction) {
            case ("x", "left"): return String(format: "if(gt(t,%.3f),-W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("x", "right"): return String(format: "if(gt(t,%.3f),W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "up"): return String(format: "if(gt(t,%.3f),-H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "down"): return String(format: "if(gt(t,%.3f),H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "pop"): return String(format: "if(gt(t,%.3f),round(H*0.05*pow((t-%.3f)/%.3f,3)),0)", exitStart, exitStart, anim)
            default: return "0"
            }
        }
    }

    // MARK: - Output naming

    /// <output>/<YYYY-MM-DD>/hl-<duration>-<n>.mp4, sharing the per-day
    /// counter with the Python builder (it scans every mp4's trailing number).
    private nonisolated static func outputFile(profile: BrandProfile,
                                               totalDuration: Double,
                                               baseName: String? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = profile.outputFolderURL
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let baseName {
            return Self.uniqueFile(named: baseName, in: directory)
        }

        var counter = 1
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.pathExtension.lowercased() == "mp4" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
            if parts.count >= 3, let value = Int(parts[parts.count - 1]), value >= counter {
                counter = value + 1
            }
        }
        return directory.appendingPathComponent("hl-\(Int(totalDuration))-\(counter).mp4")
    }

    /// `<name>.mp4`, or `<name> 2.mp4`, `<name> 3.mp4`, … when taken.
    nonisolated static func uniqueFile(named baseName: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(baseName + ".mp4")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(counter).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}

/// Serializes and memoizes caption PNG rasterization — identical caption text
/// renders once per run, even across concurrent segment jobs.
actor CaptionPNGCache {
    private let renderer: CaptionRenderer
    private let directory: URL
    private var cache: [String: CaptionRenderer.RenderedCaption] = [:]

    init(renderer: CaptionRenderer, directory: URL) {
        self.renderer = renderer
        self.directory = directory
    }

    func rendered(_ text: String) throws -> CaptionRenderer.RenderedCaption {
        if let hit = cache[text] { return hit }
        let rendered = try renderer.render(text: text, to: directory)
        cache[text] = rendered
        return rendered
    }
}
