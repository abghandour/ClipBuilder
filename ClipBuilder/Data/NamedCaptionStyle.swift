import Foundation

nonisolated struct NamedCaptionStyle: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var name: String
    var style: CaptionStyle
}

nonisolated extension BrandProfile {
    func withCaptionStyle(id: String?) -> Self {
        var copy = self
        copy.captions = captionStyle(id: id)
        return copy
    }

    func captionStyle(id: String?) -> CaptionStyle {
        guard let id, let uuid = UUID(uuidString: id),
              let named = captionStyles?.first(where: { $0.id == uuid }) else { return captions }
        return named.style
    }
}

nonisolated extension WizardOptions {
    /// Unknown or old values retain the profile's placement and layout behavior.
    var captionPositionOverride: String? {
        guard let captionPosition, ["bottom", "middle", "top"].contains(captionPosition) else { return nil }
        return captionPosition
    }
}
