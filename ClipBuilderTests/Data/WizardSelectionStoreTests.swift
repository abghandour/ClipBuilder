import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard selection store")
struct WizardSelectionStoreTests {
    @Test func takesEditsBestProjectScopeAndDeletion() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let project = try await db.createProject(profileName: "Test", name: "First")
        let other = try await db.createProject(profileName: "Test", name: "Other")
        var options = WizardOptions()
        options.projectID = project
        options.aiInstructions = "Keep the answer"
        var plan = Fixtures.plan()
        plan.headline = "The answer"
        plan.provenance = AIProvenance(provider: "fixture", model: "test", task: "wizard")
        let first = try await db.recordWizardTake(projectID: project, options: options.step1, plan: plan)
        let second = try await db.addWizardSelectionTake(selectionID: first.selectionID, plan: plan,
            note: "Start later", proxyPath: "/tmp/proxy.mp4", criticScore: 90, criticNotes: "Good")
        #expect(first.ordinal == 1 && second.ordinal == 2)
        #expect(first.provenance == plan.provenance)
        let selections = try await db.fetchWizardSelections(projectID: project)
        #expect(selections.count == 1 && selections.first?.name == "The answer")
        #expect(selections.first?.step1Options.aiInstructions == options.aiInstructions)
        #expect(try await db.fetchWizardSelections(projectID: other).isEmpty)
        try await db.setBestWizardSelectionTake(selectionID: first.selectionID, takeID: second.id)
        #expect(try await db.wizardSelection(id: first.selectionID)?.bestTakeID == second.id)
        plan.clips[0].start = 3
        plan.clips[0].areaClips = [WizardPlanAreaClip(area: "Side", sceneID: 8, start: 3, end: 6)]
        try await db.updateWizardSelectionTakePlan(id: second.id, plan: plan)
        let edited = try #require(try await db.wizardSelectionTake(id: second.id))
        #expect(edited.ordinal == 2 && edited.plan.clips[0].start == 3)
        #expect(edited.sceneIDs == [1, 8])
        #expect(edited.proxyPath == nil && edited.criticScore == nil && edited.criticNotes == nil)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: first.selectionID).count == 2)
        let video = try await db.insertGeneratedVideo(path: "/tmp/reel.mp4", duration: 4,
            timelineJSON: "{}", wizardProvider: "fixture", wizardModel: nil,
            projectID: project, selectionTakeID: second.id)
        #expect(try await db.fetchGeneratedVideos(projectID: project).first { $0.id == video }?.selectionTakeID == second.id)
        #expect(try await db.fetchTimelines(projectID: project).first?.sourceRunID == "take:\(second.id)")
        try await db.deleteWizardSelectionTake(id: second.id)
        #expect(try await db.wizardSelection(id: first.selectionID)?.bestTakeID == nil)
        #expect(try await db.fetchGeneratedVideos(projectID: project).first?.selectionTakeID == nil)
        try await db.deleteWizardSelection(id: first.selectionID)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: first.selectionID).isEmpty)
        #expect(try await db.fetchGeneratedVideos(projectID: project).count == 1)
    }

    @Test func bestTakeCannotBelongToAnotherSelectionAndProjectDeletionCascades() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let project = try await db.createProject(profileName: "Test", name: "Project")
        let first = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: Fixtures.plan())
        let second = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: Fixtures.plan())
        await #expect(throws: WizardSelectionError.self) {
            try await db.setBestWizardSelectionTake(selectionID: first.selectionID, takeID: second.id)
        }
        try await db.setBestWizardSelectionTake(selectionID: first.selectionID, takeID: first.id)
        try await db.deleteProject(id: project)
        #expect(try await db.fetchWizardSelections(projectID: project).isEmpty)
        #expect(try await db.wizardSelectionTake(id: first.id) == nil)
    }

    @Test func additiveMigrationPreservesExistingOutputsAndReopens() async throws {
        let directory = try TempDirectory()
        let path = directory.url.appendingPathComponent("old.db")
        do {
            let connection = try SQLiteConnection(path: path.path)
            try connection.executeScript(Database.schema)
            try connection.execute("DROP TABLE wizard_selections")
            try connection.execute("DROP TABLE wizard_selection_takes")
            try Database.migrate(connection)
            try connection.execute("PRAGMA user_version = 20")
            try connection.execute("INSERT INTO generated_videos (path, duration, timeline_json) VALUES ('/tmp/old.mp4', 4, '{}')")
        }
        let db = try Database(path: path)
        #expect(try await db.fetchGeneratedVideos().first?.path == "/tmp/old.mp4")
        #expect(try await db.fetchGeneratedVideos().first?.selectionTakeID == nil)
        let project = try await db.createProject(profileName: "Test", name: "Migrated")
        let take = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: Fixtures.plan())
        let reopened = try Database(path: path)
        #expect(try await reopened.wizardSelectionTake(id: take.id)?.plan.clips.count == 1)
    }

    @Test func failedPlanEncodingRollsBackSelectionCreation() async throws {
        let temp = try TempDatabase()
        let project = try await temp.database.createProject(profileName: "Test", name: "Project")
        var plan = Fixtures.plan()
        plan.targetDuration = .nan
        do {
            _ = try await temp.database.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: plan)
            Issue.record("Non-finite plan should fail JSON encoding")
        } catch is EncodingError {
            #expect(try await temp.database.fetchWizardSelections(projectID: project).isEmpty)
        }
    }

}

extension WizardSelectionStoreTests {
    @Test func persistedFootageAndRenamingSurviveTakeEditsWithoutANewOrdinal() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo()
        let project = try await db.createProject(profileName: "Test", name: "Selections", videoIDs: [videoID])
        let scene = try #require(try await db.fetchScenes(projectID: project).first)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id)])
        let take = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: plan)
        #expect(take.plan.footage?.first?.videoID == videoID)
        #expect(take.plan.footage?.first?.start == scene.startTime)
        #expect(take.plan.footage?.first?.end == scene.endTime)
        try await db.renameWizardSelection(id: take.selectionID, name: "  The finishing exchange  ")
        #expect(try await db.wizardSelection(id: take.selectionID)?.name == "The finishing exchange")
        var edited = take.plan
        edited.clips[0].start = 3
        try await db.updateWizardSelectionTakePlan(id: take.id, plan: edited)
        let reread = try #require(try await db.wizardSelectionTake(id: take.id))
        #expect(reread.ordinal == 1)
        #expect(reread.plan.clips[0].start == 3)
        #expect(reread.plan.footage?.first?.start == scene.startTime)
        #expect(try await db.fetchWizardSelectionTakes(selectionID: take.selectionID).count == 1)
    }
}

extension WizardSelectionStoreTests {
    @Test func criticReferencesExcludeAllLooksOfTheSelectionAndTheirBatchSiblings() async throws {
        let temp = try TempDatabase()
        let db = temp.database
        let project = try await db.createProject(profileName: "Test", name: "Selections")
        let first = try await db.recordWizardTake(projectID: project, options: WizardOptions().step1, plan: Fixtures.plan())
        let second = try await db.addWizardSelectionTake(selectionID: first.selectionID, plan: Fixtures.plan())
        let look1 = try await db.insertGeneratedVideo(path: "/tmp/look1.mp4", duration: 4, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: project, selectionTakeID: first.id, batchID: "look1")
        let look2 = try await db.insertGeneratedVideo(path: "/tmp/look2.mp4", duration: 4, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: project, selectionTakeID: second.id, batchID: "look2")
        let sibling = try await db.insertGeneratedVideo(path: "/tmp/sibling.mp4", duration: 4, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: project, batchID: "look1")
        let unrelated = try await db.insertGeneratedVideo(path: "/tmp/unrelated.mp4", duration: 4, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: project, batchID: "other")
        let exclusion = try await db.wizardSelectionCriticExclusion(selectionID: first.selectionID)
        #expect(exclusion.ids == Set([look1, look2, sibling].map { "generated:\($0)" }))
        #expect(!exclusion.ids.contains("generated:\(unrelated)"))
        #expect(exclusion.batchIDs == ["look1", "look2"])
        #expect(exclusion.paths == ["/tmp/look1.mp4", "/tmp/look2.mp4", "/tmp/sibling.mp4"])
    }
}
