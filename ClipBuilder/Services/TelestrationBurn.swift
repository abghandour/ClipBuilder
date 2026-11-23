import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Segment-local animation on a held source frame, before any framing.
nonisolated enum TelestrationBurn {
    static let frameRate = 30.0

    nonisolated struct LingerFrame: Equatable, Sendable {
        var elapsed: Double
        var sourceOffset: Double
    }

    /// One picture per screen frame, spaced by speed in the source clock.
    static func lingerFrameTimes(_ drawing: Telestration, offset: Double, duration: Double,
                                 speed: Double, paused: Bool = false, overlapStart: Double? = nil) -> [LingerFrame] {
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0,
              speed.isFinite, speed > 0 else { return [] }
        guard offset < TelestrationRules.carriedDuration(of: drawing) else { return [] }
        let span = paused ? duration : min(duration, TelestrationRules.carriedDuration(of: drawing) - offset)
        guard span > 0 else { return [] }
        return (0..<Int(ceil(span * frameRate))).compactMap { index in
            let local = Double(index) / frameRate
            guard local < span else { return nil }
            let elapsed = paused ? overlapStart.map { max(0, local - $0) } ?? 0 : local
            return LingerFrame(elapsed: offset + elapsed, sourceOffset: paused ? 0 : local * speed)
        }
    }

    /// Animation seconds on this segment's frame grid. The exclusive end
    /// leaves no last picture to repeat after the drawing has faded away.
    static func frameTimes(_ drawing: Telestration, offset: Double, duration: Double) -> [Double] {
        guard offset.isFinite, duration.isFinite, duration > 0,
              drawing.duration.isFinite, StrikeFreezeRules.drawingHoldRange.contains(drawing.duration) else { return [] }
        let start = max(0, offset)
        // A figure that stays into the motion is on screen to the end of the
        // pause, also when the pause outlasts the drawing's own animation.
        let stays = TelestrationRules.lingerDuration(of: drawing) > 0
        let span = stays ? duration : min(duration, drawing.duration - start)
        guard span > 0 else { return [] }
        return (0..<Int(ceil(span * frameRate))).map { start + Double($0) / frameRate }
            .filter { (stays || $0 < drawing.duration) && $0 < start + duration }
    }

    @concurrent
    static func prepare(source: URL, drawing: Telestration, offset: Double, duration: Double,
                        scratch: URL, lingering: Bool = false, speed: Double = 1, pausedStay: Bool = false,
                        screenStay: TelestrationScreenStay.Mapping? = nil, stayTransitionStart: Double? = nil) async throws -> (sequences: [StrikeHighlightBurn.Sequence], size: CGSize)? {
        let times = lingering
            ? lingerFrameTimes(drawing, offset: offset, duration: duration, speed: speed, paused: pausedStay, overlapStart: stayTransitionStart).map(\.elapsed)
            : frameTimes(drawing, offset: offset, duration: duration)
        guard !times.isEmpty else { return nil }
        let size: CGSize
        if let screenStay {
            size = screenStay.outputSize
        } else {
            let dimensions = await FFmpeg.dimensions(of: source)
            size = CGSize(width: dimensions.width, height: dimensions.height)
        }
        guard size.width > 0, size.height > 0 else {
            throw StrikeHighlightBurn.Failure(message: "Could not read the drawing's source size.")
        }
        let scale = screenStay == nil ? min(1, StrikeHighlightBurn.maxOverlayWidth / size.width) : 1
        let width = max(2, Int((size.width * scale).rounded()))
        let height = max(2, Int((size.height * scale).rounded()))
        let folder = scratch.appendingPathComponent("telestration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for (frame, time) in times.enumerated() {
                try Task.checkCancellation()
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw StrikeHighlightBurn.Failure(message: "Could not draw the drawing.")
                }
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.clear(rect)
                if let screenStay {
                    guard let painterRect = screenStay.painterRect else {
                        throw StrikeHighlightBurn.Failure(message: "Could not map the staying drawing.")
                    }
                    // Flip the context once: both the crop and the painter rect
                    // are top-left coordinates, including off-centre windows.
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: 1, y: -1)
                    context.clip(to: screenStay.picture)
                    // Mapping selects coordinates, not the animation clock:
                    // a hold still draws in and keeps its figures
                    // until the pause ends. Only motion consumes their linger.
                    let state = lingering
                        ? TelestrationRules.carriedState(of: drawing, at: time)
                        : TelestrationTransition.state(drawing, at: time, overlapStart: stayTransitionStart)
                    TelestrationPainter.draw(state,
                        in: context, rect: painterRect, topLeftOrigin: true)
                } else if lingering {
                    TelestrationPainter.draw(TelestrationRules.carriedState(of: drawing, at: time),
                        in: context, rect: rect, topLeftOrigin: false)
                } else {
                    TelestrationPainter.draw(TelestrationTransition.state(drawing, at: time, overlapStart: stayTransitionStart),
                        in: context, rect: rect, topLeftOrigin: false)
                }
                let url = folder.appendingPathComponent(String(format: "d%04d.png", frame))
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw StrikeHighlightBurn.Failure(message: "Could not write the drawing.")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw StrikeHighlightBurn.Failure(message: "Could not write the drawing.")
                }
            }
            return ([StrikeHighlightBurn.Sequence(offset: 0, frames: times.count,
                pattern: folder.appendingPathComponent("d%04d.png").path,
                frameDuration: lingering ? (pausedStay ? 1 : speed) / frameRate : nil)], size)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Only framing modes that require a movie use an intermediate. The
    /// normal path prepares pictures in the segment's existing worker.
    @concurrent
    static func burn(source: URL, start: Double, duration: Double, drawing: Telestration,
                     offset: Double, speed: Double, scratch: URL) async throws -> URL? {
        guard let marks = try await prepare(source: source, drawing: drawing, offset: offset,
            duration: duration, scratch: scratch, lingering: true, speed: speed) else { return nil }
        let folder = URL(fileURLWithPath: marks.sequences[0].pattern).deletingLastPathComponent()
        let output = folder.appendingPathComponent("burned.mov")
        do {
            let filters = try StrikeHighlightBurn.inGraph(marks.sequences, size: marks.size, input: "[0:v]", tag: "drawing")
            try await FFmpeg.run(["-y", "-ss", String(format: "%.6f", max(0, start)),
                "-t", String(format: "%.6f", duration * speed), "-i", source.path,
                "-filter_complex", filters.joined(separator: ";"), "-map", "[drawing]", "-map", "0:a?",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p",
                "-c:a", "pcm_s24le", "-t", String(format: "%.6f", duration * speed), output.path],
                timeout: 600, capture: .boundedStderrTail(), purpose: "drawing stay")
            return output
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
