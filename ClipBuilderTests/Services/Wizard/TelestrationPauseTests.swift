import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@Suite("Telestration pauses")
struct TelestrationPauseTests {
    @Test(arguments: [0.5, 1.0])
    func movingDrawingMapsEveryClock(motion: Double) throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip])
        var annotation = drawing(2)
        annotation.stay = 1
        annotation.fade = 0.5 // duration 2, source span 2 * motion
        annotation.motion = motion
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        cut.textOverlays = [.init(text: "Drawing", startTime: 2.25, endTime: 2.75)]
        cut.imageOverlays = [.init(path: "/tmp/figure.png")]
        cut.imageOverlays[0].startTime = 2.25
        cut.imageOverlays[0].endTime = 2.75
        cut.imageOverlays[0].track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1),
                                    .init(time: 10, xFrac: 1, yFrac: 0, wFrac: 0.1)]
        cut.soundTrack = [.init(name: "music", startTime: 2.25, duration: 0.5)]
        cut.cropBlocks = [.init(layout: .fullScreen, startTime: 0, duration: 10)]
        let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: [scene.id: scene], sourceTypes: [:],
            contacts: [:], drawings: [scene.videoPath: [annotation]], options: options(), xfadeDuration: 0.5)
        let timing = try #require(result.timings[0]), output = try #require(result.cuts[0])
        #expect(timing.pauses.isEmpty && timing.movingDrawings == [annotation])
        #expect(timing.outputDuration == 10 + 2 * (1 - motion))
        #expect(timing.outputTime(2.25) == 2 + 0.25 / motion)
        #expect(abs(timing.plannedTime(forOutput: timing.outputTime(2.75)) - 2.75) < 1e-9)
        #expect(output.videoTrack.count == 3 && output.videoTrack.allSatisfy { $0.hold != true && $0.timedAssembly == true })
        #expect(MultitrackRenderer.usesTimedAssembly(output, transitions: []))
        #expect(output.textOverlays[0].startTime == timing.outputTime(2.25))
        #expect(output.imageOverlays[0].endTime == timing.outputTime(2.75))
        #expect(output.soundTrack[0].duration == 0.5 / motion)
        #expect(output.cropBlocks[0].duration == timing.outputDuration)
        let keys = try #require(output.imageOverlays[0].track)
        #expect(abs(try #require(ImageTrackKey.interpolate(keys, at: timing.outputTime(2.5))).xFrac - 0.25) < 1e-9)
        let captions = timing.captions([.init(raster: .init(text: "Drawing", activeIndex: nil),
            position: "bottom", start: 2.25, end: 2.75)])
        #expect(captions.first?.start == timing.outputTime(2.25) && captions.first?.end == timing.outputTime(2.75))
        let voice = VoiceOverPlacement.Cut(videoID: scene.videoID, sourceStart: 0, sourceEnd: 10,
            reelStart: 0, reelDuration: timing.outputDuration, pauses: timing.pauses, stretches: timing.stretches)
        #expect(voice.localTime(ofSource: 2.75) == timing.outputTime(2.75))
        let status = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene, sourceType: .fight,
            saved: .init(drawings: [annotation]), options: options(), xfadeDuration: 0.5, cut: cut, preparation: result)
        #expect(status.line.contains("drawing over the moving picture") && !status.hasPause)
    }

    @Test func movingDrawingReplacesContactsAndKeepsOtherPauses() {
        var annotation = drawing(2)
        annotation.motion = 0.5
        let timing = WizardStrikePauses.timing(for: Fixtures.planClip(start: 0, end: 10),
            contacts: [1, 1.8, 2.5, 3.3, 7], seconds: 0.8, drawings: [annotation])
        #expect(timing.pauses.map(\.time) == [1, 7])
        #expect(timing.filteredContacts == 0 && timing.movingDrawings == [annotation])
        #expect(abs(timing.outputDuration - 13) < 1e-9)
        var overlapping = drawing(3)
        overlapping.motion = 0.5
        let fallback = WizardStrikePauses.timing(for: Fixtures.planClip(start: 0, end: 10),
            contacts: [2.5], seconds: 0.8, drawings: [annotation, overlapping])
        #expect(fallback.movingDrawings.isEmpty && fallback.pauses.count == 3)
        #expect(fallback.pauses.compactMap(\.drawing).allSatisfy { $0.motion == nil })
        #expect(fallback.motionFallbackReasons == ["overlaps another drawing"])
    }

    @Test func sharedFallbackAndDubSkipMovingDrawings() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip])
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        var annotation = drawing(2)
        annotation.motion = 0.5
        var shared = cut
        var companion = cut.videoTrack[0]
        companion.uid = UUID()
        companion.track = 1
        shared.videoTrack.append(companion)
        let prepared = WizardStrikePauses.prepare(plan: plan, cuts: [0: shared], sceneMap: [scene.id: scene], sourceTypes: [:],
            contacts: [:], drawings: [scene.videoPath: [annotation]], options: options(), xfadeDuration: 0.5)
        #expect(prepared.messages == ["Drawing: clip 1: the picture pauses (the clip shows several pictures)"])
        #expect(prepared.timings[0]?.movingDrawings.isEmpty == true)
        let holds = try #require(prepared.cuts[0]).videoTrack.filter { $0.hold == true }
        #expect(holds.count == 2 && holds.allSatisfy { $0.telestration?.motion == nil })
        let status = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene, sourceType: .fight,
            saved: .init(drawings: [annotation]), options: options(), xfadeDuration: 0.5, cut: shared, preparation: prepared)
        #expect(status.line.contains("the picture pauses (the clip shows several pictures)"))
        var dubbed = options()
        dubbed.dubLanguage = "en"
        let skipped = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: [scene.id: scene], sourceTypes: [:],
            contacts: [:], drawings: [scene.videoPath: [annotation]], options: dubbed, xfadeDuration: 0.5)
        #expect(skipped.cuts[0] == cut && skipped.timings[0]?.outputDuration == 10)
        #expect(skipped.messages == ["Drawing: skipped for dubbed reels; holds have no speech."])
    }

    @Test func actualExtractedSpeedFallbackRestoresThePause() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        var clip = Fixtures.planClip(start: 0, end: 10)
        clip.speed = 0.5
        var annotation = drawing(2)
        annotation.motion = 0.5
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        // Within the extraction-clock tolerance, but below the speed floor.
        cut.videoTrack[0].speed = 0.5 - 1e-12
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: [scene.id: scene],
            sourceTypes: [:], contacts: [:], drawings: [scene.videoPath: [annotation]], options: options(), xfadeDuration: 0.5)
        #expect(result.timings[0]?.movingDrawings.isEmpty == true)
        let hold = try #require(result.cuts[0]?.videoTrack.first { $0.hold == true })
        #expect(hold.telestration == TelestrationMotionRules.paused(annotation))
        #expect(result.messages == ["Drawing: clip 1: the picture pauses (speed would be below 0.25×)"])
    }

    @Test func movingDrawingAndContactSlowingDoNotOverlap() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        var annotation = drawing(2)
        annotation.motion = 0.5 // ends at source 3.4
        var settings = options()
        settings.strikeSlowMotion = "medium"
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: [scene.id: scene],
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [3.7, 7]],
            drawings: [scene.videoPath: [annotation]], options: settings, xfadeDuration: 0.5)
        let timing = try #require(result.timings[0])
        #expect(timing.filteredSlowContacts == 1 && timing.stretches.count == 2)
        #expect(abs(timing.outputDuration - 12.15) < 1e-9)
        let parts = try #require(result.cuts[0]?.videoTrack)
        #expect(parts.first { $0.telestration != nil }?.speed == 0.5)
        #expect(abs(parts.reduce(0) { $0 + $1.duration } - timing.outputDuration) < 1e-9)
    }

    @Test func exactContactAtMovingDrawingStillSlowsTheLeadAndFlashes() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        var annotation = drawing(2)
        annotation.motion = 0.5
        var settings = options()
        settings.strikeSlowMotion = "medium"
        settings.strikeFlash = true
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: [scene.id: scene],
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]],
            drawings: [scene.videoPath: [annotation]], options: settings, xfadeDuration: 0.5)
        let timing = try #require(result.timings[0])
        #expect(timing.filteredSlowContacts == 0 && timing.stretches.count == 2 && timing.pauses.isEmpty)
        let piece = try #require(result.cuts[0]?.videoTrack.first { $0.telestration != nil })
        #expect(piece.flashIn == StrikeImpactRules.flashDuration && piece.speed == 0.5)
        #expect(abs(piece.startTime - 2.75) < 1e-9)
    }

    @Test func pausedDrawingPinsPiecesTimingGraphsAndCacheEvidence() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        let annotation = drawing(2)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: [scene.id: scene],
            sourceTypes: [:], contacts: [:], drawings: [scene.videoPath: [annotation]], options: options(), xfadeDuration: 0.5)
        let output = try #require(result.cuts[0])
        #expect(output.videoTrack.map(\.sourceStart) == [0, 2, 2])
        #expect(output.videoTrack.map(\.sourceEnd) == [2, 2, 10])
        #expect(output.videoTrack.map(\.duration) == [2, 2.8, 8])
        #expect(output.videoTrack.map(\.startTime) == [0, 2, 4.8])
        #expect(result.timings[0] == .init(plannedDuration: 10, pauses: [.init(time: 2, duration: 2.8, drawing: annotation)]))
        var legacy = cut
        legacy.videoTrack = StrikeFreezeRules.pieces(cut.videoTrack[0], pauses: [.init(time: 2, duration: 2.8, drawing: annotation)])
        for index in legacy.videoTrack.indices { legacy.videoTrack[index].uid = output.videoTrack[index].uid }
        #expect(output == legacy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(output) == encoder.encode(legacy))
        let current = MultitrackRenderer.resolveClips(document: output, scenes: [scene])
        let previous = MultitrackRenderer.resolveClips(document: legacy, scenes: [scene])
        #expect(try RenderSegmentCache.key(current) == RenderSegmentCache.key(previous))
        // The prepass key fingerprints the source file, so it must exist.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prepass-key-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var currentHold = current[1], previousHold = previous[1]
        currentHold.sourcePath = file.path
        previousHold.sourcePath = file.path
        #expect(try MultitrackRenderer.prepassKey(currentHold, area: nil, tuning: "balanced")
            == MultitrackRenderer.prepassKey(previousHold, area: nil, tuning: "balanced"))
        #expect(TelestrationLingerResolution.cacheEvidence(current) == nil)
        let graph = try StrikeHighlightBurn.inHoldGraph([.init(offset: 0, frames: 84, pattern: "/tmp/d%04d.png")],
            size: CGSize(width: 640, height: 360), input: "[hold]", tag: "draw")
        #expect(graph == ["[hold]setpts=PTS-STARTPTS[draw_b0]",
            "movie=filename='/tmp/d%04d.png':f=image2,settb=1/30,format=rgba,scale=640:360,setpts=N/(30*TB)+0.000000/TB[draw_m0]",
            "[draw_b0][draw_m0]overlay=eof_action=pass:repeatlast=0[draw]"])
    }

    private func drawing(_ time: Double, stay: Double = 2) -> Telestration {
        Telestration(time: time, figures: [.init(kind: .arrow,
            points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.8, y: 0.7)])], stay: stay)
    }

    private func options() -> WizardOptions {
        var result = WizardOptions()
        result.useBRoll = false
        result.includeOutro = false
        result.framing = Framing(subject: .original)
        return result
    }

    @Test("Mixed pauses keep their own lengths and replace a nearby contact at the drawing's time")
    func mixedOrderAndLengths() {
        let clip = Fixtures.planClip(start: 10, end: 20)
        let first = drawing(12.2), last = drawing(17, stay: 6)
        let timing = WizardStrikePauses.timing(for: clip, contacts: [18, 12, 15], seconds: 0.8, drawings: [last, first])
        #expect(timing.pauses.map { ($0.time * 10).rounded() / 10 } == [2.2, 5, 7, 8])
        #expect(timing.pauses.map(\.duration) == [first.duration, 0.8, last.duration, 0.8])
        #expect(timing.pauses.compactMap(\.drawing) == [first, last])
        #expect(abs(timing.outputDuration - (10 + first.duration + last.duration + 1.6)) < 1e-9)
    }

    @Test("Drawings win spacing conflicts on either side at changed speeds", arguments: [0.5, 2.0])
    func drawingPriority(speed: Double) {
        var clip = Fixtures.planClip(start: 0, end: 10)
        clip.speed = speed
        let annotation = drawing(4)
        let distance = max(0.25, StrikeFreezeRules.minimumPiece * speed) - 0.01
        let timing = WizardStrikePauses.timing(for: clip, contacts: [4 - distance, 4 + distance, 7],
            seconds: 0.8, drawings: [annotation])
        #expect(timing.pauses.map(\.time) == [4 / speed, 7 / speed])
        #expect(timing.pauses.first?.drawing == annotation)
        let edge = StrikeFreezeRules.minimumPiece * speed
        let edges = WizardStrikePauses.timing(for: clip, contacts: [], seconds: nil,
            drawings: [drawing(edge - 0.001), drawing(edge), drawing(10 - edge), drawing(10 - edge + 0.001)])
        #expect(edges.pauses.count == 2 && edges.filteredDrawings == 2)
    }

    @Test("Eight contacts and eight drawings have independent caps; overlong drawings are skipped")
    func independentCapsAndLengths() {
        let clip = Fixtures.planClip(start: 0, end: 40)
        let annotations = (1...9).map { drawing(Double($0) * 2) }
        let timing = WizardStrikePauses.timing(for: clip, contacts: (1...9).map { Double($0) * 2 + 1 },
            seconds: 100, drawings: annotations)
        #expect(timing.pauses.count == 16)
        #expect(timing.pauses.count { $0.drawing != nil } == 8)
        #expect(timing.pauses.filter { $0.drawing == nil }.allSatisfy { $0.duration == 5 })
        #expect(timing.filteredDrawings == 1 && timing.filteredContacts == 1)
        var long = drawing(25)
        long.fade = 40 - long.stay - long.drawSpeed
        let allowed = WizardStrikePauses.timing(for: clip, contacts: [], seconds: nil, drawings: [long])
        #expect(allowed.pauses.first?.duration == 40)
        long.fade += 0.01
        let rejected = WizardStrikePauses.timing(for: clip, contacts: [25], seconds: 0.8, drawings: [long])
        #expect(rejected.filteredDrawings == 1 && rejected.pauses.count == 1)
        #expect(rejected.pauses.first?.drawing == nil)
        #expect(StrikeFreezeRules.holdRange == 0.05...5.0)
    }

    @Test("Mixed pieces split once, keep source clocks and camera paths, and attach only to the right hold")
    func mixedPieces() throws {
        var clip = Fixtures.timelineClip(sourceStart: 10, duration: 5, startTime: 3, speed: 2)
        clip.cameraPath = [.init(t: 0, x: 0, y: 0, w: 0.4, h: 1), .init(t: 10, x: 0.6, y: 0, w: 0.4, h: 1)]
        let annotation = drawing(16, stay: 6)
        let pieces = StrikeFreezeRules.pieces(clip, pauses: [
            .init(time: 12, duration: 0.8), .init(time: 16, duration: annotation.duration, drawing: annotation)
        ])
        #expect(pieces.count == 5)
        #expect(pieces.map(\.sourceStart) == [10, 12, 12, 16, 16])
        #expect(pieces.map(\.sourceEnd) == [12, 12, 16, 16, 20])
        #expect(pieces.map(\.duration) == [1, 0.8, 2, annotation.duration, 2])
        #expect(pieces.compactMap(\.telestration) == [annotation])
        #expect(pieces[3].telestration == annotation && pieces[3].hold == true)
        #expect(pieces.allSatisfy { $0.strikeImpactsFrozen == true })
        var cursor = 3.0
        for piece in pieces {
            #expect(abs(piece.startTime - cursor) < 1e-9)
            cursor += piece.duration
        }
        let expected = HoldClipRules.cameraPath(try #require(clip.cameraPath), at: 6, duration: annotation.duration)
        #expect(pieces[3].cameraPath == expected)
        #expect(pieces[3].speed == nil && pieces[3].sourceSpan == 0)
        #expect(StrikeFreezeRules.pieces(pieces[4], pauses: [.init(time: 18, duration: 0.8)]).isEmpty)
    }

    @Test("Any source can draw with contact pauses off; rejected drawings get a per-clip count")
    func prepareAnySourceAndMessages() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .podcast], contacts: [scene.videoPath: [3]],
            drawings: [scene.videoPath: [drawing(0.1), drawing(4), drawing(4.1), drawing(12)]],
            options: options(), xfadeDuration: 0.5)
        #expect(result.timings[0]?.pauses.count == 1)
        #expect(result.cuts[0]?.videoTrack[1].telestration == drawing(4))
        #expect(result.messages == ["Drawing: clip 1: skipped 2 (too close to an edge or another pause)."])
        #expect(WizardStrikePauses.contactPaths(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .podcast], options: options()).isEmpty)
    }

    @Test("Dub skips drawings; multi-source pauses and nearby ordinary joins share one clock")
    func eligibilityAndJoins() {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip, clip], transitions: ["fade"])
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        for mode in ["dub", "composed", "allowed"] {
            var settings = options()
            settings.dubLanguage = mode == "dub" ? "pt" : nil
            var source = cut
            if mode == "composed" { source.videoTrack.append(cut.videoTrack[0]) }
            let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: source, 1: source], sceneMap: map,
                sourceTypes: [:], contacts: [:], drawings: [scene.videoPath: [drawing(0.25), drawing(9.75)]],
                options: settings, xfadeDuration: 0.5)
            #expect(!result.messages.isEmpty)
            #expect(result.messages.allSatisfy { $0.hasPrefix("Drawing:") })
            if mode == "allowed" || mode == "composed" {
                #expect(result.joins.transitions == ["cut"])
                #expect(result.timings[0]?.pauses.count == 2)
            } else {
                #expect(result.cuts[0] == source)
                #expect(result.timings.values.allSatisfy { $0.pauses.isEmpty })
            }
        }
    }

    @Test("Mixed pause clocks map captions and the renderer reconstructs their own lengths")
    func mixedCaptionClock() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        var clip = Fixtures.planClip(start: 0, end: 10)
        clip.speed = 2
        let annotation = drawing(6, stay: 6)
        var settings = options()
        settings.strikeImpactFreeze = 0.8
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]],
            drawings: [scene.videoPath: [annotation]], options: settings, xfadeDuration: 0.5)
        let timing = try #require(result.timings[0])
        #expect(timing.outputTime(1) == 1)
        #expect(abs(timing.outputTime(3) - 3.8) < 1e-9)
        #expect(abs(timing.outputTime(4) - (4.8 + annotation.duration)) < 1e-9)
        let caption = timing.captions([.init(raster: .init(text: "Spanning", activeIndex: nil), position: "bottom", start: 0.5, end: 4)])
        #expect(caption.first?.start == 0.5)
        #expect(abs(try #require(caption.first?.end) - (4.8 + annotation.duration)) < 1e-9)
        var document = try #require(result.cuts[0])
        document.captionPosition = "auto"
        for index in document.videoTrack.indices { document.videoTrack[index].captions = "bottom" }
        let captions = MultitrackRenderer.captionCuts(MultitrackRenderer.resolveClips(document: document, scenes: [scene]))
        #expect(captions.count == 1)
        let reconstructed = try #require(captions.first).timing
        #expect(reconstructed.pauses.map(\.duration) == [0.8, annotation.duration])
        #expect(abs(reconstructed.outputTime(4) - timing.outputTime(4)) < 1e-9)
    }

    @Test("Nil drawings preserve old encoding and explicit empty drawings preserve pause results")
    func compatibilityAndIdentity() throws {
        let clip = Fixtures.timelineClip()
        let plain = try JSONEncoder().encode(clip)
        #expect(!String(decoding: plain, as: UTF8.self).contains("telestration"))
        #expect(try JSONDecoder().decode(TimelineClip.self, from: plain).telestration == nil)
        var held = clip
        held.hold = true
        held.telestration = drawing(3)
        let loaded = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(held))
        #expect(loaded.telestration == held.telestration)
        var changed = held
        changed.telestration?.stay += 1
        #expect(changed != held)
        let planClip = Fixtures.planClip(start: 0, end: 10)
        #expect(WizardStrikePauses.timing(for: planClip, contacts: [1, 3], seconds: 0.8)
            == WizardStrikePauses.timing(for: planClip, contacts: [1, 3], seconds: 0.8, drawings: []))
        let resolved = try #require(MultitrackRenderer.resolveClips(document: Fixtures.timelineDocument(clips: [held]), scenes: []).first)
        #expect(resolved.telestration == held.telestration)
        var altered = resolved
        altered.telestration?.stay += 1
        #expect(try RenderSegmentCache.key(resolved) != RenderSegmentCache.key(altered))
        altered.useFramedSource(URL(fileURLWithPath: "/tmp/framed.mov"), identity: "fixture", areaPass: true, reusable: true)
        #expect(altered.telestration == nil)
    }

    @Test("Explicit empty drawings leave contact-only cuts, timings, messages and joins unchanged")
    func emptyDrawingPreparation() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip, clip], transitions: ["fade"])
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        var settings = options()
        settings.strikeImpactFreeze = 0.8
        let contacts = [scene.videoPath: [0.1, 0.5, 8, 9.5]]
        let plain = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: contacts, options: settings, xfadeDuration: 0.5)
        let empty = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: contacts, drawings: [:], options: settings, xfadeDuration: 0.5)
        #expect(plain.timings == empty.timings && plain.messages == empty.messages && plain.joins == empty.joins)
        for index in plan.clips.indices {
            let a = try #require(plain.cuts[index])
            var b = try #require(empty.cuts[index])
            #expect(a.videoTrack.count == b.videoTrack.count)
            // A split allocates fresh editor IDs; every other field must match.
            for piece in b.videoTrack.indices { b.videoTrack[piece].uid = a.videoTrack[piece].uid }
            #expect(a == b)
        }
    }

    @Test("Status reports total seconds for unequal pauses")
    func mixedStatus() {
        let scene = Fixtures.scene(start: 0, end: 10)
        var settings = options()
        settings.strikeImpactFreeze = 0.8
        let annotation = drawing(6)
        let saved = StrikeClipStatusRules.Saved(contacts: [2], drawings: [annotation])
        let status = StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 10)]),
            scene: scene, sourceType: .fight, saved: saved, options: settings, xfadeDuration: 0.5)
        #expect(status.pause == .mixedPauses(seconds: [0.8, annotation.duration]))
        #expect(status.hasPause && status.line.contains("total"))
    }
}
