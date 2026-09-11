import Foundation

@MainActor
enum BuilderWizardDiff {
    static func lines(session: BuilderScriptSession, steps: [BuilderScriptStep]) -> [String] {
        let diff = session.diff()
        guard !diff.isEmpty else { return ["No timeline changes."] }
        var lines: [String] = []
        if let candidate = session.candidate {
            let beforeIDs = Set(session.baseline.videoTrack.map(\.uid))
            let afterIDs = Set(candidate.videoTrack.map(\.uid))
            let removed = session.baseline.videoTrack.filter { !afterIDs.contains($0.uid) }
            if !removed.isEmpty {
                lines.append("Removed \(removed.count) clips: " + removed.map { name($0, library: session.library) }.joined(separator: ", "))
            }
            let splits = steps.filter { if case .splitClip = $0.command { true } else { false } }.count
            if splits > 0 { lines.append("Split \(splits) clips") }
            let beforeOrigins = Set(session.baseline.videoTrack.map(\.originKey))
            let added = candidate.videoTrack.filter { !beforeIDs.contains($0.uid) && !beforeOrigins.contains($0.originKey) }
            for track in Set(added.filter(\.isCutaway).map(\.track)).sorted() {
                let clips = added.filter { $0.isCutaway && $0.track == track }
                lines.append("Added \(clips.count) B-roll on Track \(["I", "II", "III", "IV", "V", "VI"][track]): "
                             + clips.map { name($0, library: session.library) }.joined(separator: ", "))
            }
        }
        lines.append("Duration \(diff.beforeDuration.timecode) → \(diff.afterDuration.timecode)")
        return lines
    }

    private static func name(_ clip: TimelineClip, library: ScriptLibrarySnapshot) -> String {
        let name = library.scenes.first { $0.id == clip.sceneID }?.videoFilename
            ?? URL(fileURLWithPath: clip.videoFile ?? "").lastPathComponent
        return "\(name) at \(clip.startTime.timecode)"
    }

    /// The complete field-level diff remains available, including indirect
    /// framing/layout changes; summaries alone are not the approval evidence.
    static func detail(_ change: TimelineDiff.Change) -> String {
        let field = change.path.replacingOccurrences(of: "document.", with: "")
        return "\(field): \(value(change.before)) → \(value(change.after))"
    }

    private static func value(_ value: ScriptValue?) -> String {
        guard let value else { return "absent" }
        switch value {
        case .null: return "none"
        case .bool(let v): return v ? "yes" : "no"
        case .number(let v): return v.formatted(.number.precision(.fractionLength(0...3)))
        case .string(let v): return v
        case .array(let values): return "[" + values.map { self.value($0) }.joined(separator: ", ") + "]"
        case .object(let fields):
            return fields.keys.sorted().map { "\($0): \(self.value(fields[$0]))" }.joined(separator: "; ")
        }
    }
}
