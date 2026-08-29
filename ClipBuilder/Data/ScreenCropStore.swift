import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One vertex of a screen-crop area, normalized to the 9:16 output canvas
/// (0…1 in both axes, top-left origin).
nonisolated struct ScreenCropPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    /// True when the point sits on the canvas border.
    var onBorder: Bool { x <= 0 || x >= 1 || y <= 0 || y >= 1 }
}

/// A named closed polygon on the 9:16 canvas — the part of a clip that
/// stays visible when the area is applied (everything outside is masked).
nonisolated struct ScreenCropArea: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var points: [ScreenCropPoint]

    var id: String { name }

    /// Axis-aligned bounds, for the planner's description and list rows.
    var bounds: (x: Double, y: Double, w: Double, h: Double) {
        guard let first = points.first else { return (0, 0, 0, 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// Fraction of the canvas the polygon covers (shoelace, canvas units).
    var coverage: Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// "top 50% · full width" style summary for lists and the AI prompt.
    var summary: String {
        let box = bounds
        func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        return "x \(pct(box.x))–\(pct(box.x + box.w)), y \(pct(box.y))–\(pct(box.y + box.h)), "
            + "\(pct(coverage)) of the frame, \(points.count) points"
    }

    /// Even-odd point-in-polygon test in canvas units.
    func contains(x: Double, y: Double) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let pi = points[i], pj = points[j]
            if (pi.y > y) != (pj.y > y),
               x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// A saved Screen Crop: one or more named areas laid out on the 9:16
/// canvas — e.g. "Split" with "top" and "bottom". Identity is the file
/// name, like overlay templates; areas are referenced as "Layout/Area".
nonisolated struct ScreenCropLayout: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var areas: [ScreenCropArea]

    var id: String { name }

    enum CodingKeys: String, CodingKey { case areas }

    init(name: String, areas: [ScreenCropArea] = []) {
        self.name = name
        self.areas = areas
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = ""
        areas = try container.decodeIfPresent([ScreenCropArea].self, forKey: .areas) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(areas, forKey: .areas)
    }

    /// "Layout/Area" for every area — the names clips and plans carry.
    var references: [String] {
        areas.map { ScreenCropStore.reference(layout: name, area: $0.name) }
    }
}

/// Loads, saves, and enumerates screen crops at
/// `~/Documents/ClipBuilder/assets/screen_crops/<Layout>.json`, and resolves
/// the "Layout/Area" references the Builder and AI Wizard store on clips.
nonisolated enum ScreenCropStore {
    // MARK: - Built-in layouts

    private static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [ScreenCropPoint] {
        [ScreenCropPoint(x: x0, y: y0), ScreenCropPoint(x: x1, y: y0),
         ScreenCropPoint(x: x1, y: y1), ScreenCropPoint(x: x0, y: y1)]
    }

    /// Ready-made layouts that ship with the app (not files; duplicate one
    /// in the Screen Crop section to customize it).
    static let builtIn: [ScreenCropLayout] = [
        ScreenCropLayout(name: "50-50 Horizontal", areas: [
            ScreenCropArea(name: "Top", points: rect(0, 0, 1, 0.5)),
            ScreenCropArea(name: "Bottom", points: rect(0, 0.5, 1, 1)),
        ]),
        ScreenCropLayout(name: "33-33-33 Horizontal", areas: [
            ScreenCropArea(name: "Top", points: rect(0, 0, 1, 1.0 / 3)),
            ScreenCropArea(name: "Middle", points: rect(0, 1.0 / 3, 1, 2.0 / 3)),
            ScreenCropArea(name: "Bottom", points: rect(0, 2.0 / 3, 1, 1)),
        ]),
        ScreenCropLayout(name: "50-50 Diagonal", areas: [
            ScreenCropArea(name: "Upper", points: [ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 0),
                                                   ScreenCropPoint(x: 1, y: 1)]),
            ScreenCropArea(name: "Lower", points: [ScreenCropPoint(x: 0, y: 0), ScreenCropPoint(x: 1, y: 1),
                                                   ScreenCropPoint(x: 0, y: 1)]),
        ]),
    ]

    static func isBuiltIn(_ name: String) -> Bool {
        builtIn.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Built-in layouts followed by the saved ones (a saved layout with a
    /// built-in's name wins, so a customized copy can shadow it).
    static func all() -> [ScreenCropLayout] {
        let custom = list()
        let shadowed = Set(custom.map { $0.name.lowercased() })
        return builtIn.filter { !shadowed.contains($0.name.lowercased()) } + custom
    }

    static func layout(named name: String?) -> ScreenCropLayout? {
        guard let name, !name.isEmpty else { return nil }
        return all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static var directory: URL {
        ProfileStore.profilesDirectory.appendingPathComponent("assets/screen_crops", isDirectory: true)
    }

    static func layoutURL(name: String) -> URL {
        directory.appendingPathComponent(ProfileStore.sanitize(name) + ".json")
    }

    static func list() -> [ScreenCropLayout] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> ScreenCropLayout? in
                guard let data = try? Data(contentsOf: url),
                      var layout = try? JSONDecoder().decode(ScreenCropLayout.self, from: data)
                else { return nil }
                layout.name = url.deletingPathExtension().lastPathComponent
                return layout
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ layout: ScreenCropLayout) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: layoutURL(name: layout.name))
    }

    /// Returns the final (sanitized) name.
    static func rename(_ name: String, to newName: String) throws -> String {
        let sanitized = ProfileStore.sanitize(newName)
        guard sanitized != ProfileStore.sanitize(name) else { return name }
        try FileManager.default.moveItem(at: layoutURL(name: name), to: layoutURL(name: sanitized))
        return sanitized
    }

    static func delete(name: String) throws {
        try FileManager.default.trashItem(at: layoutURL(name: name), resultingItemURL: nil)
    }

    /// "Name", "Name 2", "Name 3", … whichever is free.
    static func uniqueName(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "Screen Crop" : trimmed
        guard FileManager.default.fileExists(atPath: layoutURL(name: candidate).path) else {
            return candidate
        }
        var counter = 2
        while FileManager.default.fileExists(atPath: layoutURL(name: "\(candidate) \(counter)").path) {
            counter += 1
        }
        return "\(candidate) \(counter)"
    }

    // MARK: - References

    static func reference(layout: String, area: String) -> String {
        "\(layout)/\(area)"
    }

    /// Every "Layout/Area" reference across built-in and saved layouts.
    static func allReferences() -> [String] {
        all().flatMap(\.references)
    }

    /// Resolve "Layout/Area" (or just "Layout" for a single-area layout) to
    /// its polygon — case-insensitive on both parts, so the AI's casing
    /// never breaks a lookup. Nil when nothing matches.
    static func area(reference: String?) -> ScreenCropArea? {
        guard let reference, !reference.isEmpty else { return nil }
        let parts = reference.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let layoutName = parts.first, let layout = layout(named: layoutName) else { return nil }
        if parts.count == 2 {
            return layout.areas.first { $0.name.caseInsensitiveCompare(parts[1]) == .orderedSame }
        }
        return layout.areas.count == 1 ? layout.areas[0] : nil
    }

    // MARK: - Mask rendering

    /// A grayscale PNG the size of the output frame: white inside the area,
    /// black outside — what ffmpeg's alphamerge turns into the clip's alpha.
    @discardableResult
    static func writeMask(for area: ScreenCropArea, to url: URL,
                          width: Int = RenderEngine.outputWidth,
                          height: Int = RenderEngine.outputHeight) throws -> URL {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if area.points.count >= 3 {
            // CoreGraphics is bottom-up; the canvas is top-down.
            let path = CGMutablePath()
            for (index, point) in area.points.enumerated() {
                let cgPoint = CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height))
                if index == 0 { path.move(to: cgPoint) } else { path.addLine(to: cgPoint) }
            }
            path.closeSubpath()
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Resolve a clip's reference and write its mask into `directory`
    /// (named after the reference so repeated clips share one file). Nil
    /// when the reference no longer resolves — the clip then renders unmasked.
    static func maskFile(reference: String?, in directory: URL) -> URL? {
        guard let reference, let area = area(reference: reference) else { return nil }
        let file = directory.appendingPathComponent(
            "mask_" + ProfileStore.sanitize(reference.replacingOccurrences(of: "/", with: "_")) + ".png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        return try? writeMask(for: area, to: file)
    }
}
