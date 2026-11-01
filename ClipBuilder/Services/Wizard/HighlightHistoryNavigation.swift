import Foundation

/// Pure rules for the highlight history selector (docs/Highlight-History-Plan.md,
/// Phase 2): entry labels, previous/next stepping, which entries this library
/// can open, and the options a reopened full-wizard entry runs with.
nonisolated enum HighlightHistoryNavigation {
    static let noteExcerptLength = 40

    /// "Nov 1, 14:05" in the user's time zone.
    static let defaultDateStyle: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()

    /// `created_at` is SQLite `datetime('now')`: "yyyy-MM-dd HH:mm:ss" in UTC.
    static func date(from createdAt: String?) -> Date? {
        guard var text = createdAt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: " ", with: "T")
        if !text.hasSuffix("Z"), !text.contains("+") { text += "Z" }
        return try? Date(text, strategy: .iso8601)
    }

    static func flowLabel(_ flow: String) -> String {
        if let known = WizardHighlightFlow(rawValue: flow) { return known.label }
        return flow.isEmpty ? "Highlight" : flow
    }

    /// The Express length ("15 s", "Auto"), else the full wizard's recipe or
    /// target duration.
    static func lengthOrRecipe(_ settings: WizardHighlightSettings?) -> String? {
        guard let settings else { return nil }
        if let raw = settings.length, let length = MiniWizardFlow.Length(rawValue: raw) { return length.label }
        let preset = settings.options.formatPreset
        if !preset.isEmpty, preset != "custom" {
            return ReelRecipe.recipe(id: preset)?.title ?? preset
        }
        return settings.options.targetDurationSeconds.map { "\($0) s" }
    }

    /// The note on one line, cut to `noteExcerptLength` characters with an ellipsis.
    static func noteExcerpt(_ note: String?) -> String? {
        let flat = (note ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        guard flat.count > noteExcerptLength else { return flat }
        var cut = String(flat.prefix(noteExcerptLength - 1))
        // Finish on a whole word when one fits.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= noteExcerptLength / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The candidate's title: the plan headline Express shows on its cards,
    /// else the intro title.
    static func title(_ record: WizardHighlightRecord) -> String? {
        let plan = record.plan
        for candidate in [plan?.headline, plan?.introTitle] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// What the user asked for: the regenerate note when the entry is a
    /// regenerate, else the run's instructions to the AI.
    static func request(_ record: WizardHighlightRecord) -> String? {
        if let note = noteExcerpt(record.note) { return note }
        return noteExcerpt(record.settings?.options.aiInstructions)
    }

    /// "<short date> · <title> · <instructions excerpt>". The author, flow and
    /// length are the same for every candidate of a run, so they stay in the
    /// tooltip (`detail`) and out of the row.
    static func label(for record: WizardHighlightRecord, dateStyle: Date.FormatStyle? = nil, now: Date = Date()) -> String {
        [date(from: record.createdAt).map { shortDate($0, style: dateStyle, now: now) },
         title(record), request(record)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The menu title for the current entry: "<short date> · <title>".
    static func shortLabel(for record: WizardHighlightRecord, dateStyle: Date.FormatStyle? = nil, now: Date = Date()) -> String {
        [date(from: record.createdAt).map { shortDate($0, style: dateStyle, now: now) }, title(record)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Who made it and how: "<author> · <flow> · <length or recipe>".
    static func detail(for record: WizardHighlightRecord) -> String {
        let author = record.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [author?.isEmpty == false ? author : nil, flowLabel(record.flow), lengthOrRecipe(record.settings)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "10:07" for today, "Nov 1" for an earlier day this year, "Nov 1, 2025"
    /// before that. A caller-supplied style wins (tests pin the zone).
    static func shortDate(_ date: Date, style: Date.FormatStyle? = nil, now: Date = Date(),
                          calendar: Calendar = .current) -> String {
        if let style { return date.formatted(style) }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Entries are newest first, so Previous steps to an older entry (a
    /// higher index). Nothing selected starts at the newest.
    static func previousIndex(current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return current + 1 < count ? current + 1 : nil
    }

    /// Next steps to a newer entry (a lower index).
    static func nextIndex(current: Int?, count: Int) -> Int? {
        guard count > 0, let current, current > 0, current < count else { return nil }
        return current - 1
    }

    /// Entries naming a source video this library does not have.
    static func unavailableIDs(_ records: [WizardHighlightRecord], localHashes: Set<String>) -> Set<Int64> {
        Set(records.filter { record in
            (record.videoHashes ?? []).contains { !$0.isEmpty && !localHashes.contains($0) }
        }.map(\.id))
    }

    /// "4 clips · 27 s": the plan's clip count and played duration.
    static func planSummary(_ plan: WizardPlan?) -> String? {
        guard let plan, !plan.clips.isEmpty else { return nil }
        let seconds = plan.clips.reduce(0.0) { total, clip in
            total + max(0, clip.end - clip.start) / max(clip.speed, 0.01)
        }
        let count = plan.clips.count == 1 ? "1 clip" : "\(plan.clips.count) clips"
        return "\(count) · \(Int(seconds.rounded())) s"
    }

    /// A recorded run's options on this Mac. Team Sync strips every `*Paths`
    /// key before upload (`SyncMapping.portableJSON`), so a teammate's options
    /// arrive with no source paths at all: the sources are always rebuilt from
    /// the row's video hashes through this library (hash to path), keeping any
    /// recorded path this library still has. When the row was not authored
    /// on this Mac (`author` differs from `localAuthor`) or any path had to be
    /// rebuilt, the recorded scene ids and analyze-batch ids are the other
    /// Mac's rows and are dropped, with the scene-selection flag.
    static func localOptions(_ recorded: WizardOptions, videoHashes: [String], localVideos: [VideoRecord],
                             projectID: Int64?, author: String? = nil, localAuthor: String? = nil) -> WizardOptions {
        var options = recorded
        options.projectID = projectID
        let localPaths = Set(localVideos.compactMap(\.path).filter { !$0.isEmpty })
        let kept = options.sourceVideoPaths.filter { localPaths.contains($0) }
        let hashes = Set(videoHashes.filter { !$0.isEmpty })
        let matched = Set(localVideos.filter { hashes.contains($0.hash) }.compactMap(\.path).filter { !$0.isEmpty })
        var rebuilt = kept.count != options.sourceVideoPaths.count
        if options.sourcesRestricted || !options.sourceVideoPaths.isEmpty {
            let paths = kept.union(matched)
            if !matched.subtracting(kept).isEmpty { rebuilt = true }
            options.sourceVideoPaths = paths
            if paths.isEmpty { options.sourcesRestricted = false }
        }
        let normalize = { (text: String?) in text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
        let foreign = normalize(author) != normalize(localAuthor)
        if foreign || rebuilt {
            options.sourceSceneIDs = []
            options.sourceSceneSelection = false
            options.selectedRunIDs = []
        }
        return options
    }
}

/// One row of the full wizard's "Show clips" list for an opened entry.
nonisolated struct HighlightPlanClipRow: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case main = "Main", area = "Area", broll = "B-roll"
    }

    var id: String
    var kind: Kind
    var videoName: String
    /// Source seconds in the recording.
    var start: Double
    var end: Double
    /// Seconds on the reel (speed applied for main clips).
    var duration: Double
    var textOverlay: String?
}

extension HighlightHistoryNavigation {
    /// The opened plan's clips in reel order: each main clip, then its layout
    /// areas and B-roll cutaways. B-roll source times are the cutaway scene's
    /// start plus its offset.
    static func clipRows(_ plan: WizardPlan, sceneMap: [Int64: SceneRecord]) -> [HighlightPlanClipRow] {
        func name(_ id: Int64) -> String {
            guard let path = sceneMap[id]?.videoPath, !path.isEmpty else { return "Missing scene \(id)" }
            return URL(fileURLWithPath: path).lastPathComponent
        }
        var rows: [HighlightPlanClipRow] = []
        for (index, clip) in plan.clips.enumerated() {
            let text = clip.textOverlay?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(HighlightPlanClipRow(id: "\(index)", kind: .main, videoName: name(clip.sceneID),
                start: clip.start, end: clip.end, duration: max(0, clip.end - clip.start) / max(clip.speed, 0.01),
                textOverlay: text?.isEmpty == false ? text : nil))
            for (area, cut) in clip.areaClips.enumerated() {
                rows.append(HighlightPlanClipRow(id: "\(index).a\(area)", kind: .area, videoName: name(cut.sceneID),
                    start: cut.start, end: cut.end, duration: max(0, cut.end - cut.start), textOverlay: nil))
            }
            for (number, cut) in (clip.brollCuts ?? []).enumerated() {
                let length = max(0, cut.end - cut.start)
                let sourceStart = (sceneMap[cut.sceneID]?.startTime ?? 0) + cut.sceneOffset
                rows.append(HighlightPlanClipRow(id: "\(index).b\(number)", kind: .broll, videoName: name(cut.sceneID),
                    start: sourceStart, end: sourceStart + length, duration: length, textOverlay: nil))
            }
        }
        return rows
    }

    /// "1:05.2–1:12.0" for source ranges.
    static func timecode(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(value) / 60
        let rest = value - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

/// Which history one selector bar lists: Express rows for one source video,
/// or the full wizard's rows for the project.
nonisolated struct HighlightHistoryScope: Hashable, Sendable {
    var projectID: Int64
    /// Express only: the source video's hash.
    var videoHash: String?
    var express: Bool

    static func express(projectID: Int64, videoHash: String) -> HighlightHistoryScope {
        HighlightHistoryScope(projectID: projectID, videoHash: videoHash, express: true)
    }

    static func fullWizard(projectID: Int64) -> HighlightHistoryScope {
        HighlightHistoryScope(projectID: projectID, videoHash: nil, express: false)
    }

    /// Rows of this bar's kind. A flow this build does not know is listed
    /// by the full wizard, which can still rerun its options.
    func includes(_ record: WizardHighlightRecord) -> Bool {
        guard record.projectID == projectID else { return false }
        let isExpress = record.highlightFlow?.isExpress ?? false
        guard isExpress == express else { return false }
        guard let videoHash else { return true }
        return record.videoHashes?.contains(videoHash) == true
    }
}
