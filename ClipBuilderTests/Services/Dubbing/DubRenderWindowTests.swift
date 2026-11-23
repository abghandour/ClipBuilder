import Foundation
import Testing
@testable import Clip_Builder

@Suite("Dub render window clock")
struct DubRenderWindowTests {
    @Test(arguments: [false, true])
    func emptySpeechWindowRetainsFullPolicy(bumper: Bool) throws {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 4)
        clip.videoFile = "/tmp/source.mp4"
        var document = Fixtures.timelineDocument(clips: [clip])
        if bumper {
            var extra = clip; extra.uid = UUID(); extra.bumper = true
            extra.startTime = 4; extra.duration = 1
            document.videoTrack.append(extra)
        }
        document.dub = DubSettings(language: "en", replaceOriginal: true)
        document.dubLines = [DubLine(clipUID: clip.uid, speakerKey: "host", voice: "v", text: "Early",
            sourceStart: 0, sourceEnd: 0.5, start: 0, duration: 0.5)]
        let window = MultitrackRenderer.windowed(document, from: 2, to: 5)
        #expect(window.dubLines?.isEmpty == true)
        let state = try #require(DubRenderWindow.state(document: document))
        #expect(state.enabled && state.replacementActive)
        #expect(state.frameBounded == bumper)
        #expect(state.replaceBeforeAssembly == bumper)
        let evidence = try #require(DubRenderWindow.evidence(document: document, clock: .identity, lower: 2, upper: 5))
        #expect(evidence.state == state)
        var disabled = document; disabled.dub?.enabled = false
        let other = try #require(DubRenderWindow.evidence(document: disabled, clock: .identity, lower: 2, upper: 5))
        let activeKey = try RenderSegmentCache.key(evidence)
        let disabledKey = try RenderSegmentCache.key(other)
        #expect(activeKey != disabledKey)
    }

    @Test("Removing the bumper keeps bounded recipes and the full replacement route")
    func recipeWindowWithoutBumperRetainsPolicy() throws {
        var head = Fixtures.timelineClip(sceneID: nil, duration: 2)
        head.transIn = "cut"; head.transOut = "cut"
        var tail = head; tail.uid = UUID(); tail.startTime = 2; tail.transIn = "whip_left"
        var bumper = head; bumper.uid = UUID(); bumper.startTime = 4; bumper.bumper = true
        var document = Fixtures.timelineDocument(clips: [head, tail, bumper])
        document.dub = DubSettings(language: "en", replaceOriginal: true)
        document.dubLines = [DubLine(clipUID: head.uid, speakerKey: "host", voice: "fixture", text: "Early",
            sourceStart: 0, sourceEnd: 0.2, start: 0, duration: 0.2)]
        let window = MultitrackRenderer.windowed(document, from: 0.5, to: 4)
        let windowHasBumper = window.videoTrack.contains { $0.bumper }
        #expect(!windowHasBumper)
        #expect(window.dubLines?.isEmpty == true)
        let bounded = try #require(DubRenderWindow.state(document: document))
        #expect(bounded.frameBounded && bounded.replaceBeforeAssembly)
        let boundedEvidence = try #require(DubRenderWindow.evidence(document: document, clock: .identity, lower: 0.5, upper: 4))
        document.videoTrack.removeLast()
        let unbounded = try #require(DubRenderWindow.state(document: document))
        #expect(unbounded.replacementActive && !unbounded.frameBounded && !unbounded.replaceBeforeAssembly)
        let unboundedEvidence = try #require(DubRenderWindow.evidence(document: document, clock: .identity, lower: 0.5, upper: 4))
        let boundedKey = try RenderSegmentCache.key(boundedEvidence)
        let unboundedKey = try RenderSegmentCache.key(unboundedEvidence)
        #expect(boundedKey != unboundedKey)
        document.dubLines = nil
        #expect(DubRenderWindow.state(document: document) == nil)
    }

    @Test("A window after a bumper retains the full speed-ramp bridge clock")
    func recipeAndBumperFullClock() {
        var head = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        head.transIn = "cut"; head.transOut = "cut"
        var tail = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 2, startTime: 2)
        tail.transIn = "speed_ramp"; tail.transOut = "cut"
        var bumper = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 4)
        bumper.bumper = true; bumper.transIn = "cut"; bumper.transOut = "cut"
        var document = Fixtures.timelineDocument(clips: [head, tail, bumper])
        document.dubLines = [DubLine(clipUID: head.uid, speakerKey: "host", voice: "fixture", text: "Event",
            sourceStart: 1.8, sourceEnd: 4.8, start: 1.8, duration: 3)]
        let window = MultitrackRenderer.windowed(document, from: 4.2, to: 5)
        let clock = DubRenderWindow.clock(document: document, window: window, scenes: [], camera: "balanced", lower: 4.2)
        #expect(abs(clock.map(1.8) - 1.62) < 1e-9)
        #expect(abs(clock.map(4.2) - 3.9) < 1e-9)
    }

    @Test("A removed owner can still start speaking after the mapped window begins")
    func overlappingJoinKeepsPositiveDelay() throws {
        let owner = Fixtures.timelineClip(sceneID: nil, duration: 2)
        let incoming = Fixtures.timelineClip(sceneID: nil, duration: 2, startTime: 2)
        var document = Fixtures.timelineDocument(clips: [owner, incoming])
        document.dubLines = [DubLine(clipUID: owner.uid, speakerKey: "host", voice: "fixture", text: "Later",
            sourceStart: 1.8, sourceEnd: 2.3, start: 1.8, duration: 0.5)]
        let clock = RenderClock(segmentStarts: [0, 2], overlaps: [0: 0.5])
        let window = MultitrackRenderer.windowed(document, from: 2, to: 4)
        #expect(!window.videoTrack.contains { $0.uid == owner.uid })
        let lines = try #require(DubRenderWindow.lines(document, clock: clock, lower: 2, upper: 4))
        let line = try #require(lines.first)
        #expect(abs(line.start - 0.3) < 1e-9)
        #expect(abs(line.duration - 0.5) < 1e-9)
    }

    @Test("Dubbed bumper windows share the full document's policy with or without a hold", arguments: [false, true])
    func bumperUsesTheAssemblyClamp(withHold: Bool) throws {
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        first.transIn = "cut"; first.transOut = "cut"
        var bumper = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 1, startTime: 2)
        bumper.bumper = true; bumper.videoFile = "/tmp/bumper.mp4"
        bumper.transIn = "fade"; bumper.transOut = "fade"
        var last = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 2, startTime: 3)
        last.transIn = "fade"; last.transOut = "cut"
        var hold = Fixtures.timelineClip(sceneID: nil, sourceStart: 4, duration: 1, startTime: 5)
        hold.hold = true; hold.pauseGroup = hold.uid; hold.transIn = "cut"; hold.transOut = "cut"
        var doc = Fixtures.timelineDocument(clips: [first, bumper, last, hold])
        if !withHold { doc.videoTrack.removeLast() }
        doc.dub = DubSettings(language: "en-US", replaceOriginal: true)
        doc.dubLines = [DubLine(clipUID: first.uid, speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: 6, start: 0, duration: 6)]
        let window = MultitrackRenderer.windowed(doc, from: 4.5, to: 6.5)
        var transitions = TransitionSettings(); transitions.xfadeDuration = 0.35
        let clock = RenderContext.$transitions.withValue(transitions) {
            DubRenderWindow.clock(document: doc, window: window, scenes: [], camera: "balanced", lower: 4.5)
        }
        let joins = RenderEngine.frameCrossfadeOverlaps(durations: [2, 1, 2, 1],
            transitions: ["fade", "fade", "cut"], transitionDuration: 0.35)
        let expected = RenderClock(segmentStarts: [0, 2, 3, 5], overlaps: joins)
        #expect(abs(clock.map(4.5) - expected.map(4.5)) < 1e-9)
        let short = RenderEngine.frameCrossfadeOverlaps(durations: [2, 0.3, 4],
            transitions: ["fade", "fade"], transitionDuration: 0.35)
        #expect(abs((short[0] ?? 0) - 4.0 / 30) < 1e-9)
        #expect(abs((short[1] ?? 0) - 4.0 / 30) < 1e-9)
        let withoutHold = MultitrackRenderer.windowed(doc, from: 0, to: 4.5)
        let excludedClock = RenderContext.$transitions.withValue(transitions) {
            DubRenderWindow.clock(document: doc, window: withoutHold, scenes: [], camera: "balanced", lower: 0)
        }
        #expect(abs(excludedClock.map(4) - expected.map(4)) < 1e-9)
        #expect(MultitrackRenderer.usesFrameBoundedBumpers(withoutHold, transitions: ["speed_ramp", "fade"]))
        doc.dub = nil
        #expect(MultitrackRenderer.usesFrameBoundedBumpers(doc, transitions: ["fade", "fade"]))
        doc.dubLines = nil
        #expect(!MultitrackRenderer.usesFrameBoundedBumpers(doc, transitions: ["fade", "fade"]))
        let unchanged = DubRenderWindow.clock(document: doc, window: window, scenes: [], camera: "balanced", lower: 4.5)
        #expect(unchanged.isIdentity)
    }

    @Test("Surviving joins use the shorter window's clamp; removed joins remain in cache evidence")
    func plannedWindow() throws {
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        first.transIn = "cut"; first.transOut = "cut"
        var second = Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 4, startTime: 2)
        second.transIn = "fade"; second.transOut = "cut"
        var document = Fixtures.timelineDocument(clips: [first, second])
        document.dubLines = [DubLine(clipUID: first.uid, speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: 4, start: 0, duration: 4)]
        let window = MultitrackRenderer.windowed(document, from: 1, to: 2.5)
        var transitions = TransitionSettings(); transitions.xfadeDuration = 0.5
        let clock = RenderContext.$transitions.withValue(transitions) {
            DubRenderWindow.clock(document: document, window: window, scenes: [], camera: "balanced", lower: 1)
        }
        #expect(abs(clock.map(2) - 1.8) < 1e-9)
        let old = try #require(DubRenderWindow.evidence(document: document, clock: .identity, lower: 4, upper: 6))
        let shifted = try #require(DubRenderWindow.evidence(document: document, clock: clock, lower: 4, upper: 6))
        let oldKey = try RenderSegmentCache.key(old, version: "test")
        let shiftedKey = try RenderSegmentCache.key(shifted, version: "test")
        #expect(oldKey != shiftedKey)
    }

    @Test("A removed join consumes speech on the render clock", arguments: [3.8, 6.0])
    func removedJoin(duration: Double) throws {
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 4)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        document.dubLines = [DubLine(clipUID: UUID(), speakerKey: "host", voice: "fixture", text: "Speech",
            sourceStart: 0, sourceEnd: duration, start: 0, duration: duration)]
        let clock = RenderClock(segmentStarts: [0, 2, 4, 5], overlaps: [0: 0.5])
        let lines = try #require(DubRenderWindow.lines(document, clock: clock, lower: 4.5, upper: 7))
        let line = try #require(lines.first)
        #expect(line.start == -3.5)
        let layout = DubPauseRules.layout(line, freezes: [0..<0.5])
        let resumed = try #require(layout.segments.last)
        #expect(resumed.audioStart == 3.5)
        #expect(resumed.start == 0.5)
        #expect(abs(resumed.duration - (duration - 3.5)) < 1e-9)
    }

    @Test("Recipe ranges use cumulative frame boundaries and preserve the no-recipe clock")
    func recipeRanges() {
        let ranges = RecipeAssemblyClock.ranges(durations: [1.034, 0.223, 1.034, 0.223, 1.034], overlaps: [:])
        #expect(ranges[2].lowerBound == 38.0 / 30)
        #expect(ranges[4].lowerBound == 75.0 / 30)
        #expect(ranges[4].upperBound == 106.0 / 30)
        let joins = JoinOverlaps()
        joins.record(0, 0.5)
        let old = RenderClock(segmentStarts: [0, 2], overlaps: joins.all)
        let same = RenderClock(segmentStarts: [0, 2], segmentEnds: [2, 4], joins: joins)
        #expect(old == same)
        joins.reconcile(1, range: 1.5666666666666667..<3.6)
        let exact = RenderClock(segmentStarts: [0, 2], segmentEnds: [2, 4], joins: joins)
        #expect(abs(exact.map(2) - old.map(2) - 2.0 / 30) < 1e-9)
        #expect(abs(exact.map(3) - exact.map(2) - 1) < 1e-9)
        #expect(exact.map(4, end: true) == 3.6)
    }
}
