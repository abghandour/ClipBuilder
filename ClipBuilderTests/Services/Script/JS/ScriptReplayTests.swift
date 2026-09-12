import Foundation
import Testing
@testable import Clip_Builder

@MainActor @Suite("Verified script replay", .serialized)
struct ScriptReplayTests {
    @Test func localParserRoundTripAndAfterApply() async throws {
        let live = ScriptFixtures.gapModel(persistent: true)
        let library = ScriptFixtures.gapLibrary()
        live.selection = .clip(live.document.videoTrack[0].uid)
        let baseline = live.document
        let context = ParserContext(library: library, model: live)
        guard case .script(let steps) = BuilderRequestParser().parse("remove the selected clip", context: context) else {
            Issue.record("Expected local script"); return
        }
        let session = BuilderScriptSession(live: live, library: library, ownsHydration: false)
        let result = session.run(steps)
        #expect(result.completed)
        session.freeze()
        let retained = session.replay
        let export = await ScriptReplayExporter.verify(retained, name: "Local parser")
        let source = try #require(export.source, Comment(rawValue: export.reason ?? "No export"))
        #expect(source.contains("params.clip"))
        let undo = UndoManager(); undo.groupsByEvent = false; live.undoManager = undo
        let candidate = try #require(session.frozenCandidate)
        _ = try live.applyScriptSnapshot(candidate: candidate, baseline: baseline,
            baselineRevision: session.baselineRevision, actionName: "Replay").get()
        session.discard()
        let afterApply = await ScriptReplayExporter.verify(retained, name: "Local parser")
        #expect(afterApply.source == source)
        #expect(live.document != baseline)
    }

    @Test func agentListsBindCreatedIDsAndExcludeRollback() async throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let first = session.run([.init(.addText(at: 0, text: "Created"))], recoverRefusals: true)
        let id = try #require(first.outcomes.first?.createdIDs["overlay"])
        let refused = session.run([.init(.setText(overlay: id, text: "ROLLBACK")),
                                  .init(.removeClip(clip: UUID().uuidString))], recoverRefusals: true)
        #expect(!refused.completed)
        let next = session.run([.init(.setText(overlay: id, text: "Kept"))], recoverRefusals: true)
        #expect(next.completed)
        session.freeze()
        #expect(session.replay.entries.count == 2)
        let result = await ScriptReplayExporter.verify(session.replay, name: "Agent lists")
        let source = try #require(result.source, Comment(rawValue: result.reason ?? "No export"))
        #expect(source.contains("replay1.overlay"))
        #expect(!source.contains(id))
        #expect(!source.contains("ROLLBACK"))
    }

    @Test func existingBindingsAreRewrittenAcrossRebinding() async throws {
        let session = ScriptFixtures.session()
        defer { session.discard() }
        let a = session.run([.init(.addText(at: 0, text: "A"), bind: "replay1")], recoverRefusals: true)
        let id = try #require(a.outcomes.first?.createdIDs["overlay"])
        #expect(session.run([.init(.addText(at: 2, text: "B"), bind: "replay1"),
                             .init(.setText(overlay: "$replay1", text: "B changed"))], recoverRefusals: true).completed)
        #expect(session.run([.init(.setText(overlay: id, text: "A changed"))], recoverRefusals: true).completed)
        session.freeze()
        let result = await ScriptReplayExporter.verify(session.replay, name: "Rebinding")
        #expect(result.source != nil, Comment(rawValue: result.reason ?? ""))
    }

    @Test func unsupportedBaselineKindsGiveReason() async throws {
        let live = ScriptFixtures.gapModel()
        let commands: [BuilderCommand] = [
            .removeSound(sound: live.document.soundTrack[0].uid.uuidString),
            .removeOverlay(overlay: live.document.textOverlays[0].uid.uuidString),
            .removeCropBlock(block: live.document.cropBlocks[0].uid.uuidString)
        ]
        for command in commands {
            let session = BuilderScriptSession(live: live, library: ScriptFixtures.gapLibrary(), ownsHydration: false)
            #expect(session.run([.init(command)]).completed)
            session.freeze()
            let result = await ScriptReplayExporter.verify(session.replay, name: "Unsupported")
            #expect(result.source == nil)
            #expect(result.reason?.contains("Unsupported baseline reference kind") == true)
            session.discard()
        }
    }

    @Test func prerequisiteReplayUsesRecordedSnapshotAndReport() async throws {
        let live = ScriptFixtures.model()
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library(), ownsHydration: false)
        defer { session.discard() }
        var refreshed = ScriptFixtures.library()
        refreshed.prerequisiteOutcomes[1] = [.transcript: .completedEmpty]
        let entry = ScriptReplayTranscript.Entry(steps: [.init(.ensureTranscript(video: 1))],
            result: .init(outcomes: [.unchanged(reason: "Recorded stub")], completed: true, hasDocumentChanges: false),
            libraryAfterPrerequisite: refreshed, report: .init(outcome: .completedEmpty))
        #expect(session.replayPrerequisite(entry).completed)
        #expect(session.run([.init(.addText(at: 0, text: "After ensure"))]).completed)
        session.freeze()
        let result = await ScriptReplayExporter.verify(session.replay, name: "Prerequisite replay")
        let source = try #require(result.source, Comment(rawValue: result.reason ?? "No export"))
        #expect(source.contains("ensure_transcript"))
        let header = try ScriptHeader.parse(source)
        #expect(header.requires.count == 1)
    }

    @Test func countAndByteOverflowDisableExport() async throws {
        let live = ScriptFixtures.model()
        let capture = ScriptCapture(model: live, library: ScriptFixtures.library())
        let entry = ScriptReplayTranscript.Entry(steps: [.init(.setPlayhead(at: 0))],
            result: .init(outcomes: [.unchanged(reason: "No change")], completed: true, hasDocumentChanges: false))
        var transcript = ScriptReplayTranscript(capture: capture)
        for _ in 0..<129 { transcript.append(entry) }
        #expect(transcript.disabledReason?.contains("128 entries") == true)
        #expect(transcript.entries.isEmpty)
        let result = await ScriptReplayExporter.verify(transcript, name: "Overflow")
        #expect(result.source == nil)
        var bytes = ScriptReplayTranscript(capture: capture)
        var huge = entry
        huge.result.outcomes = [.unchanged(reason: String(repeating: "x", count: 4 * 1024 * 1024))]
        bytes.append(huge)
        #expect(bytes.disabledReason?.contains("4 MiB") == true)
    }
}
