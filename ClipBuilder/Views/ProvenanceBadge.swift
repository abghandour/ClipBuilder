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
