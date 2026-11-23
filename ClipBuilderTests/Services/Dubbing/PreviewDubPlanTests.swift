import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder live dub plan")
struct PreviewDubPlanTests {
    @Test("Replacement follows the source, never the bumper's overlapping time range")
    func replacementBeforeAssembly() throws {
        var document = document()
        document.dub?.replaceOriginal = true
        #expect(DubSourceEnvelope.replacesFootageBeforeAssembly(document))
        let plan = PreviewDubPlan.make(document: document)
        let footage = PreviewDubPlan.ramps(plan: plan, within: 4.8..<6.2, volume: 1, bumper: false)
        #expect(footage.allSatisfy { abs($0.from) < 1e-9 && abs($0.to) < 1e-9 })
        let bumper = PreviewDubPlan.ramps(plan: plan, within: 5..<6, volume: 1, bumper: true)
        #expect(bumper.allSatisfy { abs($0.from - 0.2) < 1e-9 && abs($0.to - 0.2) < 1e-9 })
        let settings = try #require(document.dub)
        let lines = document.dubLines ?? []
        let mixed = DubMixer.overlayFilter(lines: lines, settings: settings,
            freezes: DubFreezes.intervals(in: document), bumpers: [5..<6], sourceAlreadyReplaced: true)
        var duckOnly = settings; duckOnly.replaceOriginal = false
        let expected = DubMixer.overlayFilter(lines: lines, settings: duckOnly, freezes: DubFreezes.intervals(in: document))
        #expect(mixed == expected)
        document.videoTrack.removeAll(where: \.bumper)
        #expect(!DubSourceEnvelope.replacesFootageBeforeAssembly(document))
        let unchanged = DubMixer.overlayFilter(lines: lines, settings: settings)
        #expect(unchanged == "[0:a]volume='0.0':eval=frame[orig];[orig][1:a]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]")
        document.dubLines = nil
        #expect(!DubSourceEnvelope.replacesFootageBeforeAssembly(document))
    }

    private func document() -> TimelineDocument {
        let clip = Fixtures.timelineClip(sceneID: nil, duration: 10)
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 2)
        hold.hold = true; hold.pauseGroup = hold.uid
        var bumper = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 5)
        bumper.bumper = true
        var document = Fixtures.timelineDocument(clips: [clip, hold, bumper])
        document.dub = DubSettings(language: "en", originalLevel: 0.2, replaceOriginal: false)
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "a", voice: "v", text: "Speech",
            sourceStart: 0, sourceEnd: 6, start: 0, duration: 6, rate: 1.2, stretch: 1.1, audio: "a.caf")]
        return document
    }

    @Test(arguments: ["plain", "freeze", "overlap"])
    func liveUsesExportEnvelope(kind: String) throws {
        var document = document()
        if kind != "freeze" { document.videoTrack.removeAll { $0.hold == true } }
        if kind == "overlap", var line = document.dubLines?.first {
            line.id = UUID(); line.start = 6.05; line.duration = 1
            document.dubLines?.append(line)
        }
        let freezes = DubFreezes.intervals(in: document)
        let export = DubSourceEnvelope.ranges(lines: document.dubLines ?? [], freezes: freezes)
        let live = PreviewDubPlan.make(document: document)
        #expect(live.envelopes == export)
        let ramps = PreviewDubPlan.ramps(plan: live, within: 0..<10, volume: 1)
        for ramp in ramps {
            let time = (ramp.start + ramp.end) / 2
            let expected = 1 - 0.8 * (export.map { $0.amount(at: time) }.max() ?? 0)
            #expect(abs((ramp.from + ramp.to) / 2 - expected) < 1e-9)
        }
        let settings = try #require(document.dub)
        let filter = DubMixer.overlayFilter(lines: document.dubLines ?? [], settings: settings, freezes: freezes)
        let expression = DubPlanning.duckExpression(lines: document.dubLines ?? [], level: 0.2, ramp: 0.15, freezes: freezes)
        #expect(filter.contains("volume='" + expression + "'"))
    }

    @Test("Freezes stop audio; speech continues over bumpers; synthesis rate is not applied twice")
    func blocks() {
        let plan = PreviewDubPlan.make(document: document())
        #expect(plan.blocks.count == 2)
        for (actual, expected) in zip(plan.blocks.map(\.start), [0.0, 3.0]) { #expect(abs(actual - expected) < 1e-9) }
        for (actual, expected) in zip(plan.blocks.map(\.duration), [2.0, 4.0]) { #expect(abs(actual - expected) < 1e-9) }
        for (actual, expected) in zip(plan.blocks.map(\.sourceStart), [0.0, 2.2]) { #expect(abs(actual - expected) < 1e-9) }
        #expect(plan.blocks.allSatisfy { abs($0.stretch - 1.1) < 1e-9 })
        #expect(abs(plan.blocks[0].fadeOut - 0.01) < 1e-9)
        #expect(abs(plan.blocks[1].fadeIn - 0.01) < 1e-9)
        let expected: [Range<Double>] = [(-0.15)..<2, 3..<7.15]
        #expect(plan.duckRanges == expected)
        #expect(abs(plan.originalLevel - 0.2) < 1e-9)
    }

    @Test("Unprepared, missing, disabled and toggle-off lines add nothing")
    func absentAudio() {
        var document = document()
        #expect(PreviewDubPlan.make(document: document, enabled: false) == .empty)
        #expect(PreviewDubPlan.make(document: document, missingAudio: ["a.caf"]) == .empty)
        document.dubLines?[0].audio = nil
        #expect(PreviewDubPlan.make(document: document) == .empty)
        document.dubLines = nil
        #expect(PreviewDubPlan.make(document: document) == .empty)
        document = self.document()
        document.dub?.enabled = false
        #expect(PreviewDubPlan.make(document: document) == .empty)
    }

    @Test("Overlapping voices share one duck envelope, clipped with continuous gain at video boundaries")
    func ducking() throws {
        var document = document()
        var second = try #require(document.dubLines?.first)
        second.id = UUID(); second.start = 1; second.duration = 1
        document.dubLines?.append(second)
        let plan = PreviewDubPlan.make(document: document)
        let ramps = PreviewDubPlan.ramps(plan: plan, within: 0.02..<1, volume: 0.5)
        let first = try #require(ramps.first), last = try #require(ramps.last)
        #expect(abs(first.from - 0.1) < 1e-9)
        #expect(abs(first.to - 0.1) < 1e-9)
        #expect(abs(last.end - 1) < 1e-9 && abs(last.to - 0.1) < 1e-9)
        let gap = PreviewDubPlan.ramps(plan: plan, within: 2.2..<2.9, volume: 1)
        #expect(gap.allSatisfy { abs($0.from - 1) < 1e-9 && abs($0.to - 1) < 1e-9 })
    }

    @Test("Replace original mutes continuously; bumper audio is ducked while speech continues")
    func replacement() throws {
        var document = document()
        document.dub?.replaceOriginal = true
        var missing = try #require(document.dubLines?.first)
        missing.id = UUID(); missing.start = 8; missing.duration = 1; missing.audio = nil
        document.dubLines?.append(missing)
        let plan = PreviewDubPlan.make(document: document)
        let expected: [Range<Double>] = [0..<5, 6..<10]
        #expect(abs(plan.originalLevel - 0.2) < 1e-9)
        #expect(plan.duckRanges == expected)
        let replaced = PreviewDubPlan.ramps(plan: plan, within: 8.1..<8.9, volume: 1)
        #expect(replaced.allSatisfy { abs($0.from) < 1e-9 && abs($0.to) < 1e-9 })
        let bumper = PreviewDubPlan.ramps(plan: plan, within: 5.1..<5.9, volume: 1)
        #expect(bumper.allSatisfy { abs($0.from - 0.2) < 1e-9 && abs($0.to - 0.2) < 1e-9 })
        let ends = PreviewDubPlan.ramps(plan: plan, within: 9.9..<10, volume: 1)
        #expect(ends.allSatisfy { abs($0.from) < 1e-9 && abs($0.to) < 1e-9 })
    }
}
