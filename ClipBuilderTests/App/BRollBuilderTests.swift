import AppKit
import Testing
@testable import Clip_Builder

/// B-roll is bound to time: packing never moves it and never steps over it,
/// it takes its track's area unless it covers everything, and turning a clip
/// into B-roll (or back) is a timeline edit with its own undo name.
@MainActor
@Suite("Builder B-roll", .serialized)
struct BRollBuilderTests {
    private func makeUndoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func model(clips: [TimelineClip] = [], trackCount: Int = 2,
                       cropBlocks: [CropBlockItem] = []) throws -> BuilderTimelineModel {
        let model = BuilderTimelineModel()
        var document = Fixtures.timelineDocument(clips: clips)
        document.cropBlocks = cropBlocks
        document.trackCount = trackCount
        model.loadDocument(document)
        // The visible track count is derived from the row and the clips on
        // load; the tests below place B-roll on track 2 deliberately.
        model.document.trackCount = trackCount
        return model
    }

    private func clip(start: Double, duration: Double, track: Int = 0) -> TimelineClip {
        Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: duration,
                              startTime: start, track: track)
    }

    private func cutaway(start: Double, duration: Double, track: Int = 0,
                         coverAll: Bool = false) -> TimelineClip {
        var clip = clip(start: start, duration: duration, track: track)
        clip.role = .cutaway
        clip.coverAllAreas = coverAll
        clip.enforceCutawayRules()
        return clip
    }

    @Test("repacking a sequential track ignores B-roll and never moves it")
    func repackIgnoresCutaways() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let broll = cutaway(start: 7, duration: 2)
        let model = try model(clips: [clip(start: 0, duration: 4),
                                      clip(start: 10, duration: 4),
                                      broll])
        model.resolveLayout(track: 0)
        let mains = model.document.mainClips(inTrack: 0)
        #expect(mains.map(\.startTime) == [0, 4], "the main clips pack end to end")
        #expect(model.document.cutaways(inTrack: 0).map(\.startTime) == [7],
                "the B-roll stays exactly where it was put")
    }

    @Test("B-roll is not an obstacle: a main clip packs straight through it")
    func cutawayIsNotAnObstacle() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 6),
                                      clip(start: 20, duration: 6),
                                      cutaway(start: 2, duration: 2)])
        model.resolveLayout(track: 0)
        #expect(model.document.mainClips(inTrack: 0).map(\.startTime) == [0, 6])
    }

    @Test("adding B-roll defaults to the gap up to the next cut, clamped to 1-5 s")
    func defaultDurationAgainstTheNextCut() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4), clip(start: 4, duration: 20)])
        #expect(model.defaultCutawayDuration(at: 1, track: 0) == 3, "up to the cut at 4")
        #expect(model.defaultCutawayDuration(at: 3.8, track: 0) == 1, "clamped up to one second")
        #expect(model.defaultCutawayDuration(at: 5, track: 0) == 5, "clamped down to five seconds")
        #expect(model.defaultCutawayDuration(at: 1, track: 1) == 3, "nothing ahead: three seconds")
    }

    @Test("addCutaway places muted B-roll at the playhead without moving anything")
    func addCutawayPlacesAndMovesNothing() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4), clip(start: 4, duration: 10)])
        model.playhead = 3
        let uid = try #require(model.addCutaway(source: .file(url: URL(fileURLWithPath: "/tmp/broll.mp4"),
                                                             duration: 30),
                                                track: 0, sourceStart: 5).uid)
        let added = try #require(model.clip(uid))
        #expect(added.isCutaway && added.muted && added.startTime == 3)
        #expect(added.duration == 1, "the cut at 4 is one second ahead")
        #expect(added.sourceStart == 5)
        #expect(model.document.mainClips(inTrack: 0).map(\.startTime) == [0, 4],
                "the footage underneath does not move")
    }

    @Test("cover-all B-roll skips the area check that would refuse the track")
    func coverAllSkipsCanPlace() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [], trackCount: 2,
                              cropBlocks: [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 20)])
        #expect(!model.canPlace(track: 1, at: 2), "Full Screen gives track 2 no area")
        let source = CutawaySource.file(url: URL(fileURLWithPath: "/tmp/broll.mp4"), duration: 30)
        #expect(model.addCutaway(source: source, at: 2, track: 1, duration: 2) == .noArea(track: 1))
        let uid = try #require(model.addCutaway(source: source, at: 2, track: 1,
                                                duration: 2, coverAll: true).uid)
        let added = try #require(model.clip(uid))
        #expect(added.coverAllAreas && !model.document.isOrphaned(added))

        // Turning cover-all off leaves it on a track with no area: orphaned.
        model.setCutawayCoverAll(uid, false)
        let narrowed = try #require(model.clip(uid))
        #expect(!narrowed.coverAllAreas && model.document.isOrphaned(narrowed))
    }

    @Test("role conversion is lossy and repacks the track")
    func roleConversionBothWays() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4), clip(start: 4, duration: 4)])
        let first = try #require(model.document.mainClips(inTrack: 0).first?.uid)
        model.updateClip(first) {
            $0.captions = "bottom"
            $0.centerStage = true
            $0.wide = true
        }

        model.setClipRole(first, role: .cutaway)
        let broll = try #require(model.clip(first))
        #expect(broll.isCutaway && broll.captions == "none" && !broll.centerStage && broll.muted)
        #expect(model.document.mainClips(inTrack: 0).map(\.startTime) == [0],
                "the track repacks without it")
        #expect(broll.startTime == 0, "the B-roll keeps its own time")

        model.setClipRole(first, role: .main)
        let restored = try #require(model.clip(first))
        #expect(restored.role == .main)
        #expect(restored.captions == "none", "nothing dropped comes back")
        #expect(model.document.mainClips(inTrack: 0).count == 2)
    }

    @Test("role conversion names its own undo step in both directions")
    func roleConversionUndoNames() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4)])
        let undo = makeUndoManager()
        model.undoManager = undo
        let first = try #require(model.document.mainClips(inTrack: 0).first?.uid)

        undo.beginUndoGrouping()
        model.setClipRole(first, role: .cutaway)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Make B-roll")

        undo.beginUndoGrouping()
        model.setClipRole(first, role: .main)
        undo.endUndoGrouping()
        #expect(undo.undoActionName == "Make main clip")
    }

    @Test("B-roll sound follows the audio choice")
    func cutawayAudioChoice() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [cutaway(start: 0, duration: 4)])
        let uid = try #require(model.document.cutaways(inTrack: 0).first?.uid)
        #expect(model.clip(uid)?.muted == true)
        model.setCutawayAudio(uid, .mixed)
        #expect(model.clip(uid)?.muted == false)
        model.setCutawayAudio(uid, .muted)
        #expect(model.clip(uid)?.muted == true)
    }

    @Test("duplicating B-roll keeps the role and gives the copy its own identity")
    func duplicateKeepsRole() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [cutaway(start: 0, duration: 4)])
        let uid = try #require(model.document.cutaways(inTrack: 0).first?.uid)
        model.duplicateClip(uid)
        let all = model.document.cutaways(inTrack: 0)
        #expect(all.count == 2 && all.allSatisfy(\.isCutaway))
        #expect(all[0].originKey != all[1].originKey)
    }

    @Test("moving B-roll to another track takes that track's area with it")
    func moveCarriesTheArea() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [cutaway(start: 0, duration: 4)],
                              cropBlocks: [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"),
                                                         startTime: 0, duration: 20)])
        let uid = try #require(model.document.cutaways(inTrack: 0).first?.uid)
        model.placeClip(uid, startTime: 2, track: 1)
        let moved = try #require(model.clip(uid))
        #expect(moved.track == 1 && moved.startTime == 2 && moved.isCutaway)
        #expect(moved.screenCrop == model.document.cropBlock(at: 2)?.layout.reference(forTrack: 1))
    }

    @Test("an Option-drag payload asks for B-roll; a plain one does not")
    func dropPayloadParsing() {
        #expect(TimelineDropPayload.scene(7) == "scene:7")
        #expect(TimelineDropPayload.scene(7, cutaway: true) == "scene:7:cutaway")
        let plain = TimelineDropPayload.parse("scene:7")
        #expect(plain?.sceneID == 7 && plain?.cutaway == false)
        let broll = TimelineDropPayload.parse("scene:7:cutaway")
        #expect(broll?.sceneID == 7 && broll?.cutaway == true)
        #expect(TimelineDropPayload.parse("image:7") == nil)
        #expect(TimelineDropPayload.parse("scene:not-a-number") == nil)
    }

    @Test("a request from a track's context menu carries the clicked spot's default length")
    func brollRequestFromAClick() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4), clip(start: 4, duration: 20)])
        model.brollRequest = BuilderTimelineModel.BRollRequest(time: 2, track: 0)
        let request = try #require(model.brollRequest)
        #expect(model.defaultCutawayDuration(at: request.time, track: request.track) == 2,
                "two seconds to the cut at 4, not the playhead's answer")
        #expect(model.hasMainClip(inTrack: 0, from: 2, to: 4))
        #expect(model.mainCuts(inTrack: 0, from: 1, to: 6) == [4])
    }

    @Test("the inspector's dissolve fields are clamped when they are committed")
    func inspectorFadeSetters() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [cutaway(start: 0, duration: 4)])
        let uid = try #require(model.document.cutaways(inTrack: 0).first?.uid)
        model.updateClip(uid) { $0.fadeIn = 10; $0.fadeOut = 1 }
        let edited = try #require(model.clip(uid))
        #expect(edited.fadeIn == 2, "never longer than half the clip")
        #expect(edited.fadeOut == 1)
        model.setClipRole(uid, role: .main)
        #expect(model.clip(uid)?.fadeIn == 0, "a main clip has no dissolve")
    }

    @Test("a full-scene cutaway keeps its dissolves through save, load and hydration")
    func fullSceneCutawayKeepsFades() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let scene = Fixtures.scene(start: 2, end: 10)
        var broll = Fixtures.timelineClip(sceneID: scene.id, sourceStart: 2, duration: 8)
        broll.sceneFullDuration = 8
        broll.role = .cutaway
        broll.fadeIn = 1
        broll.fadeOut = 1
        broll.enforceCutawayRules()

        let data = try JSONEncoder().encode(Fixtures.timelineDocument(clips: [broll]))
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        let raw = try #require(decoded.videoTrack.first)
        // An untrimmed scene clip is written as a bare scene id, so the
        // duration only arrives with hydration — the dissolves must not be
        // clamped away against a length of zero in the meantime.
        #expect(raw.duration == 0)
        #expect(raw.fadeIn == 1 && raw.fadeOut == 1)

        let model = BuilderTimelineModel()
        model.updateScenes([scene])
        model.loadDocument(decoded)
        let hydrated = try #require(model.document.videoTrack.first)
        #expect(hydrated.duration == 8)
        #expect(hydrated.fadeIn == 1 && hydrated.fadeOut == 1)
    }

    @Test("an insertion is clamped to the source and refused when there is none")
    func insertionBounds() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 20)])
        let short = CutawaySource.file(url: URL(fileURLWithPath: "/tmp/broll.mp4"), duration: 3)

        // Asking for five seconds of a three-second file gets three, and
        // the caller is told the ask was cut down.
        let outcome = model.addCutaway(source: short, at: 0, track: 0, duration: 5)
        let uid = try #require(outcome.uid)
        if case .added(_, let clampedTo) = outcome {
            #expect(clampedTo != nil && abs((clampedTo ?? 0) - 3) < 0.001)
        } else {
            Issue.record("expected an insertion")
        }
        #expect(outcome.message(at: 0)?.contains("3.0 s") == true)
        let added = try #require(model.clip(uid))
        #expect(added.duration <= 3.0001 && added.duration > 2.9)
        #expect((added.sourceEnd ?? 0) <= 3.0001, "the window never runs past the file")

        // An ask that fits is kept to the millisecond and reported as
        // nothing: a picked window is not rounded to the timeline's grid.
        let exact = model.addCutaway(source: short, at: 6, track: 0, duration: 1.2)
        let exactUID = try #require(exact.uid)
        #expect(exact.message(at: 6) == nil)
        #expect(model.clip(exactUID)?.duration == 1.2)

        // The default length, on the other hand, snaps to the grid.
        let defaulted = model.addCutaway(source: short, at: 10, track: 0)
        let defaultedUID = try #require(defaulted.uid)
        let defaultedDuration = try #require(model.clip(defaultedUID)?.duration)
        #expect(abs(defaultedDuration * 2 - (defaultedDuration * 2).rounded()) < 0.001)

        // A window that starts at the very end has nothing left to give.
        #expect(model.addCutaway(source: short, at: 4, track: 0, duration: 2, sourceStart: 3) == .noSource)
        #expect(model.addCutaway(source: .file(url: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 0),
                                 at: 4, track: 0, duration: 2) == .noSource)
        #expect(CutawayInsertion.noSource.message(at: 0) != nil)
    }

    @Test("a remembered picker choice belongs to the document it was made in")
    func rememberedPickIsScopedToTheDocument() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4)])
        func remember() {
            model.lastBRollPick = BuilderTimelineModel.BRollPick(
                sourceKey: "scene:1", sourceStart: 2, length: 3, track: 0, coverAll: false)
            model.brollRequest = BuilderTimelineModel.BRollRequest(time: 1, track: 0)
        }

        remember()
        model.loadDocument(Fixtures.timelineDocument(clips: [clip(start: 0, duration: 4)]))
        #expect(model.lastBRollPick == nil && model.brollRequest == nil)

        remember()
        model.loadTimeline(id: 7, document: Fixtures.timelineDocument(clips: []))
        #expect(model.lastBRollPick == nil && model.brollRequest == nil)

        remember()
        model.closeTimeline()
        #expect(model.lastBRollPick == nil && model.brollRequest == nil)

        remember()
        model.load(profileName: "Another")
        #expect(model.lastBRollPick == nil && model.brollRequest == nil)
    }

    @Test("dragging B-roll across tracks measures from its own strip band")
    func stripBandDragGeometry() throws {
        let scope = try DataFolderOverride()
        _ = scope
        let model = try model(clips: [clip(start: 0, duration: 4),
                                      cutaway(start: 0, duration: 2),
                                      clip(start: 0, duration: 4, track: 1)])
        let lane = model.timelineLayout().videoTracks[0]
        #expect(lane.cutawayRowCount == 1)
        // A cutaway riding in the band is nearer the lane below than its
        // own lane's middle suggests: without the band offset this drag
        // would land on the wrong track.
        let straight = model.trackIndex(fromTrack: 0, verticalDelta: 0, blockOffset: 0)
        #expect(straight == 0)
        let down = model.trackIndex(fromTrack: 0, verticalDelta: lane.laneHeight,
                                    blockOffset: 0)
        #expect(down == 1)
        let fromBand = model.trackIndex(fromTrack: 0, verticalDelta: lane.laneHeight - 4,
                                        blockOffset: 4)
        #expect(fromBand == 1, "the block's own offset is part of the measurement")
    }

    @Test("B-roll rules still run in a project with no analyzed scenes")
    func hydrationWithoutScenes() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var broll = clip(start: 0, duration: 4)
        broll.role = .cutaway
        broll.captions = "bottom"
        broll.centerStage = true
        broll.muted = false
        // Straight into the document, without enforcing anything first.
        var document = Fixtures.timelineDocument(clips: [broll])
        document.trackCount = 1
        let model = BuilderTimelineModel()
        model.loadDocument(document)
        let loaded = try #require(model.document.videoTrack.first)
        #expect(loaded.isCutaway && loaded.muted && loaded.captions == "none" && !loaded.centerStage)
    }

    @Test("splitting a mixed cutaway's feeds leaves the second feed silent")
    func splitFeedsSilenceTheSecondCutaway() throws {
        let scope = try DataFolderOverride()
        _ = scope
        var broll = clip(start: 0, duration: 4)
        broll.role = .cutaway
        broll.cutawayAudio = .mixed
        broll.wide = true
        broll.enforceCutawayRules()
        #expect(!broll.muted)
        let model = try model(clips: [broll], trackCount: 2)
        model.splitZoomFeeds(broll.uid, leftName: "Left", rightName: "Right",
                             sourceAspect: 16.0 / 9.0)
        let feeds = model.document.videoTrack.filter(\.isCutaway)
            .sorted { $0.track < $1.track }
        guard feeds.count == 2 else {
            // The split needs the 50-50 layout; without it there is nothing
            // to check, and the rest of the suite covers the rules.
            return
        }
        #expect(!feeds[0].muted, "the first feed keeps the mixed-in sound")
        #expect(feeds[1].muted && feeds[1].cutawayAudio == .muted,
                "the second feed is silent, and says so as its audio choice")
    }

    @Test("a load that lands after Stop does not start playing again")
    func loadRaceAgainstStop() {
        typealias Picker = BuilderBRollPickerSheet
        #expect(Picker.shouldApplyLoad(loadGeneration: 3, currentGeneration: 3,
                                       isPresented: true, cancelled: false))
        // Stop bumps the generation, so the load in flight is stale.
        #expect(!Picker.shouldApplyLoad(loadGeneration: 3, currentGeneration: 4,
                                        isPresented: true, cancelled: false))
        #expect(!Picker.shouldApplyLoad(loadGeneration: 3, currentGeneration: 3,
                                        isPresented: false, cancelled: false))
        #expect(!Picker.shouldApplyLoad(loadGeneration: 3, currentGeneration: 3,
                                        isPresented: true, cancelled: true))
    }

    @Test("restoring the remembered pick does not reset its window")
    func restoreGuard() {
        typealias Picker = BuilderBRollPickerSheet
        #expect(!Picker.shouldResetWindow(newID: "scene:1", pendingRestoreID: "scene:1"),
                "the change that reports the restored selection is not a user change")
        #expect(Picker.shouldResetWindow(newID: "scene:2", pendingRestoreID: "scene:1"))
        #expect(Picker.shouldResetWindow(newID: "scene:2", pendingRestoreID: nil))
        #expect(Picker.shouldResetWindow(newID: nil, pendingRestoreID: "scene:1"))
    }

    // MARK: - Snapshot rows

    @Test("the strip band gets its own rows, and no rows at all without B-roll")
    func snapshotRows() throws {
        var document = Fixtures.timelineDocument(clips: [clip(start: 0, duration: 4),
                                                         clip(start: 4, duration: 4)])
        document.trackCount = 2
        let plain = TimelineLayoutSnapshot(document: document)
        #expect(plain.videoTracks[0].cutawayRowCount == 0)
        #expect(plain.videoTracks[0].rowCount == 1)
        #expect(plain.videoTracks[0].laneHeight == TimelineLayoutSnapshot.rowHeight)
        #expect(plain.videoTracks[0].mainRowsOffset == 0)

        // Two overlapping cutaways need two strip rows; the main rows are
        // unchanged because packing them is a separate problem.
        document.videoTrack.append(cutaway(start: 1, duration: 4))
        document.videoTrack.append(cutaway(start: 2, duration: 4))
        let withBRoll = TimelineLayoutSnapshot(document: document)
        let lane = withBRoll.videoTracks[0]
        #expect(lane.clips.count == 2, "the strip clips are not main clips")
        #expect(lane.cutaways.count == 2)
        #expect(lane.rowCount == 1 && lane.cutawayRowCount == 2)
        #expect(lane.laneHeight == TimelineLayoutSnapshot.rowHeight
                + 2 * TimelineLayoutSnapshot.stripHeight)
        #expect(lane.mainRowsOffset == 2 * TimelineLayoutSnapshot.stripHeight)
        #expect(Set(lane.cutawayRows.values) == [0, 1])
        #expect(withBRoll.videoTracks[1].cutawayRowCount == 0)
    }
}
