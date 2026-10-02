import Foundation

/// Deterministic adjustments and checks applied to a `WizardPlan` after the
/// model returns it. Pure functions: no actor state, no I/O, so each rule is
/// unit-tested on its own (`WizardPlanRulesTests`). `WizardEngine` calls
/// these between validation and assembly.
nonisolated enum WizardPlanRules {

    /// Keep the question and a complete answer sentence before considering
    /// length or optional jumps to the exchange's closing sentences.
    static func podcastExchangeCuts(scene: ClosedRange<Double>, sentenceEnds: [Double],
                                    turns: [SpeakerTurn], proposed: [ClosedRange<Double>],
                                    targetSeconds: Int?) -> (cuts: [ClosedRange<Double>], exceededTarget: Bool) {
        guard let targetSeconds, scene.upperBound - scene.lowerBound > Double(targetSeconds) else {
            return ([scene], false)
        }
        let target = Double(targetSeconds)
        let boundaries = Array(Set([scene.lowerBound, scene.upperBound] + sentenceEnds.filter {
            $0.isFinite && scene.contains($0)
        })).sorted()
        let covering = turns.filter { $0.end > scene.lowerBound && $0.start < scene.upperBound }
            .sorted { $0.start < $1.start }
        let speaker = covering.first { $0.start <= scene.lowerBound }
        let answerStart = speaker.flatMap { first in
            covering.first {
                $0.start > scene.lowerBound
                    && SpeakerTurnCleanup.identity($0) != SpeakerTurnCleanup.identity(first)
            }?.start
        } ?? boundaries.first { $0 > scene.lowerBound } ?? scene.upperBound
        let answerEnd = boundaries.first { $0 > answerStart } ?? scene.upperBound
        let filledEnd = boundaries.last { $0 <= scene.lowerBound + target } ?? scene.lowerBound
        let openingEnd = max(answerEnd, filledEnd)
        var cuts = [scene.lowerBound...openingEnd]
        var duration = openingEnd - scene.lowerBound
        guard duration <= target else { return (cuts, true) }

        // Expand proposals to whole sentences, then merge before rejecting
        // short fragments: several adjacent fragments may form one sentence.
        let snapped = proposed.compactMap { range -> ClosedRange<Double>? in
            let start = max(scene.lowerBound, range.lowerBound)
            let end = min(scene.upperBound, range.upperBound)
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let lower = boundaries.last { $0 <= start } ?? scene.lowerBound
            let upper = boundaries.first { $0 >= end } ?? scene.upperBound
            return lower...upper
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in snapped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        for range in merged where range.upperBound - range.lowerBound >= 1 {
            guard cuts.count < 3 else { break }
            guard let last = cuts.last, range.lowerBound > last.upperBound else { continue }
            let extra = range.upperBound - range.lowerBound
            guard duration + extra <= target else { continue }
            cuts.append(range)
            duration += extra
        }
        return (cuts, false)
    }

    /// Bounded source-time dialogue for planning, retaining both ends of a
    /// long exchange so its question and closing point remain visible.
    static func podcastTranscriptText(scene: ClosedRange<Double>, segments: [TranscriptSegment],
                                      turns: [SpeakerTurn], speakerNames: [String: String],
                                      characterLimit: Int = 1500) -> String {
        let marker = "[… transcript truncated …]"
        guard characterLimit >= marker.count else { return String(marker.prefix(max(0, characterLimit))) }
        let lines = PodcastExchangeSegmenter.sentenceSegments(segments, turns: turns)
            .filter { $0.end > scene.lowerBound && $0.start < scene.upperBound }
            .sorted { $0.start < $1.start }.map { row in
                let midpoint = (max(row.start, scene.lowerBound) + min(row.end, scene.upperBound)) / 2
                let key = turns.first { $0.start <= midpoint && $0.end > midpoint }?.personKey
                let name = key.flatMap { speakerNames[$0] }.map { " \($0):" } ?? ""
                let prefix = String(format: "    [%.1f–%.1f]%@ ",
                                    max(row.start, scene.lowerBound), min(row.end, scene.upperBound), name)
                let text = row.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let budget = max(0, min(360, characterLimit) - prefix.count - marker.count)
                if text.count > budget + marker.count {
                    return prefix + String(text.prefix(budget * 2 / 3)) + marker + String(text.suffix(budget - budget * 2 / 3))
                }
                return prefix + text
            }
        let full = lines.joined(separator: "\n")
        guard full.count > characterLimit else { return full }
        let budget = characterLimit - marker.count - 2
        var head: [String] = []
        var tail: [String] = []
        var headCount = 0
        var tailCount = 0
        for line in lines {
            guard headCount + line.count + 1 <= budget * 2 / 3 else { break }
            head.append(line)
            headCount += line.count + 1
        }
        for line in lines.dropFirst(head.count).reversed() {
            guard tailCount + line.count + 1 <= budget - headCount else { break }
            tail.insert(line, at: 0)
            tailCount += line.count + 1
        }
        return (head + [marker] + tail).joined(separator: "\n")
    }

    /// The longest stretch inside `start..<end` not covered by `used`.
    static func longestFreeGap(start: Double, end: Double,
                               used: [(start: Double, end: Double)]) -> (start: Double, end: Double)? {
        let blockers = used.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        var best: (start: Double, end: Double)?
        var cursor = start
        for blocker in blockers {
            if blocker.start > cursor, best == nil || blocker.start - cursor > best!.end - best!.start {
                best = (cursor, blocker.start)
            }
            cursor = max(cursor, blocker.end)
        }
        if cursor < end, best == nil || end - cursor > best!.end - best!.start {
            best = (cursor, end)
        }
        return best
    }

    /// Where the plan drifts from a picked reference template: screen time
    /// off by more than a quarter, or cut count outside 0.6x to 1.67x.
    static func templateAdherenceFindings(_ plan: WizardPlan, options: WizardOptions) -> [String] {
        guard let template = options.templateJSON.flatMap({ AIResponseParser.jsonObject(from: $0) })
        else { return [] }
        var findings: [String] = []
        if options.targetDurationSeconds == nil,
           let duration = (template["duration"] as? NSNumber)?.doubleValue, duration > 3 {
            let screen = plan.clips.reduce(0.0) { $0 + ($1.end - $1.start) / max(0.1, $1.speed) }
            if abs(screen - duration) / duration > 0.25 {
                findings.append(String(format: "Planned footage runs %.1fs but the reference template runs %.1fs — match it within ~25%%.",
                                       screen, duration))
            }
        }
        if let cuts = (template["cut_count"] as? NSNumber)?.intValue, cuts > 1 {
            let ratio = Double(plan.clips.count) / Double(cuts)
            if ratio < 0.6 || ratio > 1.67 {
                findings.append("The plan has \(plan.clips.count) clips but the reference template cuts \(cuts) times — match its cut cadence.")
            }
        }
        return findings
    }

    /// A pinned overlay template restyles every text overlay; pinned text
    /// replaces the first overlay (or lands on clip 1 when none exists).
    static func enforcePinnedOverlays(_ plan: WizardPlan, options: WizardOptions) -> WizardPlan {
        guard options.enableTextOverlays,
              options.pinnedOverlayTemplate != nil || options.pinnedOverlayText != nil,
              !plan.clips.isEmpty else { return plan }
        var plan = plan
        if let name = options.pinnedOverlayTemplate {
            for index in plan.clips.indices where plan.clips[index].textOverlay != nil {
                plan.clips[index].overlayStyle = name
            }
        }
        if let text = options.pinnedOverlayText {
            let index = plan.clips.firstIndex { $0.textOverlay != nil } ?? 0
            plan.clips[index].textOverlay = text
            if let name = options.pinnedOverlayTemplate {
                plan.clips[index].overlayStyle = name
            }
        }
        return plan
    }

    /// Interview and podcast presets introduce each named person once: a
    /// lower-third on the first clip that shows them, or, for podcasts, a
    /// timed introduction when their speaker turn starts inside the clip.
    static func addAutomaticLowerThirds(_ plan: WizardPlan, options: WizardOptions,
                                        people: [PersonRecord],
                                        sceneMap: [Int64: SceneRecord],
                                        speakerTurns: [Int64: [SpeakerTurn]] = [:]) -> WizardPlan {
        guard options.enableTextOverlays,
              options.formatPreset == "interview" || options.formatPreset == "podcast" else { return plan }
        var plan = plan
        var introduced = Set<String>()
        let named = people.filter { !$0.name.isEmpty && !$0.hidden }
        for index in plan.clips.indices {
            if options.formatPreset == "podcast",
               let scene = sceneMap[plan.clips[index].sceneID] {
                let clip = plan.clips[index]
                for turn in speakerTurns[scene.videoID] ?? [] {
                    guard turn.end > clip.start, turn.start < clip.end,
                          let key = turn.personKey, !introduced.contains(key),
                          let person = named.first(where: { $0.key == key }) else { continue }
                    var introduction = WizardTextStyle.minimal.overlayItem(
                        text: person.displayName, kicker: person.descriptor,
                        placement: "bottom", textCase: "as_written")
                    introduction.startTime = max(0, turn.start - clip.start) / clip.speed
                    introduction.endTime = min((clip.end - clip.start) / clip.speed,
                                                introduction.startTime + 3)
                    introduction.unbounded = false
                    introduction.transIn = "slide_left"
                    plan.clips[index].speakerIntroductions.append(introduction)
                    introduced.insert(key)
                }
                continue
            }
            guard plan.clips[index].textOverlay == nil,
                  let scene = sceneMap[plan.clips[index].sceneID],
                  let person = named.first(where: {
                      !introduced.contains($0.key) && scene.tags.contains($0.tag)
                  }) else { continue }
            plan.clips[index].textOverlay = person.displayName
            plan.clips[index].overlayStyle = "lower-third"
            plan.clips[index].overlayKicker = person.descriptor.isEmpty ? "Guest" : person.descriptor
            plan.clips[index].overlayAnimation = "slide_left"
            introduced.insert(person.key)
        }
        return plan
    }

    /// The re-plan prompt suffix after the critic asks for another version.
    static func critiqueFeedbackBlock(_ critique: ReelCritique, attempt: Int,
                                      previousPlanJSON: String) -> String {
        var lines = ["\n\n## A CRITIC REVIEWED THE RENDERED VERSION \(attempt) — BUILD A BETTER ONE"]
        lines.append("It watched the actual rendered frames and scored the reel \(critique.score)/100: \(critique.summary)")
        if !critique.issues.isEmpty {
            lines.append("Issues visible in the rendered video:")
            lines.append(contentsOf: critique.issues.map { "- \($0)" })
        }
        if !critique.notes.isEmpty {
            lines.append("Apply every one of these improvement notes:")
            lines.append(contentsOf: critique.notes.map { "- \($0)" })
        }
        if !critique.strengths.isEmpty {
            lines.append("Keep what already worked:")
            lines.append(contentsOf: critique.strengths.map { "- \($0)" })
        }
        lines.append("Previous plan JSON (yours):")
        lines.append(String(previousPlanJSON.prefix(4000)))
        lines.append("Produce a NEW complete plan (same JSON schema as above) that fixes every issue — do not repeat the previous plan unchanged.")
        return lines.joined(separator: "\n")
    }
}
