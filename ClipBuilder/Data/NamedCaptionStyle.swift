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

    func captionStyle(forPerson key: String, runStyleID: String?) -> CaptionStyle {
        guard let id = personCaptionStyles?[key], let uuid = UUID(uuidString: id),
              let named = captionStyles?.first(where: { $0.id == uuid }) else {
            return captionStyle(id: runStyleID)
        }
        return named.style
    }

    /// Keep only valid overrides that change the run's appearance.
    func speakerCaptionStyles(runStyleID: String?) -> [String: CaptionStyle] {
        let runStyle = captionStyle(id: runStyleID)
        var styles: [String: CaptionStyle] = [:]
        for (key, id) in personCaptionStyles ?? [:] {
            guard let uuid = UUID(uuidString: id),
                  let named = captionStyles?.first(where: { $0.id == uuid }),
                  named.style != runStyle else { continue }
            styles[key] = named.style
        }
        return styles
    }
}

nonisolated extension WizardOptions {
    /// Unknown or old values retain the profile's placement and layout
    /// behavior; a dragged `custom:x,y` position passes through.
    var captionPositionOverride: String? {
        guard let captionPosition,
              ["bottom", "middle", "top"].contains(captionPosition) || CustomPosition.isCustom(captionPosition)
        else { return nil }
        return captionPosition
    }
}
