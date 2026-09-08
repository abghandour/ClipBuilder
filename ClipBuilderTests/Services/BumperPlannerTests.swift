import Foundation
import Testing
@testable import Clip_Builder

@Suite("Bumper planner")
struct BumperPlannerTests {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64 = 7
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func asset(_ name: String, placements: Set<BumperPlacement> = Set(BumperPlacement.allCases)) -> BumperAsset {
        BumperAsset(path: "/\(name).mp4", displayName: name, placements: placements, duration: 2)
    }

    private func document() -> TimelineDocument {
        Fixtures.timelineDocument(clips: (0..<5).map {
            Fixtures.timelineClip(duration: 4, startTime: Double($0 * 4))
        })
    }

    @Test("intro shifts clips, sounds, overlays and crop blocks")
    func intro() throws {
        var doc = document()
        doc.soundTrack = [SoundItem()]
        doc.textOverlays = [TextOverlayItem()]
        doc.imageOverlays = [ImageOverlayItem()]
        doc.overlayBlocks = [OverlayBlockItem()]
        doc.cropBlocks = [CropBlockItem(layout: .fullScreen, startTime: 0, duration: 20)]
        var options = WizardOptions()
        options.includeIntroBumper = true
        var rng = Generator()
        let logs = BumperPlanner.apply(to: &doc, bumpers: [asset("Intro")], options: options, using: &rng)
        let intro = try #require(doc.videoTrack.first(where: { $0.bumper }))
        #expect(intro.startTime == 0)
        #expect(intro.sceneID == nil)
        #expect(intro.sourceStart == 0 && intro.sourceEnd == 2)
        #expect(intro.captions == "none" && !intro.wide && !intro.centerStage)
        #expect(intro.transIn == nil && intro.transOut == nil)
        #expect(doc.videoTrack.filter { !$0.bumper }.map(\.startTime) == [2, 6, 10, 14, 18])
        #expect(doc.soundTrack[0].startTime == 2)
        #expect(doc.textOverlays[0].startTime == 2 && doc.textOverlays[0].endTime == 5)
        #expect(doc.imageOverlays[0].startTime == 2 && doc.imageOverlays[0].endTime == 5)
        #expect(doc.overlayBlocks[0].startTime == 2)
        #expect(doc.cropBlocks.map(\.startTime) == [0, 2])
        #expect(logs.count == 1)
    }

    @Test("middle uses a clip boundary within the middle forty percent")
    func middle() throws {
        var doc = document()
        var options = WizardOptions()
        options.includeMiddleBumper = true
        var rng = Generator()
        _ = BumperPlanner.apply(to: &doc, bumpers: [asset("CTA")], options: options, using: &rng)
        let middle = try #require(doc.videoTrack.first(where: { $0.bumper }))
        #expect([8.0, 12.0].contains(middle.startTime))
        #expect((6.0...14.0).contains(middle.startTime))
        #expect(doc.videoTrack.map { $0.startTime + $0.duration }.max() == 22)
    }

    @Test("middle skips when no eligible boundary exists")
    func noMiddleBoundary() {
        var doc = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(duration: 20)])
        var options = WizardOptions()
        options.includeMiddleBumper = true
        var rng = Generator()
        #expect(BumperPlanner.apply(to: &doc, bumpers: [asset("CTA")], options: options, using: &rng).isEmpty)
    }

    @Test("outro follows the branded outro card")
    func outro() throws {
        var doc = document()
        var card = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2.5, startTime: 20)
        card.videoFile = "/outro_card.mp4"
        doc.videoTrack.append(card)
        var options = WizardOptions()
        options.includeOutroBumper = true
        var rng = Generator()
        _ = BumperPlanner.apply(to: &doc, bumpers: [asset("Outro")], options: options, using: &rng)
        #expect(try #require(doc.videoTrack.first(where: { $0.bumper })).startTime == 22.5)
    }

    @Test("alternatives avoid duplicates and seeded selection is repeatable")
    func distinct() {
        var first = document(), second = document()
        var options = WizardOptions()
        options.includeIntroBumper = true
        options.includeMiddleBumper = true
        options.includeOutroBumper = true
        let assets = [asset("A"), asset("B"), asset("C")]
        var rng = Generator(), repeatRng = Generator()
        _ = BumperPlanner.apply(to: &first, bumpers: assets, options: options, using: &rng)
        _ = BumperPlanner.apply(to: &second, bumpers: assets, options: options, using: &repeatRng)
        let paths = first.videoTrack.filter(\.bumper).compactMap(\.videoFile)
        #expect(paths.count == 3 && Set(paths).count == 3)
        #expect(paths == second.videoTrack.filter(\.bumper).compactMap(\.videoFile))
    }

    @Test("disallowed placements and unknown durations insert nothing")
    func unavailable() {
        var doc = document()
        let before = doc
        var options = WizardOptions()
        options.includeIntroBumper = true
        var rng = Generator()
        let assets = [asset("Outro only", placements: [.outro]),
                      BumperAsset(path: "/broken.mp4", displayName: "Broken", placements: [.intro])]
        #expect(BumperPlanner.apply(to: &doc, bumpers: assets, options: options, using: &rng).isEmpty)
        #expect(doc == before)
    }

    @Test("a crossing secondary track splits with speed-correct source ranges")
    func crossingTrack() throws {
        var doc = document()
        doc.videoTrack.append(Fixtures.timelineClip(sourceStart: 10, duration: 12, track: 1, speed: 2))
        BumperPlanner.insertGap(in: &doc, at: 8, duration: 2)
        let pieces = doc.videoTrack.filter { $0.track == 1 }.sorted { $0.startTime < $1.startTime }
        #expect(pieces.count == 2)
        #expect(pieces[0].duration == 8 && pieces[0].sourceEnd == 26)
        #expect(pieces[1].startTime == 10 && pieces[1].sourceStart == 26 && pieces[1].duration == 4)
    }
}
