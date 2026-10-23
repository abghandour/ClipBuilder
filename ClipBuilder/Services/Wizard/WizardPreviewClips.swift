import Foundation

/// One stretch of kept footage the Express preview can scrub through: the
/// scene it belongs to and the exact source range the render will use.
nonisolated struct WizardPreviewClip: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var scene: SceneRecord
    var start: Double
    var end: Double

    var range: ClosedRange<Double> { start...max(start, end) }
    var duration: Double { max(0, end - start) }
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
        let picked = pickClips(run: run, scenes: scenes, byID: byID)
        if !picked.isEmpty { return picked }
        let takes = run.candidates.filter { $0.kept && !$0.take.plan.clips.isEmpty }
        if !takes.isEmpty {
            for candidate in takes {
                for (index, clip) in candidate.take.plan.clips.enumerated() where clip.end > clip.start {
                    guard let scene = byID[clip.sceneID] else { continue }
                    let title = candidate.take.plan.clips.count > 1
                        ? "\(candidate.selection.name) · \(index + 1)" : candidate.selection.name
                    result.append(.init(id: "take-\(candidate.id)-\(index)", title: title,
                                        scene: scene, start: clip.start, end: clip.end))
                }
            }
            return result
        }
        return result
    }

    private static func pickClips(run: MiniWizardRun, scenes: [SceneRecord], byID: [Int64: SceneRecord]) -> [WizardPreviewClip] {
        var result: [WizardPreviewClip] = []
        switch run.footageKind {
        case .qa:
            guard let qa = run.qa else { return [] }
            for section in qa.sections where qa.kept.contains(section.id) && section.scene.videoID == run.video.id {
                let range = section.range
                guard range.upperBound > range.lowerBound else { continue }
                result.append(.init(id: "qa-\(section.id)", title: section.question,
                                    scene: section.scene, start: range.lowerBound, end: range.upperBound))
            }
        case .transcript:
            for pick in run.transcript?.picks ?? [] {
                guard let scene = containing(pick.range, id: pick.sceneID, scenes: scenes, byID: byID) else { continue }
                result.append(.init(id: "pick-\(pick.id)", title: "Passage \(pick.position + 1)",
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
