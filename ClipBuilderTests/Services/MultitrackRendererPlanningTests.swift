import Testing
@testable import Clip_Builder

@Suite("Multitrack renderer planning")
struct MultitrackRendererPlanningTests {
    @Test("clip resolution applies track settings and drops missing scenes")
    func resolveClips() {
        var valid = Fixtures.timelineClip(sceneID: 1, sourceStart: 2, duration: 4, track: 0, speed: 0.5)
        valid.position = nil
        valid.captions = "inherit"
        var missing = Fixtures.timelineClip(sceneID: 999, track: 1)
        missing.videoFile = nil
        missing.sourceStart = nil
        var document = Fixtures.timelineDocument(clips: [valid, missing])
        document.trackSettings[0] = TrackSettings(muted: true, defaultPosition: "center", captions: "bottom")

        let resolved = MultitrackRenderer.resolveClips(document: document, scenes: [Fixtures.scene()])
        #expect(resolved.count == 1)
        #expect(resolved[0].muted)
        #expect(resolved[0].effectivePosition == "center")
        #expect(resolved[0].captionsPosition == "bottom")
        #expect(resolved[0].speed == 0.5)
    }

    @Test("layered segments represent overlaps and omit gaps")
    func layeredSegments() {
        let clips = [
            resolved(start: 0, duration: 3, track: 0),
            resolved(start: 2, duration: 3, track: 1),
            resolved(start: 7, duration: 1, track: 0),
        ]
        let segments = MultitrackRenderer.buildLayeredSegments(clips)
        #expect(segments.map(\.start) == [0, 2, 3, 7])
        #expect(segments.map(\.end) == [2, 3, 5, 8])
        #expect(segments[1].clips.count == 2)
    }

    @Test("crop blocks split clips and discard tracks without an area")
    func cropBlocks() {
        var document = TimelineDocument()
        document.cropBlocks = [
            CropBlockItem(layout: CropLayoutRef(name: "50-50 Horizontal"), startTime: 0, duration: 2),
            CropBlockItem(layout: .fullScreen, startTime: 2, duration: 2),
        ]
        let trackZero = resolved(start: 0, duration: 4, track: 0)
        let trackOne = resolved(start: 0, duration: 4, track: 1)
        let pieces = MultitrackRenderer.applyCropBlocks([trackZero, trackOne], document: document)
        #expect(pieces.filter { $0.track == 0 }.count == 2)
        #expect(pieces.filter { $0.track == 1 }.count == 1)
        #expect(pieces.first { $0.track == 1 }?.duration == 2)
    }

    private func resolved(start: Double, duration: Double, track: Int) -> MultitrackRenderer.ResolvedClip {
        MultitrackRenderer.ResolvedClip(
            sourcePath: "/tmp/fixture.mp4", videoID: 1, sourceStart: 0,
            startTime: start, duration: duration, track: track, wide: false,
            muted: false, transIn: nil, transOut: nil, effectivePosition: "center",
            effectiveCropXFrac: nil, freeCrops: nil, screenCrop: nil,
            areaWindow: nil, captionsPosition: nil
        )
    }
}
