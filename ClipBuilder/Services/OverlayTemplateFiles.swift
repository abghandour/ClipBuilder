import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding, cropping, and encoding stay off the main actor.
nonisolated enum OverlayTemplateFiles {
    static func write(response: String, provenance: AIProvenance, imageData: Data, imageURL: URL,
                      log: @escaping @Sendable (String) -> Void) throws -> String {
        guard let object = AIResponseParser.jsonObject(from: response),
              let rawOverlays = object["overlays"] as? [[String: Any]], !rawOverlays.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (no overlays found)")
        }

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIError.notConfigured("Could not read the image.")
        }
        var composition = OverlayComposition()
        composition.provenance = provenance
        var croppedCount = 0
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
        for raw in rawOverlays {
            try Task.checkCancellation()
            let x = (raw["x"] as? NSNumber)?.doubleValue ?? 0.5
            let y = (raw["y"] as? NSNumber)?.doubleValue ?? 0.5
            let w = min(1, max(0.02, (raw["w"] as? NSNumber)?.doubleValue ?? 0.3))
            let h = min(1, max(0.02, (raw["h"] as? NSNumber)?.doubleValue ?? 0.1))
            if (raw["kind"] as? String) == "image" {
                // Crop the mark out of the reference image into the library.
                let pixelWidth = Double(cgImage.width)
                let pixelHeight = Double(cgImage.height)
                // Clamp the box to the image so a mark at the edge keeps
                // its true size instead of a silently narrower crop.
                let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
                let rect = CGRect(x: (x - w / 2) * pixelWidth,
                                  y: (y - h / 2) * pixelHeight,
                                  width: w * pixelWidth,
                                  height: h * pixelHeight).intersection(bounds).integral
                guard !rect.isEmpty, let crop = cgImage.cropping(to: rect) else { continue }
                let name = raw["description"] as? String ?? "overlay mark"
                let sanitized = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
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
                var item = ImageOverlayItem(path: fileURL.path, startTime: 0, endTime: 3)
                item.xFrac = x
                item.yFrac = y
                item.wFrac = w
                item.unbounded = true
                composition.images.append(item)
                croppedCount += 1
            } else {
                let text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var item = TextOverlayItem(text: text, startTime: 0, endTime: 3)
                item.xFrac = x
                item.yFrac = y
                item.wFrac = w
                item.hFrac = h
                item.fontcolor = raw["fontcolor"] as? String ?? "white"
                item.bold = raw["bold"] as? Bool ?? false
                item.italic = raw["italic"] as? Bool ?? false
                if let bg = raw["bgcolor"] as? String {
                    item.bgcolor = bg
                    item.boxOpacity = (raw["box_opacity"] as? NSNumber)?.doubleValue ?? 0.6
                }
                item.isDynamic = raw["dynamic"] as? Bool ?? false
                item.unbounded = true
                composition.texts.append(item)
            }
        }
        guard !composition.isEmpty else {
            throw AIError.emptyResponse("overlay extraction (nothing usable)")
        }
        let base = imageURL.deletingPathExtension().lastPathComponent
        let name = OverlayTemplateStore.uniqueName(base: "Wizard – \(base)")
        try Task.checkCancellation()
        try OverlayTemplateStore.save(OverlayTemplate(name: name, composition: composition))
        templateSaved = true
        log("Created overlay template \"\(name)\": \(composition.texts.count) text(s), \(croppedCount) cropped image(s)")
        return name
    }
}
