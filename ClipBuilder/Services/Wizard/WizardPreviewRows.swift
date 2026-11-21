import Foundation

/// One row of the Express preview's List tab: a kept clip with the text that
/// describes it.
nonisolated struct WizardPreviewRow: Identifiable, Sendable, Equatable {
    enum TextKind: Sendable, Equatable {
        /// The spoken words inside the clip's range.
        case transcript
        /// The analyzer's beat-by-beat narrative for the scene.
        case description
        /// What the fight scorer logged inside the clip ("A: right punch to the head").
        case action
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
    var videoID: Int64 = 0

    var range: ClosedRange<Double> { start...max(start, end) }
    var duration: Double { max(0, end - start) }
}

/// Pure rules for the List tab.
nonisolated enum WizardPreviewRows {
    /// Follow the clip through the accepted order; if it left, keep the nearest row selected.
    static func reconciledIndex(_ index: Int, previousIDs: [String], ids: [String]) -> Int {
        if previousIDs.indices.contains(index), let found = ids.firstIndex(of: previousIDs[index]) { return found }
        return max(0, min(index, ids.count - 1))
    }

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

    /// What the fight scorer logged inside a clip, in words, in time order:
    /// "Jan: right punch to the head; Carlos: takedown attempt, defended".
    /// A pause on contact is one held frame, so it takes the blow nearest it.
    static func action(for range: ClosedRange<Double>, events: [FightEventRecord],
                       names: [String: String]) -> String {
        let held = range.upperBound - range.lowerBound < 0.05
        let scored = StrikeStatsSummary.deduplicatedStrikes(events)
            + events.filter { !StrikeStatsSummary.strikeFamily.contains($0.action) }
        var inside = scored.filter { event in
            // An action with a length (a submission attempt) counts while it is going on.
            let end = max(event.time, event.endTime ?? event.time)
            return held ? abs(event.time - range.lowerBound) <= 0.3
                 : end > event.time ? event.time < range.upperBound && end > range.lowerBound
                 : event.time >= range.lowerBound && event.time < range.upperBound
        }.sorted { $0.time < $1.time }
        if held, let nearest = inside.min(by: { abs($0.time - range.lowerBound) < abs($1.time - range.lowerBound) }) {
            inside = [nearest]
        } else if held {
            // No blow at the held frame: an action going on through it (a submission attempt).
            inside = scored.filter { event in
                guard let end = event.endTime, end > event.time else { return false }
                return event.time <= range.lowerBound && range.lowerBound < end
            }.max { $0.time < $1.time }.map { [$0] } ?? []
        }
        let phrases = inside.map { event -> String in
            let name = names[event.fighterKey].flatMap { $0.isEmpty ? nil : $0 }
            return [name, phrase(event)].compactMap { $0 }.joined(separator: ": ")
        }
        let shown = phrases.prefix(4).joined(separator: "; ")
        return phrases.count > 4 ? "\(shown); +\(phrases.count - 4) more" : shown
    }

    /// One scored event in plain words.
    static func phrase(_ event: FightEventRecord) -> String {
        let label = (FightScoring.actionPoints.first { $0.action == event.action }?.label
            ?? event.action.replacingOccurrences(of: "_", with: " ")).lowercased()
        if StrikeStatsSummary.strikeFamily.contains(event.action) {
            guard let detail = StrikeDetail(event.detail) else { return label }
            var words = [detail.limb?.rawValue, detail.technique.rawValue].compactMap { $0 }.joined(separator: " ")
            if let target = detail.target { words += target == .legs ? " to the legs" : " to the \(target.rawValue)" }
            if event.action == "ground_strike" { words += " on the ground" }
            return event.action == "significant_strike" ? "big \(words)" : words
        }
        let extra = [event.outcome, event.detail].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("|") }
        return ([label] + extra).joined(separator: ", ")
    }

    /// Rows in clip order. Text is chosen by content: transcript words when
    /// the clip's range has any, else what the fight scorer logged there,
    /// else the scene narrative, else nothing. A Fight metrics pick was
    /// chosen for its action, so it says the action first and falls back
    /// to words (usually commentary) only when nothing else describes it.
    static func rows(clips: [WizardPreviewClip], lines: [Int64: [Line]],
                     events: [Int64: [FightEventRecord]] = [:], names: [String: String] = [:]) -> [WizardPreviewRow] {
        clips.map { clip in
            var fightPick = false
            if case .fightPick = owner(of: clip.id) { fightPick = true }
            let segments = segments(for: clip.range, lines: lines[clip.scene.videoID] ?? [])
            let narrative = (clip.scene.narrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let action = segments.isEmpty || fightPick
                ? action(for: clip.range, events: events[clip.scene.videoID] ?? [], names: names) : ""
            let (text, kind): (String, WizardPreviewRow.TextKind) =
                !segments.isEmpty && !fightPick ? (text(segments), .transcript)
                : !action.isEmpty ? (action, .action)
                : !narrative.isEmpty ? (narrative, .description)
                : !segments.isEmpty ? (text(segments), .transcript)
                : ("", .none)
            return WizardPreviewRow(id: clip.id, title: clip.title, videoURL: clip.scene.videoURL,
                                    start: clip.start, end: clip.end, text: text, textKind: kind,
                                    segments: kind == .transcript ? segments : [], videoID: clip.scene.videoID)
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
