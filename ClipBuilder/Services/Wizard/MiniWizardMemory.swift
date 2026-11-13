import Foundation

/// Stable per-profile keys and source validation, independent of UserDefaults and views.
nonisolated enum MiniWizardMemory {
    enum Field: String, CaseIterable, Sendable {
        case videoPath, footageKind, length
        case broll, includeBRoll
        case framing
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

    /// The Highlights candidates' list order for a batch (selection ids),
    /// stored next to `mini.kept.<batch>`.
    static func highlightOrderKey(_ batchID: String) -> String { "mini.order.\(batchID)" }

    static func eligibleSource(_ video: VideoRecord, hasScenes: Bool = true, hasTranscript: Bool = false) -> Bool {
        video.isLocal && ((hasScenes && video.analyzedAt != nil) || hasTranscript)
    }

    /// Call only after loading the current project's eligible sources successfully.
    /// Missing sources clear the answer; never choose a replacement.
    static func validatedVideoPath(_ path: String, videos: [VideoRecord], transcribedIDs: Set<Int64> = []) -> String {
        videos.contains { $0.path == path && eligibleSource($0, hasTranscript: transcribedIDs.contains($0.id)) } ? path : ""
    }
}

extension MiniWizardMemory {
    static func batchKey(profileName: String, projectID: Int64, videoID: Int64,
                         kind: MiniWizardFlow.FootageKind, length: MiniWizardFlow.Length = .automatic) -> String {
        "mini.\(profileName).batch.\(projectID).\(videoID).\(kind.rawValue).\(length.rawValue)"
    }

    // Highlights are found on one transcript set. A batch remembers the
    // set it was found on, and only the active set's batch is offered.
    static func highlightSetKey(_ batchID: String) -> String { "mini.batchset.\(batchID)" }

    static func rememberHighlightBatch(_ batchID: String, profileName: String, projectID: Int64, videoID: Int64,
                                       length: MiniWizardFlow.Length, setKey: String, current: Bool = true,
                                       defaults: UserDefaults = .standard) {
        let key = batchKey(profileName: profileName, projectID: projectID, videoID: videoID, kind: .highlights, length: length)
        // `current` is false for a batch found on a set that is no longer
        // active: it is filed under its own set and offered there only.
        if current || setKey.isEmpty { defaults.set(batchID, forKey: key) }
        guard !setKey.isEmpty else { return }
        defaults.set(batchID, forKey: "\(key).set.\(setKey)")
        defaults.set(setKey, forKey: highlightSetKey(batchID))
    }

    /// The batch to offer while `setKey` is active. A batch from before
    /// sets were recorded has unknown provenance and is offered under any.
    static func highlightBatch(profileName: String, projectID: Int64, videoID: Int64, length: MiniWizardFlow.Length,
                               setKey: String, defaults: UserDefaults = .standard) -> String? {
        let key = batchKey(profileName: profileName, projectID: projectID, videoID: videoID, kind: .highlights, length: length)
        guard !setKey.isEmpty else { return defaults.string(forKey: key) }
        if let own = defaults.string(forKey: "\(key).set.\(setKey)") { return own }
        guard let last = defaults.string(forKey: key) else { return nil }
        let found = defaults.string(forKey: highlightSetKey(last))
        return found == nil || found == setKey ? last : nil
    }

    /// A batch that could not be restored is no longer offered.
    static func forgetHighlightBatch(_ batchID: String, profileName: String, projectID: Int64, videoID: Int64,
                                     length: MiniWizardFlow.Length, setKey: String, defaults: UserDefaults = .standard) {
        let key = batchKey(profileName: profileName, projectID: projectID, videoID: videoID, kind: .highlights, length: length)
        for candidate in [key, "\(key).set.\(setKey)"] where defaults.string(forKey: candidate) == batchID {
            defaults.removeObject(forKey: candidate)
        }
    }

    /// Before the set changes: every project's unrecorded Highlights batch
    /// of the video was found on the set in use until now.
    static func stampLegacyHighlightBatches(profileName: String, videoID: Int64, setKey: String,
                                            defaults: UserDefaults = .standard) {
        guard !setKey.isEmpty else { return }
        let prefix = "mini.\(profileName).batch."
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(prefix), !key.contains(".set."), let batchID = value as? String else { continue }
            let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[1] == String(videoID),
                  parts[2] == MiniWizardFlow.FootageKind.highlights.rawValue,
                  defaults.string(forKey: highlightSetKey(batchID)) == nil else { continue }
            defaults.set(setKey, forKey: highlightSetKey(batchID))
            defaults.set(batchID, forKey: "\(key).set.\(setKey)")
        }
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
