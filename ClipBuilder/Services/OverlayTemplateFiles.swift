import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding, cropping, and encoding stay off the main actor.
nonisolated enum OverlayTemplateFiles {
    /// Save the elements the Text Look Wizard extracted as a new overlay
    /// template. `frame(at:)` returns the reference pixels for cropping an
    /// image mark: the image itself for a still, or a full-resolution frame
    /// near the element's `at` time for a video (nil time = the poster frame).
    /// Returns the created template's name.
    static func write(elements: [TextLookExtraction.OverlayElement], provenance: AIProvenance,
                      sourceURL: URL, isVideo: Bool, duration: Double,
                      frame: (Double?) -> Data?,
                      log: @escaping @Sendable (String) -> Void) throws -> String {
        guard !elements.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (no overlays found)")
        }
        var composition = OverlayComposition()
        composition.provenance = provenance
        var croppedCount = 0
        var decoded: [String: CGImage] = [:]
        func image(at time: Double?) -> CGImage? {
            let key = time.map { String(format: "%.2f", $0) } ?? "poster"
            if let cached = decoded[key] { return cached }
            guard let data = frame(time),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            decoded[key] = cgImage
            return cgImage
        }
        // Stage beside the final files so publishing a crop stays on one filesystem.
        let staging = AssetKind.images.rootURL.appendingPathComponent(".overlay-extraction-\(UUID().uuidString)", isDirectory: true)
        var writtenFiles: [URL] = []
        var templateSaved = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            if !templateSaved {
                for url in writtenFiles { try? FileManager.default.removeItem(at: url) }
            }
            if !writtenFiles.isEmpty { AssetStore.invalidateCatalog(.images) }
        }
        for element in elements {
            try Task.checkCancellation()
            let timing = timing(for: element, isVideo: isVideo, duration: duration)
            switch element.kind {
            case .image:
                // Crop the mark out of the reference pixels into the library.
                guard let cgImage = image(at: isVideo ? element.at : nil) else { continue }
                let pixelWidth = Double(cgImage.width)
                let pixelHeight = Double(cgImage.height)
                // Clamp the box to the image so a mark at the edge keeps
                // its true size instead of a silently narrower crop.
                let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
                let rect = CGRect(x: (element.x - element.w / 2) * pixelWidth,
                                  y: (element.y - element.h / 2) * pixelHeight,
                                  width: element.w * pixelWidth,
                                  height: element.h * pixelHeight).intersection(bounds).integral
                guard !rect.isEmpty, let crop = cgImage.cropping(to: rect) else { continue }
                let sanitized = element.description.map { $0.isLetter || $0.isNumber ? $0 : "-" }
                    .reduce(into: "") { if $1 != "-" || $0.last != "-" { $0.append($1) } }
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let directory = AssetKind.images.rootURL
                do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
                catch { continue }
                var fileURL = directory.appendingPathComponent("\(sanitized.isEmpty ? "overlay" : sanitized).png")
                var counter = 2
                while FileManager.default.fileExists(atPath: fileURL.path) {
                    fileURL = directory.appendingPathComponent("\(sanitized.isEmpty ? "overlay" : sanitized)-\(counter).png")
                    counter += 1
                }
                let stagedURL = staging.appendingPathComponent(UUID().uuidString + ".png")
                guard let destination = CGImageDestinationCreateWithURL(stagedURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, crop, nil)
                guard CGImageDestinationFinalize(destination) else { continue }
                try Task.checkCancellation()
                // A failed crop is optional; only successfully moved files belong to this extraction.
                do { try FileManager.default.moveItem(at: stagedURL, to: fileURL) }
                catch { continue }
                writtenFiles.append(fileURL)
                var item = ImageOverlayItem(path: fileURL.path, startTime: timing.start, endTime: timing.end)
                item.xFrac = element.x
                item.yFrac = element.y
                item.wFrac = element.w
                item.unbounded = timing.unbounded
                item.transIn = element.enter ?? item.transIn
                item.transOut = element.exit ?? item.transOut
                composition.images.append(item)
                croppedCount += 1
            case .text:
                guard !element.text.isEmpty else { continue }
                var item = TextOverlayItem(text: element.text, startTime: timing.start, endTime: timing.end)
                item.xFrac = element.x
                item.yFrac = element.y
                item.wFrac = element.w
                item.hFrac = element.h
                item.fontcolor = element.fontcolor
                item.fontfamily = element.fontFamily
                item.bold = element.bold
                item.italic = element.italic
                item.underline = element.underline
                item.strikethrough = element.strikethrough
                if let bg = element.bgcolor {
                    item.bgcolor = bg
                    item.boxOpacity = element.boxOpacity ?? 0.6
                }
                item.isDynamic = element.dynamic
                item.unbounded = timing.unbounded
                item.transIn = element.enter ?? item.transIn
                item.transOut = element.exit ?? item.transOut
                composition.texts.append(item)
            }
        }
        guard !composition.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (nothing usable)")
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let name = OverlayTemplateStore.uniqueName(base: "Wizard – \(base)")
        try Task.checkCancellation()
        try OverlayTemplateStore.save(OverlayTemplate(name: name, composition: composition))
        templateSaved = true
        log("Created overlay template \"\(name)\": \(composition.texts.count) text(s), \(croppedCount) cropped image(s)")
        return name
    }

    struct Timing: Equatable {
        var start: Double
        var end: Double
        var unbounded: Bool
    }

    /// A still has no timing: every element lasts as long as the overlay.
    /// From a video, an element the model saw leave keeps its window; one
    /// that is on screen from the start and stays is unbounded. One that
    /// enters late and stays is bounded to the clip: `OverlayComposition.duration`
    /// ignores unbounded end times, so a late unbounded element would fall
    /// outside the three-second block the Builder inserts.
    static func timing(for element: TextLookExtraction.OverlayElement, isVideo: Bool, duration: Double) -> Timing {
        guard isVideo else { return Timing(start: 0, end: 3, unbounded: true) }
        let start = min(max(0, element.start ?? 0), max(0, duration))
        if let end = element.end, end > start + 0.1, duration <= 0 || end < duration - 0.25 {
            return Timing(start: start, end: end, unbounded: false)
        }
        let end = max(start + 1, duration)
        return Timing(start: start, end: end, unbounded: start < 0.25)
    }
}
