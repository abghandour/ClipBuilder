import Foundation

/// Stable per-profile keys and source validation, independent of UserDefaults and views.
nonisolated enum MiniWizardMemory {
    enum Field: String, CaseIterable, Sendable {
        case videoPath, footageKind, length
        case quality, preset, cameraFocus, captions, englishCaptions, captionPosition, captionStyleID
        case nameTagContent, nameTagStyle, nameTagPosition
        case introVideo, outroVideo, nameTags, watermark, outputMode
    }

    static func key(for field: Field, profileName: String) -> String {
        "mini.\(profileName).\(field.rawValue)"
    }

    static func field(forKey key: String, profileName: String) -> Field? {
        let prefix = "mini.\(profileName)."
        guard key.hasPrefix(prefix) else { return nil }
        return Field(rawValue: String(key.dropFirst(prefix.count)))
    }

    /// Call only after loading the current project's eligible sources successfully.
    /// An absent or no-longer-analyzed video clears the answer; never choose a replacement.
    static func validatedVideoPath(_ path: String, videos: [VideoRecord]) -> String {
        videos.contains { $0.path == path && $0.analyzedAt != nil } ? path : ""
    }
}
