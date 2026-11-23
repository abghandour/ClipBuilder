import AppKit
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder dub selection", .serialized)
struct BuilderDubLaneTests {
    @Test("Undo uses its own audio after the durable row is replaced; a missing file cannot restore the new text",
          .enabled(if: FFmpeg.isAvailable))
    func undoAudioSurvivesDurableTakeReplacement() async throws {
        let scope = try DataFolderOverride(); _ = scope
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        let payloadAudio = temp.directory.url.appendingPathComponent("voice.mp3")
        try await FFmpeg.run(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:a", "libmp3lame", payloadAudio.path])
        let payload = try JSONSerialization.data(withJSONObject: [
            "audio_base64": try Data(contentsOf: payloadAudio).base64EncodedString()
        ])
        let transport = ElevenLabsTransportStub([(200, payload), (200, payload)])
        let takes = DubTakeStore(settings: { ElevenLabsSettings() }, client: { transport.client() })
        let directory = temp.directory.url.appendingPathComponent("audio")
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        var first = DubLine(clipUID: clip.uid, speakerKey: "host", voice: "elevenlabs:fixture", text: "First",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1,
            takeSource: .init(videoID: videoID, transcriptionKey: "transcript", rowStart: 0,
                rowEnd: 1, language: "en", text: "First"))
        let firstTake = try await takes.audio(for: first, database: temp.database, directory: directory)
        let preparedFirst = try #require(firstTake)
        first = preparedFirst.line
        first.audio = preparedFirst.url.lastPathComponent
        let model = BuilderTimelineModel()
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        var document = Fixtures.timelineDocument(clips: [clip]); document.dubLines = [first]
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        var second = first
        second.text = "Second"; second.audio = nil
        let secondTake = try await takes.audio(for: second, database: temp.database, directory: directory)
        let preparedSecond = try #require(secondTake)
        second = preparedSecond.line; second.audio = preparedSecond.url.lastPathComponent
        model.setDub(settings: nil, lines: [second])
        let rows = try await temp.database.fetchDubTakes(videoID: videoID)
        #expect(rows.count == 1)
        #expect(rows.first?.text == "Second")
        #expect(first.takeID == second.takeID)
        undo.undo()
        let undone = try #require(model.document.dubLines?.first)
        #expect(undone.text == "First")
        let synthesizer = DubSynthesizer(directory: directory)
        let restored = try await synthesizer.restoringAudio(lines: [undone], database: temp.database, allowSynthesis: false)
        #expect(restored.first?.audio == first.audio)
        #expect((restored.first?.duration ?? 0) > 0)
        let requests = await transport.requests.count
        #expect(requests == 2)
        try FileManager.default.removeItem(at: preparedFirst.url)
        await #expect(throws: ScriptError.self) {
            _ = try await synthesizer.restoringAudio(lines: [undone], database: temp.database, allowSynthesis: false)
        }
        #expect(!FileManager.default.fileExists(atPath: preparedFirst.url.path))
        let finalRequests = await transport.requests.count
        #expect(finalRequests == 2)
    }

    @Test("Restored metadata persists through the real same-revision save queue and reload")
    func restoredTakeIsPersisted() async throws {
        let temp = try await TempDatabase()
        let profile = Fixtures.brand(name: "RestoredDubAudio")
        let settings = AppSettings()
        let store = AppStore(settings: settings, profiles: [profile], active: profile,
            ai: AIService(config: settings.ai), database: temp.database)
        let project = try await temp.database.createProject(profileName: profile.profileName, name: "Restore")
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        var line = DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "Reviewed",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: "missing.caf")
        var document = Fixtures.timelineDocument(clips: [clip]); document.dubLines = [line]
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let id = try await temp.database.createTimeline(projectID: project, name: "Timeline", documentJSON: json)
        store.builder.loadTimeline(id: id, document: document)
        store.saveTimeline(id: id, document: store.builder.document)
        try await store.drainTimelineSaves(database: temp.database, id: id)
        let revision = store.builder.revision
        #expect(store.builder.persistedRevision == revision)
        line.audio = "restored.caf"; line.duration = 1.25
        store.builder.restoreDubAudio([line], missingAudio: [])
        #expect(store.builder.revision == revision)
        store.builder.flushPendingAutosave()
        try await store.drainTimelineSaves(database: temp.database, id: id)
        let saved = try #require(try await temp.database.fetchTimeline(id: id))
        let reloaded = try JSONDecoder().decode(TimelineDocument.self, from: Data(saved.documentJSON.utf8))
        #expect(reloaded.dubLines?.first?.audio == "restored.caf")
        #expect(abs((reloaded.dubLines?.first?.duration ?? 0) - 1.25) < 1e-9)
        #expect(saved.documentRevision == revision)
        #expect(!store.builder.hasPendingDubAudioSave)
    }

    @Test("Restoration never pairs First's take with Second's text on redo")
    func restoredTakeSurvivesUndoAndRedo() throws {
        let scope = try DataFolderOverride(); _ = scope
        let model = BuilderTimelineModel()
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        var line = DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "First",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: "missing.caf", takeID: "first-take")
        var document = Fixtures.timelineDocument(clips: [clip]); document.dubLines = [line]
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        line.text = "Second"
        model.setDub(settings: nil, lines: [line])
        undo.undo() // Both stacks contain an old file name when restoration arrives.
        line = try #require(model.document.dubLines?.first)
        line.audio = "restored.caf"; line.duration = 1.25
        model.restoreDubAudio([line], missingAudio: [])
        undo.redo()
        #expect(model.document.dubLines?.first?.text == "Second")
        #expect(model.document.dubLines?.first?.audio == "missing.caf")
        #expect(abs((model.document.dubLines?.first?.duration ?? 0) - 1) < 1e-9)
        undo.undo()
        let restored = try #require(model.document.dubLines?.first)
        #expect(restored.text == "First" && restored.audio == "restored.caf")
        #expect(restored.takeID == "first-take")
        #expect(abs(restored.duration - 1.25) < 1e-9)
    }

    @Test("Snapshot hydration requires every take input, but permits placement edits",
          arguments: ["text", "voice", "speaker", "rate", "stretch", "take", "source", "placement"])
    func hydrationMatchesTakeInputs(edit: String) throws {
        let scope = try DataFolderOverride(); _ = scope
        let model = BuilderTimelineModel()
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        var original = DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "First",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: "missing.caf", takeID: "first")
        var document = Fixtures.timelineDocument(clips: [clip]); document.dubLines = [original]
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        var changed = original
        switch edit {
        case "text": changed.text = "Second"
        case "voice": changed.voice = "other"
        case "speaker": changed.speakerKey = "guest"
        case "rate": changed.rate = 1.1
        case "stretch": changed.stretch = 1.1
        case "take": changed.takeID = "second"
        case "source": changed.sourceEnd = 0.9
        default: changed.start = 2
        }
        model.setDub(settings: nil, lines: [changed])
        undo.undo()
        original.audio = "first-restored.caf"; original.duration = 1.25
        model.restoreDubAudio([original], missingAudio: [])
        undo.redo()
        let redone = try #require(model.document.dubLines?.first)
        let expectedAudio = edit == "placement" ? "first-restored.caf" : "missing.caf"
        #expect(redone.audio == expectedAudio)
        #expect(abs(redone.start - changed.start) < 1e-9)
        // A second restoration must not evict the first take's snapshot repair.
        changed.audio = "second-restored.caf"; changed.duration = 1.5
        model.restoreDubAudio([changed], missingAudio: [])
        undo.undo()
        let undone = try #require(model.document.dubLines?.first)
        let expectedUndo = edit == "placement" ? "second-restored.caf" : "first-restored.caf"
        #expect(undone.audio == expectedUndo)
    }

    @Test("Restored take hydrates lane and audition availability without an undo step or stopping Live")
    func restoredTakeAvailability() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        var line = DubLine(clipUID: clip.uid, speakerKey: "host", voice: "fixture", text: "Reviewed",
            sourceStart: 0, sourceEnd: 1, start: 0, duration: 1, audio: "old.caf")
        var document = Fixtures.timelineDocument(clips: [clip])
        document.dubLines = [line]
        model.loadTimeline(id: 54, document: document)
        var savedAudio: String?
        model.onTimelineAutosave = { _, snapshot in savedAudio = snapshot.dubLines?.first?.audio }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.missingDubAudio = ["old.caf"]
        let before = try #require(model.dubLineBlock(line.id))
        #expect(!before.prepared)
        let revision = model.revision
        line.audio = "restored.caf"
        model.restoreDubAudio([line], missingAudio: [])
        let after = try #require(model.dubLineBlock(line.id))
        #expect(after.prepared)
        #expect(after.line.audio == "restored.caf")
        #expect(model.document.dubLines == [line])
        #expect(!undo.canUndo)
        #expect(model.revision == revision)
        model.flushPendingAutosave()
        #expect(savedAudio == "restored.caf")
    }

    @Test func summaryResolvesSelectedDubLine() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 2)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        let line = DubLine(clipUID: hold.uid, speakerKey: "host", voice: "v", text: "Read only",
            sourceStart: 0, sourceEnd: 4, start: 0, duration: 4)
        document.dubLines = [line]
        let summary = try BuilderDocumentSummary(document: document, offset: 0, limit: 20, selection: .dubLine(line.id))
        let row = try #require(summary.rows.first { $0.id == line.id.uuidString })
        #expect(row.lane == "dubLine" && row.readOnly == true)
        #expect(row.speaker == "host" && row.text == "Read only")
        #expect(abs(row.start) < 1e-9 && abs(row.duration - 5) < 1e-9)
    }

    @Test func playbackOwnershipStopsPendingAudition() throws {
        let model = BuilderTimelineModel()
        var stoppedExact = 0
        model.claimPlayback(.line, stopExact: { stoppedExact += 1 })
        model.claimPlayback(.live, stopExact: { stoppedExact += 1 })
        model.claimPlayback(.exact, stopExact: { stoppedExact += 1 })
        #expect(stoppedExact == 2)
        #expect(model.dubAudition.player == nil && model.livePreview.player == nil)
        model.reportLivePlayhead(1.1)
        #expect(abs(model.playhead - 1.1) < 1e-9)
        model.playhead = 1.12
        #expect(abs(model.playhead - 1.12) < 1e-9)
    }

    @Test("Selection leaves playhead/document/undo alone; inspector uses the lane's derived values")
    func selection() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 2)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        let line = DubLine(clipUID: hold.uid, speakerKey: "host", voice: "Voice", text: "Read only",
            sourceStart: 0, sourceEnd: 4, start: 0, duration: 4, tight: true)
        document.dubLines = [line]
        let model = BuilderTimelineModel()
        model.loadTimeline(id: 54, document: document)
        model.onTimelineAutosave = { _, _ in }
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        model.playhead = 1.25
        let revision = model.revision
        model.selectDubLine(line.id)
        #expect(model.selection == .dubLine(line.id))
        #expect(model.playhead == 1.25 && model.revision == revision)
        #expect(!undo.canUndo)
        let block = try #require(model.dubLineBlock(line.id))
        #expect(block.duration == 5 && block.freezes.count == 1)
        #expect(block.line.voice == "Voice" && block.line.text == "Read only" && block.line.tight)
        model.setDub(settings: nil, lines: nil)
        #expect(model.dubLineBlock(line.id) == nil)
        undo.undo()
        #expect(model.dubLineBlock(line.id)?.line == line)
    }

    @Test("Dub toggling never changes the existing video or music preview blocks")
    func existingPlan() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("source.mp4")
        try Data().write(to: source)
        var clip = Fixtures.timelineClip(sceneID: nil, duration: 4)
        clip.videoFile = source.path
        let document = Fixtures.timelineDocument(clips: [clip])
        model.loadDocument(document)
        let before = model.previewPlan(musicLookup: [:])
        #expect(!before.segments.isEmpty)
        model.document.dub = DubSettings(language: "en")
        model.document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "v", text: "Speech",
            sourceStart: 0, sourceEnd: 2, start: 0, duration: 2, audio: "voice.caf")]
        model.liveDubEnabled = false
        let after = model.previewPlan(musicLookup: [:])
        #expect(before.segments.map(\.url) == after.segments.map(\.url))
        #expect(before.segments.map(\.timelineStart) == after.segments.map(\.timelineStart))
        #expect(before.segments.map(\.duration) == after.segments.map(\.duration))
        #expect(before.segments.map(\.volume) == after.segments.map(\.volume))
        #expect(before.music.map(\.url) == after.music.map(\.url))
        #expect(BuilderDubLayout.layout(document: document).isEmpty)
        #expect(!BuilderDubLayout.layout(document: model.document).isEmpty)
    }
}
