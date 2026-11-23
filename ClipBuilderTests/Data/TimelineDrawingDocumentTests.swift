import CoreGraphics
import Foundation
import Testing
@testable import Clip_Builder

@MainActor
@Suite("Timeline drawing document persistence")
struct TimelineDrawingDocumentTests {
    @Test("A store-made drawn hold round trips in its document without a reel freeze marker")
    func roundTrip() throws {
        let clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 4, speed: 2)
        let model = ScriptFixtures.model(clips: [clip])
        let drawing = Telestration(figures: [.init(kind: .oval,
            points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.8)])], stay: 7.3)
        let uid = try model.drawOnPause(clip.uid, at: 1, drawing: drawing).get()
        let original = try #require(model.clip(uid))
        let restored = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(model.document))
        #expect(restored.videoTrack.count == 3)
        let hold = try #require(restored.videoTrack.first { $0.hold == true })
        #expect(hold.telestration == original.telestration)
        #expect(abs(hold.duration - drawing.duration) < 1e-9)
        #expect(abs(try #require(hold.sourceStart) - 12) < 1e-9)
        #expect(abs(try #require(hold.sourceEnd) - (try #require(hold.sourceStart))) < 1e-9)
        #expect(hold.speed == nil)
        #expect(restored.videoTrack.allSatisfy { $0.strikeImpactsFrozen == nil })
        for (saved, decoded) in zip(model.document.videoTrack, restored.videoTrack) {
            #expect(abs(saved.startTime - decoded.startTime) < 1e-9)
            #expect(abs(saved.duration - decoded.duration) < 1e-9)
            #expect(saved.videoFile == decoded.videoFile && saved.originKey == decoded.originKey)
        }
        try model.setDrawing(uid, drawing: nil).get()
        let cleared = try #require(model.clip(uid))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        #expect(json["telestration"] == nil && json["strike_impacts_frozen"] == nil)
        let plain = try JSONDecoder().decode(TimelineDocument.self, from: JSONEncoder().encode(model.document))
        let plainHold = try #require(plain.videoTrack.first { $0.hold == true })
        #expect(plainHold.telestration == nil && abs(plainHold.duration - 5) < 1e-9)
    }
}
