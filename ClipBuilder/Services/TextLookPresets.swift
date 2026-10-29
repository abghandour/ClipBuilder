import Foundation

/// View-layer starter looks; no stored style schema or renderer changes.
nonisolated enum TextLookPresets {
    static let tags: [NamedTagStyle] = [
        NamedTagStyle(name: "Classic", style: TagStyle()),
        NamedTagStyle(name: "Clean", style: TagStyle(alignment: "center", bgOn: false)),
        NamedTagStyle(
            name: "Gold",
            style: TagStyle(
                name: TagLineStyle(font: "Archivo Black", color: "#FFD60A"),
                description: TagLineStyle(field: "Role", scale: 0.72), bgColor: "#171717", cornerRadius: 8))
    ]
}
