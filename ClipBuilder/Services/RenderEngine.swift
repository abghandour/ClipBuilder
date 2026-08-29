import Foundation
import Vision

/// Headless linear render engine — the Swift port of video.py's wizard path:
/// trim → normalize to 1080x1920@30 → concat with xfade transitions → music
/// overlay → caption/text burn-in. Multi-track compositing (the manual
/// builder) is intentionally out of scope for now.
actor RenderEngine {
    static let outputWidth = 1080
    static let outputHeight = 1920

    /// xfade transition names accepted by the planner (video.py TRANSITIONS).
    static let transitions: [String] = [
        "fade", "fadeblack", "fadewhite", "wipeleft", "wiperight", "wipeup", "wipedown",
        "slideleft", "slideright", "circlecrop", "circleopen", "circleclose", "radial",
        "dissolve", "smoothleft", "smoothright", "diagtl", "diagbr", "horzopen", "horzclose",
        "vertopen", "vertclose", "hlslice", "hrslice", "zoomin",
        "coverleft", "coverright", "revealleft", "revealright", "pixelize",
    ]

    /// Action-pack transitions: recipe bridges (TransitionRecipes) plus the
    /// flash cuts, which are just very short xfades (see `xfadeAliases`).
    static let actionTransitions: [String] =
        TransitionRecipes.names + ["flash_white", "flash_black"]

    /// Every name the timeline/planner may carry (hard cut is nil / "cut").
    static let allTransitions: [String] = actionTransitions + transitions

    /// Action names that resolve to a plain xfade with a fixed short
    /// duration — 0.12s of fadewhite reads as a flash frame, not a fade.
    static let xfadeAliases: [String: (name: String, duration: Double)] = [
        "flash_white": ("fadewhite", 0.12),
        "flash_black": ("fadeblack", 0.12),
    ]

    /// Timeline seconds a transition at a gap consumes (its overlap): plain
    /// xfades consume the configured crossfade duration, flash cuts their
    /// fixed 0.12s, recipes whatever their bridge eats, hard cuts nothing.
    /// The wizard's duration math and beat snapping share this.
    nonisolated static func consumedOverlap(_ name: String?, xfadeDuration: Double) -> Double {
        guard let name, name != "cut" else { return 0 }
        if let alias = xfadeAliases[name] { return alias.duration }
        if TransitionRecipes.isRecipe(name) { return TransitionRecipes.consumedOverlap(for: name) }
        return xfadeDuration
    }

    private let workDirectory: URL

    init() {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBuilderRender", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    func makeScratchDirectory() throws -> URL {
        let dir = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let normalizeFilter =
        "scale=\(outputWidth):\(outputHeight):force_original_aspect_ratio=decrease," +
        "pad=\(outputWidth):\(outputHeight):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=30"

    // MARK: - Subclip extraction

    /// A PNG composited over a clip during extraction (caption or text
    /// overlay). `start`/`end` bound the enable window in clip-local time;
    /// nil shows the overlay for the whole clip.
    ///
    /// `animation` ("fade" | "pop" | "slide_up") animates the overlay in and
    /// fades it out. Animated overlays must be full-frame PNGs shown for the
    /// whole clip (start/end nil) — the timing expressions assume clip-local
    /// time starting at 0.
    nonisolated struct ClipOverlay: Sendable {
        var png: URL
        var x: Int
        var y: Int
        var start: Double?
        var end: Double?
        var animation: String?
    }

    /// How a wide (landscape) source fills the portrait frame.
    nonisolated enum WideTreatment: Sendable {
        case none                 // letterbox/normalize
        case autoCrop(Double)     // 9:16 window at the given x fraction
        case split                // left/right halves stacked top/bottom
    }

    /// Baked-in letterbox detection result: the sub-rect of the source that
    /// holds real footage (screen recordings and reposts bake black bars into
    /// the pixels), as frame fractions with a top-left origin.
    nonisolated struct ContentBox: Sendable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        /// Pixel aspect of the content region (width / height).
        var aspect: Double

        var isWide: Bool { aspect > 1.05 }
    }

    /// Trim [start, start+duration], normalize to portrait 1080x1920@30, and
    /// burn any overlays — all in ONE decode→encode pass (captions, text and
    /// mute used to be separate full re-encodes). Sources without audio get a
    /// silent stereo track so every intermediate clip is concat-compatible.
    /// `mask` is a screen-crop PNG (white = visible): the finished frame is
    /// alpha-masked with it and composited over black, so only the named
    /// area of the clip shows.
    func extractClip(source: URL, start: Double, duration: Double,
                     wide: WideTreatment = .none,
                     contentBox: ContentBox? = nil,
                     overlays: [ClipOverlay] = [],
                     mute: Bool = false,
                     speed: Double = 1,
                     mask: URL? = nil,
                     output: URL) async throws {
        let hasAudio = mute ? false : await FFmpeg.hasAudioStream(source)
        var arguments = ["-y", "-ss", String(format: "%.2f", start), "-i", source.path]
        if !hasAudio { arguments += ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo"] }
        let overlayBase = hasAudio ? 1 : 2
        for overlay in overlays {
            if overlay.animation != nil {
                // Fade needs a real stream to act on, not a single still frame.
                arguments += ["-loop", "1", "-t", String(format: "%.2f", duration),
                              "-i", overlay.png.path]
            } else {
                arguments += ["-i", overlay.png.path]
            }
        }
        let maskIndex = overlayBase + overlays.count
        if let mask {
            arguments += ["-loop", "1", "-t", String(format: "%.2f", duration), "-i", mask.path]
        }

        var filters: [String] = []
        // With a mask, the overlay chain's result is an intermediate the
        // masking stage turns into [vout].
        let finalLabel = mask == nil ? "[vout]" : "[premask]"
        let baseLabel = overlays.isEmpty ? finalLabel : "[base]"
        // Baked-in bars come off first, so the wide treatments below see the
        // real footage; every later iw/ih refers to the cropped stream.
        var sourceStream = "[0:v]"
        if let box = contentBox {
            filters.append(String(format: "[0:v]crop=iw*%.4f:ih*%.4f:iw*%.4f:ih*%.4f[content]",
                                  box.w, box.h, box.x, box.y))
            sourceStream = "[content]"
        }
        // Slow motion (replay/payoff moments): stretch video timestamps;
        // the matching audio tempo change rides on the -af below.
        if speed != 1 {
            filters.append(String(format: "%@setpts=PTS/%.4f[speed]", sourceStream, speed))
            sourceStream = "[speed]"
        }
        switch wide {
        case .none:
            filters.append("\(sourceStream)\(Self.normalizeFilter)\(baseLabel)")
        case .autoCrop(let xFraction):
            filters.append(String(format: "%@crop=ih*9/16:ih:(iw-ih*9/16)*%.4f:0," +
                                  "scale=%d:%d,setsar=1,fps=30%@",
                                  sourceStream, xFraction, Self.outputWidth, Self.outputHeight, baseLabel))
        case .split:
            let half = Self.outputHeight / 2
            filters.append("""
            \(sourceStream)split=2[left][right];\
            [left]crop=iw/2:ih:0:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
            crop=\(Self.outputWidth):\(half)[top];\
            [right]crop=iw/2:ih:iw/2:0,scale=\(Self.outputWidth):\(half):force_original_aspect_ratio=increase,\
            crop=\(Self.outputWidth):\(half)[bottom];\
            [top][bottom]vstack,setsar=1,fps=30\(baseLabel)
            """)
        }

        // Overlay chain (single-frame PNG inputs persist via repeatlast).
        var previous = baseLabel
        for (index, overlay) in overlays.enumerated() {
            let outLabel = index == overlays.count - 1 ? finalLabel : "[ovl\(index)]"
            var inputLabel = "[\(overlayBase + index):v]"
            var xExpr = "\(overlay.x)"
            var yExpr = "\(overlay.y)"
            if let animation = overlay.animation {
                // Clip-local time starts at 0; the overlay runs the whole clip.
                let anim = min(0.4, max(0.15, duration / 3))
                let fadeInDuration = animation == "fade" ? anim : min(0.18, anim)
                let animLabel = "[anim\(index)]"
                filters.append(inputLabel + "format=rgba," +
                               String(format: "fade=t=in:st=0:d=%.3f:alpha=1,", fadeInDuration) +
                               String(format: "fade=t=out:st=%.3f:d=%.3f:alpha=1", duration - anim, anim) +
                               animLabel)
                inputLabel = animLabel
                switch animation {
                case "pop":
                    // Rise-settle: drop in from 5% below with a cubic ease-out.
                    yExpr = String(format: "'if(lt(t,%.3f),round(H*0.05*pow(1-t/%.3f,3)),0)'", anim, anim)
                case "slide_up":
                    yExpr = String(format: "'if(lt(t,%.3f),H-H*t/%.3f,0)'", anim, anim)
                default:
                    break
                }
            }
            var step = "\(previous)\(inputLabel)overlay=x=\(xExpr):y=\(yExpr)"
            if let windowStart = overlay.start, let windowEnd = overlay.end {
                step += String(format: ":enable='between(t,%.3f,%.3f)'", windowStart, windowEnd)
            }
            filters.append(step + outLabel)
            previous = outLabel
        }
        if mask != nil {
            filters.append("[\(maskIndex):v]format=gray,scale=\(Self.outputWidth):\(Self.outputHeight)[maskv]")
            filters.append("\(finalLabel)[maskv]alphamerge[masked]")
            filters.append(String(format: "color=c=black:s=%dx%d:r=30:d=%.2f[maskbg]",
                                  Self.outputWidth, Self.outputHeight, duration))
            filters.append("[maskbg][masked]overlay=shortest=1,format=yuv420p[vout]")
        }

        arguments += ["-filter_complex", filters.joined(separator: ";"),
                      "-map", "[vout]", "-map", hasAudio ? "0:a" : "1:a"]
        if speed != 1, hasAudio {
            arguments += ["-af", String(format: "atempo=%.4f", min(2, max(0.5, speed)))]
        }
        arguments += ["-t", String(format: "%.2f", duration)]
        try await FFmpeg.run(arguments + FFmpeg.encodeArgs + [output.path], timeout: 900)
    }

    /// A screen-crop layout block: every entry is a normalized 1080×1920
    /// clip already framed into its area, paired with the area's mask PNG.
    /// Each is alpha-masked and stacked over black; the first entry's audio
    /// is the block's audio. Shorter entries hold their last frame.
    func compositeAreas(_ entries: [(clip: URL, mask: URL)], duration: Double,
                        output: URL) async throws {
        guard !entries.isEmpty else { throw AIError.unusableResponse("A layout block needs at least one area clip.") }
        let w = Self.outputWidth
        let h = Self.outputHeight
        var arguments: [String] = ["-y", "-f", "lavfi", "-i",
                                   String(format: "color=c=black:s=%dx%d:r=30:d=%.3f", w, h, duration)]
        var filters: [String] = []
        var previous = "[0:v]"
        for (index, entry) in entries.enumerated() {
            let clipIndex = 1 + index * 2
            let maskIndex = clipIndex + 1
            arguments += ["-i", entry.clip.path,
                          "-loop", "1", "-t", String(format: "%.3f", duration), "-i", entry.mask.path]
            filters.append("[\(maskIndex):v]format=gray,scale=\(w):\(h)[mk\(index)]")
            filters.append("[\(clipIndex):v]scale=\(w):\(h),setsar=1,fps=30[v\(index)]")
            filters.append("[v\(index)][mk\(index)]alphamerge[am\(index)]")
            let outLabel = index == entries.count - 1 ? "[stack]" : "[o\(index)]"
            filters.append("\(previous)[am\(index)]overlay=x=0:y=0:shortest=0:eof_action=repeat\(outLabel)")
            previous = outLabel
        }
        filters.append("[stack]format=yuv420p[vout]")
        arguments += ["-filter_complex", filters.joined(separator: ";"),
                      "-map", "[vout]", "-map", "1:a?",
                      "-t", String(format: "%.3f", duration)]
        arguments += FFmpeg.encodeArgs
        arguments.append(output.path)
        try await FFmpeg.run(arguments, timeout: 900)
    }

    /// Plain trim + normalize (no overlays).
    func extractSubclip(source: URL, start: Double, duration: Double, output: URL) async throws {
        try await extractClip(source: source, start: start, duration: duration, output: output)
    }

    /// Re-encode an arbitrary clip (intro/outro) to the standard format.
    func normalizeClip(source: URL, output: URL) async throws {
        let duration = await FFmpeg.duration(of: source)
        try await extractSubclip(source: source, start: 0, duration: max(duration, 0.1), output: output)
    }

    // MARK: - Wide-source handling

    /// Detect baked-in black bars (screen recordings, reposted reels): rows
    /// and columns that stay black across sampled frames are bars; what's
    /// left is the content box. Returns nil when the content effectively
    /// fills the frame or detection is unreliable (dark footage).
    func detectContentBox(source: URL, start: Double, duration: Double) async -> ContentBox? {
        let frames: [(pixels: [UInt8], width: Int, height: Int)] =
            await withTaskGroup(of: (pixels: [UInt8], width: Int, height: Int)?.self) { group in
                for i in 0..<5 {
                    let t = start + duration * (0.1 + 0.8 * Double(i) / 4.0)
                    group.addTask {
                        await ThumbnailService.grayscaleFrame(url: source, at: t, width: 256)
                    }
                }
                var collected: [(pixels: [UInt8], width: Int, height: Int)] = []
                for await frame in group where frame != nil {
                    collected.append(frame!)
                }
                return collected
            }
        guard let first = frames.first else { return nil }
        let width = first.width
        let height = first.height
        guard width > 0, height > 0,
              frames.allSatisfy({ $0.width == width && $0.height == height }) else { return nil }

        // A row/column is "lit" if any sampled frame has a pixel above the
        // compression-noise floor there.
        var rowMax = [UInt8](repeating: 0, count: height)
        var columnMax = [UInt8](repeating: 0, count: width)
        for frame in frames {
            frame.pixels.withUnsafeBufferPointer { pixels in
                var offset = 0
                for y in 0..<height {
                    for x in 0..<width {
                        let v = pixels[offset]
                        offset += 1
                        if v > rowMax[y] { rowMax[y] = v }
                        if v > columnMax[x] { columnMax[x] = v }
                    }
                }
            }
        }
        let threshold: UInt8 = 32
        guard let top = rowMax.firstIndex(where: { $0 > threshold }),
              let bottom = rowMax.lastIndex(where: { $0 > threshold }),
              let left = columnMax.firstIndex(where: { $0 > threshold }),
              let right = columnMax.lastIndex(where: { $0 > threshold }),
              bottom > top, right > left else { return nil }

        // Inset one sample pixel so soft bar edges don't leave a seam.
        let contentWidth = Double(right - left - 1)
        let contentHeight = Double(bottom - top - 1)
        // Unreliable when almost everything is black (night footage, fades).
        guard contentWidth >= Double(width) * 0.2, contentHeight >= Double(height) * 0.2 else { return nil }
        // No meaningful bars — don't add a useless crop stage.
        guard contentWidth < Double(width) * 0.94 || contentHeight < Double(height) * 0.94 else { return nil }
        // The sample preserves the source aspect, so content aspect is
        // directly measurable in sample pixels.
        return ContentBox(x: Double(left + 1) / Double(width),
                          y: Double(top + 1) / Double(height),
                          w: contentWidth / Double(width),
                          h: contentHeight / Double(height),
                          aspect: contentWidth / contentHeight)
    }

    /// Score horizontal crop positions across sampled frames: 0.4·detail
    /// (column stdev) + 0.6·motion (frame-to-frame column diff), sliding a
    /// 9:16 window to find the busiest region. Port of auto_crop_x_frac.
    /// A `contentBox` restricts scoring to the real footage; the returned
    /// fraction is then relative to the box, matching the pre-cropped stream.
    func autoCropXFraction(source: URL, start: Double, duration: Double,
                           contentBox: ContentBox? = nil) async -> Double {
        // Grab the sample frames concurrently — each is an independent
        // AVAssetImageGenerator (or ffmpeg fallback) call.
        let frames: [(pixels: [UInt8], width: Int, height: Int)] =
            await withTaskGroup(of: (Int, (pixels: [UInt8], width: Int, height: Int)?).self) { group in
                for i in 0..<7 {
                    let fraction = 0.05 + 0.90 * Double(i) / 6.0
                    let t = start + duration * fraction
                    group.addTask {
                        (i, await ThumbnailService.grayscaleFrame(url: source, at: t, width: 384))
                    }
                }
                var collected: [(Int, (pixels: [UInt8], width: Int, height: Int))] = []
                for await (i, frame) in group {
                    if let frame { collected.append((i, frame)) }
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
        guard frames.count >= 2, let first = frames.first else { return 0.5 }
        let width = first.width
        let height = first.height
        guard frames.allSatisfy({ $0.width == width && $0.height == height }), width > 0, height > 0 else {
            return 0.5
        }

        // Column detail: stdev down each column, averaged across frames.
        // (Row-major scans with per-column accumulators for cache locality.)
        var detail = [Double](repeating: 0, count: width)
        for frame in frames {
            var sums = [Double](repeating: 0, count: width)
            var squares = [Double](repeating: 0, count: width)
            frame.pixels.withUnsafeBufferPointer { pixels in
                var offset = 0
                for _ in 0..<height {
                    for x in 0..<width {
                        let v = Double(pixels[offset])
                        offset += 1
                        sums[x] += v
                        squares[x] += v * v
                    }
                }
            }
            for x in 0..<width {
                let mean = sums[x] / Double(height)
                detail[x] += max(0, squares[x] / Double(height) - mean * mean).squareRoot()
            }
        }
        // Column motion: mean abs diff between consecutive frames.
        var motion = [Double](repeating: 0, count: width)
        for index in 1..<frames.count {
            var diffs = [Double](repeating: 0, count: width)
            frames[index - 1].pixels.withUnsafeBufferPointer { a in
                frames[index].pixels.withUnsafeBufferPointer { b in
                    var offset = 0
                    for _ in 0..<height {
                        for x in 0..<width {
                            diffs[x] += abs(Double(b[offset]) - Double(a[offset]))
                            offset += 1
                        }
                    }
                }
            }
            for x in 0..<width {
                motion[x] += diffs[x] / Double(height)
            }
        }

        func normalized(_ values: [Double]) -> [Double] {
            guard let maxValue = values.max(), maxValue > 0 else { return values }
            return values.map { $0 / maxValue }
        }
        let normalizedDetail = normalized(detail)
        let normalizedMotion = normalized(motion)
        let score = (0..<width).map { 0.4 * normalizedDetail[$0] + 0.6 * normalizedMotion[$0] }

        // Slide within the content box when one was detected — the crop
        // window's height is the content height, and the returned fraction
        // must be relative to the pre-cropped stream.
        let x0 = contentBox.map { Int((Double(width) * $0.x).rounded()) } ?? 0
        let contentWidth = contentBox.map { Int((Double(width) * $0.w).rounded()) } ?? width
        let contentHeight = contentBox.map { Double(height) * $0.h } ?? Double(height)
        let targetWidth = Int((contentHeight * 9.0 / 16.0).rounded())
        guard targetWidth > 0, targetWidth < contentWidth, x0 + contentWidth <= width else { return 0.5 }

        // People anchor the search: when the main subjects are found, the
        // busyness scan only refines within ±30% of the crop width around
        // them — the action fine-tunes the position, but the crop can no
        // longer drift off to a busy crowd or scoreboard and cut people off.
        var lowerBound = x0
        var upperBound = x0 + contentWidth - targetWidth
        if let peopleCenter = await Self.peopleCenterX(source: source, start: start, duration: duration) {
            let desired = min(max(Int((peopleCenter * Double(width)).rounded()) - targetWidth / 2,
                                  lowerBound), upperBound)
            let deviation = Int(0.3 * Double(targetWidth))
            lowerBound = max(lowerBound, desired - deviation)
            upperBound = min(upperBound, desired + deviation)
        }

        var prefix: [Double] = [0]
        prefix.reserveCapacity(width + 1)
        for value in score { prefix.append(prefix[prefix.count - 1] + value) }
        func windowSum(_ left: Int) -> Double { prefix[left + targetWidth] - prefix[left] }
        var bestLeft = lowerBound
        var bestSum = windowSum(lowerBound)
        for left in lowerBound...upperBound where windowSum(left) > bestSum {
            bestSum = windowSum(left)
            bestLeft = left
        }
        return min(1, max(0, Double(bestLeft - x0) / Double(contentWidth - targetWidth)))
    }

    /// Median horizontal center (fraction of frame width) of the primary
    /// people across three sampled frames of the clip; nil when nobody is
    /// detected. Uses the same detector and peripheral-people filter as the
    /// analyzer's portrait-fit pass, so crops and previews agree on who the
    /// subjects are.
    static func peopleCenterX(source: URL, start: Double, duration: Double) async -> Double? {
        var centers: [Double] = []
        for fraction in [0.25, 0.5, 0.75] {
            guard let data = await ThumbnailService.jpegFrame(url: source, at: start + duration * fraction,
                                                              maxDimension: 720) else { continue }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try? VNImageRequestHandler(data: data).perform([request])
            let boxes = Analyzer.primaryPeopleBoxes((request.results ?? []).map(\.boundingBox))
            guard !boxes.isEmpty else { continue }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            centers.append(Double(union.midX))
        }
        guard !centers.isEmpty else { return nil }
        return centers.sorted()[centers.count / 2]
    }

    // MARK: - Concatenation

    /// Concatenate normalized clips with per-gap transitions or hard cuts —
    /// the port of video.py concatenate_clips(). Each transitions entry is an
    /// xfade name, an action recipe name, "cut"/nil (hard cut). Recipe gaps
    /// are resolved first into trimmed clips + rendered bridge segments; the
    /// rest groups consecutive xfade-joined clips, xfades within each group,
    /// then plain-concats the groups. Falls back to the concat demuxer on
    /// degenerate durations.
    func concatenate(clips: [URL], transitions: [String?], output: URL) async throws {
        guard !clips.isEmpty else { return }
        if clips.count == 1 {
            try FileManager.default.copyItemReplacing(at: clips[0], to: output)
            return
        }
        var padded = transitions.map { $0 == "cut" ? nil : $0 }
        while padded.count < clips.count - 1 { padded.append(nil) }
        padded = Array(padded.prefix(clips.count - 1))

        // Recipe gaps produce intermediate files that must live until the
        // final concat below, so their scratch is cleaned at function exit.
        var recipeScratch: URL?
        defer { if let recipeScratch { try? FileManager.default.removeItem(at: recipeScratch) } }
        var clips = clips
        if padded.contains(where: { TransitionRecipes.isRecipe($0) }) {
            let scratch = try makeScratchDirectory()
            recipeScratch = scratch
            (clips, padded) = try await resolveRecipeGaps(clips: clips, transitions: padded,
                                                          scratch: scratch)
        }

        if padded.allSatisfy({ $0 == nil }) {
            try await concatPlain(clips: clips, output: output)
            return
        }
        if padded.allSatisfy({ $0 != nil }) {
            do {
                try await xfadeAll(clips: clips, transitions: padded.compactMap { $0 }, output: output)
            } catch {
                try await concatPlain(clips: clips, output: output)
            }
            return
        }

        // Mixed: group runs of transition-joined clips.
        var groups: [(clips: [URL], transitions: [String])] = []
        var currentClips = [clips[0]]
        var currentTransitions: [String] = []
        for index in 1..<clips.count {
            if let name = padded[index - 1] {
                currentClips.append(clips[index])
                currentTransitions.append(name)
            } else {
                groups.append((currentClips, currentTransitions))
                currentClips = [clips[index]]
                currentTransitions = []
            }
        }
        groups.append((currentClips, currentTransitions))

        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var groupOutputs: [URL] = []
        for (index, group) in groups.enumerated() {
            if group.clips.count == 1 {
                groupOutputs.append(group.clips[0])
            } else {
                let groupOutput = scratch.appendingPathComponent("group_\(index).mp4")
                do {
                    try await xfadeAll(clips: group.clips, transitions: group.transitions, output: groupOutput)
                } catch {
                    try await concatPlain(clips: group.clips, output: groupOutput)
                }
                groupOutputs.append(groupOutput)
            }
        }
        if groupOutputs.count == 1 {
            try FileManager.default.copyItemReplacing(at: groupOutputs[0], to: output)
        } else {
            try await concatPlain(clips: groupOutputs, output: output)
        }
    }

    // MARK: - Action recipe bridges

    /// Replace every gap carrying a TransitionRecipes name with three pieces:
    /// the outgoing clip minus its tail, a rendered bridge segment, and the
    /// incoming clip minus its head — all hard-cut. Gaps whose clips are too
    /// short, and bridges that fail to render, degrade to plain hard cuts.
    private func resolveRecipeGaps(clips: [URL], transitions: [String?], scratch: URL)
        async throws -> (clips: [URL], transitions: [String?]) {
        let durations = try await BoundedConcurrency.map(clips, limit: FFmpeg.jobLimit) { _, clip in
            await FFmpeg.duration(of: clip)
        }
        let sfxEnabled = SettingsStore.loadSettings().transitions.sfxEnabled

        // A clip must keep >= 0.4s of real content after losing its head to
        // the previous gap's recipe and its tail to the next gap's.
        let minRemainder = 0.4
        var headTrim = [Double](repeating: 0, count: clips.count)
        var tailTrim = [Double](repeating: 0, count: clips.count)
        var recipe = [String?](repeating: nil, count: transitions.count)
        for gap in transitions.indices {
            guard let name = transitions[gap], TransitionRecipes.isRecipe(name) else { continue }
            let (tail, head) = TransitionRecipes.pieces(for: name)
            // The incoming clip may still lose its own tail to the NEXT gap's
            // recipe — that gap's check sees headTrim[gap + 1] and guards it.
            guard durations[gap] - headTrim[gap] - tail >= minRemainder,
                  durations[gap + 1] - head >= minRemainder else { continue }
            recipe[gap] = name
            tailTrim[gap] = tail
            headTrim[gap + 1] = head
        }

        // Render every bridge; a failed bridge reverts its gap to a hard cut.
        struct Bridge: Sendable { var gap: Int; var url: URL? }
        let plans: [(gap: Int, name: String)] = recipe.indices.compactMap { gap in
            recipe[gap].map { (gap, $0) }
        }
        let bridges = try await BoundedConcurrency.map(plans, limit: FFmpeg.jobLimit) { _, plan -> Bridge in
            let (gap, name) = plan
            let (tail, head) = TransitionRecipes.pieces(for: name)
            do {
                var tailPiece: URL?
                var headPiece: URL?
                var lastFrame: URL?
                if tail > 0 {
                    tailPiece = scratch.appendingPathComponent("tail_\(gap).mp4")
                    try await Self.trim(clips[gap], from: durations[gap] - tail,
                                        duration: tail, output: tailPiece!)
                }
                if head > 0 {
                    headPiece = scratch.appendingPathComponent("head_\(gap).mp4")
                    try await Self.trim(clips[gap + 1], from: 0, duration: head, output: headPiece!)
                }
                if name == "knife_slash" {
                    lastFrame = scratch.appendingPathComponent("last_\(gap).png")
                    try await FFmpeg.run(["-y", "-ss", String(format: "%.3f", max(0, durations[gap] - 0.05)),
                                          "-i", clips[gap].path, "-frames:v", "1",
                                          "-update", "1", lastFrame!.path], timeout: 60)
                }
                var sfx: URL?
                if sfxEnabled, let kind = TransitionSFX.kind(for: name) {
                    sfx = await TransitionSFX.url(for: kind, in: scratch)
                }
                let bridge = scratch.appendingPathComponent("bridge_\(gap).mp4")
                try await TransitionRecipes.renderBridge(name: name, tailPiece: tailPiece,
                                                         headPiece: headPiece, lastFrameA: lastFrame,
                                                         sfx: sfx, output: bridge)
                return Bridge(gap: gap, url: bridge)
            } catch {
                return Bridge(gap: gap, url: nil)
            }
        }
        let bridgeByGap = Dictionary(uniqueKeysWithValues: bridges.map { ($0.gap, $0.url) })
        for plan in plans where (bridgeByGap[plan.gap] ?? nil) == nil {
            recipe[plan.gap] = nil
            tailTrim[plan.gap] = 0
            headTrim[plan.gap + 1] = 0
        }

        // Trim the source clips that lost a head and/or tail to a bridge.
        let headTrims = headTrim
        let tailTrims = tailTrim
        let trimmed = try await BoundedConcurrency.map(Array(clips.indices),
                                                       limit: FFmpeg.jobLimit) { _, index -> URL in
            guard headTrims[index] > 0 || tailTrims[index] > 0 else { return clips[index] }
            let remainder = durations[index] - headTrims[index] - tailTrims[index]
            let url = scratch.appendingPathComponent("trimmed_\(index).mp4")
            try await Self.trim(clips[index], from: headTrims[index],
                                duration: remainder, output: url)
            return url
        }

        var outClips: [URL] = [trimmed[0]]
        var outTransitions: [String?] = []
        for gap in transitions.indices {
            if recipe[gap] != nil, let bridge = bridgeByGap[gap] ?? nil {
                outTransitions.append(nil)
                outClips.append(bridge)
                outTransitions.append(nil)
            } else {
                outTransitions.append(TransitionRecipes.isRecipe(transitions[gap]) ? nil : transitions[gap])
            }
            outClips.append(trimmed[gap + 1])
        }
        return (outClips, outTransitions)
    }

    /// Frame-accurate re-encoded sub-clip of a normalized intermediate.
    private nonisolated static func trim(_ source: URL, from start: Double,
                                         duration: Double, output: URL) async throws {
        try await FFmpeg.run(["-y", "-ss", String(format: "%.3f", max(0, start)),
                              "-i", source.path,
                              "-t", String(format: "%.3f", duration)]
                             + FFmpeg.encodeArgs + [output.path], timeout: 300)
    }

    /// xfade every gap in one pass with per-gap transition durations (flash
    /// cuts run 0.12s, regular crossfades the configured duration); throws
    /// when durations can't support the crossfades so callers can fall back
    /// to a plain concat.
    private func xfadeAll(clips: [URL], transitions: [String], output: URL) async throws {
        let durations = try await BoundedConcurrency.map(clips, limit: FFmpeg.jobLimit) { _, clip in
            await FFmpeg.duration(of: clip)
        }
        let configured = SettingsStore.loadSettings().transitions.xfadeDuration

        // Resolve each gap to (xfade name, requested duration), then clamp to
        // what the adjoining clips can afford. Any gap that can't fit even a
        // minimal crossfade sinks the whole pass to plain concat.
        var resolved: [(name: String, duration: Double)] = []
        for index in 0..<(clips.count - 1) {
            let raw = transitions[safe: index] ?? "fade"
            let (name, requested) = Self.xfadeAliases[raw]
                ?? (Self.transitions.contains(raw) ? raw : "fade", configured)
            let affordable = min(durations[index], durations[index + 1]) * 0.4
            let actual = min(requested, affordable)
            guard actual >= 0.05 else { throw CocoaError(.featureUnsupported) }
            resolved.append((name, actual))
        }

        var arguments = ["-y"]
        for clip in clips {
            arguments += ["-i", clip.path]
        }

        var filterParts: [String] = []
        var previousVideo = "[0:v]"
        var previousAudio = "[0:a]"
        var offset = durations[0] - resolved[0].duration
        for index in 1..<clips.count {
            let gap = resolved[index - 1]
            let outVideo = index == clips.count - 1 ? "[vout]" : "[v\(index)]"
            let outAudio = index == clips.count - 1 ? "[aout]" : "[a\(index)]"
            filterParts.append("\(previousVideo)[\(index):v]xfade=transition=\(gap.name):" +
                               String(format: "duration=%.3f:offset=%.3f", gap.duration, offset) + outVideo)
            filterParts.append("\(previousAudio)[\(index):a]acrossfade=" +
                               String(format: "d=%.3f", gap.duration) + outAudio)
            previousVideo = outVideo
            previousAudio = outAudio
            if index < clips.count - 1 {
                offset += durations[index] - resolved[index].duration
            }
        }

        try await FFmpeg.run(arguments + [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vout]", "-map", "[aout]",
        ] + FFmpeg.encodeArgs + [output.path], timeout: 1800)
    }

    /// Every input is one of our own normalized intermediates (identical
    /// codec/resolution/fps/pixel format), so the video stream can be
    /// stream-copied — a sub-second remux instead of re-encoding the whole
    /// timeline. Audio is re-encoded (fast) to smooth AAC priming gaps at
    /// the joins.
    private func concatPlain(clips: [URL], output: URL) async throws {
        let listFile = workDirectory.appendingPathComponent("concat_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listFile) }
        let listing = clips
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listing.write(to: listFile, atomically: true, encoding: .utf8)
        try await FFmpeg.run(["-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
                              "-c:v", "copy"] + FFmpeg.audioEncodeArgs +
                             ["-movflags", "+faststart", output.path],
                             timeout: 600)
    }

    // MARK: - Audio

    /// Mix a music bed under the video: music at 0.18 (0.25 when the video
    /// is silent), with a 2s fade-out at the end. Port of overlay_music().
    func overlayMusic(video: URL, music: URL, output: URL) async throws {
        let duration = await FFmpeg.duration(of: video)
        let fadeStart = max(0, duration - 2.0)
        let hasAudio = await FFmpeg.hasAudioStream(video)
        if hasAudio {
            let filter = String(format: "[1:a]volume=0.18,afade=t=out:st=%.2f:d=2.0[music];" +
                                "[0:a][music]amix=inputs=2:duration=first:dropout_transition=2[aout]", fadeStart)
            try await FFmpeg.run(["-y", "-i", video.path, "-stream_loop", "-1", "-i", music.path,
                                  "-filter_complex", filter,
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "192k",
                                  "-shortest", output.path], timeout: 1200)
        } else {
            let filter = String(format: "[1:a]volume=0.25,afade=t=out:st=%.2f:d=2.0[aout]", fadeStart)
            try await FFmpeg.run(["-y", "-i", video.path, "-stream_loop", "-1", "-i", music.path,
                                  "-filter_complex", filter,
                                  "-map", "0:v", "-map", "[aout]",
                                  "-c:v", "copy", "-c:a", "aac", "-ar", "44100", "-ac", "2", "-b:a", "192k",
                                  "-shortest", output.path], timeout: 1200)
        }
    }

}

nonisolated extension FileManager {
    func copyItemReplacing(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
