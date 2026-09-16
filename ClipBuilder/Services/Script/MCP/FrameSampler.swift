import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Frames of a source video for the Wizard's agent: JPEGs at chosen source
/// times, optionally cropped to a rectangle of the frame, with the people
/// and faces Vision sees in each full frame as fractions of the frame
/// (top-left origin) and, when the analysis knows, who they are.
nonisolated enum FrameSampler {
    struct Crop: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    struct Request: Codable, Sendable, Equatable {
        var video: Int64
        var times: [Double]
        var crop: Crop? = nil
        var size: Int? = nil
    }

    struct Box: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        /// Roster key when the podcast tiles or the People pass place
        /// someone there.
        var person: String? = nil
    }

    struct Frame: Codable, Sendable, Equatable {
        var time: Double
        var width: Int
        var height: Int
        var people: [Box]
        var faces: [Box]
        /// Grid layouts: the tile under the largest face.
        var tile: Int? = nil
    }

    struct Image: Codable, Sendable, Equatable {
        var mimeType: String
        var data: String
        var label: String
    }

    struct Result: Codable, Sendable, Equatable {
        var video: Int64
        var size: Int
        var crop: Crop?
        var frames: [Frame]
        /// Pulled out into image content by the run coordinator; the text
        /// the model reads keeps only their count.
        var images: [Image]
    }

    static let maximumTimes = 12
    static let sizeRange = 160...1024
    static let defaultSize = 512

    static func validate(_ request: Request, duration: Double) throws {
        guard !request.times.isEmpty, request.times.count <= maximumTimes else {
            throw ScriptError.invalid("sample_frames takes 1 to \(maximumTimes) times.")
        }
        for time in request.times {
            guard time.isFinite, time >= 0, time <= max(0, duration) + 1e-6 else {
                throw ScriptError.invalid("Times are source seconds within the video (0…\(duration)).")
            }
        }
        if let crop = request.crop {
            for value in [crop.x, crop.y, crop.w, crop.h] {
                guard value.isFinite, value >= 0, value <= 1 else { throw ScriptError.invalid("crop uses fractions 0…1.") }
            }
            guard crop.w >= 0.05, crop.h >= 0.05, crop.x + crop.w <= 1 + 1e-9, crop.y + crop.h <= 1 + 1e-9 else {
                throw ScriptError.invalid("crop must be at least 0.05 wide and high and stay inside the frame.")
            }
        }
        if let size = request.size, !sizeRange.contains(size) {
            throw ScriptError.invalid("size is the longest edge in pixels, \(sizeRange.lowerBound)…\(sizeRange.upperBound).")
        }
    }

    static func sample(_ request: Request, video: VideoRecord,
                       roster: [VideoPersonRecord]) async throws -> Result {
        try validate(request, duration: video.duration)
        let size = request.size ?? defaultSize
        let tiles = video.podcastTiles
        let times = request.times.map { min(max(0, $0), max(0, video.duration - 0.05)) }
        // Detect on a frame large enough for faces in a grid; deliver smaller.
        let sources = await ThumbnailService.jpegFrames(url: video.url, at: times, maxDimension: 1280, quality: 0.85)
        var frames: [Frame] = []
        var images: [Image] = []
        for (time, data) in zip(times, sources) {
            try Task.checkCancellation()
            guard let data, let full = cgImage(data) else {
                throw ScriptError.invalid("No frame could be read at \(time) s.")
            }
            let faces = await PodcastVisualAnalyzer.faceSamples(data).map(\.box)
            let people = await humanBoxes(data)
            func labeled(_ rect: CGRect) -> Box {
                let cx = rect.midX, cy = rect.midY
                let tile = tiles.first { $0.contains(x: cx, y: cy) }
                let person = tile?.personKey ?? roster.first { person in
                    guard let box = person.portraitBox else { return false }
                    return cx >= box.x && cx <= box.x + box.w && cy >= box.y && cy <= box.y + box.h
                }?.key
                return Box(x: round4(rect.minX), y: round4(rect.minY), w: round4(rect.width), h: round4(rect.height),
                           person: person)
            }
            let largestFace = faces.max { $0.width * $0.height < $1.width * $1.height }
            let tile = largestFace.flatMap { face in tiles.first { $0.contains(x: face.midX, y: face.midY) }?.index }
            let delivered = try render(full, crop: request.crop, size: size)
            frames.append(Frame(time: time, width: delivered.width, height: delivered.height,
                                people: people.map(labeled), faces: faces.map(labeled), tile: tile))
            images.append(Image(mimeType: "image/jpeg", data: delivered.jpeg.base64EncodedString(),
                                label: String(format: "%.2f s", time)))
        }
        return Result(video: video.id, size: size, crop: request.crop, frames: frames, images: images)
    }

    private static func round4(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }

    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Vision's human rectangles with a top-left origin.
    private static func humanBoxes(_ data: Data) async -> [CGRect] {
        guard let permit = try? await MediaWorkScheduler.current.acquire(.vision) else { return [] }
        defer { withExtendedLifetime(permit) {} }
        var request = DetectHumanRectanglesRequest(.revision2)
        request.upperBodyOnly = false
        let timing = PerfSignpost.begin("Vision", metadata: "sample_frames people")
        defer { PerfSignpost.end(timing) }
        return ((try? await request.perform(on: data)) ?? []).map { observation in
            let rect = observation.boundingBox.cgRect
            return CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    /// The frame (or its crop) scaled so the longest edge is `size`.
    static func render(_ image: CGImage, crop: Crop?, size: Int) throws -> (jpeg: Data, width: Int, height: Int) {
        var source = image
        if let crop {
            let rect = CGRect(x: crop.x * Double(image.width), y: crop.y * Double(image.height),
                              width: crop.w * Double(image.width), height: crop.h * Double(image.height))
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else {
                throw ScriptError.invalid("crop is empty at this frame size.")
            }
            source = cropped
        }
        let scale = min(1, Double(size) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScriptError.invalid("Could not scale the frame.")
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw ScriptError.invalid("Could not scale the frame.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScriptError.invalid("Could not encode the frame.")
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScriptError.invalid("Could not encode the frame.") }
        return (output as Data, width, height)
    }
}
