import Foundation

/// One row of the Express preview's List tab: a kept clip with the text that
/// describes it.
nonisolated struct WizardPreviewRow: Identifiable, Sendable, Equatable {
    enum TextKind: Sendable, Equatable {
        /// The spoken words inside the clip's range.
        case transcript
        /// The analyzer's beat-by-beat narrative for the scene.
        case description
        case none
    }

    /// One speaker's stretch of the clip's words.
    struct Segment: Sendable, Equatable {
        var speaker: String?
        var text: String
    }

    var id: String
    var title: String
    var videoURL: URL
    /// The clip's first frame, in source seconds.
    var start: Double
    var end: Double
    /// Plain text: speaker names prefix their stretches ("Alice: …").
    var text: String
    var textKind: TextKind
    /// The transcript split by speaker, in order; empty for a description.
    var segments: [Segment] = []

    var range: ClosedRange<Double> { start...max(start, end) }
    var duration: Double { max(0, end - start) }
}

/// Pure rules for the List tab.
nonisolated enum WizardPreviewRows {
    /// One transcript row's words with the speaker it was attributed to.
    struct Line: Sendable, Equatable {
        var speaker: String?
        var words: [TranscriptQATrim.Word]
    }

    /// A video's original-language rows as lines, in transcript order.
    static func lines(rows: [TranscriptRow], speaker: (TranscriptRow) -> String?) -> [Line] {
        rows.filter { !$0.isTranslation }
            .sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
            .map { Line(speaker: speaker($0), words: TranscriptQATrim.words(for: $0)) }
    }

    /// Words without speakers, for callers that have none.
    static func lines(words: [TranscriptQATrim.Word]) -> [Line] { [Line(speaker: nil, words: words)] }

    /// The words inside `range`, grouped into one segment per run of the
    /// same speaker.
    static func segments(for range: ClosedRange<Double>, lines: [Line]) -> [WizardPreviewRow.Segment] {
        var result: [WizardPreviewRow.Segment] = []
        for line in lines {
            let text = line.words.filter { TranscriptQATrim.contains($0, in: range) }.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, last.speaker == line.speaker {
                result[result.count - 1].text += " " + text
            } else {
                result.append(.init(speaker: line.speaker, text: text))
            }
        }
        return result
    }

    static func text(_ segments: [WizardPreviewRow.Segment]) -> String {
        segments.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: " ")
    }

    /// Rows in clip order. Text is chosen by content: transcript words when
    /// the clip's range has any, else the scene narrative, else nothing.
    static func rows(clips: [WizardPreviewClip], lines: [Int64: [Line]]) -> [WizardPreviewRow] {
        clips.map { clip in
            let segments = segments(for: clip.range, lines: lines[clip.scene.videoID] ?? [])
            let narrative = (clip.scene.narrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let (text, kind): (String, WizardPreviewRow.TextKind) =
                !segments.isEmpty ? (text(segments), .transcript)
                : !narrative.isEmpty ? (narrative, .description)
                : ("", .none)
            return WizardPreviewRow(id: clip.id, title: clip.title, videoURL: clip.scene.videoURL,
                                    start: clip.start, end: clip.end, text: text, textKind: kind,
                                    segments: kind == .transcript ? segments : [])
        }
    }

    static func rows(clips: [WizardPreviewClip], words: [Int64: [TranscriptQATrim.Word]]) -> [WizardPreviewRow] {
        rows(clips: clips, lines: words.mapValues(lines(words:)))
    }

    /// The order after dropping `id` at `slot`, a boundary index between rows
    /// (0 = before the first, count = after the last). Unchanged when the drop
    /// lands where the row already is.
    static func reorderedIDs(_ ids: [String], moving id: String, toSlot slot: Int) -> [String] {
        guard let from = ids.firstIndex(of: id) else { return ids }
        var result = ids
        result.remove(at: from)
        var to = slot
        if to > from { to -= 1 }
        result.insert(id, at: min(result.count, max(0, to)))
        return result
    }

    /// What a row moves with: its owner (a take's cuts move together), or
    /// itself when the id names no owner.
    static func blockKey(_ clipID: String) -> String {
        guard let owner = owner(of: clipID) else { return clipID }
        switch owner {
        case .qa(let v): return "qa-\(v)"
        case .transcriptPick(let v): return "pick-\(v)"
        case .fightPick(let v): return "fight-\(v)"
        case .take(let v): return "take-\(v)"
        }
    }

    /// Consecutive rows sharing a block key.
    static func blocks(_ rows: [WizardPreviewRow]) -> [[WizardPreviewRow]] {
        var result: [[WizardPreviewRow]] = []
        for row in rows {
            if let last = result.last?.last, blockKey(last.id) == blockKey(row.id) {
                result[result.count - 1].append(row)
            } else {
                result.append([row])
            }
        }
        return result
    }

    /// `reorderedIDs` over blocks: the block holding `id` drops at `slot`, a
    /// boundary index between blocks, and the result is flattened.
    static func reorderedIDs(blocks: [[String]], moving id: String, toSlot slot: Int) -> [String] {
        guard let from = blocks.firstIndex(where: { $0.contains(id) }) else { return blocks.flatMap { $0 } }
        var result = blocks
        let block = result.remove(at: from)
        var to = slot
        if to > from { to -= 1 }
        result.insert(block, at: min(result.count, max(0, to)))
        return result.flatMap { $0 }
    }

    /// `full` with the slots of the ids named in `order` refilled in that
    /// order; ids `full` lacks are dropped and the rest keep their places.
    static func merging(_ order: [Int64], into full: [Int64]) -> [Int64] {
        let listed = Set(order).intersection(full)
        var replacements = order.filter(listed.contains)[...]
        return full.map { id in
            guard listed.contains(id), let next = replacements.popFirst() else { return id }
            return next
        }
    }

    /// Each clip id's position for the owner's reorder action.
    enum Owner: Equatable, Sendable {
        case qa(Int64), transcriptPick(Int64), fightPick(Int64), take(Int64)
    }

    static func owner(of clipID: String) -> Owner? {
        let parts = clipID.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "qa": return Int64(parts[1]).map(Owner.qa)
        case "pick": return Int64(parts[1]).map(Owner.transcriptPick)
        case "fight": return Int64(parts[1]).map(Owner.fightPick)
        case "take": return Int64(parts[1].split(separator: "-").first ?? "").map(Owner.take)
        default: return nil
        }
    }

    /// The owners' ids in list order, each once (a take with several cuts
    /// has one row per cut but moves as one).
    static func ownerIDs(_ clipIDs: [String]) -> [Int64] {
        var seen = Set<Int64>()
        return clipIDs.compactMap { id in
            guard let owner = owner(of: id) else { return nil }
            let value: Int64 = switch owner {
            case .qa(let v), .transcriptPick(let v), .fightPick(let v), .take(let v): v
            }
            return seen.insert(value).inserted ? value : nil
        }
    }
}
