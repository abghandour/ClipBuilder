import Foundation
import Testing
@testable import Clip_Builder

@Suite("Staying figure transitions")
struct TelestrationTransitionTests {
    @Test func everyOfferedName() {
        let blended = ["fade", "dissolve", "fadeblack", "fadewhite", "flash_white", "flash_black"]
        let cut = ["wipeleft", "wiperight", "wipeup", "wipedown",
            "slideleft", "slideright", "circlecrop", "circleopen", "circleclose", "radial",
            "smoothleft", "smoothright", "diagtl", "diagbr", "horzopen", "horzclose",
            "vertopen", "vertclose", "hlslice", "hrslice", "zoomin", "coverleft", "coverright",
            "revealleft", "revealright", "pixelize", "knife_slash",
            "zoom_punch", "whip_left", "whip_right", "impact_shake", "glitch", "speed_ramp"]
        #expect(Set(blended + cut) == Set(RenderEngine.allTransitions))
        for name in blended { #expect(!TelestrationTransition.requiresCut(name)) }
        for name in cut { #expect(TelestrationTransition.requiresCut(name)) }
        #expect(!TelestrationTransition.requiresCut(nil))
        #expect(!TelestrationTransition.requiresCut("cut"))
        #expect(TelestrationTransition.requiresCut("unknown"))
    }

    @Test func savedTransitionReturnsWithoutStay() {
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        doc.videoTrack[1].transIn = "slideleft"
        let resolve = { MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: [])) }
        #expect(resolve().transitions == ["cut"])
        #expect(TelestrationTransition.notice(document: doc, scenes: [], clipID: doc.videoTrack[1].uid, entering: true))
        #expect(TelestrationTransition.notice(document: doc, scenes: [], clipID: doc.videoTrack[0].uid, entering: false))
        #expect(doc.videoTrack[1].transIn == "slideleft")
        doc.videoTrack[0].telestration?.figures[0].linger = 0
        #expect(resolve().transitions == ["slideleft"])
        #expect(!TelestrationTransition.notice(document: doc, scenes: [], clipID: doc.videoTrack[1].uid, entering: true))
        doc.videoTrack[0].telestration = nil
        #expect(resolve().transitions == ["slideleft"])
    }

    @Test func fadingSidesAgree() throws {
        let drawing = Telestration(figures: [.init(linger: 0.15)], fade: 0.2)
        let start = drawing.duration - 0.3
        for elapsed in [0.0, 0.05, 0.1, 0.16, 0.25] {
            let outgoing = TelestrationTransition.state(drawing, at: start + elapsed, overlapStart: start)
            let incoming = TelestrationRules.lingerState(of: drawing, at: elapsed)
            #expect(outgoing.figures.count == incoming.figures.count)
            if let a = outgoing.figures.first, let b = incoming.figures.first {
                #expect(abs(a.opacity - b.opacity) < 1e-8)
                #expect(a.progress == b.progress)
            }
        }
    }

    @Test(arguments: ["slideleft", "fade"])
    func higherTrackStayControlsSharedJoin(name: String) throws {
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        for i in doc.videoTrack.indices { doc.videoTrack[i].track = 1 }
        var companion = doc.videoTrack
        for i in companion.indices {
            companion[i].uid = UUID()
            companion[i].track = 0
            companion[i].telestration = nil
        }
        companion[1].transIn = name
        doc.videoTrack += companion
        let planned = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: []))
        #expect(planned.transitions == [name == "fade" ? "fade" : "cut"])
        #expect(TelestrationTransition.notice(document: doc, scenes: [], clipID: companion[1].uid, entering: true) == (name != "fade"))
        let synced = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions, timed: true, duration: 0.35)
        let drawn = try #require(synced.first?.clips.first { $0.track == 1 })
        let plain = try #require(synced.first?.clips.first { $0.track == 0 })
        #expect((drawn.stayTransitionStart != nil) == (name == "fade"))
        #expect(plain.stayTransitionStart == nil)
        #expect(companion[1].transIn == name)
    }

    @Test func outgoingRecipeShortensDissolve() throws {
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        doc.videoTrack[1].duration = 1
        doc.videoTrack[1].transIn = "fade"
        var next = doc.videoTrack[1]
        next.uid = UUID()
        next.startTime += next.duration
        next.sourceStart = 1
        next.duration = 2
        next.transIn = "speed_ramp"
        doc.videoTrack.append(next)
        let planned = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: []))
        let overlaps = RenderEngine.crossfadeOverlaps(durations: planned.segments.map(\.duration),
            transitions: planned.transitions, transitionDuration: 0.35, applyingRecipeTrims: true)
        // speed_ramp removes 0.5 s of the one-second continuation; assembly
        // can crossfade only 40% of that remainder (0.2 s, not 0.35 s).
        let expected = try RenderEngine.resolvedGaps(durations: [doc.videoTrack[0].duration, 0.5],
            transitions: ["fade"], configured: 0.35, maximumOverlap: nil)
        let overlap = try #require(overlaps[0])
        #expect(abs(overlap - expected[0].duration) < 1e-9)
        #expect(overlaps[1] == nil)
        let synced = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions, timed: false, duration: 0.35)
        let start = try #require(synced[0].clips[0].stayTransitionStart)
        #expect(abs(start - (doc.videoTrack[0].duration - 0.2)) < 1e-9)
    }

    @Test func windowEndingInsideOverlapKeepsFullStrengthClock() throws {
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"), linger: 0.2)
        doc.videoTrack[1].transIn = "fade"
        let join = doc.videoTrack[0].duration
        let planned = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: []))
        let full = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions, timed: true, duration: 0.35)
        let start = try #require(full[0].clips[0].stayTransitionStart)
        let window = MultitrackRenderer.windowed(doc, scenes: [], from: join - 0.3, to: join - 0.1)
        #expect(window.document.videoTrack.count == 1)
        #expect(window.stayTransitions[doc.videoTrack[0].uid] == start)
        let nested = MultitrackRenderer.windowed(window.document, scenes: [], stayTransitions: window.stayTransitions, from: 0.05, to: 0.15)
        let pieces = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: nested.document, scenes: []))
        let synced = TelestrationTransition.synchronize(pieces.segments, transitions: pieces.transitions, timed: true,
            duration: 0.35, context: nested.stayTransitions)
        let hold = try #require(synced.first?.clips.first)
        let drawing = try #require(hold.telestration)
        let actual = TelestrationTransition.state(drawing, at: drawing.offset ?? 0, overlapStart: hold.stayTransitionStart)
        let reference = TelestrationTransition.state(try #require(doc.videoTrack[0].telestration), at: join - 0.25, overlapStart: start)
        let actualOpacity = try #require(actual.figures.first?.opacity)
        let referenceOpacity = try #require(reference.figures.first?.opacity)
        #expect(abs(actualOpacity - referenceOpacity) < 1e-9)
    }

    @Test func ordinaryOverlapTimingAndNoStayKeysRemainUnchanged() throws {
        let durations = [0.7, 0.3, 2.0]
        let transitions = ["fade", "flash_white"]
        let expected = try RenderEngine.resolvedGaps(durations: durations, transitions: transitions,
            configured: 0.35, maximumOverlap: nil)
        let actual = RenderEngine.crossfadeOverlaps(durations: durations, transitions: transitions.map { $0 }, transitionDuration: 0.35)
        #expect(actual[0] == expected[0].duration && actual[1] == expected[1].duration)
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"), linger: nil)
        doc.videoTrack[1].transIn = "slideleft"
        let planned = MultitrackRenderer.plannedSegments(MultitrackRenderer.resolveClips(document: doc, scenes: []))
        let synced = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions, timed: true, duration: 0.35)
        #expect(planned.transitions == ["slideleft"])
        #expect(try RenderSegmentCache.key(planned.segments.flatMap(\.clips)) == RenderSegmentCache.key(synced.flatMap(\.clips)))
        #expect(synced.flatMap(\.clips).allSatisfy { $0.stayTransitionStart == nil })
        #expect(MultitrackRenderer.windowed(doc, scenes: [], from: 0.5, to: 1).stayTransitions.isEmpty)
    }

    @Test(arguments: ["slideleft", "fade"])
    func laterPlainHoldUsesCarriedStay(name: String) throws {
        var doc = StayRenderFixture.document(source: URL(fileURLWithPath: "/tmp/fixture.mp4"), linger: 1.5)
        doc.videoTrack[1].sourceEnd = (doc.videoTrack[1].sourceStart ?? 0) + doc.videoTrack[1].sourceSpan
        let moving = doc.videoTrack[1]
        let paused = try #require(TimelinePauseRules.insert([
            .init(time: moving.startTime + 0.3, duration: 0.8, owner: moving.uid)
        ], into: doc, resolve: { $0 }))
        doc = paused.document
        let holdIndex = try #require(doc.videoTrack.firstIndex { $0.uid == paused.holds[0] })
        let tailIndex = holdIndex + 1
        doc.videoTrack[tailIndex].transIn = name
        let resolved = MultitrackRenderer.resolveClips(document: doc, scenes: [])
        let outgoing = try #require(resolved.first { $0.documentIndex == holdIndex })
        let incoming = try #require(resolved.first { $0.documentIndex == tailIndex })
        #expect(outgoing.stayHoldID == nil && outgoing.lingeringHold != nil)
        #expect(TelestrationTransition.crosses(outgoing: outgoing, incoming: incoming, at: incoming.startTime))
        #expect(TelestrationTransition.notice(document: doc, scenes: [], clipID: doc.videoTrack[tailIndex].uid,
            entering: true) == (name == "slideleft"))
        let planned = MultitrackRenderer.plannedSegments(resolved)
        #expect(planned.transitions.last == (name == "fade" ? "fade" : "cut"))
        let synced = TelestrationTransition.synchronize(planned.segments, transitions: planned.transitions,
            timed: true, duration: 0.35)
        let held = try #require(synced.flatMap(\.clips).first { $0.documentIndex == holdIndex })
        #expect((held.stayTransitionStart != nil) == (name == "fade"))
        if name == "fade" {
            let start = try #require(held.stayTransitionStart)
            let window = MultitrackRenderer.windowed(doc, scenes: [], from: outgoing.startTime + 0.6, to: incoming.startTime - 0.05)
            #expect(abs(try #require(window.stayTransitions[paused.holds[0]]) - (start - 0.6)) < 1e-9)
            let nested = MultitrackRenderer.windowed(window.document, scenes: [], lingering: window.lingering,
                lingerHolds: window.lingerHolds, stayTransitions: window.stayTransitions, from: 0.05, to: 0.1)
            #expect(abs(try #require(nested.stayTransitions[paused.holds[0]]) - (start - 0.65)) < 1e-9)
        }
    }

    @Test func carriedStayAdvancesOnlyDuringDissolve() {
        let drawing = Telestration(figures: [.init(linger: 1.5)])
        let frames = TelestrationBurn.lingerFrameTimes(drawing, offset: 0.3, duration: 0.8,
            speed: 1, paused: true, overlapStart: 0.5)
        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.elapsed - (0.3 + max(0, Double(index) / 30 - 0.5))) < 1e-9)
            #expect(frame.sourceOffset == 0)
        }
    }

}
