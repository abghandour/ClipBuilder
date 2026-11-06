import Foundation
import Testing
@testable import Clip_Builder

@Suite("Highlight history storage")
struct WizardHighlightStorageTests {
    private func draft(_ projectID: Int64, plan: WizardPlan?, parentID: Int64? = nil,
                       flow: WizardHighlightFlow = .expressHighlights) -> WizardHighlightDraft {
        var options = WizardOptions()
        options.projectID = projectID
        return WizardHighlightDraft(projectID: projectID, flow: flow, batchID: "batch", parentID: parentID,
            settings: WizardHighlightSettings(options: options, length: "15"), plan: plan,
            provenance: [AIRole(role: "Plan", provenance: AIProvenance(provider: "claude", model: "m", task: "wizard"))],
            note: "first", author: "Tester")
    }

    /// A second connection, as a teammate's sync or an older build would write.
    private func raw(_ temp: TempDatabase, _ sql: String) throws {
        let connection = try SQLiteConnection(path: temp.path.path)
        try connection.execute(sql)
    }

    @Test func highlightsRecordFootageByHashAndListNewestFirst() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let projectID = try await db.createProject(profileName: "Test", name: "History", videoIDs: [videoID])
        let scenes = try await db.fetchScenes(videoID: videoID).sorted { $0.startTime < $1.startTime }
        let hash = try #require(try await db.video(id: videoID)).hash
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scenes[0].id, start: 1, end: 5),
                                         Fixtures.planClip(sceneID: scenes[1].id, start: 11, end: 15)])

        let first = try await db.insertWizardHighlight(draft(projectID, plan: plan))
        #expect(first.videoHashes == [hash])
        // Footage is recorded by ascending scene id, whatever order the ids were handed out in.
        #expect(first.footage == scenes.sorted { $0.id < $1.id }
            .map { HighlightFootageRef(sceneID: $0.id, videoHash: hash, start: $0.startTime, end: $0.endTime) })
        #expect(first.highlightFlow == .expressHighlights && first.author == "Tester" && first.note == "first")
        #expect(first.settings?.length == "15" && first.settings?.options.projectID == projectID)
        #expect(first.plan?.clips.map(\.sceneID) == scenes.map(\.id))
        #expect(first.plan?.footage?.count == 2, "plan_json keeps this Mac's footage snapshot")
        #expect(first.provenance.first?.provenance.provider == "claude")

        let child = try await db.insertWizardHighlight(draft(projectID, plan: plan, parentID: first.id))
        #expect(child.parentID == first.id)
        #expect(try await db.fetchHighlights(projectID: projectID).map(\.id) == [child.id, first.id])
        #expect(try await db.fetchHighlights(projectID: projectID, videoHash: hash).count == 2)
        #expect(try await db.fetchHighlights(projectID: projectID, videoHash: "elsewhere").isEmpty)
        let other = try await db.createProject(profileName: "Test", name: "Other", videoIDs: [videoID])
        #expect(try await db.fetchHighlights(projectID: other).isEmpty)

        try await db.updateWizardHighlight(id: first.id, generatedVideoID: nil, takeID: nil)
        try await db.updateWizardHighlightNote(id: first.id, note: "  ")
        #expect(try await db.fetchHighlight(id: first.id)?.note == nil)
        try await db.deleteHighlight(id: first.id)
        #expect(try await db.fetchHighlight(id: child.id)?.parentID == nil, "a deleted parent leaves the child")
        try await db.deleteProject(id: projectID)
        #expect(try await db.fetchHighlight(id: child.id) == nil)
    }

    @Test func openResolvesFootageAndCreatesMissingScenes() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let projectID = try await db.createProject(profileName: "Test", name: "Open", videoIDs: [videoID])
        let scenes = try await db.fetchScenes(videoID: videoID).sorted { $0.startTime < $1.startTime }
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scenes[0].id, start: 1, end: 5),
                                         Fixtures.planClip(sceneID: scenes[1].id, start: 11, end: 15)])
        let record = try await db.insertWizardHighlight(draft(projectID, plan: plan))

        let same = try #require(try await db.openHighlight(id: record.id))
        #expect(same.missingVideoHashes.isEmpty)
        #expect(same.plan?.clips.map(\.sceneID) == scenes.map(\.id))

        // Re-analysis (or a teammate's Mac) has no scene for the second range.
        try raw(temp, "DELETE FROM scenes WHERE id = \(scenes[1].id)")
        let reopened = try #require(try await db.openHighlight(id: record.id))
        let plan2 = try #require(reopened.plan)
        #expect(plan2.clips[0].sceneID == scenes[0].id)
        // scenes.id has no AUTOINCREMENT, so the recreated scene may reuse the
        // deleted id; identify it by its range and the history tag instead.
        let created = try #require(try await db.fetchScenes(ids: [plan2.clips[1].sceneID]).first)
        #expect(created.videoID == videoID && created.startTime == 10 && created.endTime == 18)
        #expect(created.tags.contains(Database.highlightHistoryTag))
        #expect(plan2.clips[1].start == 11 && plan2.clips[1].end == 15)

        // A source video this library lacks: nothing is created.
        try await db.deleteVideos([videoID])
        let missing = try #require(try await db.openHighlight(id: record.id))
        #expect(missing.plan == nil && missing.missingVideoHashes == record.videoHashes)
    }

    @Test func qaPicksArePerProjectAndImportLegacyOnce() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 3)
        let a = try await db.createProject(profileName: "Test", name: "A", videoIDs: [videoID])
        let b = try await db.createProject(profileName: "Test", name: "B", videoIDs: [videoID])
        let ids = try await db.fetchScenes(videoID: videoID).sorted { $0.startTime < $1.startTime }.map(\.id)

        try await db.replaceQAPicks(projectID: a, videoID: videoID, sceneIDs: [ids[2], ids[0], ids[2]])
        #expect(try await db.fetchQAPicks(projectID: a, videoID: videoID) == [ids[2], ids[0]])
        #expect(try await db.fetchQAPicks(projectID: b, videoID: videoID).isEmpty)

        // Legacy import fills only an empty list and skips scenes that are gone.
        #expect(try await db.fetchQAPicks(projectID: b, videoID: videoID, importing: [ids[1], 99_999]) == [ids[1]])
        #expect(try await db.fetchQAPicks(projectID: a, videoID: videoID, importing: [ids[1]]) == [ids[2], ids[0]])

        try await db.replaceQAPicks(projectID: a, videoID: videoID, sceneIDs: [])
        #expect(try await db.fetchQAPicks(projectID: a, videoID: videoID).isEmpty)
        try await db.deleteProject(id: b)
        #expect(try await db.fetchQAPicks(projectID: b, videoID: videoID).isEmpty)
    }

    @Test func qaPickReorderKeepsUnlistedAndTicksAppend() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 4)
        let a = try await db.createProject(profileName: "Test", name: "A", videoIDs: [videoID])
        let ids = try await db.fetchScenes(videoID: videoID).sorted { $0.startTime < $1.startTime }.map(\.id)
        try await db.replaceQAPicks(projectID: a, videoID: videoID, sceneIDs: [ids[0], ids[1], ids[2]])
        // A reorder names only what the list showed; a pick synced in
        // meanwhile (ids[3]) keeps its place after them and is not deleted.
        try await db.applyQAPickDelta(projectID: a, videoID: videoID, inserted: [ids[3]], deleted: [])
        try await db.reorderQAPicks(projectID: a, videoID: videoID, sceneIDs: [ids[2], ids[0], ids[1]])
        #expect(try await db.fetchQAPicks(projectID: a, videoID: videoID) == [ids[2], ids[0], ids[1], ids[3]])
        // Unkeep two, keep one again: it lands at the end, after a reload too.
        try await db.applyQAPickDelta(projectID: a, videoID: videoID, inserted: [], deleted: [ids[0], ids[1]])
        try await db.applyQAPickDelta(projectID: a, videoID: videoID, inserted: [ids[0]], deleted: [])
        #expect(try await db.fetchQAPicks(projectID: a, videoID: videoID) == [ids[2], ids[3], ids[0]])
    }

    @Test func picksAreProjectScopedAndLegacyRowsAreAdoptedOnFirstWrite() async throws {
        let temp = try await TempDatabase()
        let db = temp.database
        let videoID = try await temp.seedVideo(sceneCount: 1)
        let a = try await db.createProject(profileName: "Test", name: "A", videoIDs: [videoID])
        let b = try await db.createProject(profileName: "Test", name: "B", videoIDs: [videoID])

        let inA = try await db.addTranscriptPick(projectID: a, videoID: videoID, start: 0, end: 2)
        let inB = try await db.addTranscriptPick(projectID: b, videoID: videoID, start: 3, end: 5)
        #expect(inA.projectID == a && inA.position == 0 && inB.position == 0)
        #expect(try await db.fetchTranscriptPicks(projectID: a, videoID: videoID).map(\.id) == [inA.id])
        #expect(try await db.fetchTranscriptPicks(projectID: b, videoID: videoID).map(\.id) == [inB.id])

        // A pick from before project scoping shows in every project ...
        let legacy = try await db.addTranscriptPick(projectID: a, videoID: videoID, start: 6, end: 8)
        try raw(temp, "UPDATE transcript_picks SET project_id = NULL WHERE id = \(legacy.id)")
        #expect(try await db.fetchTranscriptPicks(projectID: b, videoID: videoID).map(\.id).contains(legacy.id))
        #expect(try await db.fetchTranscriptPicks(projectID: a, videoID: videoID).map(\.id).contains(legacy.id))
        // ... until one project writes to the video's list.
        _ = try await db.addTranscriptPick(projectID: b, videoID: videoID, start: 9, end: 9.5)
        #expect(try await db.transcriptPick(id: legacy.id)?.projectID == b)
        #expect(try await db.fetchTranscriptPicks(projectID: a, videoID: videoID).map(\.id) == [inA.id])
        #expect(try await db.fetchTranscriptPicks(projectID: nil, videoID: videoID).count == 4)
        try await db.deleteTranscriptPicks(projectID: b, videoID: videoID)
        #expect(try await db.fetchTranscriptPicks(projectID: nil, videoID: videoID).map(\.id) == [inA.id])

        let fightA = try await db.addFightPick(projectID: a, videoID: videoID, start: 0, end: 2, eventIDs: [])
        let fightLegacy = try await db.addFightPick(projectID: a, videoID: videoID, start: 3, end: 4, eventIDs: [])
        try raw(temp, "UPDATE fight_picks SET project_id = NULL WHERE id = \(fightLegacy.id)")
        #expect(try await db.fetchFightPicks(projectID: b, videoID: videoID).map(\.id) == [fightLegacy.id])
        try await db.setFightPickRange(projectID: b, id: fightLegacy.id, start: 3, end: 5)
        #expect(try await db.fetchFightPicks(projectID: a, videoID: videoID).map(\.id) == [fightA.id])
        #expect(try await db.fetchFightPicks(projectID: b, videoID: videoID).first?.range == 3...5)
    }

    @Test func schema39DatabaseGainsPickProjectsAndHistoryTables() async throws {
        let directory = try TempDirectory()
        let path = directory.url.appendingPathComponent("old.db")
        do {
            let connection = try SQLiteConnection(path: path.path)
            try connection.executeScript(Database.schema)
            try Database.migrate(connection)
            for table in ["transcript_picks", "fight_picks", "qa_picks", "wizard_highlights"] {
                try connection.execute("DROP TABLE \(table)")
            }
            try connection.execute("""
                CREATE TABLE transcript_picks (id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, start_time REAL NOT NULL, end_time REAL NOT NULL, original_start REAL NOT NULL,
                    original_end REAL NOT NULL, scene_id INTEGER REFERENCES scenes(id) ON DELETE SET NULL,
                    created_at TEXT DEFAULT (datetime('now')))
                """)
            try connection.execute("""
                CREATE TABLE fight_picks (id INTEGER PRIMARY KEY, video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, start_time REAL NOT NULL, end_time REAL NOT NULL, original_start REAL NOT NULL,
                    original_end REAL NOT NULL, event_ids TEXT NOT NULL DEFAULT '[]',
                    scene_id INTEGER REFERENCES scenes(id) ON DELETE SET NULL, created_at TEXT DEFAULT (datetime('now')))
                """)
            try connection.execute("PRAGMA user_version = 39")
        }
        let db = try await Task.detached { try Database(path: path) }.value
        let videoID = try await db.registerVideo(hash: "h", filename: "f.mp4", path: "/tmp/f.mp4", duration: 10,
                                                 width: 1920, height: 1080, wide: true)
        let projectID = try await db.createProject(profileName: "Test", name: "Migrated", videoIDs: [videoID])
        #expect(try await db.addTranscriptPick(projectID: projectID, videoID: videoID, start: 0, end: 1).projectID == projectID)
        #expect(try await db.addFightPick(projectID: projectID, videoID: videoID, start: 0, end: 1, eventIDs: []).projectID == projectID)
        #expect(try await db.fetchHighlights(projectID: projectID).isEmpty)
        #expect(try await db.fetchQAPicks(projectID: projectID, videoID: videoID).isEmpty)
    }
}
