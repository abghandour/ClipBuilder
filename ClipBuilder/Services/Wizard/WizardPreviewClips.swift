import Foundation

/// One stretch of kept footage the Express preview can scrub through: the
/// scene it belongs to and the exact source range the render will use.
nonisolated struct WizardPreviewClip: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var scene: SceneRecord
    var start: Double
    var end: Double
    var brollCuts: [BRollCut]? = nil
    /// The rendered clock, after pacing, speed and transition overlaps.
    var outputStart: Double? = nil
    var outputDuration: Double? = nil
    var chosenSubject: Framing.Subject? = nil

    var range: ClosedRange<Double> { start...max(start, end) }
    var duration: Double { max(0, end - start) }
}

/// One moment of a kept clip, in source time, for a still pinned to it.
nonisolated struct WizardPreviewMoment: Equatable, Hashable, Sendable {
    var clipID: String
    var time: Double
}

/// The kept footage of an Express run as preview clips, in output order.
nonisolated enum WizardPreviewClips {
    /// Kept takes win once picks have become selections (the step Settings
    /// performs); before that the kept Q&A exchanges, transcript picks or
    /// fight picks stand in, with the same ranges the selections will get.
    static func kept(run: MiniWizardRun, scenes: [SceneRecord]) -> [WizardPreviewClip] {
        // Only this recording's scenes: a pick without a scene must never
        // borrow a longer overlapping scene from another video.
        let scenes = scenes.filter { $0.videoID == run.video.id }
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WizardPreviewClip] = []
        // Q&A, Transcript and Fight picks are the live footage the user edits;
        // their saved takes lag until Settings records them again, so the
        // picks come first and the takes only stand in when there are none.
        var picked = pickClips(run: run, scenes: scenes, byID: byID)
        if !picked.isEmpty {
            let saved = run.candidates.flatMap { $0.take.plan.clips }
            for index in picked.indices {
                let piece = picked[index]
                let exact = saved.first { clip in
                    if let pickID = clip.miniPickID {
                        return piece.id == "pick-\(pickID)" || piece.id == "fight-\(pickID)"
                    }
                    return clip.sceneID == piece.scene.id && abs(clip.start - piece.start) < 0.001 && abs(clip.end - piece.end) < 0.001
                }
                picked[index].brollCuts = exact?.brollCuts
            }
            return picked
        }
        let takes = run.candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        if !takes.isEmpty {
            for candidate in takes {
                for (index, clip) in candidate.take.plan.clips.enumerated() where clip.end > clip.start {
                    guard let scene = byID[clip.sceneID] else { continue }
                    let title = candidate.take.plan.clips.count > 1
                        ? "\(candidate.selection.name) · \(index + 1)" : candidate.selection.name
                    result.append(.init(id: "take-\(candidate.id)-\(index)", title: title,
                                        scene: scene, start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                        chosenSubject: candidate.take.plan.framing))
                }
            }
            return result
        }
        return result
    }

    /// The Express reel as preview clips, in reel order. A loaded section
    /// supplies the live range (and every cut of a Highlights candidate);
    /// otherwise the item's snapshot stands in.
    static func reel(items: [MiniReelItem], runs: [MiniWizardFlow.FootageKind: MiniWizardRun],
                     videoID: Int64, scenes: [SceneRecord]) -> [WizardPreviewClip] {
        let scenes = scenes.filter { $0.videoID == videoID }
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let runs = runs.filter { $0.value.video.id == videoID }
        var result: [WizardPreviewClip] = []
        for item in items.sorted(by: { $0.position < $1.position }) {
            if let run = runs[item.kind] {
                result += liveClips(item, run: run, scenes: scenes, byID: byID)
            } else if let scene = containing(item.range, id: item.sceneID, scenes: scenes, byID: byID) {
                result.append(.init(id: item.clipID, title: item.title, scene: scene,
                                    start: item.range.lowerBound, end: item.range.upperBound))
            }
        }
        // Reviewed B-roll cuts live on the recorded takes.
        let saved = runs.values.flatMap { $0.candidates.flatMap { $0.take.plan.clips } }
        for index in result.indices where result[index].brollCuts == nil {
            let piece = result[index]
            let exact = saved.first { clip in
                if let pickID = clip.miniPickID {
                    return piece.id == "pick-\(pickID)" || piece.id == "fight-\(pickID)"
                }
                return clip.sceneID == piece.scene.id && abs(clip.start - piece.start) < 0.001 && abs(clip.end - piece.end) < 0.001
            }
            result[index].brollCuts = exact?.brollCuts
        }
        return result
    }

    private static func liveClips(_ item: MiniReelItem, run: MiniWizardRun, scenes: [SceneRecord],
                                  byID: [Int64: SceneRecord]) -> [WizardPreviewClip] {
        switch item.kind {
        case .qa:
            guard let qa = run.qa, qa.kept.contains(item.itemID),
                  let section = qa.sections.first(where: { $0.id == item.itemID }),
                  section.range.upperBound > section.range.lowerBound else { return [] }
            return [.init(id: item.clipID, title: section.question, scene: section.scene,
                          start: section.range.lowerBound, end: section.range.upperBound)]
        case .transcript:
            guard let pick = run.transcript?.picks.first(where: { $0.id == item.itemID }), pick.kept,
                  let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { return [] }
            return [.init(id: item.clipID, title: item.title, scene: scene,
                          start: pick.range.lowerBound, end: pick.range.upperBound)]
        case .fightMetrics:
            guard let pick = run.fight?.picks.first(where: { $0.id == item.itemID }),
                  let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { return [] }
            return [.init(id: item.clipID, title: "Stretch \(pick.position + 1)", scene: scene,
                          start: pick.range.lowerBound, end: pick.range.upperBound)]
        case .highlights:
            guard let candidate = run.candidates.first(where: { $0.id == item.itemID }), candidate.kept else { return [] }
            var result: [WizardPreviewClip] = []
            for (index, clip) in candidate.take.plan.clips.enumerated() where clip.end > clip.start {
                guard let scene = byID[clip.sceneID] else { continue }
                let title = candidate.take.plan.clips.count > 1
                    ? "\(candidate.selection.name) · \(index + 1)" : candidate.selection.name
                result.append(.init(id: "take-\(candidate.id)-\(index)", title: title, scene: scene,
                                    start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                    chosenSubject: candidate.take.plan.framing))
            }
            return result
        }
    }

    /// The kept takes of a batch (the Full wizard's and a rough cut's) as
    /// preview clips, in output order, titled by their selection.
    static func takes(_ takes: [WizardSelectionTake], names: [Int64: String],
                      scenes: [SceneRecord]) -> [WizardPreviewClip] {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WizardPreviewClip] = []
        for take in takes {
            let name = names[take.selectionID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base = name.isEmpty ? "Take \(take.ordinal)" : name
            for (index, clip) in take.plan.clips.enumerated() where clip.end > clip.start {
                guard let scene = byID[clip.sceneID] else { continue }
                let title = take.plan.clips.count > 1 ? "\(base) · \(index + 1)" : base
                result.append(.init(id: "take-\(take.id)-\(index)", title: title,
                                    scene: scene, start: clip.start, end: clip.end, brollCuts: clip.brollCuts,
                                    chosenSubject: take.plan.framing))
            }
        }
        return result
    }

    /// The stripped document the renderer used, rather than the take's plan
    /// before pacing. Each take starts its own output clock at zero.
    static func rendered(_ document: TimelineDocument, take: WizardSelectionTake, name: String,
                         scenes: [SceneRecord], xfadeDuration: Double) -> [WizardPreviewClip] {
        let byID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clips = document.videoTrack.filter { !$0.isCutaway }.sorted { $0.startTime < $1.startTime }
        var cursor = 0.0
        var result: [WizardPreviewClip] = []
        for (index, clip) in clips.enumerated() {
            if index > 0 { cursor -= RenderEngine.consumedOverlap(clip.transIn, xfadeDuration: xfadeDuration) }
            let start = cursor
            cursor += clip.duration
            guard let sceneID = clip.sceneID, let scene = byID[sceneID], clip.duration > 0 else { continue }
            let sourceStart = clip.sourceStart ?? scene.startTime
            let sourceEnd = clip.sourceEnd ?? (sourceStart + clip.duration * (clip.speed ?? 1))
            guard sourceEnd > sourceStart else { continue }
            let title = clips.count > 1 ? "\(name) · \(index + 1)" : name
            result.append(.init(id: "take-\(take.id)-\(index)", title: title, scene: scene,
                                start: sourceStart, end: sourceEnd,
                                outputStart: start, outputDuration: clip.duration, chosenSubject: take.plan.framing))
        }
        return result
    }

    /// The moment of kept footage at the rendered playhead. In an overlap
    /// the incoming clip supplies the still. Untimed clips play back to back;
    /// past the end stays on the last clip's last moment.
    static func moment(in clips: [WizardPreviewClip], at time: Double) -> WizardPreviewMoment? {
        let time = max(0, time.isFinite ? time : 0)
        var cursor = 0.0
        var moment: WizardPreviewMoment?
        for clip in clips {
            let start = clip.outputStart ?? cursor
            let duration = clip.outputDuration ?? clip.duration
            if start > time, moment != nil { break }
            let fraction = duration > 0 ? min(1, max(0, (time - start) / duration)) : 0
            moment = WizardPreviewMoment(clipID: clip.id, time: clip.start + fraction * clip.duration)
            cursor = start + duration
        }
        return moment
    }

    /// The preview clips cut from one take, in output order.
    static func clips(_ clips: [WizardPreviewClip], ofTake takeID: Int64) -> [WizardPreviewClip] {
        clips.filter { $0.id.hasPrefix("take-\(takeID)-") }
    }

    private static func pickClips(run: MiniWizardRun, scenes: [SceneRecord], byID: [Int64: SceneRecord]) -> [WizardPreviewClip] {
        var result: [WizardPreviewClip] = []
        switch run.footageKind {
        case .qa:
            guard let qa = run.qa else { return [] }
            let ordered = MiniWizardQARules.ordering(qa.sections, by: qa.keptOrder)
            for section in ordered where qa.kept.contains(section.id) && section.scene.videoID == run.video.id {
                let range = section.range
                guard range.upperBound > range.lowerBound else { continue }
                result.append(.init(id: "qa-\(section.id)", title: section.question,
                                    scene: section.scene, start: range.lowerBound, end: range.upperBound))
            }
        case .transcript:
            // Numbered over the kept picks: the list and the reel count only those.
            for (index, pick) in (run.transcript?.picks ?? []).filter(\.kept).enumerated() {
                guard let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { continue }
                result.append(.init(id: "pick-\(pick.id)", title: "Passage \(index + 1)",
                                    scene: scene, start: pick.range.lowerBound, end: pick.range.upperBound))
            }
        case .fightMetrics:
            for pick in run.fight?.picks ?? [] {
                guard let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { continue }
                result.append(.init(id: "fight-\(pick.id)", title: "Stretch \(pick.position + 1)",
                                    scene: scene, start: pick.range.lowerBound, end: pick.range.upperBound))
            }
        case .highlights:
            break
        }
        return result
    }

    /// A pick's own scene when it has one; otherwise the scene overlapping the
    /// pick most, so the still can read that scene's transcript and framing.
    private static func containing(_ range: ClosedRange<Double>, id: Int64?, scenes: [SceneRecord],
                                   byID: [Int64: SceneRecord]) -> SceneRecord? {
        guard range.upperBound > range.lowerBound else { return nil }
        if let id, let scene = byID[id] { return scene }
        return scenes.filter { !$0.excluded && !$0.ignored }.max { lhs, rhs in
            overlap(lhs, range) < overlap(rhs, range)
        }.flatMap { overlap($0, range) > 0 ? $0 : nil }
    }

    private static func overlap(_ scene: SceneRecord, _ range: ClosedRange<Double>) -> Double {
        max(0, min(scene.endTime, range.upperBound) - max(scene.startTime, range.lowerBound))
    }

    /// m:ss, or h:mm:ss past an hour, for the scrubber's time readout.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
