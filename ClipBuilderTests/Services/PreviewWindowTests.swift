import Foundation
import Testing
@testable import Clip_Builder

@Suite("Preview window: 5 s of final footage from the playhead")
struct PreviewWindowTests {
    @Test("the window follows the playhead and stays inside the timeline")
    func range() {
        #expect(AppStore.exactPreviewRange(from: 4, seconds: 5, totalDuration: 14) == 4...9)
        #expect(AppStore.exactPreviewRange(from: 12, seconds: 5, totalDuration: 14) == 9...14)
        #expect(AppStore.exactPreviewRange(from: -3, seconds: 5, totalDuration: 14) == 0...5)
        #expect(AppStore.exactPreviewRange(from: 1, seconds: 5, totalDuration: 3) == 0...3)
        #expect(AppStore.exactPreviewRange(from: 0, seconds: 5, totalDuration: 0) == 0...0)
    }

    @Test("clips, overlays, blocks and sound are trimmed and rebased; the song keeps its place")
    func windowed() {
        var doc = Fixtures.timelineDocument(clips: [
            Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, startTime: 0),   // 0–6
            Fixtures.timelineClip(sceneID: nil, sourceStart: 20, duration: 6, startTime: 6),   // 6–12
            Fixtures.timelineClip(sceneID: nil, sourceStart: 30, duration: 4, startTime: 12),  // 12–16
        ])
        doc.videoTrack[1].speed = 2 // source runs twice as fast in the second clip
        doc.soundTrack = [SoundItem(name: "song", volume: 3, startTime: 2, duration: 12, sourceOffset: 1)]
        var text = TextOverlayItem(); text.startTime = 3; text.endTime = 9
        doc.textOverlays = [text]
        var image = ImageOverlayItem(); image.startTime = 8; image.endTime = 20
        doc.imageOverlays = [image]
        doc.cropBlocks = [CropBlockItem(layout: .init(name: "Full Screen"), startTime: 0, duration: 16)]

        let window = MultitrackRenderer.windowed(doc, from: 4, to: 9)

        #expect(window.videoTrack.count == 2)
        #expect(window.videoTrack[0].startTime == 0 && window.videoTrack[0].duration == 2)
        #expect(window.videoTrack[0].sourceStart == 14)          // 10 + 4 s into the clip at speed 1
        #expect(window.videoTrack[1].startTime == 2 && window.videoTrack[1].duration == 3)
        #expect(window.videoTrack[1].sourceStart == 20)          // starts at its own start, untouched
        #expect(window.soundTrack.count == 1)
        #expect(window.soundTrack[0].startTime == 0 && window.soundTrack[0].duration == 5)
        #expect(window.soundTrack[0].sourceOffset == 3)          // 1 already + 2 s cut from the front
        #expect(window.textOverlays[0].startTime == 0 && window.textOverlays[0].endTime == 5)
        #expect(window.imageOverlays[0].startTime == 4 && window.imageOverlays[0].endTime == 5)
        #expect(window.cropBlocks[0].startTime == 0 && window.cropBlocks[0].duration == 5)
    }

    @Test("a straddling clip is trimmed with speed applied to its source position")
    func speed() {
        var clip = Fixtures.timelineClip(sceneID: nil, sourceStart: 10, duration: 6, startTime: 0)
        clip.speed = 2
        let window = MultitrackRenderer.windowed(Fixtures.timelineDocument(clips: [clip]), from: 2, to: 4)
        #expect(window.videoTrack[0].sourceStart == 14)          // 2 timeline seconds = 4 source seconds
        #expect(window.videoTrack[0].duration == 2)
    }

    @Test("bumpers keep the overlapping part of their span")
    func bumpers() {
        var bumper = Fixtures.timelineClip(sceneID: nil, sourceStart: 0, duration: 2, startTime: 5)
        bumper.bumper = true; bumper.videoFile = "/bumper.mp4"
        let doc = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: nil, duration: 10, startTime: 0), bumper])
        let window = MultitrackRenderer.windowed(doc, from: 6, to: 11)
        let kept = window.videoTrack.first { $0.bumper }
        #expect(kept?.startTime == 0 && kept?.duration == 1 && kept?.sourceStart == 1)
    }

    @Test("sound items persist their offset only when set")
    func soundItemCodable() throws {
        let plain = SoundItem(name: "song", volume: 3, startTime: 1, duration: 2)
        let json = try String(decoding: JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("source_offset"))
        let offset = SoundItem(name: "song", volume: 3, startTime: 1, duration: 2, sourceOffset: 4.5)
        let decoded = try JSONDecoder().decode(SoundItem.self, from: JSONEncoder().encode(offset))
        #expect(decoded.sourceOffset == 4.5)
        let legacy = try JSONDecoder().decode(SoundItem.self, from: Data(#"{"name":"song","volume":3,"start_time":1,"duration":2}"#.utf8))
        #expect(legacy.sourceOffset == 0)
    }

    @Test("the fast preview and the trimmed-edge path both carry the song offset")
    @MainActor func previewPlanOffset() throws {
        var doc = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: nil, duration: 10, startTime: 0)])
        doc.soundTrack = [SoundItem(name: "song", volume: 3, startTime: 0, duration: 10, sourceOffset: 7)]
        let scope = try DataFolderOverride()
        _ = scope
        let model = BuilderTimelineModel()
        model.loadDocument(doc)
        let plan = model.previewPlan(musicLookup: ["song": URL(fileURLWithPath: "/song.mp3")])
        #expect(plan.music.map(\.sourceOffset) == [7])
        let trimmed = MultitrackRenderer.windowed(doc, from: 3, to: 10)
        #expect(trimmed.soundTrack[0].sourceOffset == 10)
    }
}

@Suite("Preview slices: overlays at the cut and cache keys")
struct PreviewSliceTests {
    @Test("overlay blocks are expanded before the cut, so items after the cut survive; clipped animations settle")
    func overlayBlocks() {
        var doc = Fixtures.timelineDocument(clips: [Fixtures.timelineClip(sceneID: nil, duration: 10, startTime: 0)])
        var late = TextOverlayItem(); late.text = "late"; late.startTime = 2; late.endTime = 3   // block-relative
        var early = TextOverlayItem(); early.text = "early"; early.startTime = 0; early.endTime = 6
        var block = OverlayBlockItem(); block.startTime = 1; block.duration = 6
        block.composition.texts = [late, early]
        doc.overlayBlocks = [block]
        let window = MultitrackRenderer.windowed(doc, from: 2, to: 7)
        #expect(window.overlayBlocks.isEmpty)
        let texts = Dictionary(uniqueKeysWithValues: window.textOverlays.map { ($0.text, $0) })
        #expect(texts["late"]?.startTime == 1 && texts["late"]?.endTime == 2)     // absolute 3–4 → 1–2
        #expect(texts["late"]?.transIn == "fade")                                // starts inside: animates in
        #expect(texts["early"]?.startTime == 0 && texts["early"]?.endTime == 5)   // absolute 1–7 → 0–5
        #expect(texts["early"]?.transIn == "cut" && texts["early"]?.transOut == "fade")
    }

    @Test("the slice key ignores changes outside the window and reacts to changes inside it")
    func key() {
        let doc = Fixtures.timelineDocument(clips: [
            Fixtures.timelineClip(sourceStart: 0, duration: 5, startTime: 0),
            Fixtures.timelineClip(sourceStart: 20, duration: 5, startTime: 5),
        ])
        let scenes = [Fixtures.scene()]
        let profile = Fixtures.brand()
        func key(_ document: TimelineDocument, _ window: ClosedRange<Double>) -> String? {
            AppStore.builderPreviewKey(document: document, scenes: scenes, profile: profile, camera: "balanced", window: window)
        }
        let base = key(doc, 0...5)
        #expect(base != nil)
        #expect(key(doc, 0...5) == base)                                  // stable across calls
        var later = doc; later.videoTrack[1].sourceStart = 30
        #expect(key(later, 0...5) == base)                                 // change after the window
        #expect(key(later, 5...10) != key(doc, 5...10))                    // …is a change for that window
        var inside = doc; inside.videoTrack[0].sourceStart = 1
        #expect(key(inside, 0...5) != base)
        var music = doc; music.soundTrack = [SoundItem(name: "song", volume: 3, startTime: 0, duration: 10)]
        #expect(key(music, 0...5) != base)
        var text = doc; var overlay = TextOverlayItem(); overlay.startTime = 7; overlay.endTime = 9; text.textOverlays = [overlay]
        #expect(key(text, 0...5) == base)                                  // overlay outside the window
        #expect(key(text, 5...10) != key(doc, 5...10))
        var otherScene = scenes[0]; otherScene.centerStagePathJSON = "{}"
        #expect(AppStore.builderPreviewKey(document: doc, scenes: [otherScene], profile: profile, camera: "balanced", window: 0...5) != base)
    }
}
