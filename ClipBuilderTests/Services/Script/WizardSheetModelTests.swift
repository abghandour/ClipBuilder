import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Wizard sheet model")
struct WizardSheetModelTests {
    private func makeStore(_ temp: TempDatabase) async throws -> AppStore {
        let profile = Fixtures.brand(name: "WizardSheetModelTests")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
                             ai: AIService(config: settings.ai), database: temp.database)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Project")
        let json = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument(clips: [Fixtures.timelineClip()])), as: UTF8.self)
        let id = try await temp.database.createTimeline(projectID: project, name: "Timeline", documentJSON: json)
        store.activeProjectID = project
        store.builder.load(profileName: profile.profileName)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: id)))
        store.builder.updateScenes([Fixtures.scene()])
        return store
    }

    private func sheet(_ store: AppStore, defaults: UserDefaults) -> WizardSheetModel {
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        library.tags = ["fixture"]
        library.people = [PersonRecord(id: 1, key: "alex", name: "Alex", descriptor: "")]
        library.scenes[0].tags += ["person:alex"]
        let snapshot = library
        return WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults), loadLibrary: { snapshot })
    }

    // Like BuilderPrerequisitesTests.Harness, capture only the temporary DB
    // and inject service work. No DataFolderOverride survives an await.
    @Test(arguments: [false, true])
    func deferredSilenceSavesEffectsBeforePreviewOrFailure(failAfterSaving: Bool) async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let project = try #require(store.activeProjectID)
        let video = try await temp.database.registerVideo(hash: UUID().uuidString, filename: "fixture.mp4",
            path: "/tmp/fixture.mp4", duration: 10, width: 100, height: 100, wide: false)
        try await temp.database.assignVideos([video], to: project)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Fixtures.brand(name: "WizardSheetModelTests")
        var calls = 0
        let prerequisites = BuilderPrerequisites {
            BuilderPrerequisiteContext(database: temp.database, profile: profile, projectID: project,
                language: "en", isCurrent: { true }, perform: { kind, row in
                    #expect(kind == .transcript && row.id == video)
                    calls += 1
                    try await temp.database.replaceTranscripts(videoID: row.id, language: "en", isTranslation: false,
                        segments: [.init(start: 2, end: 6, text: "fixture", words: nil)], provider: "fake", model: "fake")
                    if failAfterSaving { throw ScriptError.invalid("fake failure after transcript save") }
                    try await temp.database.replaceTranscriptFeatures(videoID: row.id,
                        features: [.init(id: 0, videoID: row.id, startTime: 3, endTime: 4,
                                         text: "", speakerKey: nil, energy: 0, kind: .silence)], proposals: [])
                })
        }
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { try await ScriptLibrarySnapshot(projectID: project).refreshed(database: temp.database, language: "en") },
            prerequisites: prerequisites)
        let before = store.builder.document
        #expect(model.phase == .idle)
        model.request = "cut silence on track 1"
        await model.run()
        #expect(model.phase == .awaitingPrerequisites && !model.canApply)
        #expect(!model.prerequisiteDisclosures.isEmpty && model.persistentEffects.isEmpty && calls == 0)
        #expect(store.builder.document == before)
        let session = try #require(model.session)
        model.request = "mute this clip" // Confirmation retains the original request.
        await model.confirmPrerequisites()
        #expect(model.session === session && calls == 1)
        #expect(store.builder.document == before)
        #expect(model.persistentEffects.contains { $0.videoID == video && $0.scope.hasPrefix("Transcripts [") && $0.afterCount == 1 })
        #expect(try await temp.database.fetchTranscripts(videoID: video).count == 1)
        if failAfterSaving {
            #expect(model.phase == .refused && !model.canApply)
            #expect(model.reasons.contains { $0.contains("fake failure after transcript save") })
        } else {
            #expect(model.phase == .preview && model.canApply && model.diff?.isEmpty == false)
            #expect(session.candidate?.videoTrack.count == 2)
            #expect(session.candidate?.videoTrack.map(\.sourceStart) == [2, 4])
            #expect(!session.library.transcripts.isEmpty && !session.library.features.isEmpty)
        }
        let effects = model.persistentEffects
        await model.discard()
        #expect(model.phase == .discarded && model.persistentEffects == effects)
        #expect(try await temp.database.fetchTranscripts(videoID: video).count == 1)
    }

    @Test func deferredSilenceWithoutNewEvidenceRefusesOnce() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let project = try #require(store.activeProjectID)
        let video = try await temp.database.registerVideo(hash: UUID().uuidString, filename: "fixture.mp4",
            path: "/tmp/fixture.mp4", duration: 10, width: 100, height: 100, wide: false)
        try await temp.database.assignVideos([video], to: project)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Fixtures.brand(name: "WizardSheetModelTests")
        var calls = 0
        let prerequisites = BuilderPrerequisites {
            BuilderPrerequisiteContext(database: temp.database, profile: profile, projectID: project,
                language: "en", isCurrent: { true }, perform: { _, _ in calls += 1 })
        }
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { try await ScriptLibrarySnapshot(projectID: project).refreshed(database: temp.database, language: "en") },
            prerequisites: prerequisites)
        let before = store.builder.document
        model.request = "cut silence on track 1"
        await model.run()
        #expect(model.phase == .awaitingPrerequisites)
        await model.confirmPrerequisites()
        #expect(model.phase == .refused && !model.canApply && calls == 1)
        #expect(model.reasons.contains { $0.contains("still unavailable") })
        #expect(!model.persistentEffects.isEmpty && store.builder.document == before)
        await model.confirmPrerequisites()
        #expect(calls == 1 && model.phase == .refused)
        await model.discard()
    }

    @Test func rawJSONRequiresDebugBuild() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        let before = store.builder.document
        let clip = try #require(before.videoTrack.first)
        model.request = String(decoding: try JSONEncoder().encode([
            BuilderScriptStep(.setClipMuted(clip: clip.uid.uuidString, muted: true))
        ]), as: UTF8.self)
        await model.run()
        #if DEBUG
        #expect(model.phase == .preview && model.canApply)
        #else
        #expect(model.phase == .unrecognised && model.session == nil && !model.canApply)
        #endif
        #expect(store.builder.document == before)
        await model.discard()
    }

    @Test func runDiffApplyAndRevert() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = UndoManager(); undo.groupsByEvent = false
        store.builder.undoManager = undo
        let id = try #require(store.builder.timelineID)
        let clip = try #require(store.builder.document.videoTrack.first)
        store.builder.selection = .clip(clip.uid)
        let before = store.builder.document
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        #expect(model.phase == .preview && model.canApply)
        #expect(model.diff?.isEmpty == false)
        #expect(store.builder.document == before)
        #expect(model.log.contains { $0.contains("Applied") && $0.contains("ms") })
        model.request = "changed field after Run"
        await model.apply()
        #expect(model.phase == .applied && model.session == nil)
        #expect(store.builder.document.videoTrack.first?.muted == true)
        let run = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(run.request == "mute this clip" && run.provider == "local" && run.status == .applied)
        #expect(model.beforeVersion?.request == "mute this clip")
        #expect(undo.canUndo)
        await model.revert()
        #expect(store.builder.document == before && model.beforeVersion == nil)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: id).first?.status == .reverted)
    }

    @Test func discardRecordsOnceAndDoesNotEdit() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try #require(store.builder.timelineID)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let before = store.builder.document
        let model = sheet(store, defaults: defaults)
        model.request = "trim this clip to 2 s"
        await model.run()
        #expect(model.canApply)
        await model.discard()
        await model.discard()
        #expect(model.phase == .discarded && model.session == nil)
        #expect(store.builder.document == before)
        let runs = try await temp.database.fetchBuilderRuns(timelineID: id)
        #expect(runs.count == 1 && runs.first?.status == .discarded)
        #expect(try await temp.database.fetchWizardBefore(timelineID: id) == nil)
    }

    @Test func unrecognisedAndRefused() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        model.request = "remove clips tagged fixture except the last one"
        await model.run()
        #expect(model.phase == .unrecognised && !model.reasons.isEmpty && !model.canApply)
        #expect(model.session == nil)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        model.request = "split this clip at 99s"
        await model.run()
        #expect(model.phase == .refused && !model.canApply)
        #expect(model.reasons.contains { $0.contains("out_of_bounds") })
        await model.discard()
    }

    @Test func staleApply() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = UndoManager(); undo.groupsByEvent = false; store.builder.undoManager = undo
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        store.builder.addText(at: 0)
        let manual = store.builder.document
        await model.apply()
        #expect(model.failure == .staleRevision && !model.canApply)
        #expect(store.builder.document == manual)
        // Adding text selects the new item; "this clip" needs the clip again.
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        await model.run()
        #expect(model.canApply && model.failure == nil)
        await model.discard()
    }

    @Test func findThenPreviewAddition() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        let before = store.builder.document
        model.request = "find scenes of Alex fixture"
        await model.run()
        #expect(model.phase == .found && model.results.map(\.id) == [1])
        #expect(model.session == nil && !model.canApply && model.diff == nil)
        store.builder.playhead = 1
        #expect(model.pickerRequest()?.time == 1)
        #expect(store.builder.document == before)
        model.addAllAsBRoll()
        #expect(model.phase == .preview && model.canApply)
        #expect(model.session?.candidate?.videoTrack.contains { $0.isCutaway } == true)
        #expect(store.builder.document == before)
        await model.discard()
    }
    @Test func pickerAdditionUsesOneAtomicApplyAndRunRecord() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let undo = UndoManager(); undo.groupsByEvent = false
        store.builder.undoManager = undo
        let before = store.builder.document
        let find = sheet(store, defaults: defaults)
        find.request = "find scenes of Alex fixture"
        await find.run()
        let payload = try #require(find.pickerRequest())
        find.dismiss() // The captured find survives replacement of the inline model.
        let preview = sheet(store, defaults: defaults)
        preview.previewFoundAddition(payload, sceneID: 1, at: 1, track: 0,
                                     duration: 2, sourceStart: 3, coverAll: true)
        #expect(preview.phase == .preview && preview.canApply)
        let session = try #require(preview.session)
        let cutaway = try #require(session.candidate?.videoTrack.first { $0.isCutaway })
        #expect(cutaway.sourceStart == 3 && cutaway.duration == 2 && cutaway.startTime == 1)
        #expect(cutaway.track == 0 && cutaway.coverAllAreas)
        #expect(store.builder.document == before && !undo.canUndo)
        let timelineID = try #require(store.builder.timelineID)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: timelineID).isEmpty)
        await preview.apply()
        #expect(preview.phase == .applied && store.builder.document != before)
        let runs = try await temp.database.fetchBuilderRuns(timelineID: timelineID)
        #expect(runs.count == 1)
        #expect(runs.first?.runUUID == session.runUUID && runs.first?.status == .applied)
        #expect(runs.first?.request == "Add found scene as B-roll: find scenes of Alex fixture")
        #expect(runs.first?.provider == "local")
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.builder.document == before && !undo.canUndo && undo.canRedo)
        // One undo restores the complete snapshot; another registration would
        // leave canUndo true. Repeated Apply cannot create a second run.
        await preview.apply()
        #expect(try await temp.database.fetchBuilderRuns(timelineID: timelineID).count == 1)
    }

    @Test(arguments: ["revision", "timeline", "profile", "scene"])
    func pickerRejectsStaleOrForeignFind(change: String) async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let find = sheet(store, defaults: defaults)
        find.request = "find fixture"
        await find.run()
        let payload = try #require(find.pickerRequest())
        switch change {
        case "revision":
            _ = store.builder.addText(at: 0)
        case "timeline":
            let task = try #require(store.createTimeline(named: "Other", document: store.builder.document))
            await task.value
        case "profile": store.builder.load(profileName: "OtherProfile")
        default: break
        }
        let before = store.builder.document
        let preview = sheet(store, defaults: defaults)
        preview.previewFoundAddition(payload, sceneID: change == "scene" ? 999 : 1,
                                     at: 0, track: 0, duration: 2, sourceStart: 2, coverAll: false)
        #expect(preview.phase == .refused && !preview.canApply && preview.session == nil)
        #expect(store.builder.document == before)
        if change == "revision" { #expect(preview.failure == .staleRevision) }
        if change == "timeline" || change == "profile" { #expect(preview.failure == .identityChanged) }
    }

    @Test func planningResultTargetsCreatedTimelineAndPrefillsExamples() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let originalID = store.builder.timelineID
        var document = store.builder.document
        document.videoTrack.append(Fixtures.timelineClip(startTime: 4))
        let task = try #require(store.createTimeline(named: "Wizard Draft", document: document,
                                                     isWizardPlan: true, fixWithWizard: true))
        await task.value
        let result = try #require(store.builderPlanResult)
        #expect(result.openRequested && result.timelineID != originalID)
        #expect(result.timelineID == store.builder.timelineID && result.matches(store: store))
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        library.people = [PersonRecord(id: 1, key: "sam", name: "Sam Rivera", descriptor: "")]
        library.tags = ["training"]
        let snapshot = library
        let model = try #require(result.makeWizard(store: store, loadLibrary: { snapshot }))
        await model.refreshExamples()
        #expect(model.timelineID == result.timelineID && model.identityMatches)
        // One runnable request, built from the real roster; placeholders never reach the field.
        #expect(model.request == BuilderRequestParser.supportedRequests(library: snapshot).first)
        #expect(model.request == "remove clips with Sam Rivera" && model.examples.contains { $0.contains("training") })
        #expect(model.phase == .idle && model.session == nil && !model.canApply)
        model.request = "remove the selected clip"
        await model.refreshExamples()
        #expect(model.request == "remove the selected clip")
        let originalTimelineID = try #require(originalID)
        let original = try #require(try await temp.database.fetchTimeline(id: originalTimelineID))
        store.openTimelineRecord(original)
        #expect(!result.matches(store: store) && result.makeWizard(store: store) == nil)
        #expect(!model.identityMatches)
    }

    @Test func emptyLibraryPlanExamplesStayGenericAndDoNotRun() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let result = BuilderPlanResult(store: store)
        let model = try #require(result.makeWizard(store: store, loadLibrary: { ScriptLibrarySnapshot() }))
        await model.refreshExamples()
        // Placeholders stay in the example list; the field gets a request that can run as-is.
        #expect(model.examples.contains { $0.contains("<person>") && $0.contains("<tag>") })
        #expect(model.request == "cut silence longer than 1 s on track 1" && !model.request.contains("<"))
        #expect(model.phase == .idle && model.session == nil)
    }

    @Test func scenesTabKeepsRunningWizardAndPreviewSession() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardBrowserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<ScriptLibrarySnapshot, Never>?
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults), loadLibrary: {
            await withCheckedContinuation { continuation = $0 }
        })
        store.builderWizard = model
        let clip = try #require(store.builder.document.videoTrack.first)
        store.builder.selection = .clip(clip.uid)
        model.request = "mute this clip"
        let running = Task { await model.run() }
        while continuation == nil { await Task.yield() }
        // Switching tabs removes the Wizard content, but does not dismiss its model.
        var tabModel: WizardSheetModel? = model
        tabModel = nil
        #expect(tabModel == nil)
        #expect(store.builderWizard === model)
        #expect(model.phase == .running && model.busy)
        #expect(model.statusText == "Running — building your preview…")
        #expect(model.latestLogLine == "Collecting the current Library snapshot…")
        continuation?.resume(returning: library)
        await running.value
        #expect(model.phase == .preview && model.canApply)
        let session = try #require(model.session)
        tabModel = store.builderWizard
        #expect(tabModel === model)
        #expect(tabModel?.session === session)
        #expect(tabModel?.phase == .preview)
        await model.discard()
        model.dismiss()
        #expect(store.builderWizard == nil)
    }

    @Test func dismissedModelClearsOnlyItsOwnStoreReference() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardBrowserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = sheet(store, defaults: defaults)
        store.builderWizard = first
        first.dismiss()
        #expect(store.builderWizard == nil)
        let replacement = sheet(store, defaults: defaults)
        store.builderWizard = replacement
        first.dismiss()
        #expect(store.builderWizard === replacement)
        replacement.dismiss()
        #expect(store.builderWizard == nil)
    }

    @Test func statusStripInputsFollowRunAndLogClearing() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardBrowserTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        store.builderWizard = model
        #expect(!model.hasStatus && model.latestLogLine == nil && !model.busy)
        #expect(model.statusText == "Describe the edit you want to preview.")
        model.request = "find scenes of Alex fixture"
        await model.run()
        #expect(model.hasStatus && !model.busy)
        #expect(model.statusText == "Found 1 matching scenes")
        let latest = try #require(model.latestLogLine)
        #expect(latest == model.log.last)
        #expect(latest.hasPrefix("Run finished in "))
        model.clearLog()
        #expect(model.latestLogLine == nil && model.log.isEmpty)
        #expect(model.hasStatus && model.phase == .found)
        #expect(store.builderWizard === model)
        model.dismiss()
        #expect(store.builderWizard == nil)
    }

    @Test func dismissalDuringSnapshotCannotReviveRun() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<ScriptLibrarySnapshot, Never>?
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults), loadLibrary: {
            await withCheckedContinuation { continuation = $0 }
        })
        model.request = "find fixture"
        let running = Task { await model.run() }
        while continuation == nil { await Task.yield() }
        model.dismiss()
        continuation?.resume(returning: library)
        await running.value
        #expect(model.session == nil && model.results.isEmpty && !model.canApply)
    }

    @Test func discardAfterTimelineSwitchKeepsOriginalAuditOwner() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardSheetModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalID = try #require(store.builder.timelineID)
        store.builder.selection = .clip(try #require(store.builder.document.videoTrack.first).uid)
        let model = sheet(store, defaults: defaults)
        model.request = "mute this clip"
        await model.run()
        let json = String(decoding: try JSONEncoder().encode(Fixtures.timelineDocument(clips: [Fixtures.timelineClip()])), as: UTF8.self)
        let otherID = try await temp.database.createTimeline(projectID: try #require(store.activeProjectID),
                                                             name: "Other", documentJSON: json)
        store.openTimelineRecord(try #require(try await temp.database.fetchTimeline(id: otherID)))
        await model.discard()
        #expect(try await temp.database.fetchBuilderRuns(timelineID: originalID).first?.status == .discarded)
        #expect(try await temp.database.fetchBuilderRuns(timelineID: otherID).isEmpty)
    }

    @Test func revertRefusesDifferentRunThanConfirmation() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let id = try #require(store.builder.timelineID)
        let before = store.builder.document
        let row = WizardBeforeRecord(timelineID: id, runUUID: "new-run", request: "A newer request",
                                     documentJSON: "{}", appliedRevision: 1)
        try await temp.database.saveWizardBefore(row)
        #expect(await store.revertLastWizardRun(timelineID: id, expectedRunUUID: "confirmed-old-run") == .failure(.staleRevision))
        #expect(store.builder.document == before)
    }

}

extension WizardSheetModelTests {
    @Test(arguments: ["apply", "discard", "refuse"])
    func agentRoutingFreezesAndPersistsEventsThroughTerminalAction(action: String) async throws {
        let apply = action == "apply"
        let refuseScript = action == "refuse"
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.settings.ai.tasks["builder_agent"] = "claude"
        store.settings.ai.taskModels["builder_agent"] = "fixture-model"
        store.settings.ai.providers["claude"] = AIProviderSettings(bin: "/usr/bin/false", model: nil)
        let suite = "WizardAgentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        let snapshot = library
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, launch, _, consume in
                let data = try Data(contentsOf: launch.root.appendingPathComponent("mcp.json"))
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let servers = config?["mcpServers"] as? [String: Any]
                let server = servers?["clipbuilder"] as? [String: Any]
                let headers = server?["headers"] as? [String: String]
                let urlString = try #require(server?["url"] as? String)
                let url = try #require(URL(string: urlString))
                let authorization = try #require(headers?["Authorization"])
                var bodies = [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-cli","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"query","arguments":{"query":{"kind":"scenes","filter":{"people":["aljo"]}}}}}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"query":{"kind":"clips"}}}}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"fixture"}}]}}}"#
                ]
                if refuseScript {
                    bodies[bodies.count - 1] = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"remove_clip","clip":"invented"}}]}}}"#
                }
                try consume(Data((#"{"type":"system","tools":["mcp__clipbuilder__query","mcp__clipbuilder__run_script"]}"# + "\n").utf8))
                for body in bodies {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
                    let (responseData, response) = try await URLSession.shared.data(for: request)
                    let httpResponse = try #require(response as? HTTPURLResponse)
                    #expect([200, 202].contains(httpResponse.statusCode),
                            "\(httpResponse.statusCode) for \(body.prefix(80)): \(String(decoding: responseData, as: UTF8.self))")
                }
                try consume(Data((#"{"type":"result","subtype":"success","result":"Added **fixture** text with `add_text`."}"# + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        #expect(model.provider == .claude)
        let before = store.builder.document
        model.request = "add some fixture text using the agent"
        await model.run()
        if refuseScript {
            // A refused list is rolled back and the run continues; with no
            // edits left there is nothing to apply, and the refusal stays auditable.
            #expect(model.phase == .preview && !model.canApply)
            let event = try #require(model.agentEvents.first { $0.toolName == "run_script" })
            let reason = try #require(event.message)
            #expect(event.outcome == .refused && !reason.isEmpty)
            #expect(model.copyText(kind: .toolOutcomes).contains(reason))
            #expect(store.builder.document == before)
            await model.discard()
            return
        }
        #expect(model.phase == .preview && model.canApply)
        #expect(store.builder.document == before)
        #expect(model.agentEvents.map(\.sequence) == [1, 2, 3, 4])
        #expect(model.agentEvents.compactMap(\.toolName) == ["query", "query", "run_script"])
        let id = try #require(store.builder.timelineID)
        let saved = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(saved.provider == "claude" && saved.model == "fixture-model" && saved.durationSeconds != nil)
        #expect(saved.status == .completed && saved.eventsJSON.contains("run_script"))
        // A corrected read-only refusal remains auditable without blocking Apply.
        #expect(model.agentEvents.map(\.outcome) == [.refused, .completed, .completed, .completed])
        #expect(model.reasons.isEmpty)
        let events = model.agentEvents
        let diff = model.diff
        let lines = model.diffLines
        let log = model.log
        #expect(!log.isEmpty)
        #expect(model.copyText(kind: .log) == log.joined(separator: "\n"))
        let outcomes = model.copyText(kind: .toolOutcomes)
        #expect(outcomes.contains("query · refused") && outcomes.contains("run_script · completed"))
        #expect(outcomes.contains("filter is only valid for kind clips"))
        #expect(outcomes.contains(" B in / ") && outcomes.contains(" B out · ") && outcomes.contains(" ms"))
        model.request = "a different, unrun request"
        let everything = model.copyText(kind: .everything)
        #expect(everything.contains("Request\nadd some fixture text using the agent"))
        #expect(!everything.contains(model.request))
        #expect(everything.contains("Status\nReady to apply — "))
        #expect(everything.contains("Timeline changes\n" + lines.joined(separator: "\n")))
        #expect(everything.contains("Tool outcomes\n" + outcomes))
        #expect(everything.contains("Agent explanation\nAdded fixture text with add_text."))
        #expect(everything.contains("Run log\n" + log.joined(separator: "\n")))
        model.clearLog()
        #expect(model.log.isEmpty && model.copyText(kind: .log).isEmpty)
        #expect(model.agentEvents == events && model.diff == diff && model.diffLines == lines)
        #expect(model.canApply && model.copyText(kind: .toolOutcomes) == outcomes)
        let afterClear = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(afterClear == saved)
        let undo = UndoManager(); undo.groupsByEvent = false
        store.builder.undoManager = undo
        if apply { await model.apply() } else { await model.discard() }
        let finished = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(finished.status == (apply ? .applied : .discarded) && finished.eventsJSON == saved.eventsJSON)
        #expect(finished.provider == "claude")
        if apply {
            #expect(model.phase == .applied && store.builder.document != before && undo.canUndo)
            undo.undo()
            #expect(store.builder.document == before)
        } else { #expect(store.builder.document == before) }
    }
}

extension WizardSheetModelTests {
    @Test func localAssistedFindExplainsUnresolvedWithoutAgent() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardFindTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        let snapshot = library
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, _, _, _ in
                Issue.record("Local assisted find must not launch an agent")
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        model.provider = .local
        model.request = "find scenes with anjo"
        let before = store.builder.document
        await model.run()
        #expect(model.phase == .refused)
        #expect(model.statusText == "Could not resolve: 'anjo'; choose Claude to let the assistant search")
        #expect(model.session == nil && model.agentEvents.isEmpty && model.results.isEmpty)
        #expect(store.builder.document == before)
    }

    @Test(arguments: [false, true])
    func assistedFindRequiresStructuredReport(report: Bool) async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.settings.ai.providers["claude"] = AIProviderSettings(bin: "/usr/bin/false", model: nil)
        let suite = "WizardFindTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        library.scenes = (1...12).map { id in
            var scene = Fixtures.scene(); scene.id = Int64(id); return scene
        }
        let snapshot = library
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, launch, _, consume in
                #expect(launch.arguments.contains(BuilderAgentPrompt.findRules))
                let data = try Data(contentsOf: launch.root.appendingPathComponent("mcp.json"))
                let decoded = try JSONSerialization.jsonObject(with: data)
                let config = try #require(decoded as? [String: Any])
                let servers = try #require(config["mcpServers"] as? [String: Any])
                let server = try #require(servers["clipbuilder"] as? [String: Any])
                let headers = try #require(server["headers"] as? [String: String])
                let urlString = try #require(server["url"] as? String)
                let url = try #require(URL(string: urlString))
                let authorization = try #require(headers["Authorization"])
                // Claude discloses its confined inventory before any tool call; find mode has no run_script.
                try consume(Data((#"{"type":"system","tools":["mcp__clipbuilder__query","mcp__clipbuilder__get_document_summary","mcp__clipbuilder__report_scenes"]}"# + "\n").utf8))
                var bodies: [[String: Any]] = [
                    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                        "protocolVersion": "2025-06-18", "capabilities": [:],
                        "clientInfo": ["name": "fake-find", "version": "1"]]],
                    ["jsonrpc": "2.0", "method": "notifications/initialized"],
                    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                        "name": "query", "arguments": ["query": ["kind": "scenes"]]]]
                ]
                if report {
                    let scenes: [[String: Any]] = (3...12).reversed().map { ["id": $0, "reason": "Reason for scene \($0)"] }
                    bodies.append(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                        "name": "report_scenes", "arguments": ["scenes": scenes, "summary": "Ten matching scenes"]]])
                }
                for body in bodies {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let http = try #require(response as? HTTPURLResponse)
                    #expect([200, 202].contains(http.statusCode))
                    #expect(!String(decoding: data, as: UTF8.self).contains("\"isError\":true"))
                }
                try consume(Data((#"{"type":"result","subtype":"success","result":"Prose must never become the search answer"}"# + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        model.provider = .claude
        let before = store.builder.document
        model.request = "find scenes with anjo"
        await model.run()
        #expect(store.builder.document == before && !model.canApply && model.diff == nil)
        let timelineID = try #require(store.builder.timelineID)
        let runs = try await temp.database.fetchBuilderRuns(timelineID: timelineID)
        let run = try #require(runs.first)
        #expect(try await temp.database.fetchWizardBefore(timelineID: timelineID) == nil)
        if report {
            #expect(model.phase == .found && model.results.count == 10)
            #expect(model.results.map(\.id) == Array(stride(from: Int64(12), through: 3, by: -1)))
            #expect(model.results.map { model.resultReasons[$0.id] } == (3...12).reversed().map { "Reason for scene \($0)" })
            #expect(model.agentSummary == "Ten matching scenes")
            #expect(run.status == .completed && run.summary == "Ten matching scenes")
            #expect(model.session == nil)
            let picker = try #require(model.pickerRequest(sceneID: 12))
            #expect(picker.scenes.map(\.id) == [12])
            store.builder.playhead = 1
            model.addAsBRoll(sceneID: 12)
            #expect(model.phase == .preview && model.canApply)
            let candidate = try #require(model.session?.candidate)
            let additions = candidate.videoTrack.filter { $0.isCutaway }
            #expect(additions.count == 1 && additions.first?.sceneID == 12 && additions.first?.startTime == 1)
            #expect(store.builder.document == before)
            await model.discard()
            let afterDiscard = try await temp.database.fetchBuilderRuns(timelineID: timelineID)
            #expect(afterDiscard.contains { $0.runUUID == run.runUUID && $0.status == .completed })
        } else {
            #expect(model.phase == .refused && model.results.isEmpty)
            #expect(model.statusText.contains("did not call report_scenes"))
            #expect(run.status == .failed && model.agentSummary.isEmpty)
        }
    }

    @Test func recognizedFindStaysLocalWithClaudeSelectedAndCapsResults() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardFindTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        library.scenes = (1...12).map { id in
            var scene = Fixtures.scene(); scene.id = Int64(id)
            scene.narrative = "comeback"; scene.score = Double(id); return scene
        }
        let snapshot = library
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, _, _, _ in
                Issue.record("Recognized find must stay local")
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        model.provider = .claude; model.request = "search scenes for comeback"
        await model.run()
        #expect(model.phase == .found && model.results.count == 10)
        #expect(model.results.map(\.id) == Array(stride(from: Int64(12), through: 3, by: -1)))
        #expect(model.agentEvents.isEmpty && model.session == nil)
    }
}

extension WizardSheetModelTests {
    @Test func logDropsBlankLines() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardLog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        model.appendLog("")
        model.appendLog(" \t\n")
        model.appendLog("first\n\n \nsecond\n")
        #expect(model.log == ["first", "second"])
    }
}

extension WizardSheetModelTests {
    @Test func modelChoiceFollowsProviderAndPersists() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardModel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        store.settings.ai.tasks["builder_agent"] = "claude"
        store.settings.ai.taskModels["builder_agent"] = "claude-sonnet-4-6"
        let model = sheet(store, defaults: defaults)
        #expect(model.provider == .claude && model.agentModel == "claude-sonnet-4-6")
        #expect(WizardSheetModel.availableModels(for: .claude).contains("claude-haiku-4-5-20251001"))
        #expect(WizardSheetModel.availableModels(for: .local).isEmpty)

        model.agentModel = "claude-haiku-4-5-20251001"
        model.saveModelPreference()
        #expect(store.settings.ai.taskModels["builder_agent"] == "claude-haiku-4-5-20251001")

        // A model outside the provider's catalog is dropped back to the default.
        model.agentModel = "gemini-2.5-pro"
        model.saveModelPreference()
        #expect(model.agentModel == nil && store.settings.ai.taskModels["builder_agent"] == nil)
        #expect(WizardSheetModel.validModel("claude-sonnet-4-6", for: .gemini) == nil)
        #expect(WizardSheetModel.validModel("gemini-2.5-pro", for: .gemini) == "gemini-2.5-pro")
        #expect(WizardSheetModel.validModel("anything", for: .local) == "anything")
    }
}

extension WizardSheetModelTests {
    @Test(arguments: [false, true])
    func authorRetriesThenHandsOffOrRefuses(failAll: Bool) async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.settings.ai.providers["claude"] = AIProviderSettings(bin: "/usr/bin/false", model: nil)
        let suite = "WizardAuthorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library(); library.projectID = store.activeProjectID
        let snapshot = library
        let clip = try #require(store.builder.document.videoTrack.first)
        let samples = try JSONEncoder().encode(["clip": clip.uid.uuidString])
        let parameters = #"[{"name":"clip","type":"clip"}]"#
        let valid = ScriptHeaderTests.source("builder.ops.set_clip_muted({clip:params.clip,muted:true}); return {summary:'Mute preview'};", params: parameters)
        let sources = [ScriptHeaderTests.source("const broken = ;", params: parameters),
                       "/** clipbuilder-script\n{}\n*/\nreturn {};", failAll ? "invalid header again" : valid]
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, launch, _, consume in
                #expect(launch.arguments.contains(BuilderAgentPrompt.authorRules))
                let configData = try Data(contentsOf: launch.root.appendingPathComponent("mcp.json"))
                let decoded = try JSONSerialization.jsonObject(with: configData)
                let config = try #require(decoded as? [String: Any])
                let servers = try #require(config["mcpServers"] as? [String: Any])
                let server = try #require(servers["clipbuilder"] as? [String: Any])
                let headers = try #require(server["headers"] as? [String: String])
                let urlString = try #require(server["url"] as? String)
                let url = try #require(URL(string: urlString))
                let authorization = try #require(headers["Authorization"])
                try consume(Data((#"{"type":"system","tools":["mcp__clipbuilder__query","mcp__clipbuilder__get_document_summary","mcp__clipbuilder__script_reference","mcp__clipbuilder__submit_script"]}"# + "\n").utf8))
                let sampleObject = try JSONSerialization.jsonObject(with: samples)
                var bodies: [[String: Any]] = [
                    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                        "protocolVersion": "2025-06-18", "capabilities": [:],
                        "clientInfo": ["name": "fake-author", "version": "1"]]],
                    ["jsonrpc": "2.0", "method": "notifications/initialized"],
                    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                        "name": "query", "arguments": ["query": ["kind": "clips"]]]],
                    ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
                        "name": "script_reference", "arguments": [:]]]
                ]
                for (index, source) in sources.enumerated() {
                    bodies.append(["jsonrpc": "2.0", "id": index + 4, "method": "tools/call", "params": [
                        "name": "submit_script", "arguments": ["source": source, "sampleParams": sampleObject]]])
                }
                for (index, body) in bodies.enumerated() {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
                    let responseData: Data
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        let http = try #require(response as? HTTPURLResponse)
                        #expect([200, 202].contains(http.statusCode))
                        responseData = data
                    } catch {
                        // The third refusal cancels the child after accounting for
                        // its diagnostics; cancellation may beat its HTTP response.
                        if failAll, index == 6 { break }
                        throw error
                    }
                    guard index >= 4 else { continue }
                    let object = try JSONSerialization.jsonObject(with: responseData)
                    let rpc = try #require(object as? [String: Any])
                    let result = try #require(rpc["result"] as? [String: Any])
                    let content = try #require(result["content"] as? [[String: Any]])
                    let text = try #require(content.first?["text"] as? String)
                    let submission = try JSONDecoder().decode(ScriptSubmissionResult.self, from: Data(text.utf8))
                    if index < 6 || failAll {
                        #expect(result["isError"] as? Bool == true)
                        #expect(submission.status == "diagnostics")
                        let diagnostic = try #require(submission.diagnostics.first)
                        #expect(diagnostic.line != nil && diagnostic.column != nil)
                        #expect(diagnostic.code == (index == 4 ? "syntax_error" : "invalid_script"))
                    } else {
                        #expect(result["isError"] as? Bool != true)
                        #expect(submission.status == "accepted" && submission.diagnostics.isEmpty)
                    }
                }
                if !failAll {
                    try consume(Data((#"{"type":"result","subtype":"success","result":"Review the submitted script"}"# + "\n").utf8))
                }
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        model.provider = .claude; model.request = "Write a parameterized mute script"
        let before = store.builder.document
        await model.run(mode: .author)
        #expect(store.builder.document == before && !model.canApply && model.diff == nil)
        #expect(model.session == nil && model.persistentEffects.isEmpty)
        #expect(model.agentEvents.filter { $0.toolName == "submit_script" }.count == 3)
        let timelineID = try #require(store.builder.timelineID)
        let records = try await temp.database.fetchBuilderRuns(timelineID: timelineID)
        let wizardBefore = try await temp.database.fetchWizardBefore(timelineID: timelineID)
        #expect(records.isEmpty && wizardBefore == nil)
        var hydrated = false
        store.builderLibraryHydration.refresh { hydrated = true }
        #expect(hydrated)
        if failAll {
            #expect(model.phase == .refused && model.authoredScript == nil && !model.showingAuthoredScript)
            #expect(model.agentEvents.last?.outcome == .failed)
            #expect(model.statusText.contains("header"))
        } else {
            #expect(model.phase == .completed && model.showingAuthoredScript)
            let submission = try #require(model.authoredScript)
            #expect(submission.source == valid)
            let decodedParams = try JSONDecoder().decode([String: String].self, from: submission.sampleParams)
            #expect(decodedParams == ["clip": clip.uid.uuidString])
            #expect(model.scriptLibrary.source == valid && model.scriptLibrary.values["clip"] == clip.uid.uuidString)
            #expect(model.scriptLibrary.origin == .ai && model.scriptLibrary.editingID == nil)
            let scriptsBeforeSave = try await temp.database.fetchBuilderScripts()
            #expect(scriptsBeforeSave.isEmpty)
            let saved = try await model.scriptLibrary.save()
            #expect(saved.origin == .ai && saved.source == valid)
            #expect(store.builder.document == before)
        }
        model.dismiss()
    }

    @Test func localAuthoringExplainsProviderRequirement() async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        let suite = "WizardAuthorLocal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = sheet(store, defaults: defaults)
        model.provider = .local; model.request = "Write a mute script"
        await model.run(mode: .author)
        #expect(model.phase == .refused && model.statusText.contains("AI provider"))
        #expect(model.session == nil && model.agentEvents.isEmpty && !model.canApply)
        model.dismiss()
    }
}

private actor WizardReplyTestCounter {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
    func value() -> Int { count }
}

extension WizardSheetModelTests {
    @Test(arguments: ["continue", "stale", "discard"])
    func inlineRepliesKeepContextAndPreview(action: String) async throws {
        let temp = try TempDatabase()
        let store = try await makeStore(temp)
        store.settings.ai.tasks["builder_agent"] = "claude"
        store.settings.ai.providers["claude"] = AIProviderSettings(bin: "/usr/bin/false", model: nil)
        let suite = "WizardReplyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ScriptFixtures.library()
        library.projectID = store.activeProjectID
        let snapshot = library
        let counter = WizardReplyTestCounter()
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
            loadLibrary: { snapshot }, agentExecutor: { _, launch, _, consume in
                let turn = await counter.next()
                let prompt = launch.arguments.joined(separator: " ")
                #expect(prompt.contains("Make a caption"))
                if turn > 0 { #expect(prompt.contains("Use white") && prompt.contains("Which color?")) }
                if turn > 1 { #expect(prompt.contains("At the top") && prompt.contains("Where?")) }
                let data = try Data(contentsOf: launch.root.appendingPathComponent("mcp.json"))
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let servers = config?["mcpServers"] as? [String: Any]
                let server = servers?["clipbuilder"] as? [String: Any]
                let headers = server?["headers"] as? [String: String]
                let urlString = try #require(server?["url"] as? String)
                let url = try #require(URL(string: urlString))
                let authorization = try #require(headers?["Authorization"])
                var bodies = [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-cli","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
                ]
                if turn == 0 {
                    bodies += [
                        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"First turn"}}]}}}"#,
                        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Which color?"}}}"#
                    ]
                } else if turn == 1 {
                    bodies.append(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Where?"}}}"#)
                } else {
                    bodies.append(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"Final turn"}}]}}}"#)
                }
                try consume(Data((#"{"type":"system","tools":["mcp__clipbuilder__query","mcp__clipbuilder__run_script","mcp__clipbuilder__ask_user"]}"# + "\n").utf8))
                for body in bodies {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(BuilderMCPServer.wireVersion, forHTTPHeaderField: "MCP-Protocol-Version")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let httpResponse = try #require(response as? HTTPURLResponse)
                    #expect([200, 202].contains(httpResponse.statusCode))
                    #expect(!String(decoding: data, as: UTF8.self).contains("\"isError\":true"))
                }
                try consume(Data((#"{"type":"result","subtype":"success","result":"Review the caption preview."}"# + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        model.request = "Make a caption"
        let baseline = store.builder.document
        await model.run()
        #expect(model.phase == .awaitingReply && model.statusText == "Needs your answer")
        #expect(!model.canApply && store.builder.document == baseline)
        let session = try #require(model.session)
        #expect(session.state == .ready && session.workingDocument.textOverlays.count == baseline.textOverlays.count + 1)
        model.reply = "   "
        #expect(!model.canContinueReply)
        model.reply = "Use white"
        if action == "discard" {
            await model.discard()
            #expect(model.clarificationQuestion == nil && model.conversation.turns.isEmpty && model.session == nil)
        } else if action == "stale" {
            _ = store.builder.addText()
            #expect(!model.canContinueReply && model.replyValidationMessage != nil)
            await model.continueReply()
            #expect(await counter.value() == 1)
            #expect(model.reply == "Use white")
            await model.discard()
        } else {
            #expect(model.canContinueReply)
            await model.continueReply()
            #expect(model.session === session && model.phase == .awaitingReply)
            #expect(model.conversation.turns.count == 1 && model.reply.isEmpty)
            model.reply = "At the top"
            await model.continueReply()
            #expect(model.session === session && model.phase == .preview && model.canApply)
            #expect(model.conversation.turns.count == 2)
            #expect(session.candidate?.textOverlays.count == baseline.textOverlays.count + 2)
            #expect(store.builder.document == baseline)
            let undo = UndoManager(); undo.groupsByEvent = false; store.builder.undoManager = undo
            #expect(Set(model.agentEvents.map(\.id)).count == model.agentEvents.count)
            await model.apply()
            #expect(model.phase == .applied)
            #expect(store.builder.document.textOverlays.count == baseline.textOverlays.count + 2)
        }
    }

    @Test func conversationRejectsEmptyOversizedAndExcessReplies() throws {
        var conversation = BuilderConversation()
        #expect(throws: (any Error).self) { try conversation.append(question: "Q", answer: " \n") }
        #expect(throws: (any Error).self) { try conversation.append(question: "Q", answer: String(repeating: "x", count: 4097)) }
        for index in 0..<BuilderConversation.maximumTurns {
            try conversation.append(question: "Q\(index)", answer: "A\(index)")
        }
        #expect(throws: (any Error).self) { try conversation.append(question: "Q", answer: "A") }
        #expect(conversation.turns.count == BuilderConversation.maximumTurns)
        #expect(conversation.prompt(request: "Original").contains("Original"))
    }
}
