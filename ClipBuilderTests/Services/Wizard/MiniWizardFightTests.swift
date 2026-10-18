import Foundation
import Testing
@testable import Clip_Builder

@Suite("Mini Wizard Fight metrics")
struct MiniWizardFightTests {
    private func event(_ id: Int64, _ time: Double, _ fighter: String = "a", _ action: String = "strike",
                       end: Double? = nil, outcome: String? = nil, detail: String? = nil, points: Double = 1) -> FightEventRecord {
        FightEventRecord(id: id, videoID: 1, time: time, fighterKey: fighter, action: action, points: points,
                         targetKey: nil, endTime: end, outcome: outcome, detail: detail, scoringVersion: 2)
    }

    @Test func actionsAreChronologicalPaddedAndDeduplicatedLikeTheInspector() {
        let events = [event(3, 9.8, "b", "takedown_attempt", end: 11, outcome: "defended"),
                      event(1, 2), event(2, 2.25, "a", "significant_strike", points: 2),
                      event(4, 0.2), event(5, 40, "b", "submission_attempt", end: 44, outcome: "completed", detail: "armbar")]
        let actions = MiniWizardFightRules.actions(events: events, duration: 42)
        // The 2.0 and 2.2 strikes are one cluster; the heavier strike wins.
        #expect(actions.map(\.id) == [4, 2, 3, 5])
        #expect(actions[0].range == 0...0.7)
        #expect(actions[1].range == 1.75...2.75)
        #expect(actions[2].range == 9.3...11.5 && actions[2].label == "Takedown attempt · defended")
        // Clamped to the video; detail and outcome read in the label.
        #expect(actions[3].range == 39.5...42 && actions[3].label == "Submission attempt · armbar · completed")
        #expect(actions.map(\.family) == ["strike", "strike", "takedown", "submission"])
    }

    @Test func pickedActionsMergeOnlyWhenTheirTimeIsUnbroken() {
        let actions = MiniWizardFightRules.actions(events: [
            event(1, 2), event(2, 2.8, "b"), event(3, 3.7, "a", "takedown_attempt", end: 5, outcome: "completed"),
            event(4, 9), event(5, 20),
        ], duration: 60)
        // 1.5–2.5, 2.3–3.3, 3.2–5.5 overlap in turn: one unit across fighters and kinds. 9 and 20 stand alone.
        let units = MiniWizardFightRules.units(for: actions.shuffled())
        #expect(units.count == 3)
        #expect(units[0].range == 1.5...5.5 && units[0].eventIDs == [1, 2, 3])
        #expect(units[1].range == 8.5...9.5 && units[1].eventIDs == [4])
        #expect(units[2].range == 19.5...20.5 && units[2].eventIDs == [5])
        // Touching spans count as unbroken; a gap of any size does not.
        let touching = MiniWizardFightRules.units(for: [actions[0], actionAt(3)])
        #expect(touching.count == 1 && touching[0].range == 1.5...3.5)
        #expect(MiniWizardFightRules.units(for: [actions[0], actionAt(3.01)]).count == 2)
        #expect(MiniWizardFightRules.units(for: []).isEmpty)
        // "As one" spans the earliest to the latest regardless of gaps.
        #expect(MiniWizardFightRules.span(of: [actions[0], actions[4]]) == 1.5...20.5)
        #expect(MiniWizardFightRules.span(of: [actions[4]]) == 19.5...20.5)
        #expect(MiniWizardFightRules.span(of: []) == nil)
    }

    private func actionAt(_ time: Double) -> MiniWizardFightRules.Action {
        MiniWizardFightRules.actions(events: [event(99, time)], duration: 60)[0]
    }

    @Test func titlesNameTheFightersAndCountTheirActions() {
        let names = ["a": "Felipe", "b": "João"]
        let actions = MiniWizardFightRules.actions(events: [
            event(1, 2), event(2, 2.8), event(3, 3.7, "a", "takedown_attempt", end: 5, outcome: "completed"),
        ], duration: 60)
        #expect(MiniWizardFightRules.title(for: actions, names: names, number: 1) == "Felipe: 2 strikes, takedown")
        let both = actions + [actionAt(4).with(fighter: "b", action: "submission_attempt")]
        #expect(MiniWizardFightRules.title(for: both, names: names, number: 1) == "Felipe & João: 2 strikes, takedown, submission")
        // Unattributed actions still get a name; no actions fall back to a number.
        #expect(MiniWizardFightRules.title(for: [actionAt(4).with(fighter: "")], names: names, number: 2) == "Strike")
        #expect(MiniWizardFightRules.title(for: [], names: names, number: 2) == "Pick 2")
        // A pick whose events are gone keeps a numbered name; a long title is cut.
        let pick = FightPick(id: 1, videoID: 1, position: 0, start: 1, end: 5, originalStart: 1, originalEnd: 5, eventIDs: [77])
        #expect(MiniWizardFightRules.title(for: pick, actions: actions, names: names, number: 3) == "Pick 3")
        #expect(MiniWizardFightRules.title(for: actions, names: names, number: 1, limit: 12) == "Felipe: 2 s…")
        let plan = MiniWizardFightRules.plan(for: pick, sceneID: 9, name: "Felipe: strike")
        #expect(plan.clips.map { ($0.sceneID, $0.start, $0.end) }.first.map { $0 == (9, 1, 5) } == true)
        #expect(plan.targetDuration == 4 && plan.headline == "Felipe: strike")
    }

    @Test func picksRoundTripAndBecomeTaggedScenesAndSelections() async throws {
        let temp = try TempDatabase()
        let database = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let projectID = try await database.createProject(profileName: "Test", name: "Fight", videoIDs: [videoID])
        let late = try await database.addFightPick(videoID: videoID, start: 8.5, end: 9.5, eventIDs: [4])
        let early = try await database.addFightPick(videoID: videoID, start: 1.5, end: 5.5, eventIDs: [1, 2, 3])
        #expect([late, early].map(\.position) == [0, 1] && early.eventIDs == [1, 2, 3] && early.sceneID == nil)
        try await database.setFightPickRange(id: late.id, start: 8, end: 10)
        try await database.reorderFightPicks(videoID: videoID, ids: [early.id])
        var picks = try await database.fetchFightPicks(videoID: videoID)
        #expect(picks.map(\.id) == [early.id, late.id] && picks[1].range == 8...10 && picks[1].originalRange == 8.5...9.5)

        let actions = MiniWizardFightRules.actions(events: [
            event(1, 2), event(2, 2.8), event(3, 3.7, "a", "takedown_attempt", end: 5, outcome: "completed"), event(4, 9, "b"),
        ], duration: 20)
        var options = WizardStep1Options()
        options.formatPreset = "custom"
        let candidates = try await database.replaceMiniFightSelections(projectID: projectID, videoID: videoID,
            miniBatch: "batch", picks: picks, actions: actions, names: ["a": "Felipe", "b": "João"], options: options)
        #expect(candidates.map(\.selection.name) == ["Felipe: 2 strikes, takedown", "João: strike"])
        #expect(candidates.map { $0.take.plan.clips[0].start } == [1.5, 8])
        #expect(candidates.map { $0.take.plan.clips[0].end } == [5.5, 10])
        let sceneIDs = candidates.map { $0.take.plan.clips[0].sceneID }
        let scenes = try await database.fetchScenes(ids: Set(sceneIDs))
        #expect(scenes.count == 2 && scenes.allSatisfy { $0.tags.contains(Database.fightPickTag) && $0.runID != nil })
        picks = try await database.fetchFightPicks(videoID: videoID)
        #expect(picks.map(\.sceneID) == sceneIDs)
        // Saving again replaces the batch; deleting removes a pick.
        _ = try await database.replaceMiniFightSelections(projectID: projectID, videoID: videoID,
            miniBatch: "batch", picks: picks, actions: actions, names: [:], options: options)
        #expect(try await database.fetchWizardSelections(projectID: projectID, miniBatch: "batch").count == 2)
        try await database.deleteFightPick(id: late.id)
        #expect(try await database.fetchFightPicks(videoID: videoID).map(\.id) == [early.id])
    }
}

private extension MiniWizardFightRules.Action {
    func with(fighter: String? = nil, action: String? = nil) -> Self {
        var copy = self
        if let fighter { copy.fighterKey = fighter }
        if let action { copy.action = action }
        return copy
    }
}
