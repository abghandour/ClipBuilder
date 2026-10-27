import CoreGraphics
import Foundation

/// One component of a fixed overlay design the user can place by hand in
/// the Wizard preview: a text or an image, by its position among the
/// template's texts or images.
nonisolated enum OverlayComponent: Hashable, Sendable {
    case text(Int)
    case image(Int)

    var label: String {
        switch self {
        case .text(let index): "overlay text \(index + 1)"
        case .image(let index): "overlay image \(index + 1)"
        }
    }
}

/// What the user changed about one of a fixed overlay's texts beyond its
/// words: the alignment, and the box it was moved or resized to in the
/// preview (design coordinates, canvas fractions). Everything is optional
/// so an untouched text stays as designed.
nonisolated struct OverlayTextEdit: Codable, Hashable, Sendable {
    /// "left", "center" or "right"; nil keeps the design's alignment.
    var alignment: String?
    var x: Double?
    var y: Double?
    var w: Double?
    var h: Double?

    init(alignment: String? = nil, box: CGRect? = nil) {
        self.alignment = alignment
        self.box = box
    }

    var isEmpty: Bool { alignment == nil && box == nil }

    /// The hand-placed box as canvas fractions; nil when the text keeps the
    /// design's box.
    var box: CGRect? {
        get {
            guard let x, let y, let w, let h, w > 0, h > 0, x.isFinite, y.isFinite, w.isFinite, h.isFinite else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        set {
            guard let rect = newValue, rect.width > 0, rect.height > 0 else {
                x = nil; y = nil; w = nil; h = nil
                return
            }
            x = OverlayEdits.rounded(rect.minX)
            y = OverlayEdits.rounded(rect.minY)
            w = OverlayEdits.rounded(rect.width)
            h = OverlayEdits.rounded(rect.height)
        }
    }
}

/// Where the user moved or resized one of a fixed overlay's images: its
/// centre and width as canvas fractions (the height follows the file).
nonisolated struct OverlayImageEdit: Codable, Hashable, Sendable {
    var x: Double?
    var y: Double?
    var w: Double?

    init(center: CGPoint? = nil, width: Double? = nil) {
        if let center { x = OverlayEdits.rounded(center.x); y = OverlayEdits.rounded(center.y) }
        if let width, width > 0 { w = OverlayEdits.rounded(width) }
    }

    var isEmpty: Bool { center == nil && width == nil }
    var center: CGPoint? {
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
    var width: Double? {
        guard let w, w > 0, w.isFinite else { return nil }
        return w
    }
}

/// Every hand placement of a fixed overlay's components, indexed by the
/// component's position in the template. Stored as one JSON string so
/// presets and defaults carry it as a scalar.
nonisolated struct OverlayEdits: Codable, Hashable, Sendable {
    var texts: [OverlayTextEdit] = []
    var images: [OverlayImageEdit] = []

    init(texts: [OverlayTextEdit] = [], images: [OverlayImageEdit] = []) {
        self.texts = texts
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        texts = try c.decodeIfPresent([OverlayTextEdit].self, forKey: .texts) ?? []
        images = try c.decodeIfPresent([OverlayImageEdit].self, forKey: .images) ?? []
    }

    var isEmpty: Bool { texts.allSatisfy(\.isEmpty) && images.allSatisfy(\.isEmpty) }

    /// Change one text's edit, padding the list so earlier texts keep theirs.
    mutating func text(_ index: Int, _ change: (inout OverlayTextEdit) -> Void) {
        guard index >= 0 else { return }
        while texts.count <= index { texts.append(OverlayTextEdit()) }
        change(&texts[index])
    }

    mutating func image(_ index: Int, _ change: (inout OverlayImageEdit) -> Void) {
        guard index >= 0 else { return }
        while images.count <= index { images.append(OverlayImageEdit()) }
        change(&images[index])
    }

    /// Record where a component was dropped in the preview (design
    /// coordinates, canvas fractions): a text takes the whole box, an image
    /// its centre and width.
    mutating func place(_ component: OverlayComponent, at box: CGRect) {
        switch component {
        case .text(let index): text(index) { $0.box = box }
        case .image(let index): image(index) { $0 = OverlayImageEdit(center: CGPoint(x: box.midX, y: box.midY), width: box.width) }
        }
    }

    /// Drops untouched tails; nil when nothing was edited.
    var trimmed: OverlayEdits? {
        var result = self
        while result.texts.last?.isEmpty == true { result.texts.removeLast() }
        while result.images.last?.isEmpty == true { result.images.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// The edits as one JSON string ("" when nothing was edited), for
    /// UserDefaults and preset fields.
    var joined: String {
        guard let trimmed else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trimmed) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func split(_ joined: String?) -> OverlayEdits {
        guard let joined, !joined.isEmpty, let data = joined.data(using: .utf8),
              let edits = try? JSONDecoder().decode(OverlayEdits.self, from: data) else { return OverlayEdits() }
        return edits
    }

    static func rounded(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
}
