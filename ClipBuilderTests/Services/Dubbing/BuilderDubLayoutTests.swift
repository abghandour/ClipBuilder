import Foundation
import Testing
@testable import Clip_Builder

@Suite("Builder dub lane layout")
struct BuilderDubLayoutTests {
    @Test("No lines means no lane; blocks carry freezes, two rows and preparation states")
    func layout() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 1, startTime: 2)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        #expect(BuilderDubLayout.layout(document: document).isEmpty)
        var first = DubLine(clipUID: hold.uid, speakerKey: "a", voice: "voice-a", text: "First",
            sourceStart: 0, sourceEnd: 4, start: 0, duration: 4, tight: true, audio: "a.caf")
        first.draft = true
        let second = DubLine(clipUID: hold.uid, speakerKey: "b", voice: "voice-b", text: "Second",
            sourceStart: 0, sourceEnd: 1, start: 1, duration: 1)
        var third = first
        third.id = UUID(); third.start = 6; third.audio = "missing.caf"
        document.dubLines = [third, second, first]
        let layout = BuilderDubLayout.layout(document: document, missingAudio: ["missing.caf"])
        #expect(layout.rows == 2)
        #expect(layout.blocks.map(\.row) == [0, 1, 0])
        let block = try #require(layout.blocks.first)
        let freezes: [Range<Double>] = [2..<3]
        #expect(block.freezes == freezes)
        #expect(block.duration == 5)
        #expect(block.prepared && block.line.tight && block.line.draft == true)
        #expect(!layout.blocks[1].prepared && !layout.blocks[2].prepared)
        #expect(layout.blocks[1].freezes.isEmpty)
    }

    @Test("A line starting inside a hold has a dimmed leading range")
    func startsInside() throws {
        var hold = Fixtures.timelineClip(sceneID: nil, duration: 2, startTime: 1)
        hold.hold = true; hold.pauseGroup = hold.uid
        var document = Fixtures.timelineDocument(clips: [hold])
        document.dubLines = [DubLine(clipUID: hold.uid, speakerKey: "a", voice: "v", text: "Text",
            sourceStart: 0, sourceEnd: 1, start: 2, duration: 1)]
        let block = try #require(BuilderDubLayout.layout(document: document).blocks.first)
        let freezes: [Range<Double>] = [2..<3]
        #expect(block.freezes == freezes)
        #expect(block.duration == 2)
    }
}
