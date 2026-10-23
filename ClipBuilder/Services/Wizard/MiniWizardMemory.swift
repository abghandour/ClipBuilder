import Foundation

/// Stable per-profile keys and source validation, independent of UserDefaults and views.
nonisolated enum MiniWizardMemory {
    enum Field: String, CaseIterable, Sendable {
        case videoPath, footageKind, length
        case quality, preset, cameraFocus, interviewZoom, interviewZoomMoves, captions, englishCaptions, captionPosition, captionStyleID
        case safeAreaOnly, safeAreaPlatforms
        case nameTagContent, nameTagStyle, nameTagStyleID, nameTagPosition
        case introVideo, outroVideo, nameTags, watermark, outputMode
        case overlay, overlayTemplate, overlayStart, overlayDuration, overlayTexts, overlayPosition
        case introBumper, outroBumper, watermarkOverlay, watermarkOpacity, transition, look
        case muteSourceAudio, music, musicTrack, settingsTab, dub, dubLanguage
    }

    static func key(for field: Field, profileName: String) -> String {
        "mini.\(profileName).\(field.rawValue)"
    }

    static func field(forKey key: String, profileName: String) -> Field? {
        let prefix = "mini.\(profileName)."
        guard key.hasPrefix(prefix) else { return nil }
        return Field(rawValue: String(key.dropFirst(prefix.count)))
    }

    /// The Q&A exchanges kept for a video. Nothing is kept until the user
    /// ticks an exchange; the ticks are remembered per profile and video
    /// across launches. Stored as a comma-joined list of section (scene) IDs.
    static func qaKeptKey(profileName: String, videoID: Int64) -> String {
        "mini.\(profileName).qaKept.\(videoID)"
    }

    static func qaKept(profileName: String, videoID: Int64, defaults: UserDefaults = .standard) -> Set<Int64> {
        Set((defaults.string(forKey: qaKeptKey(profileName: profileName, videoID: videoID)) ?? "")
            .split(separator: ",").compactMap { Int64($0) })
    }

    static func saveQAKept(_ kept: Set<Int64>, profileName: String, videoID: Int64,
                           defaults: UserDefaults = .standard) {
        let key = qaKeptKey(profileName: profileName, videoID: videoID)
        if kept.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(kept.sorted().map(String.init).joined(separator: ","), forKey: key) }
    }

    /// Call only after loading the current project's eligible sources successfully.
    /// An absent or no-longer-analyzed video clears the answer; never choose a replacement.
    static func validatedVideoPath(_ path: String, videos: [VideoRecord]) -> String {
        videos.contains { $0.path == path && $0.analyzedAt != nil } ? path : ""
    }
}
