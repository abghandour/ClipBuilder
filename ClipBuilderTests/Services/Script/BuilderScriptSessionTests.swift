import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Builder script sessions", .serialized)
struct BuilderScriptSessionTests {
    @Test("Transient lifetime never writes, calls UI/autosave hooks, or registers undo")
    func zeroWrites() throws {
        let scope = try DataFolderOverride()
        let model = ScriptFixtures.model()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        var callbacks = 0
        model.onTimelineAutosave = { _, _ in callbacks += 1 }
        model.onUIStateChange = { callbacks += 1 }
        model.loadTimeline(id: 5, document: Fixtures.timelineDocument())
        model.addText()
        model.playhead = 2; model.focusedTrack = 0
        model.flushPendingAutosave()
        model.loadDocument(Fixtures.timelineDocument())
        model.clear()
        model.closeTimeline()
        model.load(profileName: "Scratch")
        model.addText()
        // Flush synchronously: the process-global override must never span an await.
        model.flushPendingAutosave()
        #expect(callbacks == 0 && !undo.canUndo)
        let files = try FileManager.default.contentsOfDirectory(at: scope.directory.url, includingPropertiesForKeys: nil)
        #expect(files.isEmpty, "No data folder or autosave file should appear")
    }

    @Test("Session clones by value including omitted JSON identities and leaves live state untouched")
    func cloneAndLiveIsolation() throws {
        let scope = try DataFolderOverride()
        let live = BuilderTimelineModel()
        live.document = Fixtures.timelineDocument()
        live.document.textOverlays = [TextOverlayItem(text: "Before")]
        let source = try #require(live.document.videoTrack.first)
        live.selection = .clip(source.uid); live.playhead = 1.123; live.focusedTrack = 0
        live.updateDriveBackedPaths(["/tmp/fixture.mp4"])
        let before = live.document
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library())
        #expect(TimelineDiff(before: before, after: session.baseline).isEmpty)
        #expect(session.baseline.videoTrack.first?.uid == source.uid)
        #expect(session.run([.init(.removeClip(clip: source.uid.uuidString)), .init(.addText(text: "Preview"))]).completed)
        // No await while the data-folder override is held: suites run in
        // parallel and the override is process-global. A flush is enough —
        // nothing on the live model was scheduled, and a transient run
        // must not schedule anything either.
        live.flushPendingAutosave()
        #expect(TimelineDiff(before: before, after: live.document).isEmpty)
        #expect(live.selection == .clip(source.uid) && live.playhead == 1.123 && live.focusedTrack == 0)
        #expect(!session.diff().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scope.directory.url.path).isEmpty)
        session.discard()
        #expect(session.candidate == nil && session.diff().isEmpty && session.state == .discarded)
        #expect(!session.run([]).completed)
    }

    @Test("Discarding a session does not cancel a live model's pending autosave")
    func livePendingSave() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let live = BuilderTimelineModel()
        live.loadTimeline(id: 7, document: Fixtures.timelineDocument())
        var saved: TimelineDocument?
        live.onTimelineAutosave = { _, document in saved = document }
        live.addText()
        let expected = live.document
        let session = BuilderScriptSession(live: live, library: ScriptFixtures.library())
        session.run([.init(.addText(text: "Only transient"))])
        session.discard()
        live.flushPendingAutosave()
        #expect(saved == expected)
    }

    @Test("The fixed baseline, scenes and layouts do not follow later live changes")
    func snapshots() throws {
        let live = ScriptFixtures.model()
        var library = ScriptFixtures.library()
        let session = BuilderScriptSession(live: live, library: library)
        library.scenes[0].endTime = 9
        library.layouts = []
        live.document.videoTrack.removeAll()
        let result = session.run([.init(.addScene(scene: 1, track: 0)),
                                  .init(.addCropBlock(layout: "50-50 Horizontal", at: 0, duration: 5))])
        #expect(result.completed)
        #expect(session.candidate?.videoTrack.count == 2)
        #expect(session.candidate?.videoTrack.last?.duration == 4)
        #expect(session.candidate?.trackCount == 2)
        #expect(session.baseline.videoTrack.count == 1)
    }

    @Test("Diff detects every top-level field and omitted source/hydration fields")
    func completeDiff() throws {
        let before = Fixtures.timelineDocument()
        var after = before
        after.videoTrack[0].sourceEnd = 9
        after.videoTrack[0].sceneFullDuration = 9
        after.videoTrack[0].fadeIn = 0.2
        after.videoTrack[0].captions = "bottom"
        after.videoTrack[0].areaWindow = FreeCropRect()
        after.soundTrack = [SoundItem(name: "Music")]
        after.textOverlays = [TextOverlayItem(text: "Text")]
        after.imageOverlays = [ImageOverlayItem(path: "image")]
        after.overlayBlocks = [OverlayBlockItem()]
        after.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 8)]
        after.trackCount = 2
        after.trackSequential[0] = false
        after.trackSettings[0].label = "Changed"
        after.renderSettings.preset = .landscape1080
        after.renderSettings.customWidth = 720
        after.renderSettings.quality = .archival
        after.pacing.cadence = .twoSeconds
        let diff = TimelineDiff(before: before, after: after)
        let fields = ["sourceEnd", "sceneFullDuration", "fadeIn", "captions", "areaWindow", "soundTrack",
                      "textOverlays", "imageOverlays", "overlayBlocks", "cropBlocks", "trackCount",
                      "trackSequential", "trackSettings", "renderSettings", "pacing"]
        let missing = fields.filter { field in !diff.changes.contains { $0.path.contains(field) } }
        #expect(missing.isEmpty, "Missing fields: \(missing.joined(separator: ", ")); paths: \(diff.changes.map(\.path))")
        #expect(diff.changes.contains { $0.kind == .added })
        #expect(diff.changes.contains { $0.kind == .changed })
        #expect(TimelineDiff(before: after, after: before).changes.contains { $0.kind == .removed })
        #expect(try JSONDecoder().decode(TimelineDiff.self, from: JSONEncoder().encode(diff)) == diff)
    }

    @Test("Role loss and bumper ripple are visible, including other lanes")
    func indirectDiff() throws {
        var clip = Fixtures.timelineClip()
        clip.captions = "bottom"; clip.centerStage = true
        clip.freeCrops = [FreeCrop(src: FreeCropRect(), dst: FreeCropRect())]
        let other = Fixtures.timelineClip(startTime: 4, track: 1)
        let model = ScriptFixtures.model(clips: [clip, other])
        let session = BuilderScriptSession(live: model, library: ScriptFixtures.library())
        #expect(session.run([.init(.setClipRole(clip: clip.uid.uuidString, role: .cutaway)),
                             .init(.addBumper(bumper: "intro", at: 2, mode: .pause))]).completed)
        let diff = session.diff()
        for field in ["captions", "centerStage", "freeCrops", "role"] {
            #expect(diff.changes.contains { $0.path.hasSuffix("." + field) })
        }
        #expect(diff.changes.contains { $0.path.contains(other.uid.uuidString) && $0.path.hasSuffix("startTime") })
        #expect(diff.afterDuration > diff.beforeDuration)
    }
    @Test("Multiple lists accumulate against one baseline until freeze closes admission")
    func multipleRunsAndFreeze() throws {
        let session = ScriptFixtures.session()
        #expect(session.run([.init(.addText(text: "First"))]).completed)
        let firstDiff = session.diff()
        #expect(session.state == .ready)
        let uid = try #require(session.candidate?.videoTrack.first?.uid)
        #expect(session.run([.init(.removeClip(clip: uid.uuidString)), .init(.addText(text: "Second"))]).completed)
        #expect(session.candidate?.textOverlays.map(\.text) == ["First", "Second"])
        #expect(session.candidate?.videoTrack.isEmpty == true)
        #expect(session.diff() != firstDiff)
        let frozen = session.freeze()
        let candidate = session.candidate
        #expect(session.state == .completed && session.freeze() == frozen)
        let late = session.run([.init(.addText(text: "Late"))])
        #expect(late.outcomes == [.refused(code: "closed", reason: "Session no longer accepts commands.")])
        #expect(!session.run(json: Data("[]".utf8)).completed)
        #expect(session.candidate == candidate && session.diff() == frozen)
    }

    @Test("A refusal in a later list drops the entire candidate and retains cumulative diagnostics")
    func laterRunRefusal() throws {
        let session = ScriptFixtures.session()
        #expect(session.run([.init(.addText(text: "Earlier list"))]).completed)
        let result = session.run([.init(.addText(text: "Before refusal")),
                                  .init(.removeClip(clip: UUID().uuidString)),
                                  .init(.addText(text: "Never"))])
        #expect(!result.completed && session.state == .failed && session.candidate == nil)
        let diagnostic = session.diff()
        #expect(diagnostic.changes.filter { $0.path.hasPrefix("document.textOverlays.") && $0.kind == .added }.count == 2)
        #expect(session.freeze() == diagnostic && session.state == .failed)
        #expect(!session.run([]).completed)
        #expect(session.diff() == diagnostic)
    }

    @Test("Diff JSON distinguishes absent values, explicit nulls, booleans and numbers")
    func diffValueRoundTrip() throws {
        let values: [ScriptValue] = [.null, .bool(false), .bool(true), .number(0), .number(1),
                                     .array([.null, .bool(true), .number(1)])]
        for value in values {
            #expect(try JSONDecoder().decode(ScriptValue.self, from: JSONEncoder().encode(value)) == value)
        }
        let changes: [TimelineDiff.Change] = [
            .init(path: "optional", kind: .changed, before: .null, after: .number(1)),
            .init(path: "optional", kind: .changed, before: .number(1), after: .null),
            .init(path: "added", kind: .added, before: nil, after: .null),
            .init(path: "removed", kind: .removed, before: .null, after: nil)
        ]
        #expect(try JSONDecoder().decode([TimelineDiff.Change].self, from: JSONEncoder().encode(changes)) == changes)
        #expect(ScriptValue.stored(false) == .bool(false))
        #expect(ScriptValue.stored(1) == .number(1))
    }

    @Test("Snapshot-only layouts resolve through mutations and live-only layouts are refused")
    func isolatedLayoutResolution() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var snapshotLayout = try #require(ScreenCropStore.builtIn.first { $0.name == "50-50 Horizontal" })
        snapshotLayout.name = "Snapshot-only \(UUID().uuidString)"
        #expect(ScreenCropStore.layout(named: snapshotLayout.name) == nil)
        var library = ScriptFixtures.library()
        library.layouts = [snapshotLayout]
        let session = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        let result = session.run([
            .init(.addCropBlock(layout: snapshotLayout.name, at: 0, duration: 5), bind: "crop"),
            .init(.setCropLayout(block: "$crop", layout: snapshotLayout.name)),
            .init(.addScene(scene: 1, at: 0, track: 1)),
            .init(.setTrackSequential(track: 1, sequential: true)),
            .init(.query(query: BuilderQuery(.timeline)))
        ])
        #expect(result.completed, "Snapshot-only layout must support normalization and placement: \(result.outcomes)")
        let document = try #require(session.candidate)
        #expect(document.trackCount == 2 && document.mainClips(inTrack: 1).count == 1)
        let inspection = BuilderTimelineModel(mode: .transient)
        library.withLayouts {
            inspection.seed(document: document, scenes: library.scenes)
            #expect(inspection.area(forTrack: 1, at: 0) != nil)
            #expect(inspection.canPlace(track: 1, at: 0))
        }
        #expect(!session.diff().isEmpty && session.freeze() == session.diff())
        #expect(ScriptLayoutScope.layouts == nil, "Layout scope must not leak into the live UI")

        let liveOnly = "50-50 Horizontal"
        #expect(ScreenCropStore.layout(named: liveOnly) != nil)
        let refused = BuilderScriptSession(live: ScriptFixtures.model(), library: library)
        #expect(!refused.run([.init(.addCropBlock(layout: liveOnly, at: 0, duration: 5))]).completed)
        #expect(refused.state == .failed && refused.candidate == nil)
    }

}
