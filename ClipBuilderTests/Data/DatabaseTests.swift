import Foundation
import Testing
@testable import Clip_Builder

@Suite("Database")
struct DatabaseTests {
    @Test("regression: a fresh database creates its tables before their indexes and stamps the version")
    func freshSchema() async throws {
        let temp = try TempDatabase()
        let connection = try SQLiteConnection(path: temp.path.path)
        let version = try connection.query("PRAGMA user_version").first?["user_version"]?.intValue
        #expect(version == Database.schemaVersion)
        let tables = try connection.query("SELECT name FROM sqlite_master WHERE type='table'")
            .compactMap { $0["name"]?.stringValue }
        #expect(tables.contains("videos"))
        #expect(tables.contains("scenes"))
        let indexes = try connection.query("SELECT name FROM sqlite_master WHERE type='index'")
        #expect(!indexes.isEmpty)
    }

    @Test("a database from before the version stamp migrates on open and keeps every current column")
    func legacyDatabaseMigrates() async throws {
        let fixture = try #require(Bundle(for: DatabaseBundleToken.self)
            .url(forResource: "legacy-v0", withExtension: "db"))
        let temp = try TempDirectory(prefix: "ClipBuilderLegacyDB")
        let copy = temp.url.appendingPathComponent("legacy.db")
        try FileManager.default.copyItem(at: fixture, to: copy)

        let raw = try SQLiteConnection(path: copy.path)
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == 0)

        let database = try Database(path: copy)
        #expect(try raw.query("PRAGMA user_version").first?["user_version"]?.intValue == Database.schemaVersion)
        for (table, column) in [("videos", "video_type"), ("videos", "naming_provider"),
                                ("scenes", "curated_provider"), ("scenes", "stack_choice"),
                                ("video_notes", "provider"), ("fight_events", "model")] {
            #expect(try raw.columnNames(of: table).contains(column), "\(table).\(column) missing after migration")
        }
        // The migrated file is usable, not just stamped.
        #expect(try await database.fetchVideos().isEmpty)
    }

    @Test("a database stamped with the current version skips the column migrations")
    func stampedDatabaseSkipsMigration() async throws {
        let temp = try TempDatabase()
        let raw = try SQLiteConnection(path: temp.path.path)
        // Knock a migrated column out while the stamp still says "current".
        try raw.execute("ALTER TABLE video_notes DROP COLUMN provider")
        #expect(!(try raw.columnNames(of: "video_notes").contains("provider")))

        _ = try Database(path: temp.path)
        #expect(!(try raw.columnNames(of: "video_notes").contains("provider")),
                "migration ran on a database stamped with the current version")

        // Resetting the stamp makes the next open repair it.
        try raw.execute("PRAGMA user_version = 0")
        _ = try Database(path: temp.path)
        #expect(try raw.columnNames(of: "video_notes").contains("provider"))
    }

    @Test("opens in WAL mode, and a locked folder fails cleanly instead of hanging or leaving debris")
    func journalModeAndLockedFolder() async throws {
        let temp = try TempDatabase()
        #expect(try await temp.database.journalMode() == "wal")

        // A directory that allows no new files can take neither WAL sidecars
        // nor a rollback journal, so there is nothing to fall back to: the
        // open must throw a readable error and leave the folder untouched.
        let locked = temp.directory.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(throws: (any Error).self) {
            _ = try Database(path: locked.appendingPathComponent("test.db"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
    }

    @Test("video analysis CRUD preserves tags, grades, and curation provenance")
    func analysisCRUD() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 2)
        var scenes = try await temp.database.fetchScenes(videoID: videoID)
        #expect(scenes.count == 2)
        #expect(scenes.allSatisfy { $0.tags == ["fixture"] })
        let sceneID = try #require(scenes.first?.id)

        try await temp.database.setSceneFavorite(sceneID, favorite: true)
        try await temp.database.setSceneCurated(
            sceneID, curated: true,
            provenance: AIProvenance(provider: "test", model: "fixture", task: "curate")
        )
        try await temp.database.addGrade(sceneID: sceneID, score: 8)
        try await temp.database.addGrade(sceneID: sceneID, score: 10)
        scenes = try await temp.database.fetchScenes(sceneID: sceneID)
        let updated = try #require(scenes.first)
        #expect(updated.favorite)
        #expect(updated.curated)
        #expect(updated.curatedProvider == "test")
        #expect(updated.gradeAverage == 9)
        #expect(updated.gradeCount == 2)
    }

    @Test("deleting an analysis run cascades its scenes and tags")
    func deleteAnalysisRunCascades() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 1)
        let scene = try #require(try await temp.database.fetchScenes(videoID: videoID).first)
        let runID = try #require(scene.runID)
        try await temp.database.deleteAnalysisRun(id: runID)
        #expect(try await temp.database.fetchScenes(videoID: videoID).isEmpty)

        let connection = try SQLiteConnection(path: temp.path.path)
        let dangling = try connection.query("SELECT COUNT(*) AS count FROM scene_tags").first?["count"]?.intValue
        #expect(dangling == 0)
    }

    @Test("renaming a video updates its row and records naming provenance")
    func renameVideo() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let newPath = temp.directory.url.appendingPathComponent("renamed.mp4").path
        try await temp.database.renameVideo(
            id: videoID, filename: "renamed.mp4", path: newPath,
            provenance: AIProvenance(provider: "test", model: "namer", task: "naming")
        )
        let video = try #require(try await temp.database.fetchVideos().first { $0.id == videoID })
        #expect(video.filename == "renamed.mp4")
        #expect(video.path == newPath)
        #expect(video.namingProvenance?.provider == "test")
        // Scenes follow the video through the join, not a copied path.
        let scene = try #require(try await temp.database.fetchScenes(videoID: videoID).first)
        #expect(scene.videoPath == newPath)
        #expect(scene.videoFilename == "renamed.mp4")
    }

    @Test("merging people retags scenes, moves markers, and drops the source")
    func mergePeople() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo(sceneCount: 2)
        let scenes = try await temp.database.fetchScenes(videoID: videoID)
        try await temp.database.upsertPerson(key: "alpha", descriptor: "blue shorts")
        try await temp.database.upsertPerson(key: "beta", descriptor: "red shorts")
        let people = try await temp.database.fetchPeople()
        let alpha = try #require(people.first { $0.key == "alpha" })
        let beta = try #require(people.first { $0.key == "beta" })

        // Scene 1 has only alpha; scene 2 has both (a retag collision).
        try await temp.database.addSceneTag(sceneID: scenes[0].id, tag: alpha.tag)
        try await temp.database.addSceneTag(sceneID: scenes[1].id, tag: alpha.tag)
        try await temp.database.addSceneTag(sceneID: scenes[1].id, tag: beta.tag)
        try await temp.database.addPersonMarker(videoID: videoID, at: 1, x: 0.1, y: 0.1, width: 0.2, height: 0.4)
        var marker = try #require(try await temp.database.personMarkers(videoID: videoID).first)
        marker.personID = alpha.id
        try await temp.database.updatePersonMarker(marker)

        try await temp.database.mergePeople(source: alpha, into: beta)

        let merged = try await temp.database.fetchScenes(videoID: videoID)
        #expect(merged[0].tags.contains(beta.tag))
        #expect(!merged[0].tags.contains(alpha.tag))
        #expect(merged[1].tags.filter { $0 == beta.tag }.count == 1)
        #expect(!merged[1].tags.contains(alpha.tag))
        #expect(try await temp.database.personMarkers(videoID: videoID).first?.personID == beta.id)
        #expect(try await temp.database.fetchPeople().map(\.key) == ["beta"])
    }

    @Test("video notes round trip in time order with provenance")
    func videoNotes() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.addVideoNote(videoID: videoID, at: 5, note: "later")
        try await temp.database.addVideoNote(
            videoID: videoID, at: 1, note: "soundbite",
            provenance: AIProvenance(provider: "test", model: "finder", task: "soundbites")
        )
        var notes = try await temp.database.videoNotes(videoID: videoID)
        #expect(notes.map(\.note) == ["soundbite", "later"])
        #expect(notes[0].provider == "test")
        #expect(notes[1].provider == nil)
        try await temp.database.deleteVideoNote(id: notes[0].id)
        notes = try await temp.database.videoNotes(videoID: videoID)
        #expect(notes.map(\.note) == ["later"])
    }

    @Test("person markers store their box, assignment, and ignore flag")
    func personMarkers() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.addPersonMarker(videoID: videoID, at: 2.5, x: 0.25, y: 0.5, width: 0.1, height: 0.3)
        var marker = try #require(try await temp.database.personMarkers(videoID: videoID).first)
        #expect(marker.atTime == 2.5)
        #expect(marker.x == 0.25 && marker.y == 0.5 && marker.width == 0.1 && marker.height == 0.3)
        #expect(marker.personID == nil)
        #expect(!marker.ignored)

        marker.ignored = true
        marker.atTime = 3
        try await temp.database.updatePersonMarker(marker)
        let updated = try #require(try await temp.database.personMarkers(videoID: videoID).first)
        #expect(updated.ignored)
        #expect(updated.atTime == 3)
    }

    @Test("fetchOutcomes keeps only the latest outcome per video")
    func outcomesLatestPerVideo() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        let runID = try #require(try await temp.database.fetchScenes(videoID: videoID).first?.runID)
        try await temp.database.saveFightOutcome(videoID: videoID, runID: runID, method: "decision",
                                                 winnerKey: "alpha", loserKey: "beta", event: nil, round: 3)
        try await temp.database.saveFightOutcome(videoID: videoID, runID: runID, method: "ko",
                                                 winnerKey: "beta", loserKey: "alpha", event: "Fixture 1", round: 1)
        let outcomes = try await temp.database.fetchOutcomes()
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.method == "ko")
        #expect(outcomes.first?.winnerKey == "beta")
        #expect(try await temp.database.fetchOutcomes(runIDs: [runID + 100]).isEmpty)
    }

    @Test("regression: re-analyzing a transcript keeps the user's accepted and rejected cut decisions")
    func transcriptReanalysisKeepsDecisions() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        func proposal(_ kind: EditProposal.Kind, _ start: Double, _ end: Double) -> EditProposal {
            EditProposal(id: 0, videoID: videoID, kind: kind, startTime: start, endTime: end,
                         reason: "fixture", decision: .pending)
        }
        try await temp.database.replaceTranscriptFeatures(
            videoID: videoID, features: [],
            proposals: [proposal(.silence, 0, 2), proposal(.filler, 5, 7), proposal(.silence, 9, 12)])
        var rows = try await temp.database.fetchEditProposals(videoID: videoID)
        #expect(rows.count == 3)
        rows[0].decision = .accepted
        rows[1].decision = .rejected
        try await temp.database.updateEditProposal(rows[0])
        try await temp.database.updateEditProposal(rows[1])

        // Re-transcribing proposes the same silence (shifted a frame), the
        // same filler, and a new range instead of the third one.
        try await temp.database.replaceTranscriptFeatures(
            videoID: videoID, features: [],
            proposals: [proposal(.silence, 0.1, 2.05), proposal(.filler, 5, 7), proposal(.silence, 20, 23)])
        let after = try await temp.database.fetchEditProposals(videoID: videoID)
        #expect(after.map(\.decision) == [.accepted, .rejected, .pending])
        #expect(after.map(\.startTime) == [0.1, 5, 20])
    }

    @Test("regression: an output whose project was deleted mid-render is recorded without an owner")
    func orphanedOutputStillRecorded() async throws {
        let temp = try TempDatabase()
        try await temp.database.ensureDefaultProject(profileName: "One", legacyTimelineJSON: nil)
        let projectID = try await temp.database.createProject(profileName: "One", name: "Gone")
        try await temp.database.deleteProject(id: projectID)
        let id = try await temp.database.insertGeneratedVideo(
            path: "/tmp/reel.mp4", duration: 12, timelineJSON: "{}",
            wizardProvider: nil, wizardModel: nil, projectID: projectID)
        let all = try await temp.database.fetchGeneratedVideos()
        #expect(all.contains { $0.id == id })
        // Home lists everything, including ownerless rows.
        let homeID = try #require(try await temp.database.homeProjectID(profileName: "One"))
        #expect(try await temp.database.fetchGeneratedVideos(projectID: homeID).contains { $0.id == id })
    }

    @Test("regression: Instagram report snapshot query has no ambiguous fetched_at column")
    func instagramReportInputs() async throws {
        let temp = try TempDatabase()
        let accountID = try await temp.database.upsertIGAccount(
            username: "fixture", kind: "own", displayName: nil,
            igUserID: "ig-1", followers: 100
        )
        let mediaID = try await temp.database.upsertIGReportMedia(IGReportMediaUpsert(
            accountID: accountID, shortcode: "ABC123", mediaID: "media-1",
            mediaType: "VIDEO", productType: "REELS", caption: "Fixture"
        ))
        try await temp.database.insertIGMediaInsightSnapshots([
            IGMediaInsightSnapshot(reportMediaID: mediaID, metric: "views", value: 10,
                                   fetchedAt: "2026-09-03T00:00:00Z"),
            IGMediaInsightSnapshot(reportMediaID: mediaID, metric: "views", value: 20,
                                   fetchedAt: "2026-09-04T00:00:00Z"),
        ])
        let account = try #require(try await temp.database.fetchIGAccounts().first)

        let inputs = try await temp.database.fetchIGReportInputs(account: account)
        #expect(inputs.media.first?.views == 20)
    }

    @Test("project migration creates an implicit permanent Home and supports shared membership")
    func projectMigrationAndMembership() async throws {
        let temp = try TempDatabase()
        let firstVideoID = try await temp.seedVideo()
        let secondVideoID = try await temp.seedVideo()

        try await temp.database.ensureDefaultProject(profileName: "Fixture",
                                                     legacyTimelineJSON: nil)
        var projects = try await temp.database.fetchProjects()
        let migrated = try #require(projects.first)
        #expect(migrated.name == "Home")
        #expect(migrated.isHome)
        #expect(migrated.sourceCount == 2)
        #expect(try await temp.database.fetchVideos(projectID: migrated.id).count == 2)

        let raw = try SQLiteConnection(path: temp.path.path)
        let homeMemberships = try raw.query(
            "SELECT COUNT(*) AS count FROM project_videos WHERE project_id = ?",
            [.integer(migrated.id)]
        ).first?["count"]?.intValue
        #expect(homeMemberships == 0)

        await #expect(throws: ProjectMutationError.homeIsPermanent) {
            try await temp.database.renameProject(id: migrated.id, name: "Renamed")
        }
        await #expect(throws: ProjectMutationError.homeIsPermanent) {
            try await temp.database.setProjectArchived(id: migrated.id, archived: true)
        }
        await #expect(throws: ProjectMutationError.homeIsPermanent) {
            try await temp.database.deleteProject(id: migrated.id)
        }
        await #expect(throws: ProjectMutationError.homeIsPermanent) {
            try await temp.database.duplicateProject(
                id: migrated.id,
                profileName: "Fixture",
                name: "Home Copy"
            )
        }

        let secondProjectID = try await temp.database.createProject(
            profileName: "Fixture", name: "Second", videoIDs: [firstVideoID]
        )
        var sharedVideos = try await temp.database.fetchVideos(projectID: secondProjectID)
        #expect(sharedVideos.map(\.id) == [firstVideoID])

        #expect(try await temp.database.fetchVideosNotInProject(secondProjectID).map(\.id) == [secondVideoID])
        try await temp.database.assignVideos([secondVideoID], to: secondProjectID)
        sharedVideos = try await temp.database.fetchVideos(projectID: secondProjectID)
        #expect(sharedVideos.count == 2)
        try await temp.database.removeVideos([firstVideoID], from: secondProjectID)
        #expect(try await temp.database.fetchVideos(projectID: secondProjectID).map(\.id) == [secondVideoID])
        #expect(try await temp.database.fetchVideos(projectID: migrated.id).count == 2)
        #expect(try await temp.database.fetchScenes(projectID: migrated.id).count == 2)
        projects = try await temp.database.fetchProjects()
        #expect(projects.first(where: { $0.id == secondProjectID })?.sourceCount == 1)
    }

    @Test("deleting a project preserves media and outputs and can move its timelines to Home")
    func projectDeleteSemantics() async throws {
        let temp = try TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.ensureDefaultProject(profileName: "Fixture", legacyTimelineJSON: nil)
        let home = try #require(try await temp.database.fetchProjects().first(where: \.isHome))
        let projectID = try await temp.database.createProject(
            profileName: "Fixture", name: "Disposable", videoIDs: [videoID]
        )
        let documentJSON = String(data: try JSONEncoder().encode(TimelineDocument()), encoding: .utf8) ?? "{}"
        _ = try await temp.database.createTimeline(
            projectID: projectID,
            name: "Keep This Cut",
            documentJSON: documentJSON
        )
        let outputID = try await temp.database.insertGeneratedVideo(
            path: "/tmp/project-output.mp4",
            duration: 10,
            timelineJSON: documentJSON,
            wizardProvider: "fixture",
            wizardModel: "test",
            projectID: projectID
        )

        try await temp.database.moveTimelines(from: projectID, to: home.id)
        try await temp.database.deleteProject(id: projectID)

        #expect(try await temp.database.fetchVideos(projectID: home.id).map(\.id) == [videoID])
        #expect(try await temp.database.fetchTimelines(projectID: home.id).contains { $0.name == "Keep This Cut" })
        #expect(try await temp.database.fetchGeneratedVideos(projectID: home.id).contains { $0.id == outputID })
        let raw = try SQLiteConnection(path: temp.path.path)
        let owner = try raw.query(
            "SELECT project_id FROM generated_videos WHERE id = ?",
            [.integer(outputID)]
        ).first?["project_id"]
        #expect(owner?.intValue == nil)

        let cascadeProjectID = try await temp.database.createProject(
            profileName: "Fixture",
            name: "Delete Timelines"
        )
        let deletedTimelineID = try await temp.database.createTimeline(
            projectID: cascadeProjectID,
            name: "Delete This Cut",
            documentJSON: documentJSON
        )
        try await temp.database.deleteProject(id: cascadeProjectID)
        let remainingTimelineCount = try raw.query(
            "SELECT COUNT(*) AS count FROM timelines WHERE id = ?",
            [.integer(deletedTimelineID)]
        ).first?["count"]?.intValue
        #expect(remainingTimelineCount == 0)
    }

    @Test("timelines and generated outputs remain inside their project")
    func projectTimelinesAndOutputs() async throws {
        let temp = try TempDatabase()
        _ = try await temp.seedVideo()
        try await temp.database.ensureDefaultProject(profileName: "Fixture",
                                                     legacyTimelineJSON: nil)
        let projects = try await temp.database.fetchProjects()
        let firstProjectID = try #require(projects.first?.id)
        let secondProjectID = try await temp.database.createProject(profileName: "Fixture", name: "Second")
        let documentJSON = String(data: try JSONEncoder().encode(TimelineDocument()), encoding: .utf8) ?? "{}"

        _ = try await temp.database.createTimeline(projectID: firstProjectID,
                                                   name: "Builder Cut",
                                                   documentJSON: documentJSON)
        _ = try await temp.database.insertGeneratedVideo(
            path: "/tmp/fixture.mp4", duration: 10, timelineJSON: documentJSON,
            wizardProvider: "fixture", wizardModel: "test", projectID: firstProjectID,
            batchID: "run-1"
        )

        let firstOutputs = try await temp.database.fetchGeneratedVideos(projectID: firstProjectID)
        let secondOutputs = try await temp.database.fetchGeneratedVideos(projectID: secondProjectID)
        #expect(firstOutputs.count == 1)
        #expect(secondOutputs.isEmpty)
        let timelines = try await temp.database.fetchTimelines(projectID: firstProjectID)
        #expect(timelines.count == 2)
        #expect(timelines.contains { $0.isWizard })
        let secondTimelines = try await temp.database.fetchTimelines(projectID: secondProjectID)
        #expect(secondTimelines.isEmpty)
    }

    @Test("project UI state restores detailed state and decodes older rows")
    func projectUIStateCompatibility() throws {
        let legacy = Data(#"{"section":"scenes","sceneFilter":"curated"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProjectUIState.self, from: legacy)
        #expect(decoded.section == "scenes")
        #expect(decoded.sceneFilter == "curated")
        #expect(decoded.sceneSelection.isEmpty)
        #expect(decoded.outputsSort == "newest")

        let clipID = UUID()
        let state = ProjectUIState(
            outputsScrollID: 51,
            sourceSelection: [11],
            sourceScrollID: 11,
            sceneSelection: [21],
            sceneScrollID: 21,
            sceneRunSelection: [31],
            sceneTagFilter: "person:alex",
            sceneSearchText: "knockdown",
            sceneShowHidden: true,
            sceneSortByScore: true,
            sceneMinimumScore: 7,
            sceneShowSequenceParts: true,
            timelineSelection: .clip(clipID),
            timelineFocusedTrack: 2,
            timelineScrollX: 140,
            timelineScrollY: 28
        )
        let roundTrip = try JSONDecoder().decode(
            ProjectUIState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(roundTrip == state)
    }
}

private final class DatabaseBundleToken {}
