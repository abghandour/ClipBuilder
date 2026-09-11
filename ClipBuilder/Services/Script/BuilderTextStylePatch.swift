import Foundation

/// A closed patch preserves the distinction between an omitted field and null.
nonisolated struct BuilderTextStylePatch: Codable, Sendable, Equatable {
    var fields: [String: ScriptValue]

    init(_ fields: [String: ScriptValue]) { self.fields = fields }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ScriptKey.self)
        try c.only(Self.allowedFields)
        fields = try Dictionary(uniqueKeysWithValues: c.allKeys.map {
            ($0.stringValue, try c.decode(ScriptValue.self, forKey: $0))
        })
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ScriptKey.self)
        for (key, value) in fields { try c.encode(value, forKey: ScriptKey(key)) }
    }

    static let allowedFields: Set<String> = ["fontsize", "fontcolor", "fontfamily", "bold", "italic", "bgcolor", "box_opacity", "box_radius", "opacity", "stroke_color", "stroke_width_em", "shadow_opacity", "highlight_color", "design", "kicker", "accent_color"]
    /// The designs TextOverlayRenderer draws; anything else renders as plain text.
    static let designs = ["hero", "tag"]
    static let nullableFields: Set<String> = ["bgcolor", "box_radius", "stroke_color", "highlight_color", "design", "kicker", "accent_color"]

    func validate() throws {
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: Self.allowedFields) else {
            throw BuilderCommandFailure.invalid("Text style requires known patch fields.")
        }
        for (key, value) in fields {
            if value == .null, Self.nullableFields.contains(key) { continue }
            switch (key, value) {
            case ("fontsize", .number(let size)):
                guard size.isFinite, (8...400).contains(size), size.rounded() == size else {
                    throw BuilderCommandFailure.bounds("fontsize must be an integer from 8 to 400.")
                }
            case ("box_opacity", .number(let number)), ("opacity", .number(let number)),
                 ("stroke_width_em", .number(let number)), ("shadow_opacity", .number(let number)):
                guard number.isFinite, (0...1).contains(number) else {
                    throw BuilderCommandFailure.bounds("Style opacity/width must be within 0...1.")
                }
            case ("box_radius", .number(let number)):
                guard number.isFinite, number >= 0 else { throw BuilderCommandFailure.bounds("Invalid box radius.") }
            case ("bold", .bool), ("italic", .bool): break
            case ("fontcolor", .string(let color)), ("bgcolor", .string(let color)),
                 ("stroke_color", .string(let color)), ("highlight_color", .string(let color)),
                 ("accent_color", .string(let color)):
                guard Self.validColor(color) else { throw BuilderCommandFailure.invalid("Invalid color: \(color).") }
            case ("design", .string(let design)):
                guard Self.designs.contains(design) else {
                    throw BuilderCommandFailure.invalid("design must be one of \(Self.designs.joined(separator: ", ")) or null.")
                }
            case ("fontfamily", .string(let text)), ("kicker", .string(let text)):
                guard text.utf8.count <= 16384 else { throw BuilderCommandFailure.invalid("Style text exceeds 16 KiB.") }
            default: throw BuilderCommandFailure.invalid("Invalid type for style field \(key).")
            }
        }
    }

    /// Match the renderer's names, #/0x prefix, shorthand and first-six-digit rule.
    private static func validColor(_ value: String) -> Bool {
        var hex = value.trimmingCharacters(in: .whitespaces).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.hasPrefix("0x") { hex.removeFirst(2) }
        else { return ["white", "black", "red", "yellow"].contains(hex) }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        return hex.count >= 6 && UInt32(hex.prefix(6), radix: 16) != nil
    }

    func applying(to original: TextOverlayItem) throws -> TextOverlayItem {
        try validate()
        var item = original
        for (key, value) in fields {
            switch (key, value) {
            case ("fontsize", .number(let value)): item.fontsize = Int(value)
            case ("fontcolor", .string(let value)): item.fontcolor = value
            case ("fontfamily", .string(let value)): item.fontfamily = value
            case ("bold", .bool(let value)): item.bold = value
            case ("italic", .bool(let value)): item.italic = value
            case ("bgcolor", .string(let value)): item.bgcolor = value
            case ("bgcolor", .null): item.bgcolor = nil
            case ("box_opacity", .number(let value)): item.boxOpacity = value
            case ("box_radius", .number(let value)): item.boxRadius = value
            case ("box_radius", .null): item.boxRadius = nil
            case ("opacity", .number(let value)): item.opacity = value
            case ("stroke_color", .string(let value)): item.strokeColor = value
            case ("stroke_color", .null): item.strokeColor = nil
            case ("stroke_width_em", .number(let value)): item.strokeWidthEm = value
            case ("shadow_opacity", .number(let value)): item.shadowOpacity = value
            case ("highlight_color", .string(let value)): item.highlightColor = value
            case ("highlight_color", .null): item.highlightColor = nil
            case ("design", .string(let value)): item.design = value
            case ("design", .null): item.design = nil
            case ("kicker", .string(let value)): item.kicker = value
            case ("kicker", .null): item.kicker = nil
            case ("accent_color", .string(let value)): item.accentColor = value
            case ("accent_color", .null): item.accentColor = nil
            default: break // validate() has already refused every other case.
            }
        }
        return item
    }
}
