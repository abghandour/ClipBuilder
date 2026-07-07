import Foundation

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
    nonisolated struct ResolvedClip: Sendable {
        var sourcePath: String
        var videoID: Int64?
        var sourceStart: Double
        var startTime: Double
        var duration: Double
        var track: Int
        var wide: Bool
        var stackOrder: Int
        var muted: Bool
        var transIn: String?
        var transOut: String?
        var effectivePosition: String
        var effectiveCropXFrac: Double?
        var freeCrops: [FreeCrop]?
        var captionsPosition: String?     // nil = captions off for this clip
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
        var layer: Int
        var position: String
        var muted: Bool
        var stackOrder: Int
        var cropXFrac: Double?
        var freeCrops: [FreeCrop]?
    }

    private static let width = RenderEngine.outputWidth
    private static let height = RenderEngine.outputHeight
    private static let slotHeight = 640
    private static let slotY: [String: Int] = ["top": 0, "center": 640, "bottom": 1280]
    private static let encodeArgs = ["-c:v", "libx264", "-preset", "fast", "-crf", "23",
                                     "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "128k",
                                     "-pix_fmt", "yuv420p", "-movflags", "+faststart"]

    private let render: RenderEngine

    init(render: RenderEngine) {
        self.render = render
    }

    // MARK: - Entry point

    func render(document: TimelineDocument, scenes: [SceneRecord],
                profile: BrandProfile, database: Database,
                emit: @escaping @Sendable (String) -> Void) async throws -> RenderResult {
        let clips = Self.resolveClips(document: document, scenes: scenes)
        guard !clips.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No valid clips in the video track"])
        }
        guard FFmpeg.isAvailable else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg not found — install it (e.g. brew install ffmpeg)"])
        }

        let totalDuration = clips.map { $0.startTime + $0.duration }.max() ?? 0
        let outputURL = try Self.outputFile(profile: profile, totalDuration: totalDuration)
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
        var introAdded = false

        if document.includeIntro, let intro = Self.assetURL(profile.introVideo) {
            emit("Normalizing intro…")
            let normalized = scratch.appendingPathComponent("intro_norm.mp4")
            try await render.normalizeClip(source: intro, output: normalized)
            clipPaths.append(normalized)
            transitions.append("fade")
            introAdded = true
        }

        let captionRenderer = CaptionRenderer(videoWidth: Self.width, videoHeight: Self.height,
                                              style: profile.captions)
        for (index, segment) in fullSegments.enumerated() {
            if segment.clips.isEmpty {
                emit("Segment \(index + 1)/\(fullSegments.count): gap (\(String(format: "%.1fs", segment.duration)))")
                let gapPath = scratch.appendingPathComponent(String(format: "gap%03d.mp4", index))
                try await generatePlaceholder(duration: segment.duration, output: gapPath)
                clipPaths.append(gapPath)
                if clipPaths.count > 1 { transitions.append(nil) }
                continue
            }

            emit("Segment \(index + 1)/\(fullSegments.count): compositing \(segment.clips.count) clip(s)…")
            var placements: [Placement] = []
            for clip in segment.clips {
                let clipOffset = segment.start - clip.startTime
                placements.append(Placement(sourcePath: clip.sourcePath,
                                            sourceStart: clip.sourceStart + clipOffset,
                                            sourceDur: segment.duration,
                                            isWide: clip.wide,
                                            layer: clip.track,
                                            position: clip.effectivePosition,
                                            muted: clip.muted,
                                            stackOrder: clip.stackOrder,
                                            cropXFrac: clip.effectiveCropXFrac,
                                            freeCrops: clip.freeCrops))
            }
            var segmentPath = scratch.appendingPathComponent(String(format: "seg%03d_layered.mp4", index))
            try await compositeLayeredSegment(placements: placements, duration: segment.duration,
                                              output: segmentPath)

            // Captions burn after compositing so they sit on the final frame.
            var positioned: [(segment: TranscriptSegment, position: String?)] = []
            for clip in segment.clips {
                guard let captionPosition = clip.captionsPosition, let videoID = clip.videoID else { continue }
                let clipOffset = segment.start - clip.startTime
                let sourceStart = clip.sourceStart + clipOffset
                let sourceEnd = sourceStart + segment.duration
                let rows = (try? await database.transcriptSegments(videoID: videoID,
                                                                   start: sourceStart, end: sourceEnd)) ?? []
                for row in rows {
                    // Shift to segment-local time and clamp to the window,
                    // like db.py get_transcript_for_clip().
                    let start = max(0, row.start - sourceStart)
                    let end = min(segment.duration, row.end - sourceStart)
                    guard end > start else { continue }
                    positioned.append((TranscriptSegment(start: start, end: end, text: row.text, words: nil),
                                       captionPosition))
                }
            }
            if !positioned.isEmpty {
                let cappedPath = scratch.appendingPathComponent(String(format: "seg%03d_capped.mp4", index))
                do {
                    try await burnPositionedCaptions(video: segmentPath, captions: positioned,
                                                     renderer: captionRenderer, scratch: scratch,
                                                     output: cappedPath)
                    segmentPath = cappedPath
                } catch {
                    emit("Segment \(index + 1): caption burn failed, keeping uncaptioned (\(error))")
                }
            }

            clipPaths.append(segmentPath)
            if clipPaths.count > 1 {
                transitions.append(segment.clips.first?.transIn)
            }
        }

        var outroAdded = false
        if document.includeOutro, let outro = Self.assetURL(profile.outroVideo) {
            emit("Normalizing outro…")
            let normalized = scratch.appendingPathComponent("outro_norm.mp4")
            try await render.normalizeClip(source: outro, output: normalized)
            clipPaths.append(normalized)
            outroAdded = true
            if clipPaths.count > 1 { transitions.append("fade") }
        }

        guard !clipPaths.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "No segments could be rendered"])
        }
        while transitions.count < clipPaths.count - 1 { transitions.append(nil) }
        transitions = Array(transitions.prefix(max(0, clipPaths.count - 1)))

        emit("Assembling \(clipPaths.count) segment(s)…")
        var assembled = scratch.appendingPathComponent("assembled.mp4")
        if clipPaths.count == 1 {
            assembled = clipPaths[0]
        } else {
            try await render.concatenate(clips: clipPaths, transitions: transitions, output: assembled)
        }

        let videoDuration = await FFmpeg.duration(of: assembled)

        // Music track (blocks with silence-filled gaps + original-audio ducking).
        if !document.soundTrack.isEmpty {
            let musicLookup = Dictionary(uniqueKeysWithValues:
                WizardEngine.availableMusic().map { ($0.name, $0.url) })
            var blocks: [(start: Double, duration: Double, music: URL?, volume: Int)] = []
            for item in document.soundTrack.sorted(by: { $0.startTime < $1.startTime }) {
                guard let url = musicLookup[item.name] else { continue }
                blocks.append((item.startTime, item.duration, url, item.volume))
            }
            if !blocks.isEmpty {
                var filled: [(start: Double, duration: Double, music: URL?, volume: Int)] = []
                var soundCursor = 0.0
                for block in blocks {
                    if block.start > soundCursor + 0.05 {
                        filled.append((soundCursor, block.start - soundCursor, nil, 0))
                    }
                    filled.append(block)
                    soundCursor = block.start + block.duration
                }
                if soundCursor < videoDuration {
                    filled.append((soundCursor, videoDuration - soundCursor, nil, 0))
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
                    emit("Music overlay failed, continuing without music (\(error))")
                }
            }
        }

        // Text overlays — shifted past the intro, clamped before the outro.
        let introOffset = introAdded ? await FFmpeg.duration(of: clipPaths[0]) : 0
        let outroDuration = outroAdded ? await FFmpeg.duration(of: clipPaths[clipPaths.count - 1]) : 0
        let overlays = document.textOverlays
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { item in
                var shifted = item
                shifted.startTime = item.startTime + introOffset
                shifted.endTime = min(item.endTime + introOffset, videoDuration - outroDuration)
                return shifted
            }
            .filter { $0.endTime > $0.startTime }
        if !overlays.isEmpty {
            emit("Burning \(overlays.count) text overlay(s)…")
            let withText = scratch.appendingPathComponent("with_text.mp4")
            do {
                try await addTextOverlays(video: assembled, overlays: overlays,
                                          scratch: scratch, output: withText)
                assembled = withText
            } catch {
                emit("Text overlay failed, continuing without overlays (\(error))")
            }
        }

        try FileManager.default.copyItemReplacing(at: assembled, to: outputURL)
        let finalDuration = await FFmpeg.duration(of: outputURL)

        // Persist the COMPLETE editable document so "Open in Builder" (in
        // either app) restores every clip flag and layer setting.
        let encoder = JSONEncoder()
        let timelineJSON = (try? encoder.encode(document))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await database.insertGeneratedVideo(path: outputURL.path,
                                                duration: (finalDuration * 10).rounded() / 10,
                                                timelineJSON: timelineJSON,
                                                wizardProvider: nil, wizardModel: nil)
        emit("Saved \(outputURL.lastPathComponent)")
        return RenderResult(url: outputURL, duration: finalDuration)
    }

    // MARK: - Clip resolution

    /// Port of the resolve/effective-settings pass in _generate_multitrack.
    nonisolated static func resolveClips(document: TimelineDocument,
                                         scenes: [SceneRecord]) -> [ResolvedClip] {
        let scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let settings = document.trackSettings
        var resolved: [ResolvedClip] = []

        for clip in document.videoTrack {
            var sourcePath: String?
            var videoID: Int64?
            var sourceStart = 0.0
            var duration = 0.0
            if let sceneID = clip.sceneID, let scene = scenesByID[sceneID] {
                sourcePath = scene.videoPath
                videoID = scene.videoID
                sourceStart = clip.sourceStart ?? scene.startTime
                duration = clip.duration > 0 ? clip.duration : (scene.duration * 10).rounded() / 10
            } else if let file = clip.videoFile, let start = clip.sourceStart {
                sourcePath = file
                sourceStart = start
                duration = clip.duration > 0 ? clip.duration
                    : max(0, (clip.sourceEnd ?? start) - start)
            }
            guard let sourcePath, duration > 0 else { continue }

            let track = min(max(0, clip.track), 2)
            let trackSettings = settings[safe: track] ?? TrackSettings()
            let effectivePosition = clip.position ?? trackSettings.defaultPosition
            let effectiveCrop = clip.cropXFrac ?? trackSettings.defaultCropXFrac
            let muted = clip.muted || trackSettings.muted
            let captionsResolved = clip.captions == "inherit" ? trackSettings.captions : clip.captions

            resolved.append(ResolvedClip(sourcePath: sourcePath,
                                         videoID: videoID,
                                         sourceStart: sourceStart,
                                         startTime: clip.startTime,
                                         duration: duration,
                                         track: track,
                                         wide: clip.wide,
                                         stackOrder: clip.stackOrder,
                                         muted: muted,
                                         transIn: clip.transIn,
                                         transOut: clip.transOut,
                                         effectivePosition: effectivePosition,
                                         effectiveCropXFrac: clip.wide ? effectiveCrop : nil,
                                         freeCrops: clip.freeCrops,
                                         captionsPosition: captionsResolved == "none" ? nil : captionsResolved))
        }
        return resolved.sorted {
            ($0.track, $0.startTime, $0.stackOrder) < ($1.track, $1.startTime, $1.stackOrder)
        }
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
                segments.append(Segment(start: start, end: end, clips: active))
            }
        }
        return segments
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
                             + Self.encodeArgs + [output.path], timeout: 120)
    }

    /// Port of video.py composite_layered_segment(): black base canvas, each
    /// placement overlaid in (layer, stack order) order — non-wide clips fill
    /// the frame, cropped wides fill the frame through a 9:16 window, slot
    /// wides land in a 1080x640 band, free-crop rectangles composite in z
    /// order. Unmuted clip audio mixes via amix (silence when none).
    private func compositeLayeredSegment(placements: [Placement], duration: Double,
                                         output: URL) async throws {
        guard !placements.isEmpty else {
            try await generatePlaceholder(duration: duration, output: output)
            return
        }

        let ordered = placements.enumerated()
            .sorted { ($0.element.layer, $0.element.stackOrder, $0.offset)
                    < ($1.element.layer, $1.element.stackOrder, $1.offset) }
            .map(\.element)

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

        var filters: [String] = []
        var freeCropOutputs: [Int: [(label: String, x: Int, y: Int)]] = [:]

        for (index, placement) in ordered.enumerated() {
            let sourceIndex = index + 2
            if let crops = Self.normalizedFreeCrops(placement.freeCrops), !crops.isEmpty {
                let splitOuts = (0..<crops.count).map { "[s\(index)_\($0)]" }.joined()
                filters.append("[\(sourceIndex):v]setpts=PTS-STARTPTS,setsar=1,fps=30," +
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

            let wideCropped = placement.isWide && placement.cropXFrac != nil
            if wideCropped {
                let fraction = max(0, min(1, placement.cropXFrac ?? 0.5))
                filters.append(String(format: "[%d:v]setpts=PTS-STARTPTS," +
                                      "crop=ih*9/16:ih:(iw-ih*9/16)*%.4f:0," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceIndex, fraction, Self.width, Self.height,
                                      Self.width, Self.height, index))
            } else {
                let targetHeight = placement.isWide ? Self.slotHeight : Self.height
                filters.append(String(format: "[%d:v]setpts=PTS-STARTPTS," +
                                      "scale=%d:%d:force_original_aspect_ratio=decrease," +
                                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=black," +
                                      "setsar=1,fps=30[v%d]",
                                      sourceIndex, Self.width, targetHeight,
                                      Self.width, targetHeight, index))
            }
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
            overlaySteps.append(("v\(index)", 0, y))
        }
        var previous = "[0:v]"
        for (stepIndex, step) in overlaySteps.enumerated() {
            let outLabel = stepIndex == overlaySteps.count - 1 ? "[vout]" : "[ov\(stepIndex)]"
            filters.append("\(previous)[\(step.label)]overlay=x=\(step.x):y=\(step.y):shortest=0\(outLabel)")
            previous = outLabel
        }

        // Audio: mix unmuted clips that actually carry audio.
        var audioLabels: [String] = []
        for (index, placement) in ordered.enumerated() {
            guard !placement.muted else { continue }
            guard await FFmpeg.hasAudioStream(URL(fileURLWithPath: placement.sourcePath)) else { continue }
            filters.append("[\(index + 2):a]asetpts=PTS-STARTPTS[a\(index)]")
            audioLabels.append("[a\(index)]")
        }
        let audioSource: String
        if audioLabels.isEmpty {
            filters.append("[1:a]asetpts=PTS-STARTPTS[asilent]")
            audioSource = "[asilent]"
        } else if audioLabels.count == 1 {
            audioSource = audioLabels[0]
        } else {
            filters.append(audioLabels.joined() +
                           "amix=inputs=\(audioLabels.count):duration=longest:dropout_transition=0[amix]")
            audioSource = "[amix]"
        }

        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", "[vout]", "-map", audioSource,
            "-t", String(format: "%.3f", duration),
        ] + Self.encodeArgs + [output.path], timeout: 600)
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

    /// Burn caption PNGs with per-segment vertical positions — the builder's
    /// variant of RenderEngine.burnCaptions (positions vary per source clip).
    private func burnPositionedCaptions(video: URL,
                                        captions: [(segment: TranscriptSegment, position: String?)],
                                        renderer: CaptionRenderer, scratch: URL,
                                        output: URL) async throws {
        var arguments = ["-y", "-i", video.path]
        var filterParts: [String] = []
        var previous = "[0:v]"
        for (index, entry) in captions.enumerated() {
            let text = entry.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let rendered = try renderer.render(text: text, to: scratch)
            let (x, y) = renderer.position(for: rendered, positionOverride: entry.position)
            arguments += ["-i", rendered.pngURL.path]
            let inputIndex = filterParts.count + 1
            let label = index == captions.count - 1 ? "[vout]" : "[cap\(inputIndex)]"
            filterParts.append("\(previous)[\(inputIndex):v]overlay=x=\(x):y=\(y):" +
                               String(format: "enable='between(t,%.3f,%.3f)'",
                                      entry.segment.start, entry.segment.end) + label)
            previous = label
        }
        guard !filterParts.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        if var last = filterParts.popLast() {
            if !last.hasSuffix("[vout]"), let bracket = last.lastIndex(of: "[") {
                last = String(last[..<bracket]) + "[vout]"
            }
            filterParts.append(last)
        }
        try await FFmpeg.run(arguments + [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vout]", "-map", "0:a?",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
            "-c:a", "copy", "-pix_fmt", "yuv420p", output.path,
        ], timeout: 1200)
    }

    /// Port of video.py build_music_track(): concat per-block trimmed music
    /// (volume = level/5 × 0.7) and silence gaps, 2s fade-out at the end.
    private func buildMusicTrack(segments: [(start: Double, duration: Double, music: URL?, volume: Int)],
                                 totalDuration: Double, output: URL) async throws {
        var arguments = ["-y"]
        var filters: [String] = []
        var index = 0
        for segment in segments where segment.duration > 0 {
            let musicVolume = Double(segment.volume) / 5.0 * 0.7
            if let music = segment.music, musicVolume > 0 {
                arguments += ["-stream_loop", "-1", "-i", music.path]
                filters.append(String(format: "[%d:a]atrim=0:%.3f,asetpts=PTS-STARTPTS,volume=%.3f[s%d]",
                                      index, segment.duration, musicVolume, index))
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
        ], timeout: 600)
    }

    /// Port of video.py overlay_music_track(): duck the original audio per
    /// block (1 − level/5) and mix the pre-built music bed under it.
    private func overlayMusicTrack(video: URL, musicTrack: URL,
                                   segments: [(start: Double, duration: Double, music: URL?, volume: Int)],
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
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600)
        } else {
            try await FFmpeg.run(["-y", "-i", video.path, "-i", musicTrack.path,
                                  "-map", "0:v", "-map", "1:a",
                                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                  "-shortest", "-movflags", "+faststart", output.path], timeout: 600)
        }
    }

    /// Port of video.py add_multiple_text_overlays(): render each overlay to
    /// a full-frame PNG, loop it as an input, and composite with fade/slide
    /// expressions inside its enable window.
    private func addTextOverlays(video: URL, overlays: [TextOverlayItem],
                                 scratch: URL, output: URL) async throws {
        let renderer = TextOverlayRenderer(videoWidth: Self.width, videoHeight: Self.height)
        var arguments = ["-y", "-i", video.path]
        var filters: [String] = []
        var previous = "[0:v]"
        var inputIndex = 0
        let animDuration = 0.4

        for (index, overlay) in overlays.enumerated() {
            guard let pngURL = try? renderer.render(overlay, to: scratch) else { continue }
            inputIndex += 1
            let start = overlay.startTime
            let end = overlay.endTime
            let duration = end - start
            let anim = min(animDuration, duration / 3)
            arguments += ["-loop", "1", "-t", String(format: "%.2f", duration + 1), "-i", pngURL.path]

            var current = "[\(inputIndex):v]"
            let fadeIn = overlay.transIn == "fade"
            let fadeOut = overlay.transOut == "fade"
            if fadeIn || fadeOut {
                var fadeParts = ["format=rgba"]
                if fadeIn { fadeParts.append(String(format: "fade=t=in:st=0:d=%.3f:alpha=1", anim)) }
                if fadeOut { fadeParts.append(String(format: "fade=t=out:st=%.3f:d=%.3f:alpha=1",
                                                     duration - anim, anim)) }
                let label = "[tf\(index)]"
                filters.append("\(current)\(fadeParts.joined(separator: ","))\(label)")
                current = label
            }

            let outLabel = "[txt\(index)]"
            let slideIn = overlay.transIn.hasPrefix("slide_")
            let slideOut = overlay.transOut.hasPrefix("slide_")
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
                               String(format: "enable='between(t,%.3f,%.3f)'", start, end) + outLabel)
            } else {
                filters.append("\(previous)\(current)overlay=0:0:" +
                               String(format: "enable='between(t,%.3f,%.3f)':shortest=0", start, end) + outLabel)
            }
            previous = outLabel
        }

        guard !filters.isEmpty else {
            try FileManager.default.copyItemReplacing(at: video, to: output)
            return
        }
        try await FFmpeg.run(arguments + [
            "-filter_complex", filters.joined(separator: ";"),
            "-map", previous, "-map", "0:a?",
            "-c:v", "libx264", "-preset", "fast", "-crf", "23",
            "-c:a", "copy", "-movflags", "+faststart", output.path,
        ], timeout: 900)
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
            default: return "0"
            }
        } else {
            let exitStart = time - anim
            switch (axis, direction) {
            case ("x", "left"): return String(format: "if(gt(t,%.3f),-W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("x", "right"): return String(format: "if(gt(t,%.3f),W*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "up"): return String(format: "if(gt(t,%.3f),-H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            case ("y", "down"): return String(format: "if(gt(t,%.3f),H*(t-%.3f)/%.3f,0)", exitStart, exitStart, anim)
            default: return "0"
            }
        }
    }

    // MARK: - Output naming

    private nonisolated static func assetURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
    }

    /// <output>/<YYYY-MM-DD>/hl-<duration>-<n>.mp4, sharing the per-day
    /// counter with the Python builder (it scans every mp4's trailing number).
    private nonisolated static func outputFile(profile: BrandProfile,
                                               totalDuration: Double) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = profile.outputFolderURL
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
}
