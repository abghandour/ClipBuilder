import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Burns saved strike highlights into a stretch of source footage, in the
/// source's own picture and clock, before any crop, scale or reframing.
/// Whatever the renderer then does to the clip, the highlight goes with it.
///
/// The result is a copy of exactly the stretch asked for, starting at 0,
/// with the source's sound kept losslessly.
nonisolated enum StrikeHighlightBurn {
    static let frameRate = 30.0
    /// Overlay pictures are drawn no wider than this and scaled up by
    /// ffmpeg: the shapes are soft, and full-size 4K pictures are slow to write.
    static let maxOverlayWidth = 1280.0
    /// Part of every cache key a burn feeds.
    static let version = 1

    nonisolated struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// One highlight as a numbered picture sequence.
    nonisolated struct Sequence: Sendable, Equatable {
        /// Seconds from the start of the stretch to the first picture.
        var offset: Double
        var frames: Int
        /// printf pattern of the pictures.
        var pattern: String
        /// Source seconds per picture for a screen-timed drawing on motion.
        /// Nil preserves the existing strike and held-drawing graph strings.
        var frameDuration: Double? = nil
    }

    /// The tracks that show at all inside [start, start + duration].
    static func tracks(_ tracks: [StrikeHighlightRules.Track], start: Double, duration: Double) -> [StrikeHighlightRules.Track] {
        guard duration >= 0 else { return [] }
        var showing: [StrikeHighlightRules.Track] = []
        for track in tracks.sorted(by: { $0.start < $1.start })
        where !track.keyframes.isEmpty && track.end + StrikeHighlightRules.fade > start
            && track.start - StrikeHighlightRules.fade < start + duration {
            // Several logged strikes can resolve to one blow; drawn twice it
            // would be twice as opaque.
            if let last = showing.last, last.keyframes == track.keyframes { continue }
            if showing.contains(where: { $0.keyframes == track.keyframes }) { continue }
            showing.append(track)
        }
        return showing
    }

    /// The times, in source seconds, of the pictures one track needs inside
    /// the stretch: one per output frame from fade in to fade out.
    static func frameTimes(_ track: StrikeHighlightRules.Track, start: Double, duration: Double) -> [Double] {
        if duration == 0 { return StrikeHighlightRules.sample(track, at: start) == nil ? [] : [start] }
        let first = max(start, track.start - StrikeHighlightRules.fade)
        let last = min(start + duration, track.end + StrikeHighlightRules.fade)
        guard last > first else { return [] }
        // On the stretch's frame grid, so a picture never lands between frames.
        var index = ((first - start) * frameRate).rounded(.up)
        var times: [Double] = []
        while start + index / frameRate <= last + 0.0001 {
            times.append(start + index / frameRate)
            index += 1
        }
        return times
    }

    /// Writes the pictures of every track into `folder`.
    static func sequences(tracks: [StrikeHighlightRules.Track], start: Double, duration: Double,
                          size: CGSize, folder: URL, style: String = "outline") throws -> [Sequence] {
        let scale = min(1, maxOverlayWidth / max(1, size.width))
        let width = max(2, Int((size.width * scale).rounded())), height = max(2, Int((size.height * scale).rounded()))
        var result: [Sequence] = []
        for (trackIndex, track) in Self.tracks(tracks, start: start, duration: duration).enumerated() {
            let times = frameTimes(track, start: start, duration: duration)
            guard let first = times.first else { continue }
            for (frame, time) in times.enumerated() {
                try Task.checkCancellation()
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw Failure(message: "Could not draw a strike highlight.")
                }
                if let sample = StrikeHighlightRules.sample(track, at: time) {
                    StrikeHighlightPainter.draw(sample.highlight, opacity: sample.opacity, in: context,
                                                rect: CGRect(x: 0, y: 0, width: width, height: height), topLeftOrigin: false, style: style)
                }
                let url = folder.appendingPathComponent(String(format: "h%02d_%04d.png", trackIndex, frame))
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw Failure(message: "Could not write a strike highlight.")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Could not write a strike highlight.") }
            }
            result.append(Sequence(offset: first - start, frames: times.count,
                                   pattern: folder.appendingPathComponent(String(format: "h%02d_%%04d.png", trackIndex)).path))
        }
        return result
    }

    /// The ffmpeg arguments after the source input and before the encoder
    /// settings: the picture inputs and the graph that lays them on the video.
    static func graph(_ sequences: [Sequence], size: CGSize) -> (inputs: [String], filter: String) {
        var inputs: [String] = []
        var steps = ["[0:v]setpts=PTS-STARTPTS[base0]"]
        for (index, sequence) in sequences.enumerated() {
            inputs += ["-threads", "1", "-framerate", String(format: "%.0f", frameRate), "-start_number", "0",
                       "-i", sequence.pattern]
            steps.append(String(format: "[%d:v]format=rgba,scale=%d:%d,setpts=PTS+%.6f/TB[mark%d]",
                                index + 1, Int(size.width), Int(size.height), sequence.offset, index))
            // The video runs on before the first picture and after the last.
            steps.append("[base\(index)][mark\(index)]overlay=eof_action=pass:repeatlast=0[base\(index + 1)]")
        }
        return (inputs, steps.joined(separator: ";"))
    }

    /// Filter steps that lay the pictures on `input` (a video stream whose
    /// first frame is the start of the stretch, at source speed) and name
    /// the result `[tag]`. The pictures are read inside the graph, so the
    /// command's input numbering is untouched and the stretch is decoded and
    /// encoded once, by the encode that was going to happen anyway.
    static func inGraph(_ sequences: [Sequence], size: CGSize, input: String, tag: String) throws -> [String] {
        try overlaySteps(sequences, size: size, input: input, tag: tag, pictureClock: "")
    }

    /// A hold already has its own zero-based padded clock. PNG animation
    /// needs exact 30 fps timestamps rather than image2's default 1/25 ticks.
    /// Keep existing strike graphs byte-for-byte unchanged.
    static func inHoldGraph(_ sequences: [Sequence], size: CGSize, input: String, tag: String) throws -> [String] {
        try overlaySteps(sequences, size: size, input: input, tag: tag, pictureClock: "settb=1/30,")
    }

    private static func overlaySteps(_ sequences: [Sequence], size: CGSize, input: String, tag: String,
                                     pictureClock: String) throws -> [String] {
        var steps = ["\(input)setpts=PTS-STARTPTS[\(tag)_b0]"]
        for (index, sequence) in sequences.enumerated() {
            guard !sequence.pattern.contains("'") else { throw Failure(message: "Unusable scratch path for strike highlights.") }
            let file = sequence.pattern.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            if let frameDuration = sequence.frameDuration {
                steps.append(String(format: "movie=filename='%@':f=image2,settb=1/90000,format=rgba,scale=%d:%d,setpts=N*%.9f/TB+%.6f/TB[%@_m%d]",
                    file, Int(size.width), Int(size.height), frameDuration, sequence.offset, tag, index))
            } else {
                steps.append(String(format: "movie=filename='%@':f=image2,%@format=rgba,scale=%d:%d,setpts=N/(%.0f*TB)+%.6f/TB[%@_m%d]",
                                    file, pictureClock, Int(size.width), Int(size.height), frameRate, sequence.offset, tag, index))
            }
            let out = index == sequences.count - 1 ? tag : "\(tag)_b\(index + 1)"
            steps.append("[\(tag)_b\(index)][\(tag)_m\(index)]overlay=eof_action=pass:repeatlast=0[\(out)]")
        }
        return steps
    }

    /// The pictures for the stretch [start, start + duration] of `source`,
    /// drawn off the caller's actor into a new folder under `scratch`.
    /// Empty when no track shows there.
    @concurrent
    static func prepare(source: URL, start: Double, duration: Double, tracks: [StrikeHighlightRules.Track],
                        scratch: URL, style: String = "outline") async throws -> (sequences: [Sequence], size: CGSize, folder: URL)? {
        let showing = Self.tracks(tracks, start: start, duration: duration)
        guard !showing.isEmpty, duration >= 0 else { return nil }
        let dimensions = await FFmpeg.dimensions(of: source)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        let size = CGSize(width: dimensions.width, height: dimensions.height)
        let folder = scratch.appendingPathComponent("strikes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sequences = try sequences(tracks: showing, start: start, duration: duration, size: size, folder: folder, style: style)
        guard !sequences.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return (sequences, size, folder)
    }

    /// A copy of [start, start + duration] of `source` with `tracks` drawn
    /// on it, or nil when none of them shows there. The copy starts at 0.
    /// Only for a consumer that needs a file (camera reframing reads it with
    /// AVFoundation, hence QuickTime); the segment encode uses `inGraph`.
    static func burn(source: URL, start: Double, duration: Double, tracks: [StrikeHighlightRules.Track],
                     scratch: URL, style: String = "outline") async throws -> URL? {
        guard let (sequences, size, folder) = try await prepare(source: source, start: start, duration: duration,
                                                                tracks: tracks, scratch: scratch, style: style) else { return nil }
        let graph = graph(sequences, size: size)
        // The sound is decoded and kept as PCM: lossless, and cut at exactly
        // the same point as the picture. Copied packets start at an earlier
        // packet boundary, which shifts the picture against the sound.
        let output = folder.appendingPathComponent("burned.mov")
        try await FFmpeg.run(["-y", "-ss", String(format: "%.3f", max(0, start)), "-t", String(format: "%.3f", duration),
                              "-i", source.path] + graph.inputs
                             + ["-filter_complex", graph.filter, "-map", "[base\(sequences.count)]", "-map", "0:a?",
                                "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p",
                                "-c:a", "pcm_s24le", "-t", String(format: "%.3f", duration), output.path],
                             timeout: 600, capture: .boundedStderrTail(), purpose: "strike highlights")
        return output
    }
}
