import Foundation
import Testing
@testable import Clip_Builder

struct DubPauseRulesTests {
    private func line(start: Double = 1, duration: Double = 4) -> DubLine {
        DubLine(clipUID: UUID(), speakerKey: "host", voice: "fixture", text: "Speech",
                sourceStart: 0, sourceEnd: duration, start: start, duration: duration)
    }

    private func hold(start: Double, duration: Double, group: UUID? = UUID()) -> TimelineClip {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: duration, startTime: start)
        clip.hold = true
        clip.pauseGroup = group
        return clip
    }

    @Test("Only grouped holds freeze speech; overlapping and touching members/groups form one union")
    func freezes() {
        let group = UUID()
        var moving = hold(start: 8, duration: 2); moving.hold = false
        let document = Fixtures.timelineDocument(clips: [
            hold(start: 3, duration: 1, group: group), hold(start: 3.5, duration: 1, group: group),
            hold(start: 4.5, duration: 0.5), hold(start: 6, duration: 1),
            hold(start: 1, duration: 1, group: nil), moving])
        #expect(DubFreezes.intervals(in: document) == [3..<5, 6..<7])
        let clock = RenderClock(segmentStarts: [0, 2, 4, 6], overlaps: [0: 0.5, 1: 0.25])
        #expect(DubFreezes.intervals(in: document, clock: clock) == [2.5..<4.25, 5.25..<6.25])
    }

    @Test("Layout handles first/last instant, starts inside and freezes after speech",
           arguments: [0.5, 1.0, 2.0, 4.99, 5.0, 6.0])
    func edges(time: Double) throws {
        let speech = line()
        let layout = DubPauseRules.layout(speech, freezes: [time..<(time + 1)])
        let expected = time < 5 ? 5 + min(1, time) : 5
        #expect(abs(layout.end - expected) < 1e-9)
        #expect(layout.stopsForFreeze == (time < 5))
        #expect(abs(layout.segments.reduce(0) { $0 + $1.duration } - 4) < 1e-9)
        if time <= 1 {
            #expect(layout.segments.count == 1)
            #expect(abs(try #require(layout.segments.first).start - (time + 1)) < 1e-9)
        }
        #expect(DubPauseRules.layout(speech, freezes: []).segments == [
            .init(audioStart: 0, start: 1, duration: 4, fadeIn: 0, fadeOut: 0)])
    }

    @Test("Two freezes, including one beyond the original end, consume no audio")
    func twoFreezes() {
        let speech = line()
        let layout = DubPauseRules.layout(speech, freezes: [2..<4, 6..<7])
        #expect(layout.segments.map(\.audioStart) == [0, 1, 3])
        #expect(layout.segments.map(\.start) == [1, 4, 7])
        #expect(layout.segments.map(\.duration) == [1, 2, 1])
        #expect(layout.segments.map(\.fadeIn) == [0, 0.01, 0.01])
        #expect(layout.segments.map(\.fadeOut) == [0.01, 0.01, 0])
        #expect(layout.end == 8 && speech.timelineDuration(freezes: [2..<4, 6..<7]) == 7)
    }

    @Test("Insertion moves starts at or after the exact boundary; no 20 ms edge rule",
           arguments: [2.99, 3.0, 3.01])
    func movingStarts(start: Double) throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 10)
        var document = Fixtures.timelineDocument(clips: [clip])
        var original = line(start: start); original.clipUID = clip.uid
        document.dubLines = [original]
        let inserted = try #require(TimelinePauseRules.insert([.init(time: 3, duration: 1, owner: clip.uid)],
            into: document, resolve: { $0 }))
        let speech = try #require(inserted.document.dubLines?.first)
        #expect(abs(speech.start - (start >= 3 ? start + 1 : start)) < 1e-9)
        let owner = try #require(inserted.document.videoTrack.first { $0.uid == speech.clipUID })
        #expect(start < 3 ? owner.startTime == 0 : owner.startTime == 4)
        #expect(DubPauseRules.layout(speech, freezes: DubFreezes.intervals(in: inserted.document)).stopsForFreeze == (start < 3))
        let removed = try #require(TimelinePauseRules.removed(group: inserted.holds[0], in: inserted.document))
        #expect(abs(try #require(removed.dubLines?.first).start - start) < 1e-9)
    }

    @Test("Slots and overlap checks remove freeze time, including a freeze after a planned line")
    func motionPlanning() async throws {
        let freezes = [2.0..<5.0]
        #expect(DubPlanning.slot(for: line(start: 1, duration: 1), next: line(start: 5), freezes: freezes) == 1)
        #expect(DubPlanning.slot(for: line(start: 1, duration: 3), next: line(start: 7), freezes: freezes) == 3)
        #expect(DubFreezes.motionTime(4, freezes: freezes) == 2)
        #expect(DubFreezes.timelineTime(2, freezes: freezes) == 5)
        var first = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2)
        first.videoFile = "/fixture.mp4"
        var tail = first; tail.uid = UUID(); tail.startTime = 5; tail.sourceStart = 2; tail.sourceEnd = 5; tail.duration = 3
        let document = Fixtures.timelineDocument(clips: [first, hold(start: 2, duration: 3), tail])
        func row(_ start: Double, _ end: Double) -> TranscriptRow {
            TranscriptRow(id: 1, videoID: 7, language: "en-US", isTranslation: true,
                startTime: start, endTime: end, text: "one two", originalText: nil, wordsJSON: nil, provider: nil, model: nil)
        }
        let settings = DubSettings(language: "en-US")
        let planned = DubPlanning.lines(document: document, rows: [first.uid: [row(1, 2)], tail.uid: [row(2, 4)]],
            turns: [:], settings: settings)
        #expect(planned.map(\.start) == [1, 5] && planned.allSatisfy { !$0.tight })
        #expect(DubPlanning.slot(for: planned[0], next: planned[1], freezes: freezes) == 1)
        var across = line(start: 1, duration: 3); across.clipUID = first.uid
        let reopened = await DubPreparation.reopening(document: document, scenes: [], settings: settings,
            lines: [across, line(start: 7)], speakerNames: [:])
        #expect(reopened.slots[across.id] == 3)
        #expect(!reopened.overlaps.contains(across.id))
        let stub = DubPreparation.Speech(voices: { _ in [.init(identifier: "fixture", language: "en-US", name: "Fixture")] },
            synthesize: { _, _, _ in URL(fileURLWithPath: "/tmp/dub-refit.caf") }, duration: { _ in 3 })
        let fitted = try await DubPreparation.fit(across, slot: 3, overlapping: false, speech: stub)
        #expect(fitted.rate == 1 && fitted.stretch == 1 && !fitted.tight)
        #expect(DubPauseRules.layout(fitted, freezes: freezes).end == 7)
        let prepared = try await DubPreparation.synthesize(document: document,
            rows: [first.uid: [row(1, 2)], tail.uid: [row(2, 4)]], turns: [:], settings: settings, speech: stub)
        #expect(prepared.slots[prepared.lines[0].id] == 1)
        #expect(DubPauseRules.layout(prepared.lines[0], freezes: freezes).stopsForFreeze)
        var edited = document
        let held = try #require(edited.videoTrack.firstIndex { $0.hold == true })
        let later = try #require(edited.videoTrack.firstIndex { $0.uid == tail.uid })
        edited.videoTrack[held].duration = 4
        edited.videoTrack[later].startTime = 6
        let again = try await DubPreparation.synthesize(document: edited,
            rows: [first.uid: [row(1, 2)], tail.uid: [row(2, 4)]], turns: [:], settings: settings, speech: stub)
        #expect(again.slots[again.lines[0].id] == 1 && again.lines[1].start == 6)
        let parts = DubPauseRules.layout(again.lines[0], freezes: DubFreezes.intervals(in: edited)).segments
        #expect(parts.count == 2 && parts[1].start == 6)
        let overlapping = await DubPreparation.reopening(document: document, scenes: [], settings: settings,
            lines: [across, line(start: 6.8)], speakerNames: [:])
        #expect(overlapping.overlaps.contains(across.id))
    }

    @Test("Exact preview inside/after a freeze preserves the consumed audio offset")
    func window() throws {
        var document = Fixtures.timelineDocument(clips: [hold(start: 2, duration: 3),
            Fixtures.timelineClip(sceneID: nil, sourceStart: 2, duration: 5, startTime: 5)])
        document.dubLines = [line(start: 1, duration: 4)]
        for lower in [3.0, 5.5, 6.0] {
            let window = MultitrackRenderer.windowed(document, from: lower, to: 9)
            let speech = try #require(window.dubLines?.first)
            let parts = DubPauseRules.layout(speech, freezes: DubFreezes.intervals(in: window)).segments
            let audible = try #require(parts.last)
            #expect(abs((audible.audioStart + max(0, -audible.start)) - (lower < 5 ? 1 : lower - 4)) < 1e-9)
            #expect(abs(audible.start + audible.duration - (8 - lower)) < 1e-9)
        }
    }

    @Test("Old pauses are ignored, encoded line bytes stay legacy, cache stores only affected layouts")
    func codingAndCache() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let speech = line()
        let legacy: [String: Any] = ["id": speech.id.uuidString, "clipUID": speech.clipUID.uuidString,
            "speakerKey": "host", "voice": "fixture", "text": "Speech", "sourceStart": 0, "sourceEnd": 4,
            "start": 1, "duration": 4, "rate": 1, "stretch": 1, "tight": false]
        let old = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        #expect(try encoder.encode(speech) == old)
        var rejected = legacy; rejected["pauses"] = [["at": 1, "duration": 2]]
        #expect(try JSONDecoder().decode(DubLine.self, from: JSONSerialization.data(withJSONObject: rejected)) == speech)
        var key = RenderFinishingKey(segments: ["one"], transitions: [], transitionDuration: 0.3,
            overlays: [], settings: RenderSettings(), encoder: [], dubLines: [speech])
        let original = try RenderSegmentCache.key(key)
        key.dubSegments = DubPauseRules.cacheSegments(lines: [speech], freezes: [5..<6])
        #expect(key.dubSegments == nil)
        #expect(try RenderSegmentCache.key(key) == original)
        #expect(!(try #require(JSONSerialization.jsonObject(with: encoder.encode(key)) as? [String: Any])).keys.contains("dubSegments"))
        key.dubSegments = DubPauseRules.cacheSegments(lines: [speech], freezes: [2..<3])
        let paused = try RenderSegmentCache.key(key)
        #expect(paused != original)
        key.dubSegments = DubPauseRules.cacheSegments(lines: [speech], freezes: [3..<4])
        #expect(try RenderSegmentCache.key(key) != paused)
    }

    @Test("Unaffected graph strings stay HEAD-identical; cuts use 10 ms voice/40 ms source ramps")
    func filters() {
        var speech = line(start: 1.25, duration: 4); speech.stretch = 1.1
        let original = "[0:a]atrim=duration=8.000000,asetpts=PTS-STARTPTS[bed];" +
            "[1:a]asetpts=PTS-STARTPTS,atempo=1.100000,aresample=48000,aformat=channel_layouts=stereo,adelay=1250:all=1[line0];" +
            "[bed][line0]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]"
        let unaffected: [[Range<Double>]] = [[], [5.25..<6], [0..<1]]
        for freezes in unaffected {
            #expect(DubMixer.trackFilter(lines: [speech], duration: 8, freezes: freezes) == original)
            #expect(DubPlanning.duckExpression(lines: [speech], level: 0.15, ramp: 0.15, freezes: freezes) ==
                "1-0.850000*(max(0\\,min(1\\,min((t-1.100000)/0.150000\\,(5.400000-t)/0.150000))))")
        }
        let freezes = [2.25..<4.25]
        let graph = DubMixer.trackFilter(lines: [speech], duration: 8, freezes: freezes)
        #expect(graph.contains("afade=t=out:st=0.990000:d=0.010000"))
        #expect(graph.contains("afade=t=in:st=0:d=0.010000"))
        #expect(graph.contains("adelay=204000S:all=1"))
        let settings = DubSettings(language: "en-US", originalLevel: 0.15, replaceOriginal: false)
        let duck = DubMixer.overlayFilter(lines: [speech], settings: settings, freezes: freezes)
        #expect(duck.contains("asetnsamples=n=256:p=0"))
        #expect(duck.contains("(2.250000-t)/0.040000"))
        #expect(duck.contains("(t-4.250000)/0.040000"))
        #expect(!DubMixer.overlayFilter(lines: [speech], settings: settings).contains("asetnsamples"))
        // Stress both per-segment and per-line terms; depth must be logarithmic.
        let many: [Range<Double>] = (0..<1024).map { (index: Int) -> Range<Double> in
            let start = Double(index * 2 + 2)
            return start..<(start + 1)
        }
        let expression = DubPlanning.duckExpression(lines: [line(duration: 1100)], level: 0.15, ramp: 0.15, freezes: many)
        var depth = 0, maximum = 0
        for character in expression {
            if character == "(" { depth += 1; maximum = max(maximum, depth) }
            if character == ")" { depth -= 1 }
        }
        #expect(depth == 0 && maximum < 20)
    }
}
