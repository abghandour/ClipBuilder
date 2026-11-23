import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

struct WizardStrikePausesTests {
    private func track(_ contact: Double) -> StrikeHighlightRules.Track {
        .init(keyframes: [], contact: contact, aspect: 16.0 / 9)
    }

    @Test("No contacts is identity; one and several insert only hold time", arguments: [0.5, 1.0, 2.0])
    func timeMap(speed: Double) {
        var clip = Fixtures.planClip(start: 10, end: 20)
        clip.speed = speed
        let plain = WizardStrikePauses.timing(for: clip, contacts: [], seconds: 0.8)
        #expect(plain.outputDuration == 10 / speed)
        #expect(plain.outputTime(3) == 3)
        let one = WizardStrikePauses.timing(for: clip, contacts: [14], seconds: 0.8)
        #expect(one.pauses.count == 1 && one.pauses[0].time == 4 / speed)
        #expect(abs(one.outputDuration - (10 / speed + 0.8)) < 1e-9)
        #expect(one.outputTime(4 / speed) == 4 / speed)
        #expect(abs(one.outputTime(5 / speed) - (5 / speed + 0.8)) < 1e-9)
        let many = WizardStrikePauses.timing(for: clip, contacts: [17, 12, 14, 14], seconds: 0.8)
        #expect(many.pauses.map(\.time) == [2 / speed, 4 / speed, 7 / speed])
        #expect(abs(many.outputDuration - (10 / speed + 2.4)) < 1e-9)
    }

    @Test("Edge spacing is screen time; the Builder's cap and length bounds apply")
    func edgesAndCap() {
        var clip = Fixtures.planClip(start: 0, end: 10)
        clip.speed = 2
        let fast = WizardStrikePauses.timing(for: clip, contacts: [0.1, 0.49, 0.5, 9.5, 9.9], seconds: 0.8)
        #expect(fast.pauses.map(\.time) == [0.25, 4.75])
        clip.speed = 0.5
        let slow = WizardStrikePauses.timing(for: clip, contacts: [0.1, 0.125, 9.875, 9.9], seconds: 0.8)
        #expect(slow.pauses.map(\.time) == [0.25, 19.75])
        clip.speed = 1
        let capped = WizardStrikePauses.timing(for: clip, contacts: stride(from: 0.5, through: 9.5, by: 0.5).map { $0 }, seconds: 100)
        #expect(capped.pauses.count == StrikeFreezeRules.maximumContacts)
        #expect(capped.pauses.allSatisfy { $0.duration == StrikeFreezeRules.holdRange.upperBound })
        for seconds: Double? in [nil, 0, -1, .nan, .infinity] {
            #expect(WizardStrikePauses.timing(for: clip, contacts: [2], seconds: seconds).pauses.isEmpty)
        }
    }

    @Test("Assembly saves ordinary pieces and holds, ripples later clips and layers, and normalizes to the same render length")
    func documentAndExtractionAgree() throws {
        let scene = Fixtures.scene()
        var first = Fixtures.planClip(sceneID: scene.id, start: 2, end: 8)
        first.speakerIntroductions = [TextOverlayItem(text: "After contact", startTime: 3, endTime: 5)]
        let next = Fixtures.planClip(sceneID: scene.id, start: 12, end: 16)
        var plan = Fixtures.plan(clips: [first, next])
        plan.musicName = "Music"
        plan.transitions = ["cut"]
        let map = [scene.id: scene]
        var cut = WizardOrdinaryTimeline.cutDocument(clip: first, sceneMap: map, settings: .init(), framingPlan: nil)
        let crop = CropBlockItem(layout: .fullScreen, startTime: 0, duration: 6)
        cut.cropBlocks = [crop]
        var block = OverlayBlockItem()
        block.startTime = 3
        block.duration = 2
        cut.overlayBlocks = [block]
        var options = WizardOptions()
        options.strikeImpactFreeze = 0.8
        options.useBRoll = false
        options.framing = Framing(subject: .original)
        let prepared = WizardStrikePauses.prepare(plan: plan,
            cuts: [0: cut, 1: WizardOrdinaryTimeline.cutDocument(clip: next, sceneMap: map, settings: .init(), framingPlan: nil)],
            sceneMap: map, sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]],
            options: options, xfadeDuration: 0.3)
        let paused = try #require(prepared.cuts[0])
        #expect(paused.videoTrack.count == 3)
        #expect(paused.videoTrack.map { $0.hold == true } == [false, true, false])
        #expect(paused.videoTrack.allSatisfy { $0.strikeImpactsFrozen == true })
        let hold = paused.videoTrack[1]
        #expect(hold.sourceStart == 4 && hold.sourceEnd == 4 && hold.speed == nil)
        #expect(hold.duration == 0.8 && hold.transIn == nil && hold.transOut == nil)
        #expect(abs(paused.cropBlocks[0].duration - 6.8) < 1e-9)
        #expect(abs(paused.overlayBlocks[0].startTime - 3.8) < 1e-9)
        #expect(prepared.timings[0]?.outputDuration == 6.8)
        var document = WizardEngine.timelineDocument(from: plan, sceneMap: map, podcastCuts: prepared.cuts,
            videoTypes: [scene.videoID: .fight], pauseTimings: prepared.timings)
        #expect(abs(document.videoTrack[3].startTime - 6.8) < 1e-9)
        #expect(abs(document.textOverlays[0].startTime - 3.8) < 1e-9)
        #expect(abs(document.soundTrack[0].duration - 10.8) < 1e-9)
        document.captionPosition = "auto"
        for index in document.videoTrack.indices { document.videoTrack[index].captions = "bottom" }
        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [scene])
        #expect(resolved.contains { $0.hold && $0.muted && $0.captionsPosition == "bottom" })
        let captions = MultitrackRenderer.captionCuts(resolved)
        #expect(captions.count == 2)
        #expect(captions[0].sourceStart == 2 && abs(captions[0].sourceEnd - 8) < 1e-9)
        // The renderer rebuilds the pause from the resolved clips' times, so
        // it matches the plan's to rounding, not bit for bit.
        let rebuilt = captions[0].timing
        let planned = try #require(prepared.timings[0])
        #expect(abs(rebuilt.plannedDuration - planned.plannedDuration) < 1e-9)
        #expect(rebuilt.pauses.count == planned.pauses.count)
        for (a, b) in zip(rebuilt.pauses, planned.pauses) {
            #expect(abs(a.time - b.time) < 1e-9 && abs(a.duration - b.duration) < 1e-9)
        }
        let window = MultitrackRenderer.windowed(document, from: 2.1, to: 2.5)
        let heldCaptions = MultitrackRenderer.captionCuts(MultitrackRenderer.resolveClips(document: window, scenes: [scene]))
        let heldCaption = try #require(heldCaptions.first)
        #expect(heldCaptions.count == 1 && abs(heldCaption.timing.plannedDuration) < 1e-9)
        let heldWindows = heldCaption.timing.captions([
            .init(raster: .init(text: "At contact", activeIndex: nil), position: "bottom", start: 0, end: 1.0 / 30)
        ])
        #expect(heldWindows.count == 1 && abs(heldWindows[0].end - 0.4) < 1e-9)
        let compositor = WizardEngine.preparedDocument(from: document,
            clipURLs: [URL(fileURLWithPath: "/tmp/first.mp4"), URL(fileURLWithPath: "/tmp/next.mp4")], transitions: ["cut"])
        #expect(compositor.videoTrack.count == 2)
        #expect(abs(compositor.videoTrack[0].duration - 6.8) < 1e-9)
        #expect(abs(compositor.videoTrack[1].startTime - 6.8) < 1e-9)
        #expect(!compositor.videoTrack.contains { $0.hold == true })
        #expect(compositor.videoTrack[0].strikeImpactsFrozen == true,
                "the extracted file must retain planned-clock assembly without freezing it again")
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded.videoTrack.contains { $0.hold == true && $0.strikeImpactsFrozen == true })
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan,
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let preview = WizardPreviewClips.rendered(document, take: take, name: "Fight", scenes: [scene], xfadeDuration: 0.3)
        #expect(preview.count == 4)
        #expect(preview[1].start == 4 && preview[1].end == 4 && preview[1].outputDuration == 0.8)
        #expect(WizardPreviewClips.moment(in: preview, at: 2.4)?.time == 4)
        #expect(abs(RoughCut.plannedDuration(of: preview) - 10.8) < 1e-9)
    }

    @Test("Caption grouping keeps the source clock across holds at changed speeds", arguments: [0.5, 2.0])
    func captionClockAtSpeed(speed: Double) throws {
        let scene = Fixtures.scene()
        var clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 10)
        clip.speed = speed
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil)
        var options = WizardOptions()
        options.strikeImpactFreeze = 0.8
        options.useBRoll = false
        options.includeOutro = false
        options.framing = Framing(subject: .original)
        let prepared = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut],
            sceneMap: [scene.id: scene], sourceTypes: [scene.videoID: .fight],
            contacts: [scene.videoPath: [4, 7]], options: options, xfadeDuration: 0.3)
        var document = try #require(prepared.cuts[0])
        document.captionPosition = "auto"
        for index in document.videoTrack.indices { document.videoTrack[index].captions = "bottom" }
        let captions = MultitrackRenderer.captionCuts(MultitrackRenderer.resolveClips(document: document, scenes: [scene]))
        #expect(captions.count == 1)
        let caption = try #require(captions.first)
        #expect(abs(caption.sourceEnd - 10) < 1e-9)
        #expect(abs(caption.timing.outputDuration - (10 / speed + 1.6)) < 1e-9)
        #expect(abs(caption.timing.outputTime(8 / speed) - (8 / speed + 1.6)) < 1e-9)
    }

    @Test("Captions after contact move later and spanning captions stay visible through the pause")
    func captionWindows() {
        let timing = WizardStrikePauses.timing(for: Fixtures.planClip(start: 10, end: 20), contacts: [14], seconds: 0.8)
        let items: [CaptionOverlayPlan.Overlay] = [
            .init(raster: .init(text: "before", activeIndex: nil), position: "bottom", start: 1, end: 3),
            .init(raster: .init(text: "spans", activeIndex: nil), position: "bottom", start: 3, end: 5),
            .init(raster: .init(text: "after", activeIndex: nil), position: "bottom", start: 6, end: 8),
        ]
        let mapped = timing.captions(items)
        #expect(mapped[0].start == 1 && mapped[0].end == 3)
        #expect(mapped[1].start == 3 && mapped[1].end == 5.8)
        #expect(mapped[2].start == 6.8 && mapped[2].end == 8.8)
    }

    @Test("Dub and multi-source cuts skip pauses; short transition edges become cuts")
    func skippedCuts() throws {
        let scene = Fixtures.scene()
        let clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 10)
        var plan = Fixtures.plan(clips: [clip, clip])
        plan.transitions = ["cut"]
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        var options = WizardOptions()
        options.useBRoll = false
        options.framing = Framing(subject: .original)
        options.strikeImpactFreeze = 0.8
        options.dubLanguage = "pt"
        let dubbed = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]], options: options, xfadeDuration: 0.5)
        #expect(dubbed.cuts == [0: cut, 1: cut])
        #expect(dubbed.timings.values.allSatisfy { $0.pauses.isEmpty })
        #expect(dubbed.messages == ["Pause on contact: skipped for dubbed reels; holds have no speech."])
        options.dubLanguage = nil
        // Several pictures at once pause together since 4b; a cutaway over
        // the held frame is what still skips.
        var multi = cut
        var cutaway = cut.videoTrack[0]
        cutaway.role = .cutaway
        multi.videoTrack.append(cutaway)
        let skipped = WizardStrikePauses.prepare(plan: plan, cuts: [0: multi], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]], options: options, xfadeDuration: 0.5)
        #expect(skipped.cuts[0] == multi && skipped.timings[0]?.pauses.isEmpty == true)
        #expect(skipped.messages.count == 1)
        plan.transitions = ["fade"]
        let edges = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [0.5, 9.5]], options: options, xfadeDuration: 0.5)
        #expect(edges.timings.values.allSatisfy { $0.pauses.count == 2 })
        #expect(edges.joins.transitions == ["cut"])
        #expect(edges.messages.filter { $0.contains("transition into clip 2") }.count == 1)
        let safe = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]], options: options, xfadeDuration: 0.5)
        plan.transitions = safe.joins.transitions
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: map, podcastCuts: safe.cuts, pauseTimings: safe.timings)
        #expect(document.videoTrack[3].transIn == "fade")
        #expect(document.videoTrack[1].transIn == nil && document.videoTrack[2].transIn == nil)
    }

    private func options() -> WizardOptions {
        var options = WizardOptions()
        options.strikeImpactFreeze = 0.8
        options.useBRoll = false
        options.includeOutro = false
        options.framing = Framing(subject: .original)
        return options
    }

    @Test("Only the incoming or outgoing join that cannot fit is cut",
           arguments: [[10.5], [19.5], [10.5, 19.5], [14.0]])
    func sharedJoinOverride(contacts: [Double]) throws {
        let scene = Fixtures.scene(start: 0, end: 30)
        var plan = Fixtures.plan(clips: (0..<3).map {
            Fixtures.planClip(sceneID: scene.id, start: Double($0 * 10), end: Double(($0 + 1) * 10))
        }, transitions: ["fade", "wipeleft"])
        let map = [scene.id: scene]
        let cuts = Dictionary(uniqueKeysWithValues: plan.clips.enumerated().map { index, clip in
            (index, WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil))
        })
        let prepared = WizardStrikePauses.prepare(plan: plan, cuts: cuts, sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts],
            options: options(), xfadeDuration: 0.35)
        let expected = [contacts.contains(10.5) ? "cut" : "fade", contacts.contains(19.5) ? "cut" : "wipeleft"]
        #expect(prepared.joins.transitions == expected)
        #expect(prepared.timings[1]?.pauses.count == contacts.count)
        #expect(prepared.messages.count == expected.count { $0 == "cut" })
        #expect(prepared.joins == WizardStrikePauses.resolveJoins(plan: plan, options: options(),
            timings: prepared.timings, xfadeDuration: 0.35))
        plan.transitions = prepared.joins.transitions
        #expect(WizardStrikePauses.resolveJoins(plan: plan, options: options(),
            timings: prepared.timings, xfadeDuration: 0.35).changes.isEmpty, "Applying resolved joins again is identity")
        let document = WizardEngine.timelineDocument(from: plan, sceneMap: map,
            podcastCuts: prepared.cuts, pauseTimings: prepared.timings)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(document))
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan,
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let expectedDuration = 30 + Double(contacts.count) * 0.8
            - expected.reduce(0.0) { $0 + RenderEngine.consumedOverlap($1, xfadeDuration: 0.35) }
        let compositor = WizardEngine.preparedDocument(from: document,
            clipURLs: (0..<3).map { URL(fileURLWithPath: "/tmp/join-\($0).mp4") }, transitions: expected)
        let extras = RoughCutExtras(transition: "fade") // preserve the already resolved joins
        for candidate in [document, decoded, compositor, WizardRoughCut.strip(document, extras: extras)] {
            let preview = WizardPreviewClips.rendered(candidate, take: take, name: "Fight", scenes: [scene], xfadeDuration: 0.35)
            // Extracted compositor files have no source mapping; inspect its
            // actual join clock directly instead of pretending they are scenes.
            if candidate == compositor {
                let names = candidate.videoTrack.dropFirst().map { $0.transIn == "cut" ? nil : $0.transIn }
                let overlaps = MultitrackRenderer.crossfadeOverlaps(durations: candidate.videoTrack.map(\.duration),
                    transitions: names, transitionDuration: 0.35)
                #expect(abs(candidate.videoTrack.reduce(0.0) { $0 + $1.duration }
                    - overlaps.values.reduce(0, +) - expectedDuration) < 1e-9)
            } else {
                // A reel with pauses is joined on the 30 fps frame clock
                // (`RenderEngine.concatenateTimed`): each overlap is whole frames.
                let onFrames = 30 + Double(contacts.count) * 0.8 - expected.reduce(0.0) {
                    $0 + (RenderEngine.consumedOverlap($1, xfadeDuration: 0.35) * 30).rounded() / 30
                }
                #expect(abs(RoughCut.plannedDuration(of: preview) - onFrames) < 1e-9)
            }
        }
    }

    @Test("A shared failing join logs once even when both one-second clips need the cut")
    func oneSecondClips() {
        let scene = Fixtures.scene(start: 0, end: 2)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 1), Fixtures.planClip(start: 1, end: 2)],
                                 transitions: ["fade"])
        let cuts = Dictionary(uniqueKeysWithValues: plan.clips.enumerated().map { index, clip in
            (index, WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil))
        })
        let result = WizardStrikePauses.prepare(plan: plan, cuts: cuts, sceneMap: [scene.id: scene],
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [0.5, 1.5]], options: options(), xfadeDuration: 0.35)
        #expect(result.timings.values.allSatisfy { $0.pauses.count == 1 })
        #expect(result.joins.transitions == ["cut"])
        #expect(result.messages == ["Pause on contact: clip 1 — transition into clip 2 replaced by a cut to keep the pause."])
    }

    @Test("Disabled pauses, missing contacts, unsafe pieces and recipe joins do not change joins or timing",
           arguments: ["off", "empty", "edge", "unsafe", "recipe"])
    func unchangedJoins(mode: String) {
        let scene = Fixtures.scene(start: 0, end: 2)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 1), Fixtures.planClip(start: 1, end: 2)],
                                 transitions: [mode == "recipe" ? "knife_slash" : "fade"])
        var cuts = Dictionary(uniqueKeysWithValues: plan.clips.enumerated().map { index, clip in
            (index, WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: [scene.id: scene], settings: .init(), framingPlan: nil))
        })
        if mode == "unsafe" {
            for index in plan.clips.indices { cuts[index]?.videoTrack[0].strikeImpactsFrozen = true }
        }
        var settings = options()
        if mode == "off" { settings.strikeImpactFreeze = nil }
        let contacts = mode == "empty" ? [] : mode == "edge" ? [0.08, 1.08] : [0.5, 1.5]
        let result = WizardStrikePauses.prepare(plan: plan, cuts: cuts, sceneMap: [scene.id: scene],
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts], options: settings, xfadeDuration: 0.35)
        #expect(result.cuts == cuts)
        #expect(result.joins.transitions == plan.transitions && result.joins.changes.isEmpty)
        #expect(result.timings.values.allSatisfy { $0.pauses.isEmpty && $0.outputDuration == 1 })
    }

    @Test("Card edges and fixed-duration flashes use the same override")
    func cardAndFlashJoins() {
        var plan = Fixtures.plan(clips: [Fixtures.planClip(start: 0, end: 1)], transitions: [])
        plan.introTitle = "Fight"
        var settings = options()
        settings.formatPreset = "compilation"
        settings.includeOutro = true
        let timing = WizardStrikePauses.timing(for: plan.clips[0], contacts: [0.5], seconds: 0.8)
        let cards = WizardStrikePauses.resolveJoins(plan: plan, options: settings, timings: [0: timing], xfadeDuration: 0.35)
        #expect(cards.incoming == "cut" && cards.outgoing == "cut")
        #expect(cards.changes.map(\.boundary) == [-1, 0])
        plan.clips.append(plan.clips[0])
        plan.transitions = ["flash_white"]
        let flash = WizardStrikePauses.resolveJoins(plan: plan, options: options(), timings: [0: timing, 1: timing], xfadeDuration: 2)
        #expect(flash.transitions == ["flash_white"] && flash.changes.isEmpty)
        let close = WizardStrikePauses.timing(for: plan.clips[0], contacts: [0.25, 0.75], seconds: 0.8)
        #expect(WizardStrikePauses.resolveJoins(plan: plan, options: options(), timings: [0: close],
            xfadeDuration: 2).transitions == ["cut"])
    }

    @Test("The async proxy/document builder consumes resolved joins before computing preview duration")
    func documentBuilderJoins() async throws {
        let temp = try await TempDatabase()
        let videoID = try await temp.seedVideo()
        try await temp.database.setVideoType(id: videoID, type: VideoType.fight.rawValue)
        let projectID = try await temp.database.createProject(profileName: "Pause joins", name: "Run", videoIDs: [videoID])
        let scene = try #require(try await temp.database.fetchScenes(projectID: projectID).first)
        let plan = Fixtures.plan(clips: [Fixtures.planClip(sceneID: scene.id, start: 0, end: 1),
                                        Fixtures.planClip(sceneID: scene.id, start: 1, end: 2)], transitions: ["fade"])
        var settings = options()
        settings.projectID = projectID
        settings.nameTags = false
        settings.enableTextOverlays = false
        let document = try await WizardEngine.timelineDocument(from: plan, sceneMap: [scene.id: scene],
            options: settings, database: temp.database, strikeContacts: [scene.videoPath: [0.5, 1.5]], log: { _ in })
        #expect(document.videoTrack.count == 6)
        #expect(document.videoTrack.count { $0.hold == true } == 2)
        #expect(document.videoTrack.allSatisfy { $0.transIn == nil || $0.transIn == "cut" })
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: plan,
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let preview = WizardPreviewClips.rendered(document, take: take, name: "Fight", scenes: [scene],
            xfadeDuration: RenderContext.transitions.xfadeDuration)
        #expect(abs(RoughCut.plannedDuration(of: preview) - 3.6) < 1e-9)
    }

    @Test("Rough cuts use final bumper, B-roll, dub and transition eligibility")
    func roughEligibility() throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        var finalPlan = Fixtures.plan(clips: [clip, clip], transitions: ["fade"])
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        for mode in ["intro", "outro", "middle", "broll", "transition", "recipe", "dub"] {
            var finalOptions = options()
            let join = mode == "recipe" ? "zoom_punch" : "fade"
            finalPlan.transitions = [join]
            finalOptions.transitionChoice = join
            finalOptions.allowedTransitions = [join]
            finalOptions.includeIntroBumper = mode == "intro"
            finalOptions.includeOutroBumper = mode == "outro"
            finalOptions.includeMiddleBumper = mode == "middle"
            finalOptions.dubLanguage = mode == "dub" ? "pt" : nil
            finalOptions.useBRoll = mode == "broll"
            finalPlan.clips[0].brollCuts = mode == "broll"
                ? [BRollCut(start: 2, end: 3, sceneID: scene.id, sceneOffset: 0, reason: "fixture", origin: .user)] : nil
            let rough = WizardRoughCut.options(finalOptions)
            let retained = WizardRoughCut.pauseEligibilityOptions(finalOptions, extras: .init(), oneReel: false)
            let eligibility = WizardStrikePauses.eligibilityOptions(rough, original: retained)
            var roughPlan = finalPlan
            roughPlan.transitions = WizardStrikePauses.renderTransitions(plan: finalPlan, options: eligibility)
            let contacts = mode == "transition" ? [0.5, 9.5] : [4.0]
            let final = WizardStrikePauses.prepare(plan: finalPlan, cuts: [0: cut, 1: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts],
                options: finalOptions, xfadeDuration: 0.5)
            let preview = WizardStrikePauses.prepare(plan: roughPlan, cuts: [0: cut, 1: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts],
                options: eligibility, xfadeDuration: 0.5)
            #expect(preview.timings == final.timings)
            #expect(preview.joins == final.joins)
            #expect(preview.messages == final.messages)
            #expect(!preview.messages.isEmpty)
            #expect(!rough.includeIntroBumper && !rough.useBRoll && rough.dubLanguage == nil)
        }
    }

    @Test("Pause-enabled random transitions are stable between rough cut and Generate")
    func stablePauseJoins() {
        let plan = Fixtures.plan(clips: (0..<12).map { Fixtures.planClip(start: Double($0), end: Double($0 + 4)) })
        var final = options()
        final.transitionChoice = WizardPlanRules.randomTransitionChoice
        final.allowedTransitions = ["fade", "wipeleft", "cut"]
        let first = WizardStrikePauses.renderTransitions(plan: plan, options: final)
        let rough = WizardRoughCut.options(final)
        let original = WizardRoughCut.pauseEligibilityOptions(final, extras: .init(), oneReel: false)
        #expect(WizardStrikePauses.renderTransitions(plan: plan,
            options: WizardStrikePauses.eligibilityOptions(rough, original: original)) == first)
        #expect(first.count == 11 && Set(first) == Set(["fade", "wipeleft"]))
        let combined = WizardRoughCut.pauseEligibilityOptions(options(), extras: .init(), oneReel: true)
        #expect(combined.allowedTransitions == ["cut"])
    }

    @Test("Accepted minimum holds survive layered segmentation at every boundary", arguments: [0.5, 1.0, 2.0])
    func minimumHoldSegments(speed: Double) throws {
        let scene = Fixtures.scene(start: 0, end: 20)
        var clip = Fixtures.planClip(start: 0, end: 20)
        clip.speed = speed
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        var settings = options()
        settings.strikeImpactFreeze = 0.05
        let prepared = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4, 8, 12]],
            options: settings, xfadeDuration: 0.5)
        let document = try #require(prepared.cuts[0])
        let segments = MultitrackRenderer.buildLayeredSegments(MultitrackRenderer.resolveClips(document: document, scenes: [scene]))
        #expect(segments.filter { $0.clips.contains(where: \.hold) }.count == 3)
        #expect(abs(segments.reduce(0) { $0 + $1.duration } - (20 / speed + 0.15)) < 1e-9)
    }

    @Test("Preview uses affordable joins and outgoing transitions beside holds")
    func resolvedPreviewJoins() throws {
        let scene = Fixtures.scene(start: 0, end: 20)
        let head = Fixtures.timelineClip(sourceStart: 0, duration: 4)
        var hold = Fixtures.timelineClip(sourceStart: 4, duration: 0.8, startTime: 4)
        hold.hold = true
        hold.sourceEnd = 4
        var tail = Fixtures.timelineClip(sourceStart: 4, duration: 2, startTime: 4.8)
        tail.transOut = "fade"
        let next = Fixtures.timelineClip(sourceStart: 10, duration: 1, startTime: 6.8)
        let document = Fixtures.timelineDocument(clips: [head, hold, tail, next])
        let take = WizardSelectionTake(id: 11, selectionID: 5, ordinal: 1, note: nil, plan: Fixtures.plan(),
            sceneIDs: [scene.id], proxyPath: nil, criticScore: nil, criticNotes: nil, provenance: nil, createdAt: nil)
        let preview = WizardPreviewClips.rendered(document, take: take, name: "Fight", scenes: [scene], xfadeDuration: 0.5)
        #expect(abs(try #require(preview.last?.outputStart) - 6.4) < 1e-9)
        #expect(WizardPreviewClips.moment(in: preview, at: 6.35)?.clipID == "take-11-2")
        #expect(abs(try #require(WizardPreviewClips.moment(in: preview, at: 6.5)?.time) - 10.1) < 1e-9)
        #expect(abs(RoughCut.plannedDuration(of: preview) - 7.4) < 1e-9)
        var tiny = next
        tiny.duration = 0.1
        tiny.sourceEnd = 10.1
        let fallback = WizardPreviewClips.rendered(Fixtures.timelineDocument(clips: [head, hold, tail, tiny]),
            take: take, name: "Fight", scenes: [scene], xfadeDuration: 0.5)
        #expect(abs(try #require(fallback.last?.outputStart) - 6.8) < 1e-9,
                "An unaffordable crossfade falls back to a hard cut, as the renderer does")
    }

    @Test("Automatic B-roll rejects only eligible source types, tags and speeds")
    func automaticBRollEligibility() throws {
        var scene = Fixtures.scene(start: 0, end: 10)
        var clip = Fixtures.planClip(start: 0, end: 10)
        var settings = options()
        settings.useBRoll = true
        settings.brollInstructions = "Show reactions"
        #expect(!WizardPodcastBRoll.eligibleSource(type: .fight, scene: scene, start: 0, end: 10, speed: 1))
        for type: VideoType in [.podcast, .interview] {
            #expect(WizardPodcastBRoll.eligibleSource(type: type, scene: scene, start: 0, end: 10, speed: 1))
        }
        for tagged in [false, true] {
            scene.tags = tagged ? ["podcast"] : ["fight"]
            for speed in [1.0, 2.0] {
                clip.speed = speed
                let map = [scene.id: scene]
                let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
                let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
                    sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [4]], options: settings, xfadeDuration: 0.5)
                #expect((result.timings[0]?.pauses.isEmpty == true) == (tagged && speed == 1))
            }
        }
    }

    @Test("Filtered contacts get one count per clip, deduplicated across the run")
    func filteredContactLogging() async throws {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let map = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        for contacts in [[-1.0, 0.1, 11.0], [0.1] + (1...9).map(Double.init)] {
            let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: contacts], options: options(), xfadeDuration: 0.5)
            let count = contacts.count == 3 ? 1 : 2
            #expect(result.messages == ["Pause on contact: clip 1 — skipped \(count) contact(s) (spacing or limit)."])
            let snapshot = WizardStrikeHighlightSnapshot()
            let message = try #require(result.messages.first)
            #expect(await snapshot.shouldLogPauseSkip(message))
            #expect(await !snapshot.shouldLogPauseSkip(message))
        }
    }

    @Test("Forbidden pauses do not request marking; Action overlays still do")
    func markingPreflight() {
        let scene = Fixtures.scene(start: 0, end: 10)
        let clip = Fixtures.planClip(start: 0, end: 10)
        let plan = Fixtures.plan(clips: [clip])
        let map = [scene.id: scene]
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: map, settings: .init(), framingPlan: nil)
        for mode in ["dub", "bumper", "composed", "allowed"] {
            var settings = options()
            settings.dubLanguage = mode == "dub" ? "pt" : nil
            settings.includeIntroBumper = mode == "bumper"
            var candidate = plan
            candidate.clips[0].layout = mode == "composed" ? "Two areas" : nil
            let paths = WizardStrikePauses.contactPaths(plan: candidate, cuts: [0: cut], sceneMap: map,
                sourceTypes: [scene.videoID: .fight], options: settings)
            #expect(paths.isEmpty == (mode != "allowed" && mode != "composed"))
            for overlays in [false, true] {
                WizardStrikeHighlights.apply(to: &cut, enabled: overlays, sourceTypes: [scene.videoPath: .fight])
                let marked = WizardStrikeHighlights.sourcePaths(in: [cut]).union(paths)
                #expect(marked.isEmpty == (!overlays && mode != "allowed" && mode != "composed"))
            }
        }
    }

}
