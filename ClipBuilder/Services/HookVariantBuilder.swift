import Foundation

/// One alternative opening for a hook comparison: either a cold open (a
/// short copy of another clip's footage placed before the body) or
/// different opening text.
nonisolated struct HookAlternative: Codable, Sendable, Hashable {
    enum Mode: String, Codable, Sendable, Hashable {
        case firstClip = "first_clip"
        case openingText = "opening_text"
    }

    var label: String
    var mode: Mode
    /// `firstClip`: the scene of an existing clip whose footage becomes the
    /// cold open.
    var sceneID: Int64?
    /// `openingText`: the text shown over the first seconds.
    var overlayText: String?
    var reason: String?
}

/// Builds controlled hook comparisons from one Builder timeline: variants
/// that differ only in the opening, plus the prompt and parser for the
/// `.hooks` AI task and the readout rows. Pure; no database or network.
nonisolated enum HookVariantBuilder {
    static let originalLabel = "Original"
    static let maxAlternatives = 3
    /// Length of an inserted opening text overlay, seconds.
    static let insertedTextDuration = 2.5
    /// Longest cold open, seconds.
    static let maxColdOpenDuration = 3.0

    /// Shown under every readout. Organic posts reach different audiences at
    /// different times, so the numbers are a hint, never a verdict.
    static let readoutCaveat = """
        These are organic posts, not a randomized test: each went out at a different time to \
        whoever Instagram chose to show it to. Differences in the numbers can come from timing, \
        audience, or chance as much as from the hook, so no winner is declared.
        """

    // MARK: - Variants

    /// The opening footage: main clips on the first track, in timeline order.
    static func openingTrack(_ document: TimelineDocument) -> [TimelineClip] {
        document.mainClips(inTrack: 0)
    }

    /// Whether `firstClip` (cold open) alternatives are safe for `document`.
    /// A cold open re-times only the first track's main clips and the
    /// overlays and music, so a document with anything else timed against
    /// the footage (clips on other tracks, B-roll or bumpers, overlay
    /// blocks, crop blocks, dub lines, source-bound stat overlays) would
    /// desync; such documents get `openingText` alternatives only.
    static func allowsClipAlternatives(_ document: TimelineDocument) -> Bool {
        document.videoTrack.allSatisfy { $0.track == 0 && $0.role == .main && !$0.bumper }
            && document.overlayBlocks.isEmpty
            && document.cropBlocks.isEmpty
            && (document.dubLines ?? []).isEmpty
            && !document.textOverlays.contains { $0.stat != nil }
    }

    /// Variant documents for `alternatives` (the base itself is not
    /// included). `firstClip` builds a cold open (see `coldOpen`) and is
    /// skipped when `allowsClipAlternatives` is false. `openingText`
    /// replaces the text of the earliest plain overlay starting before
    /// `openingWindow` (split at the window when it runs longer), or
    /// inserts one at the start when none does. Alternatives that would not
    /// change the timeline, or that repeat an earlier variant, are dropped.
    static func variants(base: TimelineDocument, alternatives: [HookAlternative],
                         openingWindow: Double = 3) -> [(label: String, document: TimelineDocument)] {
        let clipsAllowed = allowsClipAlternatives(base)
        var result: [(label: String, document: TimelineDocument)] = []
        // A cold open gets fresh clip identities, so repeats are caught by
        // what they ask for as well as by the resulting document.
        var seen: Set<String> = []
        for alternative in alternatives {
            let key = switch alternative.mode {
            case .firstClip: "clip:\(alternative.sceneID.map(String.init) ?? "")"
            case .openingText: "text:\(alternative.overlayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
            }
            guard !seen.contains(key) else { continue }
            let document: TimelineDocument?
            switch alternative.mode {
            case .firstClip:
                document = clipsAllowed ? alternative.sceneID.flatMap { coldOpen(sceneID: $0, in: base) } : nil
            case .openingText:
                document = alternative.overlayText.flatMap {
                    replacingOpeningText($0, in: base, openingWindow: openingWindow)
                }
            }
            guard let document, document != base,
                  !result.contains(where: { $0.document == document }) else { continue }
            seen.insert(key)
            result.append((alternative.label, document))
        }
        return result
    }

    /// The base with a cold open: the first-track opener is replaced by a NEW
    /// clip copied from the first-track clip showing `sceneID` (same scene and
    /// file, same source start, length = min(old opener, that clip, 3 s),
    /// fresh uid and origin key). The body (every first-track clip after the
    /// opener) is unchanged apart from moving by the opener's length change,
    /// and text overlays, image overlays and music move with it. Nil when no
    /// such clip exists or it already opens. Callers check
    /// `allowsClipAlternatives` first.
    static func coldOpen(sceneID: Int64, in base: TimelineDocument) -> TimelineDocument? {
        let clips = openingTrack(base)
        guard let index = clips.firstIndex(where: { $0.sceneID == sceneID }), index > 0 else { return nil }
        let oldOpener = clips[0], source = clips[index]
        let duration = min(oldOpener.duration, source.duration, maxColdOpenDuration)
        guard duration > 0.05 else { return nil }
        var opener = source
        opener.uid = UUID()
        opener.originKey = UUID().uuidString
        opener.startTime = oldOpener.startTime
        opener.duration = duration
        opener.sourceStart = source.sourceStart
        opener.sourceEnd = source.sourceStart.map { $0 + duration * source.effectiveSpeed }
        let oldEnd = oldOpener.startTime + oldOpener.duration
        let newEnd = opener.startTime + duration
        let delta = newEnd - oldEnd   // <= 0: the body moves left by the shortening
        var document = base
        document.videoTrack = base.videoTrack.map { clip in
            if clip.uid == oldOpener.uid { return opener }
            var moved = clip
            moved.startTime += delta
            return moved
        }
        guard delta < -1e-9 else { return document }
        // Everything else timed on the timeline closes up the same stretch.
        let map = TimelineCutMap(removed: [newEnd..<oldEnd])
        let minimumPiece = 0.1
        document.textOverlays = base.textOverlays.compactMap { item in
            let start = map.time(item.startTime), end = map.time(item.endTime)
            guard end - start >= minimumPiece else { return nil }
            var moved = item
            moved.startTime = start
            moved.endTime = end
            return moved
        }
        document.imageOverlays = base.imageOverlays.compactMap { item in
            let start = map.time(item.startTime), end = map.time(item.endTime)
            guard end - start >= minimumPiece else { return nil }
            var moved = item
            moved.startTime = start
            moved.endTime = end
            moved.track = item.track?.map { key in
                var shifted = key
                shifted.time = map.time(key.time)
                return shifted
            }
            return moved
        }
        // Music stays in step with the body: an item that plays into the body
        // is shifted by the delta, and when that would move it before where
        // it may start, its head is trimmed (the song continues where it was).
        document.soundTrack = base.soundTrack.compactMap { item in
            let end = item.startTime + item.duration
            var moved = item
            if end <= oldEnd + 1e-9 {
                // Plays only under the opener: keep it inside the new one.
                moved.startTime = min(item.startTime, newEnd)
                moved.duration = min(end, newEnd) - moved.startTime
            } else {
                let shifted = item.startTime + delta
                let start = max(shifted, min(item.startTime, newEnd))
                moved.sourceOffset += start - shifted
                moved.startTime = start
                moved.duration = end + delta - start
            }
            return moved.duration >= minimumPiece ? moved : nil
        }
        return document
    }

    /// The base with `text` as the opening overlay; nil when the text is
    /// blank or already the opening text. An overlay that runs past
    /// `openingWindow` is split there: the opening piece gets `text`, the
    /// rest keeps its original text.
    static func replacingOpeningText(_ text: String, in base: TimelineDocument,
                                     openingWindow: Double = 3) -> TimelineDocument? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var document = base
        if let index = openingOverlayIndex(base, openingWindow: openingWindow) {
            let original = base.textOverlays[index]
            guard original.text != trimmed else { return nil }
            document.textOverlays[index].text = trimmed
            if original.endTime > openingWindow + 1e-9 {
                document.textOverlays[index].endTime = openingWindow
                var rest = original
                rest.uid = UUID()
                rest.startTime = openingWindow
                document.textOverlays.insert(rest, at: index + 1)
            }
        } else {
            var overlay = TextOverlayItem()
            overlay.text = trimmed
            overlay.startTime = 0
            overlay.endTime = insertedTextDuration
            overlay.position = "top"
            overlay.bold = true
            document.textOverlays.insert(overlay, at: 0)
        }
        return document
    }

    /// Whether an overlay is plain opening text a hook may rewrite: not a
    /// name tag (tag design or a tag style) and not a strike stat card.
    static func isPlainText(_ item: TextOverlayItem) -> Bool {
        item.stat == nil && item.design != "tag" && item.tagStyle == nil
    }

    /// The earliest plain text overlay that starts inside the opening.
    static func openingOverlayIndex(_ document: TimelineDocument, openingWindow: Double = 3) -> Int? {
        document.textOverlays.indices
            .filter { document.textOverlays[$0].startTime < openingWindow && isPlainText(document.textOverlays[$0]) }
            .min { document.textOverlays[$0].startTime < document.textOverlays[$1].startTime }
    }

    // MARK: - Prompt

    /// `allowClipAlternatives` false (see `allowsClipAlternatives`) asks for
    /// `opening_text` alternatives only.
    static func prompt(document: TimelineDocument, scenes: [SceneRecord], allowClipAlternatives: Bool) -> String {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clips = openingTrack(document)
        let lines = clips.enumerated().map { index, clip -> String in
            let scene = clip.sceneID.flatMap { byID[$0] }
            let blurb = sceneBlurb(scene)
            let id = clip.sceneID.map(String.init) ?? "none"
            return "\(index). scene_id \(id) · \(String(format: "%.1f", clip.duration)) s · \(blurb)"
        }
        let opening = openingOverlayIndex(document).map { document.textOverlays[$0].text } ?? ""
        let kinds = allowClipAlternatives
            ? """
                Each is ONE of:
                - "first_clip": a cold open. Give the scene_id of one of the clips above (not clip 0); up to \
                3 s of its footage plays first, replacing clip 0, and the rest plays unchanged.
                - "opening_text": new on-screen text for the first seconds. Give overlay_text, at most 8 words.
                Mix the two kinds when the footage allows.
                """
            : """
                Every alternative must be "opening_text": new on-screen text for the first seconds. Give \
                overlay_text, at most 8 words. The footage cannot change in this video (other tracks, B-roll \
                or dubbing are timed against it), so do not propose "first_clip".
                """
        let modes = allowClipAlternatives ? "\"first_clip\"|\"opening_text\"" : "\"opening_text\""
        return """
            You are improving the HOOK (the first 1–3 seconds) of a short vertical video. Everything \
            after the opening stays exactly as it is; only the opening changes.

            ## Clips, in order (index · scene · length · what happens)
            \(lines.joined(separator: "\n"))

            ## Current opening text
            \(opening.isEmpty ? "None." : "\"\(opening)\"")

            ## Task
            Propose \(maxAlternatives) alternative openings that would stop a viewer scrolling. \(kinds)
            Give each a short distinct label (2–4 words) and a one-sentence reason.

            Respond with JSON only:
            {"alternatives":[{"label":"...","mode":\(modes),"scene_id":123,\
            "overlay_text":"...","reason":"..."}]}
            """
    }

    private static func sceneBlurb(_ scene: SceneRecord?) -> String {
        guard let scene else { return "(no scene)" }
        if let narrative = scene.narrative?.trimmingCharacters(in: .whitespacesAndNewlines), !narrative.isEmpty {
            return String(narrative.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        }
        if !scene.tags.isEmpty { return scene.tags.prefix(8).joined(separator: ", ") }
        return scene.videoFilename
    }

    /// Valid alternatives from a `.hooks` response: known mode, a scene that
    /// is on the first track and not already opening (and cold opens allowed
    /// for the document), non-blank text, and a
    /// unique label that is not "Original". At most `maxAlternatives`.
    static func parseAlternatives(_ raw: String, document: TimelineDocument) -> [HookAlternative] {
        guard let object = AIResponseParser.jsonObject(from: raw),
              let items = object["alternatives"] as? [[String: Any]] else { return [] }
        let clips = openingTrack(document)
        // No cold opens when the document has footage-timed tracks.
        let movable = allowsClipAlternatives(document) ? Set(clips.dropFirst().compactMap(\.sceneID)) : []
        var labels: Set<String> = [originalLabel.lowercased()]
        var result: [HookAlternative] = []
        for item in items {
            guard result.count < maxAlternatives else { break }
            let modeText = (item["mode"] as? String ?? "").lowercased().replacingOccurrences(of: "-", with: "_")
            let mode: HookAlternative.Mode
            switch modeText {
            case "first_clip", "firstclip": mode = .firstClip
            case "opening_text", "openingtext": mode = .openingText
            default: continue
            }
            let sceneID = (item["scene_id"] as? NSNumber)?.int64Value
                ?? (item["scene_id"] as? String).flatMap { Int64($0) }
            let text = (item["overlay_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch mode {
            case .firstClip:
                guard let sceneID, movable.contains(sceneID) else { continue }
            case .openingText:
                guard let text, !text.isEmpty else { continue }
            }
            var label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if label.isEmpty { label = "Hook \(result.count + 1)" }
            label = String(label.prefix(40))
            var unique = label
            var suffix = 2
            while labels.contains(unique.lowercased()) {
                unique = "\(label) \(suffix)"
                suffix += 1
            }
            labels.insert(unique.lowercased())
            let reason = (item["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(HookAlternative(label: unique, mode: mode,
                                          sceneID: mode == .firstClip ? sceneID : nil,
                                          overlayText: mode == .openingText ? text : nil,
                                          reason: reason?.isEmpty == false ? reason : nil))
        }
        return result
    }

    // MARK: - Preferences and readout

    /// One "A/B Choices" prompt line. Labelled rows are hook picks.
    static func preferenceLine(_ preference: PreferenceRecord) -> String {
        if let chosen = preference.chosenLabel, let rejected = preference.rejectedLabel {
            return "- CHOSE \"\(chosen)\" OVER \"\(rejected)\" hook"
        }
        return "- CHOSE \"\(preference.chosenRationale)\" OVER \"\(preference.rejectedRationale)\""
    }

    struct ReadoutRow: Identifiable, Sendable, Hashable {
        var id: Int64 { videoID }
        var videoID: Int64
        var label: String
        var published: Bool
        var stats: IGStats?
        /// How many A/B picks chose this variant over another in the group.
        var picks: Int
    }

    /// One row per variant, "Original" first and the rest in render order.
    static func readout(videos: [GeneratedVideoRecord],
                        preferences: [(chosenID: Int64, rejectedID: Int64)]) -> [ReadoutRow] {
        let ids = Set(videos.map(\.id))
        let rows = videos.map { video in
            ReadoutRow(videoID: video.id, label: video.hookLabel ?? video.filename,
                       published: video.instagramMediaID != nil, stats: video.instagramStats,
                       picks: preferences.filter { $0.chosenID == video.id && ids.contains($0.rejectedID) }.count)
        }
        return rows.sorted { lhs, rhs in
            let lhsOriginal = lhs.label == originalLabel, rhsOriginal = rhs.label == originalLabel
            if lhsOriginal != rhsOriginal { return lhsOriginal }
            return lhs.videoID < rhs.videoID
        }
    }
}
