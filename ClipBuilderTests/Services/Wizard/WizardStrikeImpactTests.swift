import Foundation
import Testing
@testable import Clip_Builder

@Suite("Wizard strike impacts")
struct WizardStrikeImpactTests {
    private func options() -> WizardOptions {
        var value = WizardOptions()
        value.strikeSlowMotion = "medium"
        value.strikeFlash = true
        value.useBRoll = false
        value.includeOutro = false
        value.includeIntroBumper = false
        value.includeOutroBumper = false
        value.includeMiddleBumper = false
        value.framing = Framing(subject: .original)
        return value
    }

    @Test(arguments: [false, true])
    func timingLayersAndVoice(pauses: Bool) throws {
        let scene = Fixtures.scene(start: 0, end: 4)
        let clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 4)
        let scenes = [scene.id: scene]
        var cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        cut.textOverlays = [TextOverlayItem(text: "In stretch", startTime: 1.6, endTime: 1.9)]
        cut.imageOverlays = [ImageOverlayItem(path: "/tmp/overlay.png")]
        cut.imageOverlays[0].startTime = 1.6
        cut.imageOverlays[0].endTime = 1.9
        cut.imageOverlays[0].track = [.init(time: 0, xFrac: 0, yFrac: 0, wFrac: 0.1),
                                    .init(time: 4, xFrac: 0.8, yFrac: 0, wFrac: 0.1)]
        cut.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 4)]
        cut.soundTrack = [SoundItem(name: "music", startTime: 1.6, duration: 0.3)]
        var block = OverlayBlockItem()
        block.startTime = 1
        block.duration = 2
        block.composition.texts = [TextOverlayItem(text: "Local", startTime: 0.6, endTime: 0.9)]
        cut.overlayBlocks = [block]
        var settings = options()
        settings.strikeImpactFreeze = pauses ? 0.8 : nil
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]], options: settings, xfadeDuration: 0.3)
        let timing = try #require(result.timings[0])
        #expect(abs(timing.outputDuration - (4.75 + (pauses ? 0.8 : 0))) < 1e-9)
        #expect(abs(timing.outputTime(1.6) - 1.75) < 1e-9)
        #expect(abs(timing.outputTime(1.9) - 2.5) < 1e-9)
        let status = StrikeClipStatusRules.status(index: 0, plan: Fixtures.plan(clips: [clip]), scene: scene,
            sourceType: .fight, saved: .init(contacts: [2]), options: settings, xfadeDuration: 0.3,
            cut: cut)
        #expect(abs(status.slowAddedDuration - 0.75) < 1e-9)
        #expect(status.flashes == 1 && status.hasPause == pauses)
        #expect(status.line.contains("slow motion") && status.line.contains("1 flash"))
        let captions = timing.captions([.init(raster: .init(text: "In stretch", activeIndex: nil),
            position: "bottom", start: 1.6, end: 1.9)])
        #expect(abs(try #require(captions.first).start - 1.75) < 1e-9)
        #expect(abs(try #require(captions.first).end - 2.5) < 1e-9)
        #expect(abs(timing.plannedTime(forOutput: 2.5) - 1.9) < 1e-8)
        let output = try #require(result.cuts[0])
        #expect(abs(output.textOverlays[0].startTime - 1.75) < 1e-9)
        #expect(abs(output.imageOverlays[0].endTime - 2.5) < 1e-9)
        let keys = try #require(output.imageOverlays[0].track)
        #expect(abs(try #require(ImageTrackKey.interpolate(keys, at: 2.5)).xFrac - 0.38) < 1e-9)
        #expect(abs(output.overlayBlocks[0].composition.texts[0].startTime - 0.75) < 1e-9)
        #expect(abs(output.overlayBlocks[0].composition.texts[0].endTime - 1.5) < 1e-9)
        #expect(abs(output.soundTrack[0].duration - 0.75) < 1e-9)
        #expect(abs(output.cropBlocks[0].duration - timing.outputDuration) < 1e-9)
        let flash = try #require(output.videoTrack.first { $0.flashIn != nil })
        #expect(abs(flash.startTime - 2.75) < 1e-9)
        #expect((flash.hold == true) == pauses)
        let voice = VoiceOverPlacement.Cut(videoID: scene.videoID, sourceStart: 0, sourceEnd: 4,
            reelStart: 0, reelDuration: timing.outputDuration, pauses: timing.pauses, stretches: timing.stretches)
        #expect(abs(voice.localTime(ofSource: 1.9) - 2.5) < 1e-9)
        if pauses {
            #expect(abs(try #require(voice.localTime(inHoldOn: 2, offset: 0.3)) - 3.05) < 1e-9)
            #expect(abs(timing.plannedTime(forOutput: 3.05) - 2) < 1e-9)
        }
        var plainOptions = settings
        plainOptions.strikeSlowMotion = nil
        plainOptions.strikeFlash = nil
        let plain = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]], options: plainOptions, xfadeDuration: 0.3)
        if !pauses { #expect(plain.cuts[0] == cut && plain.messages.isEmpty) }
        #expect(abs(try #require(plain.timings[0]).outputDuration - (pauses ? 4.8 : 4)) < 1e-9)
    }

    @Test func speedFloorKeepsFlashAndCountsSkippedContact() throws {
        let scene = Fixtures.scene(start: 0, end: 4)
        var clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 4)
        clip.speed = 0.5
        let scenes = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        let result = WizardStrikePauses.prepare(plan: Fixtures.plan(clips: [clip]), cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]], options: options(), xfadeDuration: 0.3)
        let timing = try #require(result.timings[0])
        #expect(timing.stretches.isEmpty && timing.filteredSlowContacts == 1)
        #expect(abs(timing.outputDuration - 8) < 1e-9)
        #expect(result.cuts[0]?.videoTrack.contains { $0.flashIn != nil } == true)
        // Without a pause the pieces still ask for assembly on the planned clock.
        let track = try #require(result.cuts[0]?.videoTrack)
        #expect(track.count > 1 && track.allSatisfy { $0.timedAssembly == true && $0.strikeImpactsFrozen != true })
        #expect(MultitrackRenderer.usesTimedAssembly(try #require(result.cuts[0]), transitions: []))
        // A strength this version does not know plays as medium everywhere.
        var unknown = WizardOptions()
        unknown.strikeSlowMotion = "bogus"
        #expect(WizardStrikePauses.impactRequested(unknown))
        #expect(result.messages.contains { $0.contains("speed below 0.25×") })
    }

    @Test func joinsUseTheActualFirstAndLastPieces() throws {
        let scene = Fixtures.scene(start: 0, end: 4)
        let clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 4)
        let scenes = [scene.id: scene]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        var plan = Fixtures.plan(clips: [clip, clip])
        plan.transitions = ["fade"]
        let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut, 1: cut], sceneMap: scenes,
            sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [0.75]], options: options(), xfadeDuration: 0.35)
        #expect(abs(try #require(result.timings[1]?.headSegment) - 0.25) < 1e-9)
        #expect(abs(try #require(result.timings[1]?.tailSegment) - 3.25) < 1e-9)
        #expect(result.joins.transitions == ["cut"])
        #expect(result.joins.changes.count == 1)
    }

    @Test(arguments: [false, true])
    func sharedSlowFlashAndSkipMessages(pauses: Bool) throws {
        let scene = Fixtures.scene(start: 0, end: 4)
        var other = Fixtures.scene(id: 2, start: 10, end: 14)
        other.videoID = 2
        other.videoPath = "/tmp/companion.mp4"
        var clip = Fixtures.planClip(sceneID: scene.id, start: 0, end: 4)
        clip.layout = "Two pictures"
        clip.areaClips = [.init(area: "Other", sceneID: other.id, start: 10, end: 14)]
        let scenes = [scene.id: scene, other.id: other]
        let cut = WizardOrdinaryTimeline.cutDocument(clip: clip, sceneMap: scenes, settings: .init(), framingPlan: nil)
        let plan = Fixtures.plan(clips: [clip])
        var settings = options()
        settings.strikeImpactFreeze = pauses ? 0.8 : nil
        let result = WizardStrikePauses.prepare(plan: plan, cuts: [0: cut], sceneMap: scenes,
            sourceTypes: [scene.videoID: .fight, other.videoID: .fight], contacts: [other.videoPath: [12]],
            options: settings, xfadeDuration: 0.3)
        #expect(result.timings[0]?.stretches.count == 1)
        let timing = try #require(result.timings[0])
        #expect(abs(timing.outputDuration - (4.75 + (pauses ? 0.8 : 0))) < 1e-9)
        #expect(abs(timing.outputTime(1.9) - 2.5) < 1e-9)
        let captions = timing.captions([.init(raster: .init(text: "Contact", activeIndex: nil),
            position: "bottom", start: 1.6, end: 1.9)])
        #expect(abs(try #require(captions.first).start - 1.75) < 1e-9)
        #expect(abs(try #require(captions.first).end - 2.5) < 1e-9)
        let mapped = try #require(result.cuts[0])
        #expect(mapped.videoTrack.allSatisfy { $0.timedAssembly == true })
        #expect(MultitrackRenderer.usesTimedAssembly(mapped, transitions: []))
        let flashes = try #require(result.cuts[0]).videoTrack.filter { $0.flashIn != nil }
        #expect(flashes.count == 2 && flashes.allSatisfy { abs($0.startTime - 2.75) < 1e-9 })
        let status = StrikeClipStatusRules.status(index: 0, plan: plan, scene: scene, sourceType: .fight,
            saved: .init(companionScenes: [other.id: other], companionTypes: [other.videoID: .fight],
                         companionContacts: [other.videoPath: [12]]), options: settings, xfadeDuration: 0.3,
            cut: cut, preparation: result)
        // Both RangeReviewView and WizardPreviewList display this shared row.
        #expect(abs(status.slowAddedDuration - 0.75) < 1e-9)
        #expect(status.flashes == 1 && status.hasPause == pauses)
        #expect(status.line.contains("slow motion") && status.line.contains("1 flash"))
        #expect(status.impactNotes.isEmpty)
        let voice = VoiceOverPlacement.Cut(videoID: scene.videoID, sourceStart: 0, sourceEnd: 4,
            reelStart: 0, reelDuration: timing.outputDuration, pauses: timing.pauses, stretches: timing.stretches)
        #expect(abs(voice.localTime(ofSource: 1.9) - 2.5) < 1e-9)
        for reason in ["dub", "bumper", "cutaway"] {
            var settings = options()
            var input = cut
            if reason == "dub" { settings.dubLanguage = "en" }
            if reason == "bumper" { settings.includeIntroBumper = true }
            if reason == "cutaway" { input.videoTrack[1].role = .cutaway }
            let skipped = WizardStrikePauses.prepare(plan: plan, cuts: [0: input], sceneMap: scenes,
                sourceTypes: [scene.videoID: .fight], contacts: [scene.videoPath: [2]], options: settings, xfadeDuration: 0.3)
            #expect(!skipped.messages.isEmpty)
            #expect(skipped.cuts[0] == input)
            if reason == "dub" { #expect(skipped.messages.contains(WizardStrikePauses.dubSkipMessage)) }
        }
    }
}
