import Foundation
import Testing
@testable import Clip_Builder

@Suite("Timeline document")
struct TimelineDocumentTests {
    @Test("regression: playback speed survives save and load", arguments: [0.5, 1.0, 2.0])
    func playbackSpeedRoundTrip(speed: Double) throws {
        let original = Fixtures.timelineClip(sceneID: nil, sourceStart: 3, duration: 4, speed: speed)
        let data = try JSONEncoder().encode(Fixtures.timelineDocument(clips: [original]))
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)
        let clip = try #require(decoded.videoTrack.first)

        #expect(clip.speed == speed)
        #expect(clip.duration == original.duration)
        #expect(clip.sourceStart == original.sourceStart)
        #expect(clip.sourceEnd == original.sourceStart! + original.sourceSpan)
        #expect(clip.sourceSpan == original.sourceSpan)
        #expect(clip.startTime + clip.duration == original.startTime + original.duration)
    }

    @Test("custom timeline items preserve their encoded fields")
    func customItemRoundTrips() throws {
        var document = Fixtures.timelineDocument()
        document.soundTrack = [SoundItem(name: "music.wav", volume: 4, startTime: 1, duration: 8)]
        document.textOverlays = [TextOverlayItem(text: "Hello", startTime: 1, endTime: 3)]
        document.imageOverlays = [ImageOverlayItem(path: "/tmp/logo.png", startTime: 2, endTime: 5)]
        document.trackSettings[0] = TrackSettings(muted: true, defaultPosition: "center", captions: "top", defaultCropXFrac: 0.25)
        document.cropBlocks = [CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 5)]

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(TimelineDocument.self, from: data)

        #expect(decoded.soundTrack.first?.name == "music.wav")
        #expect(decoded.soundTrack.first?.volume == 4)
        #expect(decoded.textOverlays.first?.text == "Hello")
        #expect(decoded.imageOverlays.first?.path == "/tmp/logo.png")
        #expect(decoded.trackSettings[0].muted)
        #expect(decoded.trackSettings[0].defaultCropXFrac == 0.25)
        #expect(decoded.cropBlocks.first?.layout == CropLayoutRef(name: "50-50 Horizontal"))
    }

    @Test("crop blocks tile gaps and resolve overlaps")
    func normalizeCropBlocks() {
        var document = TimelineDocument()
        let first = CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 1, duration: 4)
        let winner = CropBlockItem(layout: CropLayoutRef(name: "33-33-33 Horizontal"), startTime: 3, duration: 3)
        document.cropBlocks = [first, winner]
        document.normalizeCropBlocks(winner: winner.uid, minimumEnd: 8)

        #expect(document.cropBlocks.first?.startTime == 0)
        #expect(document.cropBlocks.last?.endTime == 8)
        #expect(document.cropBlock(at: 4)?.layout == winner.layout)
        #expect(document.hasArea(track: 2, at: 4))

        var orphan = Fixtures.timelineClip(startTime: 6.5, track: 1)
        orphan.duration = 1
        #expect(document.isOrphaned(orphan))
    }

    @Test("legacy crop references migrate to the cropping row")
    func migrateLegacyScreenCrops() {
        var clip = Fixtures.timelineClip(startTime: 0)
        clip.screenCrop = "50-50 Horizontal/Bottom"
        var document = Fixtures.timelineDocument(clips: [clip])
        document.migrateLegacyScreenCrops()

        #expect(!document.cropBlocks.isEmpty)
        #expect(document.videoTrack[0].track == 1)
        #expect(document.videoTrack[0].screenCrop == nil)
        #expect(CropLayoutRef.resolve(reference: "50-50 Horizontal/Top")?.1 == 0)
        #expect(CropLayoutRef.resolve(reference: "missing/area") == nil)
    }

    @Test("overlay blocks expand inside their timeline window")
    func expandingOverlayBlocks() {
        var template = TextOverlayItem(text: "Title", startTime: 0.5, endTime: 99)
        template.unbounded = true
        var block = OverlayBlockItem()
        block.name = "Card"
        block.startTime = 4
        block.duration = 3
        block.composition = OverlayComposition(texts: [template], images: [])
        var document = TimelineDocument()
        document.overlayBlocks = [block]

        let expanded = document.expandingOverlayBlocks()
        #expect(expanded.overlayBlocks.isEmpty)
        #expect(expanded.textOverlays.first?.startTime == 4.5)
        #expect(expanded.textOverlays.first?.endTime == 7)
    }
}
