import Foundation

nonisolated struct TagLineStyle: Codable, Sendable, Hashable {
    var field: String = "Name"
    var font: String? = nil
    var scale: Double = 1
    var color: String = "#ffffff"
    var bold: Bool = true
    var italic: Bool = false
    var uppercase: Bool = false
    var underline: Bool = false
    var underlineColor: String? = nil
    var underlineThickness: Double = 0.06

    enum CodingKeys: String, CodingKey {
        case field
        case font
        case scale
        case color
        case bold
        case italic
        case uppercase
        case underline
        case underlineColor = "underline_color"
        case underlineThickness = "underline_thickness"
    }

    init(field: String = "Name", font: String? = nil, scale: Double = 1, color: String = "#ffffff",
         bold: Bool = true, italic: Bool = false, uppercase: Bool = false, underline: Bool = false,
         underlineColor: String? = nil, underlineThickness: Double = 0.06) {
        self.field = field
        self.font = font
        self.scale = scale
        self.color = color
        self.bold = bold
        self.italic = italic
        self.uppercase = uppercase
        self.underline = underline
        self.underlineColor = underlineColor
        self.underlineThickness = underlineThickness
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        field = try values.decodeIfPresent(String.self, forKey: .field) ?? "Name"
        font = try values.decodeIfPresent(String.self, forKey: .font)
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? "#ffffff"
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        uppercase = try values.decodeIfPresent(Bool.self, forKey: .uppercase) ?? false
        underline = try values.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        underlineColor = try values.decodeIfPresent(String.self, forKey: .underlineColor)
        underlineThickness = try values.decodeIfPresent(Double.self, forKey: .underlineThickness) ?? 0.06
    }
}

nonisolated struct TagImage: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var path: String = ""
    var x: Double = 0.5
    var y: Double = 0.5
    var width: Double = 0.25
    var opacity: Double = 1
    var behindText: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case x
        case y
        case width
        case opacity
        case behindText = "behind_text"
    }

    init(id: UUID = UUID(), path: String = "", x: Double = 0.5, y: Double = 0.5,
         width: Double = 0.25, opacity: Double = 1, behindText: Bool = true) {
        self.id = id
        self.path = path
        self.x = x
        self.y = y
        self.width = width
        self.opacity = opacity
        self.behindText = behindText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        x = try values.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try values.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 0.25
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        behindText = try values.decodeIfPresent(Bool.self, forKey: .behindText) ?? true
    }
}

nonisolated struct TagStyle: Codable, Sendable, Hashable {
    var name: TagLineStyle = TagLineStyle(font: "Archivo Black")
    var description: TagLineStyle = TagLineStyle(field: "Role", font: "Archivo Black", scale: 0.72)
    var alignment: String = "leading"
    var bgOn: Bool = true
    var bgColor: String = "#101010"
    var bgOpacity: Double = 0.82
    var cornerRadius: Double = 4
    var images: [TagImage] = []

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case alignment
        case bgOn = "bg_on"
        case bgColor = "bg_color"
        case bgOpacity = "bg_opacity"
        case cornerRadius = "corner_radius"
        case images
    }

    init(name: TagLineStyle = TagLineStyle(font: "Archivo Black"),
         description: TagLineStyle = TagLineStyle(field: "Role", font: "Archivo Black", scale: 0.72),
         alignment: String = "leading", bgOn: Bool = true, bgColor: String = "#101010",
         bgOpacity: Double = 0.82, cornerRadius: Double = 4, images: [TagImage] = []) {
        self.name = name
        self.name.field = "Name"
        self.description = description
        self.alignment = alignment
        self.bgOn = bgOn
        self.bgColor = bgColor
        self.bgOpacity = bgOpacity
        self.cornerRadius = cornerRadius
        self.images = images
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(TagLineStyle.self, forKey: .name) ?? TagLineStyle(font: "Archivo Black")
        description = try values.decodeIfPresent(TagLineStyle.self, forKey: .description) ?? TagLineStyle(field: "Role", font: "Archivo Black", scale: 0.72)
        alignment = try values.decodeIfPresent(String.self, forKey: .alignment) ?? "leading"
        bgOn = try values.decodeIfPresent(Bool.self, forKey: .bgOn) ?? true
        bgColor = try values.decodeIfPresent(String.self, forKey: .bgColor) ?? "#101010"
        bgOpacity = try values.decodeIfPresent(Double.self, forKey: .bgOpacity) ?? 0.82
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 4
        images = try values.decodeIfPresent([TagImage].self, forKey: .images) ?? []
        name.field = "Name"
    }
}

nonisolated struct NamedTagStyle: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String = "New Style"
    var style: TagStyle = TagStyle()

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case style
    }

    init(id: UUID = UUID(), name: String = "New Style", style: TagStyle = TagStyle()) {
        self.id = id
        self.name = name
        self.style = style
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "New Style"
        style = try values.decodeIfPresent(TagStyle.self, forKey: .style) ?? TagStyle()
    }
}

nonisolated extension BrandProfile {
    func tagStyle(id: String?) -> TagStyle {
        guard let id, let uuid = UUID(uuidString: id),
              let named = tagStyles?.first(where: { $0.id == uuid }) else { return tagStyle ?? TagStyle() }
        return named.style
    }
}
