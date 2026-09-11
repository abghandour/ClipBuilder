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
        #expect(model.session?.candidate?.videoTrack.contains(where: \.isCutaway) == true)
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
        find.dismiss() // The captured result survives the first sheet's lifetime.
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
    @Test(arguments: [false, true])
    func agentRoutingFreezesAndPersistsEventsThroughTerminalAction(apply: Bool) async throws {
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
                let bodies = [
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-cli","version":"1"}}}"#,
                    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"query":{"kind":"clips"}}}}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_script","arguments":{"steps":[{"command":{"op":"add_text","text":"fixture"}}]}}}"#
                ]
                try consume(Data((#"{"type":"system","tools":["mcp__clipbuilder__query","mcp__clipbuilder__run_script"]}"# + "\n").utf8))
                for body in bodies {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
                    let (_, response) = try await URLSession.shared.data(for: request)
                    #expect([200, 202].contains(try #require(response as? HTTPURLResponse).statusCode))
                }
                try consume(Data((#"{"type":"result","subtype":"success","result":"Added the fixture text."}"# + "\n").utf8))
                return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
            })
        #expect(model.provider == .claude)
        let before = store.builder.document
        model.request = "add some fixture text using the agent"
        await model.run()
        #expect(model.phase == .preview && model.canApply)
        #expect(store.builder.document == before)
        #expect(model.agentEvents.map(\.sequence) == [1, 2, 3])
        #expect(model.agentEvents.compactMap(\.toolName) == ["query", "run_script"])
        let id = try #require(store.builder.timelineID)
        let saved = try #require(try await temp.database.fetchBuilderRuns(timelineID: id).first)
        #expect(saved.provider == "claude" && saved.model == "fixture-model" && saved.durationSeconds != nil)
        #expect(saved.status == .completed && saved.eventsJSON.contains("run_script"))
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
