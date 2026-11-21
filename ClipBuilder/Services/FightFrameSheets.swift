import AppKit
import CoreText
import Foundation
import ImageIO
import Vision

/// The media half of `FightSampling`: reads how far apart the fighters stand,
/// and packs consecutive stills into stamped sheets for the scoring model.
nonisolated enum FightFrameSheets {
    struct Probes: Sendable {
        var readings: [(time: Double, gap: Double?)]
        var stills: [Double: Data]
    }

    struct Extraction: Sendable {
        var frames: [AIFrame]
        var requested: [Double]
        var extracted: Set<Double>
        var isComplete: Bool { FightSampling.extractionComplete(requested: requested, extracted: extracted) }
    }

    /// Fighter gap readings across a window, one every `FightSampling.probeInterval`.
    /// A frame that cannot be read gives a nil gap, which keeps the dense rate.
    @concurrent
    static func probes(url: URL, window: FightSampling.Range) async throws -> Probes {
        let times = FightSampling.probeTimes(window: window)
        let frames = await ThumbnailService.jpegFrames(url: url, at: times,
                                                       maxDimension: CGFloat(FightSampling.tileEdge), tolerance: 0)
        var stills: [Double: Data] = [:]
        var result: [(time: Double, gap: Double?)] = []
        for (time, jpeg) in zip(times, frames) {
            try Task.checkCancellation()
            guard let jpeg, let size = pixelSize(jpeg) else { result.append((time, nil)); continue }
            stills[time] = jpeg
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let probe = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                  ] as CFDictionary) else { result.append((time, nil)); continue }
            var request = DetectHumanRectanglesRequest(.revision2)
            request.upperBodyOnly = false
            let permit = try await MediaWorkScheduler.current.acquire(.vision)
            let boxes = ((try? await request.perform(on: probe)) ?? []).map { $0.boundingBox.cgRect }
            withExtendedLifetime(permit) {}
            let bodies = boxes.map { FightSampling.Body(minX: $0.minX, maxX: $0.maxX, height: $0.height) }
            result.append((time, FightSampling.gap(bodies: bodies, aspect: size.width / size.height)))
        }
        return Probes(readings: result, stills: stills)
    }

    /// One labeled image per complete sheet, with coverage for the caller.
    @concurrent
    static func frames(url: URL, sheets: [[Double]], cached: [Double: Data] = [:]) async -> Extraction {
        let times = sheets.flatMap { $0 }
        let missing = times.filter { cached[$0] == nil }
        let decoded = await ThumbnailService.jpegFrames(url: url, at: missing,
                                                       maxDimension: CGFloat(FightSampling.tileEdge), tolerance: 0)
        var stills = cached
        for (time, jpeg) in zip(missing, decoded) { stills[time] = jpeg }
        var result: [AIFrame] = []
        var extracted: Set<Double> = []
        for sheet in sheets {
            let tiles = sheet.compactMap { time in
                stills[time].map { (time: time, jpeg: $0) }
            }
            guard !Task.isCancelled else { break }
            guard tiles.count == sheet.count, let jpeg = compose(tiles) else { continue }
            extracted.formUnion(sheet)
            result.append(AIFrame(jpeg: jpeg, label: FightSampling.label(tiles.map(\.time))))
        }
        return Extraction(frames: result, requested: times, extracted: extracted)
    }

    /// Two stills across, each stamped with its time in the top left corner.
    static func compose(_ tiles: [(time: Double, jpeg: Data)]) -> Data? {
        // Decoded from memory: the stills never touch disk.
        let images = tiles.compactMap { tile -> (time: Double, image: CGImage)? in
            guard let source = CGImageSourceCreateWithData(tile.jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (tile.time, image)
        }
        guard images.count == tiles.count, let first = images.first else { return nil }
        let width = first.image.width, height = first.image.height
        let columns = min(2, images.count)
        let rows = (images.count + columns - 1) / columns
        guard let context = CGContext(data: nil, width: width * columns, height: height * rows,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width * columns, height: height * rows))
        let fontSize = max(18, CGFloat(height) / 16)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        for (index, tile) in images.enumerated() {
            // CoreGraphics' origin is bottom left; sheets read top to bottom.
            let x = CGFloat(index % columns * width)
            let y = CGFloat((rows - 1 - index / columns) * height)
            context.draw(tile.image, in: CGRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height)))
            let text = NSAttributedString(string: FightSampling.stamp(tile.time), attributes: [
                .font: font, .foregroundColor: NSColor.yellow,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let pad = fontSize * 0.3
            let box = CGRect(x: x, y: y + CGFloat(height) - bounds.height - pad * 2,
                             width: bounds.width + pad * 2, height: bounds.height + pad * 2)
            context.setFillColor(CGColor(gray: 0, alpha: 0.75))
            context.fill(box)
            context.textPosition = CGPoint(x: box.minX + pad - bounds.minX, y: box.minY + pad - bounds.minY)
            CTLineDraw(line, context)
        }
        guard let sheet = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: sheet).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func pixelSize(_ jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
