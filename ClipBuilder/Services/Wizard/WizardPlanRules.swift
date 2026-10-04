import Foundation

/// Deterministic adjustments and checks applied to a `WizardPlan` after the
/// model returns it. Pure functions: no actor state, no I/O, so each rule is
/// unit-tested on its own (`WizardPlanRulesTests`). `WizardEngine` calls
/// these between validation and assembly.
nonisolated enum WizardPlanRules {

    /// Source seconds, including secondary layout areas. Plans must carry a footage snapshot.
    static func footageRanges(_ plan: WizardPlan) -> [(videoID: Int64, start: Double, end: Double)] {
        let sources = Dictionary((plan.footage ?? []).compactMap { reference -> (Int64, Int64)? in
            guard let sceneID = reference.sceneID, let videoID = reference.videoID else { return nil }
            return (sceneID, videoID)
        }, uniquingKeysWith: { first, _ in first })
        return plan.clips.flatMap { clip in
            [(clip.sceneID, clip.start, clip.end)] + clip.areaClips.map { ($0.sceneID, $0.start, $0.end) }
        }.compactMap { sceneID, start, end in
            guard let videoID = sources[sceneID], start.isFinite, end.isFinite, end > start else { return nil }
            return (videoID, start, end)
        }
    }

    static func avoidsRanges(_ plan: WizardPlan,
                             ranges: [(videoID: Int64, start: Double, end: Double)]) -> Bool {
        let footage = footageRanges(plan)
        guard !plan.clips.isEmpty,
              footage.count == plan.clips.reduce(0, { $0 + 1 + $1.areaClips.count }) else { return false }
        return footage.allSatisfy { cut in
            let used = ranges.filter { $0.videoID == cut.videoID }
            let overlap = used.reduce(0.0) {
                $0 + max(0, min(cut.end, $1.end) - max(cut.start, $1.start))
            }
            // Match validatePlan's per-cut tolerance for small boundary overlaps.
            return overlap <= 0.5
        }
    }

    /// Keep complete alternatives in response order. As in validatePlan, a cut
    /// reusing more than 0.5 source seconds drops the later candidate wholesale.
    static func candidatesWithoutOverlap(_ candidates: [WizardPlan]) -> [WizardPlan] {
        var kept: [WizardPlan] = []
        var used: [(videoID: Int64, start: Double, end: Double)] = []
        for candidate in candidates where avoidsRanges(candidate, ranges: used) {
            kept.append(candidate)
            used += footageRanges(candidate)
        }
        return kept
    }

    static func avoidRangesRule(_ ranges: [(videoID: Int64, start: Double, end: Double)]) -> String {
        let valid = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.sorted {
            if $0.videoID != $1.videoID { return $0.videoID < $1.videoID }
            return $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        guard !valid.isEmpty else { return "" }
        return "Avoid all footage overlapping these kept candidates (video IDs, source seconds; touching endpoints are allowed):\n"
            + valid.map { "- video_id \($0.videoID): [\($0.start), \($0.end)) seconds" }.joined(separator: "\n")
    }

    /// Shorten toward the requested screen-time cadence without extending any source range.
    /// Reasons can explicitly protect the ending ("keep end" / "trim start"); otherwise
    /// keep the opening. Replay pairs retain their exact shared window.
    static func applyPacing(plan: WizardPlan, pacing: EditPacing) -> WizardPlan {
        guard pacing.cadence != .automatic else { return plan }
        var result = plan
        let total = plan.clips.reduce(0.0) { $0 + max(0, $1.end - $1.start) / max(0.1, $1.speed) }
        var cursor = 0.0
        for index in plan.clips.indices {
            let clip = plan.clips[index]
            let speed = max(0.1, clip.speed)
            let duration = (clip.end - clip.start) / speed
            let progress = total > 0 ? cursor / total : 0
            cursor += duration
            let followsReplay = index > 0 && plan.clips[index - 1].replay
                && plan.clips[index - 1].sceneID == clip.sceneID
            guard !clip.replay, !followsReplay,
                  let interval = pacing.interval(at: progress), duration > 1.5 else { continue }
            let wanted = min(duration, max(max(1.5, 1.5 / speed), interval))
            let delta = max(0, (duration - wanted) * speed)
            let reason = clip.reason?.lowercased() ?? ""
            let trimStart = reason.contains("keep end") || reason.contains("trim start")
                || reason.contains("payoff at end")
            if trimStart { result.clips[index].start += delta }
            else { result.clips[index].end -= delta }
            // All areas share the slot. Apply the same offset and never extend an area.
            for areaIndex in clip.areaClips.indices {
                let area = clip.areaClips[areaIndex]
                let available = max(0, area.end - area.start)
                let length = min(available, wanted * speed)
                if trimStart { result.clips[index].areaClips[areaIndex].start = area.end - length }
                else { result.clips[index].areaClips[areaIndex].end = area.start + length }
            }
            // Introductions are timed in screen seconds, relative to the selected cut.
            let offset = trimStart ? delta / speed : 0
            result.clips[index].speakerIntroductions = clip.speakerIntroductions.compactMap { introduction in
                var item = introduction
                item.startTime = max(0, item.startTime - offset)
                item.endTime = min(wanted, item.endTime - offset)
                return item.endTime > item.startTime ? item : nil
            }
        }
        result.targetDuration = result.clips.reduce(0) { $0 + ($1.end - $1.start) / max(0.1, $1.speed) }
        return result
    }

    /// Hard cuts form the backbone; every third boundary cycles an allowed accent.
    /// A nil list permits the catalog. Unknown names and duplicates are discarded.
    static func transitions(allowed: [String]?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let valid = Set(RenderEngine.allTransitions)
        var seen = Set<String>()
        let accents = (allowed ?? RenderEngine.allTransitions).filter { $0 != "cut" && valid.contains($0) && seen.insert($0).inserted }
        guard !accents.isEmpty else { return Array(repeating: "cut", count: count) }
        return (0..<count).map { index in
            (index + 1).isMultiple(of: 3) ? accents[(index / 3) % accents.count] : "cut"
        }
    }

    /// Names are root-relative library paths. Stable lexical order, exact folder boundary,
    /// and a known duration keep selection independent of filesystem enumeration order.
    static func musicTrack(folder: String?, tracks: [(name: String, duration: Double)],
                           duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return nil }
        let folder = folder?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return tracks.filter {
            (folder.isEmpty || $0.name.hasPrefix(folder + "/"))
                && $0.duration.isFinite && $0.duration >= duration
        }.sorted { $0.name < $1.name }.first?.name
    }

    /// Join accepted takes in card order, retaining their per-clip text and source identities.
    static func combinedPlan(_ takes: [WizardSelectionTake]) -> WizardPlan {
        let clips = takes.flatMap { $0.plan.clips }
        var plan = WizardPlan(targetDuration: 0, rationale: takes.first?.plan.rationale ?? "",
            musicName: nil, musicVolume: 0, clips: clips,
            transitions: Array(repeating: "cut", count: max(0, clips.count - 1)),
            headline: takes.first?.plan.headline)
        plan.targetDuration = WizardSelectionRules.duration(plan)
        var seen: Set<Int64> = []
        plan.footage = takes.flatMap { $0.plan.footage ?? [] }.filter {
            guard let id = $0.sceneID else { return false }
            return seen.insert(id).inserted
        }
        return plan
    }

    static func nameTagsOnly(plan: WizardPlan) -> WizardPlan {
        var result = plan
        for index in result.clips.indices {
            result.clips[index].textOverlay = nil
            result.clips[index].overlayKicker = nil
            result.clips[index].overlayStyle = nil
            result.clips[index].overlayAnimation = nil
            result.clips[index].overlayAccent = nil
            result.clips[index].overlayPlacement = nil
            result.clips[index].overlayCase = nil
        }
        return result
    }

    /// A render has one visual style. Keep all words, including contextual kickers.
    static func overlayStyle(plan: WizardPlan, style: String?) -> WizardPlan {
        var result = plan
        for index in result.clips.indices {
            result.clips[index].overlayStyle = style ?? WizardTextStyle.impact.rawValue
            result.clips[index].overlayAnimation = nil
            result.clips[index].overlayAccent = nil
            result.clips[index].overlayPlacement = nil
            result.clips[index].overlayCase = nil
        }
        return result
    }


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
        guard options.enableTextOverlays, !options.usesNameTags,
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

    /// The re-plan prompt suffix after the content critic asks for another take.
    static func critiqueFeedbackBlock(_ critique: ReelCritique, attempt: Int,
                                      previousPlanJSON: String) -> String {
        var lines = ["\n\n## A CONTENT CRITIC REVIEWED THE PROXY TAKE \(attempt) — PLAN A BETTER TAKE"]
        lines.append("It watched the content proxy and scored the take \(critique.score)/100: \(critique.summary)")
        if !critique.issues.isEmpty {
            lines.append("Content issues visible in the proxy:")
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
