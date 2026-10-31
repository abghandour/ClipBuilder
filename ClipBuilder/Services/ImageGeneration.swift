import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageGeneration {
    enum Mode: String, Codable, Sendable { case sticker, edit }

    struct Request: Sendable {
        var prompt: String
        var mode: Mode
        var frame: Data?
        var subject: CGRect?
        /// Roster name for the subject, when the frame's people are known.
        var subjectName: String?
        var keyColor: String = "#00FF00"
    }

    struct Result: Equatable, Sendable {
        var path: String
        var sourcePath: String
        var width: Int
        var height: Int
    }

    /// How the source frame at the playhead reaches the output: `window`
    /// is the part of the source that is visible (fractions of the source
    /// frame) and `box` is where that part lands (fractions of the output
    /// frame). Mirrors the Builder preview's clip layer so a box found on
    /// the source frame can be placed on the rendered picture.
    struct Placement: Equatable, Sendable {
        var window = FreeCropRect()
        var box = CGRect(x: 0, y: 0, width: 1, height: 1)

        static let fullFrame = Placement()

        /// The part of the source an aspect-fill of `box` shows, centered.
        static func filling(box: CGRect, sourceAspect: Double, outputAspect: Double) -> Placement {
            let boxAspect = outputAspect * box.width / max(0.001, box.height)
            let window: FreeCropRect
            if sourceAspect > boxAspect {
                let w = boxAspect / sourceAspect
                window = FreeCropRect(xFrac: (1 - w) / 2, yFrac: 0, wFrac: w, hFrac: 1)
            } else {
                let h = sourceAspect / boxAspect
                window = FreeCropRect(xFrac: 0, yFrac: (1 - h) / 2, wFrac: 1, hFrac: h)
            }
            return Placement(window: window, box: box)
        }

        /// A rectangle in source fractions mapped to output fractions.
        func outputRect(_ source: CGRect) -> CGRect {
            let w = max(0.001, window.wFrac), h = max(0.001, window.hFrac)
            return CGRect(x: box.minX + (source.minX - window.xFrac) / w * box.width,
                          y: box.minY + (source.minY - window.yFrac) / h * box.height,
                          width: source.width / w * box.width,
                          height: source.height / h * box.height)
        }

        /// Inverse of outputRect, used to seed tracking from a placed sticker.
        func inputRect(_ output: CGRect) -> CGRect {
            let w = max(0.001, box.width), h = max(0.001, box.height)
            return CGRect(x: window.xFrac + (output.minX - box.minX) / w * window.wFrac,
                          y: window.yFrac + (output.minY - box.minY) / h * window.hFrac,
                          width: output.width / w * window.wFrac,
                          height: output.height / h * window.hFrac)
        }

        /// Whether a source rectangle's center is on screen.
        func shows(_ source: CGRect) -> Bool {
            let cx = source.midX, cy = source.midY
            return cx >= window.xFrac && cx <= window.xFrac + window.wFrac
                && cy >= window.yFrac && cy <= window.yFrac + window.hFrac
        }
    }

    /// Roster names for face boxes (source fractions): the podcast tile the
    /// face sits in names it, else a roster portrait box that contains it.
    static func names(for faces: [CGRect], roster: [VideoPersonRecord], tiles: [PodcastTile]) -> [String?] {
        faces.map { face in
            let cx = face.midX, cy = face.midY
            let key = tiles.first { $0.contains(x: cx, y: cy) }?.personKey
                ?? roster.first { person in
                    guard let box = person.portraitBox else { return false }
                    return cx >= box.x && cx <= box.x + box.w && cy >= box.y && cy <= box.y + box.h
                }?.key
            guard let key else { return nil }
            return roster.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.displayName ?? key
        }
    }

    /// The visible part of a frame, for editing exactly what the render shows.
    static func cropped(_ image: CGImage, to window: FreeCropRect) -> CGImage {
        let rect = CGRect(x: window.xFrac * Double(image.width), y: window.yFrac * Double(image.height),
                          width: window.wFrac * Double(image.width), height: window.hFrac * Double(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1 else { return image }
        return image.cropping(to: rect) ?? image
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The overlay geometry for a result: a sticker sits on the subject at
    /// the subject's width (the sticker fills about 80 % of its own canvas,
    /// so the drawing is a little smaller than the face), an edit covers the
    /// box the frame was cut from.
    static func overlayGeometry(mode: Mode, subject: CGRect?, placement: Placement)
        -> (xFrac: Double, yFrac: Double, wFrac: Double) {
        switch mode {
        case .edit:
            return (placement.box.midX, placement.box.midY, placement.box.width)
        case .sticker:
            guard let subject else { return (0.5, 0.5, 0.3) }
            let out = placement.outputRect(subject)
            return (min(1, max(0, out.midX)), min(1, max(0, out.midY)), min(1, max(0.05, out.width)))
        }
    }

    static func prompt(for request: Request) -> String {
        let region = request.subject.map {
            String(format: "x=%.3f, y=%.3f, w=%.3f, h=%.3f (fractions)",
                   locale: Locale(identifier: "en_US_POSIX"), $0.minX, $0.minY, $0.width, $0.height)
        }
        var text: String
        switch request.mode {
        case .sticker:
            text = "Create a single PNG of \(request.prompt) as a sticker. Fill the entire background with solid pure \(request.keyColor) (RGB \(rgbDescription(request.keyColor))), no gradients, no shadow on the background, nothing else in the image. The sticker must be centered, fill about 80 % of the canvas, and face the camera."
            if request.frame != nil {
                text += " Match the lighting and head angle of the person in the attached frame"
                if let region { text += " at the region \(region)" }
                if let name = request.subjectName, !name.isEmpty { text += " (\(name))" }
                text += "."
            }
        case .edit:
            text = "Edit the attached image: \(request.prompt). Keep everything else identical, same size and framing."
            if let region {
                text += " Apply the change only to the person at \(region)"
                if let name = request.subjectName, !name.isEmpty { text += " (\(name))" }
                text += "."
            }
        }
        return text + " Use the nanobanana edit_image tool when an image is attached and generate_image otherwise. Save the file and print only its absolute path."
    }

    private static func rgbDescription(_ hex: String) -> String {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x00FF00
        return "\((value >> 16) & 255),\((value >> 8) & 255),\(value & 255)"
    }

    /// New regular image files, newest first; `before` contains absolute paths.
    /// File attributes bypass URL metadata caches.
    static func newOutputFiles(in scratch: URL, before: Set<String>) -> [URL] {
        let folder = scratch.appendingPathComponent("nanobanana-output", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> (URL, Date)? in
            guard !before.contains(url.path), ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (url, attributes[.modificationDate] as? Date ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.map(\.0)
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw AIError.unusableResponse("The generated image could not be decoded.")
        }
        return image
    }

    /// All decoding, keying, file writes and scratch cleanup run on the job's worker.
    static func save(raw: URL, mode: Mode, prompt: String, folder: URL,
                     provenance: AIProvenance) throws -> Result {
        defer { removeScratch(containing: raw) }
        try Task.checkCancellation()
        let data = try Data(contentsOf: raw)
        let decoded = try decode(data)
        let image = mode == .sticker
            ? StickerKey.trimmedToContent(StickerKey.keyed(decoded, color: (0, 1, 0))) : decoded
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = prompt.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-").prefix(60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(slug.isEmpty ? "image" : String(slug))-\(formatter.string(from: Date()))"
        let ext = mode == .sticker ? "png" : raw.pathExtension.lowercased()
        var output = folder.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: output.path) {
            output = folder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        let sidecar = output.appendingPathExtension("json")
        do {
            if mode == .sticker {
                guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw AIError.unusableResponse("Could not create the sticker PNG.")
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw AIError.unusableResponse("Could not save the sticker PNG.")
                }
            } else {
                try data.write(to: output, options: .atomic)
            }
            // Keep the prompt and task provenance beside the reusable library asset.
            let record: [String: Any] = ["prompt": prompt, "outputPath": output.path,
                "provenance": try JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance))]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: sidecar, options: .atomic)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: sidecar)
            throw error
        }
        AssetStore.invalidateCatalog(.images)
        return Result(path: output.path, sourcePath: raw.path, width: image.width, height: image.height)
    }

    static func removeScratch(containing raw: URL) {
        var directory = raw.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        while directory.path != "/" {
            if directory.lastPathComponent.hasPrefix("cb_imagegen_"),
               directory.deletingLastPathComponent().resolvingSymlinksInPath() == temporary {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            directory.deleteLastPathComponent()
        }
    }
}

nonisolated struct GeneratedImage: Equatable, Sendable {
    var image: ImageGeneration.Result
    var subject: CGRect?
    var provenance: AIProvenance
    var placement: ImageGeneration.Placement? = nil
}
