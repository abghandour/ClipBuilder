import Foundation

/// Stable per-profile keys and source validation, independent of UserDefaults and views.
nonisolated enum MiniWizardMemory {
    enum Field: String, CaseIterable, Sendable {
        case videoPath, footageKind, length
        case broll, includeBRoll
        case quality, preset, cameraFocus, interviewZoom, interviewZoomMoves, interviewCuts, interviewPunchIn, captions, englishCaptions, captionPosition, speakerCaptionPositions, captionStyleID
        case safeAreaOnly, safeAreaPlatforms
        case nameTagContent, nameTagStyle, nameTagStyleID, nameTagPosition
        case introVideo, outroVideo, nameTags, watermark, outputMode
        case overlay, overlayTemplate, overlayStart, overlayDuration, overlayTexts, overlayPosition, overlayEdits
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

extension MiniWizardMemory {
    static func batchKey(profileName: String, projectID: Int64, videoID: Int64,
                         kind: MiniWizardFlow.FootageKind, length: MiniWizardFlow.Length = .automatic) -> String {
        "mini.\(profileName).batch.\(projectID).\(videoID).\(kind.rawValue).\(length.rawValue)"
    }

    static func batchID(profileName: String, projectID: Int64, videoID: Int64,
                        kind: MiniWizardFlow.FootageKind, defaults: UserDefaults = .standard) -> String {
        let key = batchKey(profileName: profileName, projectID: projectID, videoID: videoID, kind: kind)
        if let saved = defaults.string(forKey: key) { return saved }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
