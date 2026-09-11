import Foundation
import Testing
@testable import Clip_Builder

/// All persistence goes to TempDatabase. No async scope owns DataFolderOverride,
/// no speech recognizer/provider is launched, and no user's Library is opened.
@MainActor
@Suite("Builder prerequisites")
struct BuilderPrerequisitesTests {
    @MainActor
    private final class Harness {
        let temp: TempDatabase
        var current = true
        var calls = 0
        var operation: @MainActor (BuilderPrerequisiteKind, VideoRecord, Database) async throws -> Void = { _, _, _ in }
        init() throws { temp = try TempDatabase() }
        var database: Database { temp.database }
        func video() async throws -> Int64 {
            try await database.registerVideo(hash: UUID().uuidString, filename: "test.mp4",
                path: temp.directory.url.appendingPathComponent("test.mp4").path,
                duration: 10, width: 100, height: 100, wide: false)
        }
        func adapters() -> BuilderPrerequisites {
            BuilderPrerequisites { [self] in
                BuilderPrerequisiteContext(database: database, profile: Fixtures.brand(), projectID: nil,
                    language: "en", isCurrent: { self.current }, perform: { kind, video in
                        self.calls += 1
                        try await self.operation(kind, video, self.database)
                    })
            }
        }
        func library() async throws -> ScriptLibrarySnapshot {
            try await ScriptLibrarySnapshot(projectID: nil).refreshed(database: database, language: "en")
        }
    }

    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var entered: Bool { !waiters.isEmpty }
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func release() { let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        throw ScriptError.invalid("Test did not reach its suspension point.")
    }

    private static func transcript(_ database: Database, video: Int64, language: String = "en",
                                   translation: Bool = false, text: String = "new") async throws {
        try await database.replaceTranscripts(videoID: video, language: language, isTranslation: translation,
            segments: [.init(start: 0, end: 1, text: text, words: nil)], provider: "fake", model: "fake")
    }

    @Test func unavailableAndFailureNeverPresentSheets() async throws {
        let unavailable = BuilderPrerequisites { nil }
        #expect(await unavailable.ensureTranscript(video: 1).outcome == .unavailable(reason: "The captured Library is no longer available."))
        let h = try Harness()
        let video = try await h.video()
        h.operation = { _, _, _ in throw TranscriptionError.noAudioTrack("test") }
        if case .unavailable = await h.adapters().ensureTranscript(video: video).outcome {} else { Issue.record("Expected unavailable") }
        h.operation = { _, _, _ in throw ScriptError.invalid("fake failure") }
        if case .failed = await h.adapters().ensurePeople(video: video).outcome {} else { Issue.record("Expected failed") }
        let profile = Fixtures.brand()
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()), database: h.database)
        #expect(store.currentError == nil)
        #expect(store.pendingRenameReview == nil)
        // Adapter context has no UI callbacks at all; the failure is value-only.
        #expect(h.calls == 2)
    }

    @Test(arguments: BuilderPrerequisiteKind.allCases)
    func completedEmptyPersistsAndReuses(kind: BuilderPrerequisiteKind) async throws {
        let h = try Harness()
        let video = try await h.video()
        let first = await h.adapters().ensure(kind, video: video)
        #expect(first.outcome == .completedEmpty)
        #expect(!first.effects.isEmpty)
        // A new adapter (not an in-memory success cache) still reuses empty.
        let second = await h.adapters().ensure(kind, video: video)
        #expect(second.outcome == .completedEmpty && second.effects.isEmpty)
        #expect(h.calls == 1)
        let reopened = try Database(path: h.temp.path)
        let row = try #require(try await reopened.video(id: video))
        #expect(try await reopened.prerequisiteResult(kind: kind, video: row,
            signature: "v1:\(row.hash):\(kind == .transcript ? "en" : "")", language: "en") == .completedEmpty)
    }

    @Test(arguments: BuilderPrerequisiteKind.allCases)
    func completedWithData(kind: BuilderPrerequisiteKind) async throws {
        let h = try Harness()
        let video = try await h.video()
        h.operation = { kind, video, db in
            switch kind {
            case .transcript: try await Self.transcript(db, video: video.id)
            case .people:
                try await db.upsertPerson(key: "alex", descriptor: "fake")
                let person = try #require(try await db.fetchPeople().first)
                try await db.replaceVideoPeople(videoID: video.id, entries: [(person.id, 1, nil, nil)],
                                                provenance: AIProvenance(provider: "fake"))
            case .analysis:
                _ = try await db.saveAnalysis(videoID: video.id, runName: "fake", instructions: "",
                    sampleInterval: 1, notesJSON: nil, tagRanges: ["test": [(0, 2)]], moments: [],
                    analyzedTags: ["test"], provider: "fake", model: "fake", mode: "visual")
            }
        }
        let first = await h.adapters().ensure(kind, video: video)
        if case .completedWithData(let version) = first.outcome { #expect(!version.isEmpty) }
        else { Issue.record("Expected data, got \(first.outcome)") }
        let second = await h.adapters().ensure(kind, video: video)
        #expect(second.outcome == first.outcome && second.effects.isEmpty && h.calls == 1)
    }

    @Test func runningDeduplicatesAndDrainsSharedCancellation() async throws {
        let h = try Harness()
        let video = try await h.video()
        let gate = Gate()
        defer { gate.release() }
        h.operation = { _, _, _ in await gate.wait(); try Task.checkCancellation() }
        let adapters = h.adapters()
        var admissions = 0
        let first = Task { await adapters.ensure(.people, video: video) { _ in admissions += 1 } }
        try await until { gate.entered }
        let second = Task { await adapters.ensure(.people, video: video) { _ in admissions += 1 } }
        try await until { admissions == 2 }
        if case .running(let jobID) = adapters.status(kind: .people, video: video) { #expect(!jobID.isEmpty) }
        else { Issue.record("Expected running job") }
        #expect(h.calls == 1)
        first.cancel()
        gate.release()
        let a = await first.value
        let b = await second.value
        #expect(!a.outcome.isComplete && !b.outcome.isComplete)
        #expect(adapters.status(kind: .people, video: video) == nil)
    }

    @Test func sharedSuccessfulJobIsAwaitedOnce() async throws {
        let h = try Harness()
        let video = try await h.video()
        let gate = Gate()
        defer { gate.release() }
        h.operation = { _, _, _ in await gate.wait() }
        let adapters = h.adapters()
        var admissions = 0
        let a = Task { await adapters.ensure(.people, video: video) { _ in admissions += 1 } }
        try await until { gate.entered }
        let b = Task { await adapters.ensure(.people, video: video) { _ in admissions += 1 } }
        try await until { admissions == 2 }
        gate.release()
        #expect(await a.value == b.value)
        #expect(h.calls == 1)
    }

    @Test func cancellationReachesSuspendedService() async throws {
        let h = try Harness()
        let video = try await h.video()
        var started = false
        var cancelled = false
        h.operation = { _, _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
        }
        let adapters = h.adapters()
        let job = Task { await adapters.ensureTranscript(video: video) }
        try await until { started }
        job.cancel()
        #expect(!(await job.value).outcome.isComplete)
        #expect(cancelled)
        #expect(try await h.database.fetchTranscripts(videoID: video).isEmpty)
    }

    @Test func profileSwitchCannotWriteNewProfile() async throws {
        let h = try Harness()
        let next = try Harness()
        let video = try await h.video()
        let nextVideo = try await next.video()
        let nextBefore = try await next.database.prerequisiteInventory(videoID: nextVideo)
        let gate = Gate()
        defer { gate.release() }
        h.operation = { _, video, db in
            await gate.wait()
            // Simulate a service that saved just as the switch happened.
            try await Self.transcript(db, video: video.id)
        }
        let adapters = h.adapters()
        let job = Task { await adapters.ensureTranscript(video: video) }
        try await until { gate.entered }
        h.current = false
        gate.release()
        let report = await job.value
        #expect(!report.outcome.isComplete && !report.effects.isEmpty)
        #expect(try await next.database.prerequisiteInventory(videoID: nextVideo).rows == nextBefore.rows)
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
    }

    @Test func transcriptReplacementScopeAndDecisions() async throws {
        let h = try Harness()
        let video = try await h.video()
        let other = try await h.video()
        try await Self.transcript(h.database, video: video, text: "old")
        try await Self.transcript(h.database, video: video, language: "pt", text: "Portuguese")
        try await Self.transcript(h.database, video: video, translation: true, text: "translation")
        try await Self.transcript(h.database, video: other, text: "other video")
        let proposal = EditProposal(id: 0, videoID: video, kind: .silence, startTime: 2, endTime: 3,
                                    reason: "old", decision: .rejected)
        let unrelated = EditProposal(id: 0, videoID: video, kind: .bRoll, startTime: 5, endTime: 6,
                                      reason: "keep", decision: .accepted)
        try await h.database.replaceTranscriptFeatures(videoID: video, features: [], proposals: [proposal, unrelated])
        // A partial earlier pass requires retry; it must not reuse its raw rows.
        let row = try #require(try await h.database.video(id: video))
        try await h.database.savePrerequisiteResult(kind: .transcript, videoID: video,
            signature: "v1:\(row.hash):en", outcome: .failed(reason: "enrichment failed"))
        let otherBefore = try await h.database.prerequisiteInventory(videoID: other)
        h.operation = { _, video, db in
            try await Self.transcript(db, video: video.id)
            var replacement = proposal
            replacement.decision = .pending
            replacement.reason = "regenerated"
            try await db.replaceTranscriptFeatures(videoID: video.id, features: [], proposals: [replacement])
        }
        let result = await h.adapters().ensureTranscript(video: video)
        #expect(result.outcome.isComplete)
        let rows = try await h.database.fetchTranscripts(videoID: video)
        #expect(rows.count == 3 && rows.contains { $0.text == "Portuguese" } && rows.contains { $0.text == "translation" })
        let proposals = try await h.database.fetchEditProposals(videoID: video)
        #expect(proposals.first { $0.kind == .silence }?.decision == .rejected)
        #expect(proposals.first { $0.kind == .bRoll }?.decision == .accepted)
        #expect(result.effects.contains { $0.scope == "Transcripts [en, translation=false]" })
        #expect(!result.effects.contains { $0.scope.contains("translation=true") || $0.scope.contains("[pt,") })
        #expect(try await h.database.prerequisiteInventory(videoID: other).rows == otherBefore.rows)
    }

    @Test func failedEnrichmentIsNotReusedAsSuccessfulTranscript() async throws {
        let h = try Harness()
        let video = try await h.video()
        h.operation = { _, video, db in
            try await Self.transcript(db, video: video.id)
            throw ScriptError.invalid("feature pass failed after transcript save")
        }
        let adapters = h.adapters()
        #expect(!(await adapters.ensureTranscript(video: video)).outcome.isComplete)
        #expect(!(await adapters.ensureTranscript(video: video)).outcome.isComplete)
        #expect(h.calls == 2)
    }

    @Test func peopleReplacesOnlyTargetRosterAndKeepsUserIdentity() async throws {
        let h = try Harness()
        let video = try await h.video()
        let other = try await h.video()
        try await h.database.upsertPerson(key: "alex", descriptor: "old")
        let person = try #require(try await h.database.fetchPeople().first)
        try await h.database.renamePerson(id: person.id, name: "User name")
        try await h.database.setPersonHidden(id: person.id, hidden: true)
        for id in [video, other] {
            try await h.database.replaceVideoPeople(videoID: id, entries: [(person.id, 2, nil, nil)],
                                                     provenance: AIProvenance(provider: "old"))
        }
        let row = try #require(try await h.database.video(id: video))
        try await h.database.savePrerequisiteResult(kind: .people, videoID: video,
            signature: "v1:\(row.hash):", outcome: .failed(reason: "partial"))
        h.operation = { _, video, db in
            try await db.upsertPerson(key: "alex", descriptor: "new descriptor")
            try await db.replaceVideoPeople(videoID: video.id, entries: [], provenance: AIProvenance(provider: "new"))
        }
        let report = await h.adapters().ensurePeople(video: video)
        #expect(report.outcome == .completedEmpty)
        #expect(try await h.database.fetchVideoPeople(videoID: video).isEmpty)
        #expect(try await h.database.fetchVideoPeople(videoID: other).count == 1)
        let saved = try #require(try await h.database.fetchPeople().first)
        #expect(saved.name == "User name" && saved.hidden && saved.descriptor == "new descriptor")
        #expect(report.effects.contains { $0.scope == "Shared identities" })
        #expect(try await h.database.video(id: video)?.peopleProvider == "new")
    }

    @Test func sessionHydrationIsExplicitAndBaselineStaysFixed() async throws {
        let h = try Harness()
        let video = try await h.video()
        let live = ScriptFixtures.model()
        let hydration = BuilderLibraryHydration()
        let session = BuilderScriptSession(live: live, library: try await h.library(), hydration: hydration)
        defer { session.discard() }
        let baseline = live.document
        let revision = live.revision
        var scene = Fixtures.scene(); scene.endTime = 8
        h.operation = { _, video, db in
            try await Self.transcript(db, video: video.id)
            hydration.refresh { live.updateScenes([scene]) }
        }
        let result = await session.run([.init(.ensureTranscript(video: video)), .init(.addText(text: "preview"))],
            prerequisites: h.adapters(), confirmed: true, refreshLibrary: { try await h.library() })
        #expect(result.completed)
        #expect(live.document == baseline && live.revision == revision)
        #expect(session.baseline == baseline && session.library.transcripts.count == 1)
        session.discard()
        #expect(live.revision > revision)
        #expect(!session.prerequisiteEffects.isEmpty)
    }

    @Test func externalRevisionStillInvalidatesPendingRun() async throws {
        let h = try Harness()
        let video = try await h.video()
        let live = ScriptFixtures.model()
        let session = BuilderScriptSession(live: live, library: try await h.library())
        h.operation = { _, _, _ in live.document.textOverlays.append(TextOverlayItem(text: "external")) }
        let result = await session.run([.init(.ensurePeople(video: video)), .init(.addText(text: "must not run"))],
            prerequisites: h.adapters(), confirmed: true, refreshLibrary: { try await h.library() })
        #expect(!result.completed && session.candidate == nil)
        #expect(live.document.textOverlays.map(\.text) == ["external"])
    }

    @Test func failedRunAndDiscardKeepLibraryChanges() async throws {
        let h = try Harness()
        let video = try await h.video()
        h.operation = { _, video, db in try await Self.transcript(db, video: video.id) }
        let session = BuilderScriptSession(live: ScriptFixtures.model(), library: try await h.library())
        let result = await session.run([.init(.ensureTranscript(video: video)), .init(.removeClip(clip: "invalid"))],
            prerequisites: h.adapters(), confirmed: true, refreshLibrary: { try await h.library() })
        #expect(!result.completed && session.candidate == nil && !session.prerequisiteEffects.isEmpty)
        session.discard()
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
        #expect(!session.prerequisiteEffects.isEmpty)
    }

    @Test func requiresConfirmationAndOrderedPrefix() async throws {
        let h = try Harness()
        let video = try await h.video()
        let library = try await h.library()
        let steps = [BuilderScriptStep(.ensurePeople(video: video)), .init(.addText(text: "preview"))]
        let unconfirmed = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        #expect(!(await unconfirmed.run(steps, prerequisites: h.adapters(), confirmed: false,
            refreshLibrary: { try await h.library() })).completed)
        let reordered = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        #expect(!(await reordered.run(Array(steps.reversed()), prerequisites: h.adapters(), confirmed: true,
            refreshLibrary: { try await h.library() })).completed)
        #expect(h.calls == 0)
        let synchronous = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        #expect(!synchronous.run(steps).completed)
        #expect(h.calls == 0)
        #expect(try ScriptRunner.decode(JSONEncoder().encode(steps)) == steps)
    }
    @Test func librarySurvivesApplyUndoAndPersistedRevert() async throws {
        let h = try Harness()
        let video = try await h.video()
        let profile = Fixtures.brand(name: "PrerequisiteUndo")
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()), database: h.database)
        let project = try await h.database.createProject(profileName: profile.profileName, name: "Test", videoIDs: [video])
        let document = Fixtures.timelineDocument(clips: [])
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let id = try await h.database.createTimeline(projectID: project, name: "Timeline", documentJSON: json)
        store.activeProjectID = project
        store.builder.load(profileName: profile.profileName)
        store.openTimelineRecord(try #require(try await h.database.fetchTimeline(id: id)))
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.builder.undoManager = undo
        h.operation = { _, video, db in try await Self.transcript(db, video: video.id) }
        var library = try await h.library()
        library.projectID = project
        let snapshot = library
        let session = BuilderScriptSession(live: store.builder, library: snapshot, hydration: store.builderLibraryHydration)
        let before = store.builder.document
        let result = await session.run([.init(.ensureTranscript(video: video)), .init(.addText(text: "apply"))],
            prerequisites: h.adapters(), confirmed: true, refreshLibrary: {
                try await snapshot.refreshed(database: h.database, language: "en")
            })
        #expect(result.completed)
        session.freeze()
        _ = try await store.applyWizardRun(session: session, request: "Test", provenance: AIProvenance(provider: "fake")).get()
        session.discard()
        #expect(undo.canUndo)
        undo.undo()
        #expect(store.builder.document == before)
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
        undo.redo()
        _ = try await store.revertLastWizardRun(timelineID: id, expectedRunUUID: session.runUUID).get()
        #expect(store.builder.document == before)
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
        #expect(try await h.database.fetchWizardBefore(timelineID: id) == nil)
    }

    @Test func wizardConfirmationAndFailureExplainSavedLibraryWork() async throws {
        let h = try Harness()
        let video = try await h.video()
        let profile = Fixtures.brand()
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()), database: h.database)
        let library = try await h.library()
        let suite = "PrerequisiteWizard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
                                    loadLibrary: { library }, prerequisites: h.adapters())
        h.operation = { _, video, db in try await Self.transcript(db, video: video.id) }
        let steps = [BuilderScriptStep(.ensureTranscript(video: video)), .init(.removeClip(clip: "missing"))]
        model.request = "original confirmed program"
        await model.run(program: .script(steps))
        #expect(model.phase == .awaitingPrerequisites && h.calls == 0)
        #expect(model.prerequisiteDisclosures.count == 1 && !model.canApply)
        model.request = "edited request must not change the program"
        await model.confirmPrerequisites()
        #expect(h.calls == 1 && model.phase == .refused && !model.canApply)
        #expect(model.runRequest == "original confirmed program")
        #expect(!model.persistentEffects.isEmpty)
        #expect(model.log.contains { $0.contains("Running") })
        #expect(model.log.contains { $0.contains("No timeline changes applied") })
        #expect(model.log.contains { $0.contains("Library work already saved") })
        #expect(store.currentError == nil && store.pendingRenameReview == nil)
        await model.discard()
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
        #expect(!model.persistentEffects.isEmpty)
    }

    @Test func ordinaryAppStoreRefreshDefersLiveHydration() async throws {
        let h = try Harness()
        let video = try await h.video()
        let profile = Fixtures.brand()
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()), database: h.database)
        let session = BuilderScriptSession(live: store.builder, library: try await h.library(),
                                          hydration: store.builderLibraryHydration)
        let baseline = store.builder.document
        let revision = store.builder.revision
        _ = try await h.database.saveAnalysis(videoID: video, runName: "fake", instructions: "",
            sampleInterval: 1, notesJSON: nil, tagRanges: ["test": [(0, 2)]], moments: [],
            analyzedTags: ["test"], provider: "fake", model: "fake", mode: "visual")
        let refreshed = try await h.database.fetchLibrarySnapshot()
        store.applyLibrarySnapshot(refreshed, generation: store.profileGeneration)
        #expect(store.scenes.count == 1)
        #expect(store.builder.document == baseline && store.builder.revision == revision)
        #expect(store.builder.scenes.isEmpty)
        session.discard()
        #expect(store.builder.scenes.count == 1)
    }

    @Test func discardCancelsAndDrainsWithoutLateRevival() async throws {
        let h = try Harness()
        let video = try await h.video()
        let gate = Gate()
        defer { gate.release() }
        let live = ScriptFixtures.model()
        let hydration = BuilderLibraryHydration()
        let session = BuilderScriptSession(live: live, library: try await h.library(), hydration: hydration)
        var hydrated = false
        h.operation = { _, video, db in
            await gate.wait()
            // Simulate a service crossing its final write just before stopping.
            try await Self.transcript(db, video: video.id)
        }
        let job = Task {
            await session.run([.init(.ensureTranscript(video: video)), .init(.addText(text: "late"))],
                prerequisites: h.adapters(), confirmed: true, refreshLibrary: { try await h.library() })
        }
        try await until { gate.entered }
        hydration.refresh { hydrated = true }
        #expect(!session.run([.init(.addText(text: "overtake"))]).completed)
        session.discard()
        #expect(!hydrated, "Keep hydration deferred until the active service drains")
        gate.release()
        #expect(!(await job.value).completed)
        #expect(hydrated && session.state == .discarded && session.candidate == nil)
        #expect(!session.prerequisiteEffects.isEmpty)
        #expect(try await h.database.fetchTranscripts(videoID: video).count == 1)
    }

    @Test func missingProjectVideoIsUnavailableWithoutServiceCalls() async throws {
        let h = try Harness()
        _ = try await h.video()
        let report = await h.adapters().ensureAnalysis(video: 999)
        if case .unavailable = report.outcome {} else { Issue.record("Expected unavailable") }
        #expect(h.calls == 0 && report.effects.isEmpty)
    }

    @Test func legacySuccessfulEmptyPeopleAndExistingTranscriptAreReused() async throws {
        let h = try Harness()
        let video = try await h.video()
        try await h.database.replaceVideoPeople(videoID: video, entries: [], provenance: AIProvenance(provider: "legacy"))
        try await Self.transcript(h.database, video: video)
        let adapters = h.adapters()
        #expect(await adapters.ensurePeople(video: video).outcome == .completedEmpty)
        #expect(await adapters.ensureTranscript(video: video).outcome.isComplete)
        #expect(h.calls == 0)
    }

    @Test func wizardCancellationShowsSavedEffectsWithoutTimelineApply() async throws {
        let h = try Harness()
        let video = try await h.video()
        let profile = Fixtures.brand()
        let store = AppStore(settings: AppSettings(), profiles: [profile], active: profile,
                             ai: AIService(config: AIConfig()), database: h.database)
        let library = try await h.library()
        let suite = "PrerequisiteCancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        defer { gate.release() }
        let model = WizardSheetModel(store: store, history: BuilderWizardHistory(defaults: defaults),
                                    loadLibrary: { library }, prerequisites: h.adapters())
        h.operation = { _, video, db in await gate.wait(); try await Self.transcript(db, video: video.id) }
        model.request = "Cancel test"
        await model.run(program: .script([.init(.ensureTranscript(video: video)), .init(.addText(text: "never"))]))
        model.beginConfirmedPrerequisites()
        try await until { gate.entered }
        model.cancelRun()
        gate.release()
        try await until { model.phase != .running }
        #expect(model.phase == .refused && !model.canApply)
        #expect(!model.persistentEffects.isEmpty)
        #expect(model.log.contains { $0.contains("No timeline changes applied") && $0.contains("Library work already saved") })
        #expect(store.currentError == nil && store.builder.document.textOverlays.isEmpty)
        await model.discard()
    }

    @Test func allEnsureJSONOperationsRoundTripAndRejectForce() throws {
        let steps = [BuilderScriptStep(.ensureTranscript(video: 1)), .init(.ensurePeople(video: 2)), .init(.ensureAnalysis(video: 3))]
        let json = try JSONEncoder().encode(steps)
        #expect(try ScriptRunner.decode(json) == steps)
        let text = String(decoding: json, as: UTF8.self)
        for op in ["ensure_transcript", "ensure_people", "ensure_analysis"] { #expect(text.contains(op)) }
        #expect(throws: (any Error).self) {
            try ScriptRunner.decode(Data(#"[{"command":{"op":"ensure_transcript","video":1,"force":true}}]"#.utf8))
        }
    }

}
