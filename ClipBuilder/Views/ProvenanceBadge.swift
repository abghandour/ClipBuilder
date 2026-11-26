import SwiftUI

/// The vendor mark for one AI provider — a template image from the asset
/// catalog tinted with the brand color, or an SF Symbol for unknown keys.
struct ProviderLogo: View {
    let brand: AIProviderBrand
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let asset = brand.logoAsset {
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .accessibilityLabel(brand.label)
    }

    private var tint: Color {
        brand.tintHex.flatMap(Color.init(hex:)) ?? .primary
    }
}

/// A menu row that opens with a provider's mark. Menus draw an image at its
/// own size and in the menu's text color, so the mark is a 14-point
/// template copy and carries no brand tint here.
struct ProviderMenuLabel: View {
    let title: String
    let brand: AIProviderBrand

    private var mark: Image {
        guard let asset = brand.logoAsset, let source = NSImage(named: asset),
              let copy = source.copy() as? NSImage else { return Image(systemName: "sparkles") }
        copy.size = NSSize(width: 14, height: 14)
        copy.isTemplate = true
        return Image(nsImage: copy)
    }

    var body: some View {
        // Named, so a closed menu's button shows the mark too.
        Label { Text(title) } icon: { mark.accessibilityLabel(brand.label) }
            .labelStyle(.titleAndIcon)
    }
}

nonisolated extension Color {
    /// "#RRGGBB" → Color; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
