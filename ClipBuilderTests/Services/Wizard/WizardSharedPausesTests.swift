import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard shared pauses")
struct WizardSharedPausesTests {
    private func options() -> WizardOptions {
        var value = WizardOptions()
        value.strikeImpactFreeze = 0.8
        value.useBRoll = false
        value.manualBRoll = true
        value.includeOutro = false
        value.includeIntroBumper = false
        value.includeOutroBumper = false
        value.includeMiddleBumper = false
        value.useMusic = false
        value.framing = Framing(subject: .original)
        value.allowedTransitions = ["cut"]
        return value
    }

    private func fixture() -> (WizardPlanClip, SceneRecord, SceneRecord, TimelineDocument) {
        let main = Fixtures.scene(start: 10, end: 20)
        var other = Fixtures.scene(id: 2, start: 30, end: 40)
        other.videoID = 2
        other.videoPath = "/tmp/companion.mp4"
        other.videoFilename = "Companion.mp4"
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.speed = 2
        clip.layout = "Two pictures"
        clip.areaClips = [.init(area: "Other", sceneID: other.id, start: 30, end: 36)]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [main.id: main, other.id: other],
            settings: .init(), framingPlan: nil)
        return (clip, main, other, cut)
    }

    @Test("Layout preparation merges source clocks, replaces a contact and reports all-track edge drops")
    func preparation() throws {
        let (clip, main, other, cut) = fixture()
        let drawing = Telestration(time: 34)
        let nearEdge = Telestration(time: 35.8)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [main.id: main, other.id: other], sourceTypes: [main.videoID: .fight, other.videoID: .fight],
            contacts: [main.videoPath: [12, 14], other.videoPath: [34, 35.7]],
            drawings: [other.videoPath: [drawing, nearEdge, Telestration(time: 38)]],
            options: options(), xfadeDuration: 0.35)
        let timing = try #require(result.timings[0])
        #expect(timing.pauses.map(\.time) == [1, 2])
        #expect(timing.pauses[1].drawing == drawing && timing.pauses[1].source == other.videoPath)
        #expect(timing.pauses[0].source == nil)
        #expect(timing.outputDuration == 5 + 0.8 + drawing.duration)
        #expect(timing.filteredDrawings == 1)
        // The drawing dropped at the companion's end gives back the contact
        // it had replaced (35.7), which is itself too close to that end.
        #expect(result.messages == ["Pause on contact: clip 1 — skipped 1 contact(s) (spacing or limit).",
            "Drawing: clip 1: skipped 1 (too close to an edge or another pause)."])
        let output = try #require(result.cuts[0])
        for slot in [0, 1] {
            let holds = output.videoTrack.filter { $0.track == slot && $0.hold == true }
            #expect(holds.count == 2)
            #expect(holds.map(\.startTime) == [1, 2.8])
            #expect(holds[1].telestration == (slot == 1 ? drawing : nil))
        }
        #expect(output.videoTrack.allSatisfy { $0.strikeImpactsFrozen == true })
        #expect(MultitrackRenderer.usesTimedAssembly(output, transitions: []))
        #expect(timing.outputTime(4) == 4 + 0.8 + drawing.duration)
    }

    @Test("Companion contacts require fight footage; companion drawings work with contact pauses off")
    func sourceGates() throws {
        let (clip, main, other, cut) = fixture()
        let plan = Fixtures.plan(clips: [clip]), scenes = [main.id: main, other.id: other]
        #expect(WizardStrikePauses.contactPaths(plan: plan, cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [main.videoID: .podcast, other.videoID: .fight], options: options()) == [other.videoPath])
        for fight in [false, true] {
            let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: scenes,
                sourceTypes: [main.videoID: .podcast, other.videoID: fight ? .fight : .podcast],
                contacts: [other.videoPath: [32]], options: options(), xfadeDuration: 0.35)
            #expect(result.timings[0]?.pauses.count == (fight ? 1 : 0))
        }
        var settings = options()
        settings.strikeImpactFreeze = nil
        let drawing = Telestration(time: 32)
        let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [:], contacts: [:], drawings: [other.videoPath: [drawing]], options: settings, xfadeDuration: 0.35)
        #expect(result.timings[0]?.pauses.count == 1)
        #expect(result.messages.isEmpty)
        // A framing choice can leave only one visible area: a companion that
        // is not on screen does not pause the picture that is.
        var oneArea = cut
        oneArea.videoTrack = [cut.videoTrack[0]]
        let one = WizardStrikePauses.prepare(plan: plan, cuts: [0: oneArea], sceneMap: scenes,
            sourceTypes: [:], contacts: [:], drawings: [other.videoPath: [drawing]], options: settings, xfadeDuration: 0.35)
        #expect(one.timings[0]?.pauses.isEmpty == true)
        #expect(one.cuts[0] == oneArea && one.messages.isEmpty)
        settings.drawnPauses = false
        let off = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [:], contacts: [:], drawings: [other.videoPath: [drawing]], options: settings, xfadeDuration: 0.35)
        #expect(off.cuts[0] == cut && off.timings[0]?.pauses.isEmpty == true && off.messages.isEmpty)
    }

    @Test("A companion edge rejects a contact once; cutaways still skip the whole cut")
    func contactEdgeAndCutaways() throws {
        let (clip, main, other, cut) = fixture()
        let plan = Fixtures.plan(clips: [clip]), scenes = [main.id: main, other.id: other]
        let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [main.videoID: .fight], contacts: [main.videoPath: [15.8]],
            options: options(), xfadeDuration: 0.35)
        #expect(result.cuts[0] == cut)
        #expect(result.messages == ["Pause on contact: clip 1 — skipped 1 contact(s) (spacing or limit)."])
        var broll = cut
        broll.videoTrack[1].role = .cutaway
        let skipped = WizardStrikePauses.prepare(plan: plan, cuts: [0: broll], sceneMap: scenes,
            sourceTypes: [main.videoID: .fight], contacts: [main.videoPath: [12]],
            drawings: [other.videoPath: [Telestration(time: 32)]], options: options(), xfadeDuration: 0.35)
        #expect(skipped.cuts[0] == broll && skipped.timings[0]?.pauses.isEmpty == true)
        #expect(skipped.messages == ["Pause on contact: skipped clip 1 — B-roll cutaways would cover the held frame.",
            "Drawing: skipped clip 1 — B-roll cutaways would cover the held frame."])
        #expect(WizardStrikePauses.contactPaths(plan: plan, cuts: [0: broll], sceneMap: scenes,
            sourceTypes: [main.videoID: .fight, other.videoID: .fight], options: options()).isEmpty)
        var withCuts = plan
        withCuts.clips[0].brollCuts = [.init(start: 12, end: 13, sceneID: other.id,
            sceneOffset: 0, reason: "fixture", origin: .user)]
        var enabled = options()
        enabled.useBRoll = true
        #expect(WizardStrikePauses.skipReason(index: 0, plan: withCuts, cut: cut, scene: main,
            sourceType: .fight, options: enabled) == "B-roll cutaways would cover the held frame")
        #expect(WizardStrikePauses.skipReason(index: 0, plan: withCuts, cut: cut, scene: main,
            sourceType: .fight, options: options()) == nil)
    }

    @Test("Extraction eligibility checks every track-zero piece, independent of array order")
    func sourceClock() throws {
        let (clip, main, _, cut) = fixture()
        let plan = Fixtures.plan(clips: [clip])
        let split = try #require(TimelineSplit.pieces(cut.videoTrack[0], at: 2))
        var segmented = cut
        segmented.videoTrack = [cut.videoTrack[1], split.head, split.tail]
        #expect(WizardStrikePauses.skipReason(index: 0, plan: plan, cut: segmented, scene: main,
            sourceType: .fight, options: options()) == nil)
        segmented.videoTrack[2].sourceStart = 15
        #expect(WizardStrikePauses.skipReason(index: 0, plan: plan, cut: segmented, scene: main,
            sourceType: .fight, options: options()) == "extraction source clock differs from the planned clip")
    }

    @Test("Composed same-source framing expands before splitting and counts its drawing once")
    func composed() throws {
        let main = Fixtures.scene(start: 10, end: 20)
        let clip = Fixtures.planClip(start: 10, end: 20)
        let layout = ScreenCropLayout(name: "Two", areas: [
            .init(name: "Top", points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 0.5), .init(x: 0, y: 0.5)]),
            .init(name: "Bottom", points: [.init(x: 0, y: 0.5), .init(x: 1, y: 0.5), .init(x: 1, y: 1), .init(x: 0, y: 1)])])
        let areas = layout.areas.map { AreaSegment(areaID: $0.id, sourcePath: main.videoPath,
            start: 10, duration: 10, framing: .static(window: nil)) }
        let framing = FramingPlan.composed(layout: layout, areas: areas, fit: .fill)
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [main.id: main], settings: .init(), framingPlan: framing)
        let drawing = Telestration(time: 14)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [main.id: main], sourceTypes: [:], contacts: [:], drawings: [main.videoPath: [drawing]],
            options: options(), xfadeDuration: 0.35)
        #expect(result.messages.isEmpty)
        #expect(result.timings[0]?.pauses.count == 1)
        let output = try #require(result.cuts[0])
        #expect(output.videoTrack.filter { $0.hold == true }.map(\.track) == [0, 1])
        #expect(output.videoTrack.filter { $0.hold == true }.allSatisfy { $0.telestration == drawing })
    }

    @Test("Both status services count companion pauses once and watch companion range edits")
    func statuses() throws {
        let (clip, main, other, cut) = fixture()
        var saved = StrikeClipStatusRules.Saved()
        saved.companionScenes = [other.id: other]
        saved.companionTypes = [other.videoID: .fight]
        saved.companionContacts = [other.videoPath: [32]]
        saved.companionDrawings = [other.videoPath: [Telestration(time: 34)]]
        let status = StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(clips: [clip]), scene: main,
            sourceType: .podcast, saved: saved, options: options(), xfadeDuration: 0.35, cut: cut)
        #expect(status.pause == .mixedPauses(seconds: [0.8, Telestration(time: 34).duration]))
        let preview = WizardPreviewClip(id: "clip", title: "Clip", scene: main, start: 10, end: 20)
        let request = MiniStrikeStatusRequest(dataKey: "fixture", videoID: main.videoID, isFight: false,
            clips: [.init(preview: preview, plan: clip, planAvailable: true)], options: options(), xfadeDuration: 0.35)
        #expect(request.evaluate(saved: saved).statuses["clip"]?.pause == status.pause)
        var changed = request
        changed.clips[0].plan.areaClips[0].start += 1
        #expect(changed != request)
        #expect(request.companionSceneIDs == [other.id])
    }

    @Test("Single-track preparation retains pieces, source JSON and the resolved render input", arguments: [false, true])
    func singleTrackUnchanged(withDrawing: Bool) throws {
        let scene = Fixtures.scene(start: 10, end: 20)
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.speed = 2
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        let drawings = withDrawing ? [Telestration(time: 16)] : []
        let contacts = [10.1, 12.0, 16.0]
        let timing = WizardStrikePauses.timing(for: clip, contacts: contacts, seconds: 0.8, drawings: drawings)
        let original = try #require(cut.videoTrack.first)
        var expected = cut
        expected.videoTrack = withDrawing
            ? StrikeFreezeRules.pieces(original, pauses: timing.pauses.map {
                .init(time: clip.start + $0.time * clip.speed, duration: $0.duration, drawing: $0.drawing)
            }) : StrikeFreezeRules.pieces(original, contacts: contacts, hold: 0.8)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [scene.id: scene], sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts],
            drawings: [scene.videoPath: drawings], options: options(), xfadeDuration: 0.35)
        var actual = try #require(result.cuts[0])
        #expect(result.timings[0] == timing)
        #expect(result.messages == ["Pause on contact: clip 1 — skipped 1 contact(s) (spacing or limit)."])
        #expect(actual.videoTrack.count == expected.videoTrack.count)
        for index in actual.videoTrack.indices { actual.videoTrack[index].uid = expected.videoTrack[index].uid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        let resolved = MultitrackRenderer.resolveClips(document: actual, scenes: [scene])
        let expectedResolved = MultitrackRenderer.resolveClips(document: expected, scenes: [scene])
        #expect(try encoder.encode(resolved) == encoder.encode(expectedResolved))
        let key = RenderSegmentKey(start: 0, duration: timing.outputDuration, clips: resolved,
            captions: [], overlays: [], masks: [:], fontFingerprints: [], captionStyle: CaptionStyle(),
            settings: actual.renderSettings, encoder: [])
        var expectedKey = key
        expectedKey.clips = expectedResolved
        #expect(try RenderSegmentCache.key(key) == RenderSegmentCache.key(expectedKey))
    }

    @Test("Companion drawings are fetched by source, and both row adapters bound their menu ranges")
    func companionMetadata() async throws {
        let temp = try await TempDatabase()
        let mainID = try await temp.seedVideo(), otherID = try await temp.seedVideo()
        let raw = try SQLiteConnection(path: temp.path.path)
        try raw.execute("UPDATE videos SET path = '/tmp/companion.mp4', filename = 'Companion.mp4' WHERE id = ?", [.integer(otherID)])
        let main = try #require(try await temp.database.fetchScenes(videoID: mainID).first)
        let other = try #require(try await temp.database.fetchScenes(videoID: otherID).first)
        let drawing = Telestration(time: 4)
        _ = try await temp.database.saveTelestration(.init(videoID: otherID, drawing: drawing))
        var clip = Fixtures.planClip(sceneID: main.id, start: 0, end: 4)
        clip.layout = "Two"
        clip.areaClips = [.init(area: "Other", sceneID: other.id, start: 2, end: 8)]
        let scenes = [main.id: main, other.id: other]
        let read = try await WizardStrikePauses.drawings(plan: Fixtures.plan(clips: [clip]), sceneMap: scenes, database: temp.database)
        #expect(read[other.videoPath] == [drawing] && read[main.videoPath] == [])
        let snapshot = try await temp.database.sharedStrikeClipStatusSnapshot(videoID: mainID, companionSceneIDs: [other.id])
        #expect(snapshot.drawings.isEmpty && snapshot.companionDrawings[other.videoPath] == [drawing])
        let sources = TelestrationSource.companions(clip: clip, sceneMap: scenes)
        #expect(sources.count == 1 && sources[0].range == 2...6)
        #expect(sources[0].videoID == otherID && sources[0].name == "Companion.mp4")
        let selection = WizardSelectionRecord(id: 1, projectID: 1, name: "Shared", recipe: "custom",
            step1Options: WizardStep1Options())
        let take = WizardSelectionTake(id: 1, selectionID: 1, ordinal: 1,
            plan: Fixtures.plan(clips: [clip]), sceneIDs: [main.id, other.id])
        let candidate = MiniWizardCandidate(selection: selection, take: take, kept: true, note: "")
        let mini = try #require(MiniHighlightReview.items(candidates: [candidate], video: Fixtures.video(id: mainID),
            scenes: [main, other]).first)
        let wizard = try #require(WizardFootageReview.items(selections: [.init(selection: selection, takes: [take])],
            scenes: [main, other], videos: [Fixtures.video(id: mainID)]).first)
        let reel = try #require(WizardPreviewClips.takes([take], names: [1: "Shared"], scenes: [main, other]).first)
        #expect(mini.drawingCompanions == sources && wizard.drawingCompanions == sources)
        #expect(reel.drawingCompanions == sources)
    }

    @Test("A drawing dropped at a companion's edge gives back the contact it crowded out")
    func droppedDrawingRestoresContact() throws {
        let (clip, main, other, cut) = fixture()
        // Screen 2.7 on the main picture; the drawing is at screen 2.9, 0.1 s before the companion ends.
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [main.id: main, other.id: other], sourceTypes: [main.videoID: .fight],
            contacts: [main.videoPath: [15.4]], drawings: [other.videoPath: [Telestration(time: 35.8)]],
            options: options(), xfadeDuration: 0.35)
        let timing = try #require(result.timings[0])
        #expect(timing.pauses.count == 1 && timing.pauses.first?.drawing == nil)
        #expect(abs((timing.pauses.first?.time ?? 0) - 2.7) < 1e-9)
        #expect(timing.filteredDrawings == 1 && timing.filteredContacts == 0)
    }

    @Test("Footage shown twice at one moment is one event; a picture left out of the cut adds none")
    func candidateIdentityAndVisibility() {
        let (clip, main, other, _) = fixture()
        var twice = clip
        twice.areaClips = [.init(area: "Other", sceneID: main.id, start: 10, end: 20)]
        let same = WizardSharedPauses.candidates(twice, sceneMap: [main.id: main], sourceTypes: [main.videoID: .fight],
            contacts: [main.videoPath: [12]], drawings: [main.videoPath: [Telestration(time: 14)]], options: options())
        #expect(same.contacts == [12] && same.drawings.count == 1)
        let scenes = [main.id: main, other.id: other]
        let hidden = WizardSharedPauses.candidates(clip, sceneMap: scenes, sourceTypes: [other.videoID: .fight],
            contacts: [other.videoPath: [32]], drawings: [other.videoPath: [Telestration(time: 32)]],
            options: options(), visible: [main.videoPath])
        #expect(hidden.contacts.isEmpty && hidden.drawings.isEmpty && !hidden.useContacts)
        let shown = WizardSharedPauses.candidates(clip, sceneMap: scenes, sourceTypes: [other.videoID: .fight],
            contacts: [other.videoPath: [32]], drawings: [other.videoPath: [Telestration(time: 32)]],
            options: options(), visible: [main.videoPath, other.videoPath])
        #expect(shown.contacts == [12] && shown.drawings.count == 1)
    }

    @Test("A companion that stops early shortens what a transition out of the cut can use")
    func edgeSegmentsFollowTheShortestPicture() throws {
        let (clip, main, other, cut) = fixture()
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [main.id: main, other.id: other], sourceTypes: [main.videoID: .fight],
            contacts: [main.videoPath: [12]], options: options(), xfadeDuration: 0.35)
        let timing = try #require(result.timings[0])
        // Pause at screen 1; the companion ends at 3 of 5, so the last whole stretch is 2, not 4.
        #expect(abs((timing.headSegment ?? 0) - 1) < 1e-9)
        #expect(abs((timing.tailSegment ?? 0) - 2) < 1e-9)
        // Single-picture cuts carry no edge override.
        var alone = clip
        alone.layout = nil
        alone.areaClips = []
        let single = WizardOrdinaryTimeline.cutDocument(clip: alone, sceneMap: [main.id: main], settings: .init(), framingPlan: nil)
        let plain = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [alone]), cuts: [0: single],
            sceneMap: [main.id: main], sourceTypes: [main.videoID: .fight],
            contacts: [main.videoPath: [12]], options: options(), xfadeDuration: 0.35)
        #expect(plain.timings[0]?.pauses.count == 1)
        #expect(plain.timings[0]?.headSegment == nil && plain.timings[0]?.tailSegment == nil)
    }

    @Test("An unmarked fight companion reads as marking not finished, not as no strike")
    func companionMarkingIncomplete() {
        let (clip, main, other, _) = fixture()
        var saved = StrikeClipStatusRules.Saved()
        saved.companionScenes = [other.id: other]
        saved.companionTypes = [other.videoID: .fight]
        saved.companionComplete = [other.videoPath: false]
        let plan = Fixtures.plan(clips: [clip])
        let status = StrikeClipStatusRules.status(index: 0, plan: plan, scene: main, sourceType: .podcast,
            saved: saved, options: options(), xfadeDuration: 0.35)
        #expect(status.markingIncomplete)
        saved.companionComplete = [other.videoPath: true]
        #expect(!StrikeClipStatusRules.status(index: 0, plan: plan, scene: main, sourceType: .podcast,
            saved: saved, options: options(), xfadeDuration: 0.35).markingIncomplete)
    }

    @Test("Two pictures of one file: each reaches a drawing on its own; only the reachable one pauses")
    func repeatedDrawingKeepsTheValidOccurrence() throws {
        let (_, main, other, _) = fixture()
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.layout = "Three pictures"
        // Speed 1. The long companion reaches source 34 at screen 4; the short one at screen 2, 0.1 s before it ends.
        clip.areaClips = [.init(area: "Long", sceneID: other.id, start: 30, end: 40),
                          .init(area: "Short", sceneID: other.id, start: 32, end: 34.1)]
        let scenes = [main.id: main, other.id: other]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        var settings = options()
        settings.strikeImpactFreeze = nil
        let drawing = Telestration(time: 34)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [:], contacts: [:], drawings: [other.videoPath: [drawing]], options: settings, xfadeDuration: 0.35)
        let timing = try #require(result.timings[0])
        #expect(timing.pauses.count == 1 && abs((timing.pauses.first?.time ?? 0) - 4) < 1e-9)
        #expect(timing.filteredDrawings == 1)
        // A drawing outside a short first picture is still the longer one's.
        clip.areaClips = [.init(area: "Short", sceneID: other.id, start: 30, end: 32),
                          .init(area: "Long", sceneID: other.id, start: 30, end: 36)]
        let reach = WizardSharedPauses.candidates(clip, sceneMap: scenes, sourceTypes: [:], contacts: [:],
            drawings: [other.videoPath: [drawing]], options: settings)
        #expect(reach.drawings.count == 1)
    }

    @Test("A companion cut from the main file is on screen only with a picture of its own")
    func visibilityOfSameFileCompanions() {
        let (clip, main, other, cut) = fixture()
        let scenes = [main.id: main, other.id: other]
        #expect(WizardSharedPauses.visibleSources(cut, sceneMap: scenes, main: main.videoPath) == [other.videoPath])
        var alone = cut
        alone.videoTrack = [cut.videoTrack[0]]
        #expect(WizardSharedPauses.visibleSources(alone, sceneMap: scenes, main: main.videoPath).isEmpty)
        // Resolved through the scene when the clip carries no file of its own.
        var bare = cut
        bare.videoTrack[1].videoFile = nil
        #expect(WizardSharedPauses.visibleSources(bare, sceneMap: scenes, main: main.videoPath) == [other.videoPath])
        var same = cut
        same.videoTrack[1].sceneID = main.id
        same.videoTrack[1].videoFile = main.videoPath
        #expect(WizardSharedPauses.visibleSources(same, sceneMap: scenes, main: main.videoPath) == [main.videoPath])
        _ = clip
    }

    @Test("A sliver under the renderer's shortest segment is not an edge")
    func edgeSegmentsIgnoreSlivers() throws {
        var a = Fixtures.timelineClip(sourceStart: 0, duration: 10, startTime: 0, speed: 1)
        a.track = 0
        var b = Fixtures.timelineClip(sourceStart: 0, duration: 9.99, startTime: 0, speed: 1)
        b.track = 1
        let edges = try #require(WizardSharedPauses.edgeSegments([a, b]))
        #expect(abs(edges.head - 9.99) < 1e-9 && abs(edges.tail - 9.99) < 1e-9)
    }

    @Test("A drawing no picture shows at its moment causes no hold")
    func unshownDrawingDoesNotPause() throws {
        let (_, main, other, _) = fixture()
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.layout = "Two pictures"
        // The plan has two companions of one file; the cut shows only the first.
        clip.areaClips = [.init(area: "Shown", sceneID: other.id, start: 30, end: 40),
                          .init(area: "Left out", sceneID: other.id, start: 50, end: 60)]
        let scenes = [main.id: main, other.id: other]
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        cut.videoTrack.removeAll { $0.track == 2 }
        var settings = options()
        settings.strikeImpactFreeze = nil
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [:], contacts: [:], drawings: [other.videoPath: [Telestration(time: 54), Telestration(time: 33)]],
            options: settings, xfadeDuration: 0.35)
        let timing = try #require(result.timings[0])
        #expect(timing.pauses.count == 1 && abs((timing.pauses.first?.time ?? 0) - 3) < 1e-9)
        #expect(timing.filteredDrawings == 1)
        let holds = try #require(result.cuts[0]).videoTrack.filter { $0.hold == true }
        #expect(holds.count == 2 && holds.filter { $0.telestration != nil }.count == 1)
    }
}
